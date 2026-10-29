import Darwin
import Foundation
import TabProtocol

/// Commit exactly what the user reviewed: changes are previewed through a
/// temporary index and committed only while the working tree still matches.
extension GitRepository {
    static let previewFileLimit = 4096

    /// Every change, or with `staged` only what the index holds.
    func preview(lineLimit: UInt32?, staged: Bool) throws -> GitChangesPreview {
        let status = try status()
        if status.files.contains(where: \.isConflicted) {
            throw gitError("Resolve merge conflicts before committing")
        }
        let untracked = Set(status.files.filter(\.isUntracked).map(\.path.rawValue))
        let tree = staged ? try stagedSnapshot() : try snapshot()
        let base = try status.branch.oid ?? git.text(path, ["hash-object", "-t", "tree", "/dev/null"])
        let (bytes, truncated) = try git.diff(path, [
            "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--src-prefix=a/",
            "--dst-prefix=b/", base, tree, "--",
        ], noIndex: false)
        let files = try previewFiles(base: base, tree: tree, untracked: untracked)
        let destination = try status.branch.head.flatMap { try self.destination(branch: $0) }
        return GitChangesPreview(branch: status.branch.head, head: status.branch.oid, tree: tree,
                                 diff: GitParsing.bounded(bytes, truncated: truncated, lineLimit: lineLimit),
                                 files: files, destination: destination)
    }

    func commitAll(message: String, expectedHead: String?, expectedTree: String) throws -> String {
        try ensureCommittable(expectedHead: expectedHead)
        if try snapshot() != expectedTree {
            throw gitError("Files changed after the draft was made; review the changes again")
        }
        let staging = try TemporaryIndex(repository: self)
        try git.run(path, ["add", "-A"])
        do {
            try commitIndex(message: message, expectedTree: expectedTree)
        } catch let cause as ServiceError {
            do {
                try staging.restore()
            } catch {
                throw gitError("\(cause.message). All changes were left staged")
            }
            throw cause
        }
        return try git.text(path, ["rev-parse", "HEAD"])
    }

    func commitStaged(message: String, expectedHead: String?, expectedTree: String) throws -> String {
        try ensureCommittable(expectedHead: expectedHead)
        if try stagedSnapshot() != expectedTree {
            throw gitError("Staged changes changed after the draft was made; review the changes again")
        }
        try commitIndex(message: message, expectedTree: expectedTree)
        return try git.text(path, ["rev-parse", "HEAD"])
    }

    private func ensureCommittable(expectedHead: String?) throws {
        let summary = try summary()
        if summary.branch == nil { throw gitError("Switch to a branch before committing") }
        if summary.head != expectedHead {
            throw gitError("The branch moved after the draft was made; review the changes again")
        }
        if summary.conflicted > 0 { throw gitError("Resolve merge conflicts before committing") }
    }

    private func commitIndex(message: String, expectedTree: String) throws {
        if try git.text(path, ["write-tree"]) != expectedTree {
            throw gitError("Files changed while committing; review the changes again")
        }
        do {
            try git.run(path, ["commit", "-m", message.trimmingCharacters(in: .whitespacesAndNewlines)])
        } catch let error as ServiceError {
            throw Self.explainIdentity(error)
        }
    }

    /// Pull request checkouts push to their pull request head. Other branches
    /// push to a same-named upstream, or to the same name on origin.
    func destination(branch: String) throws -> GitPushDestination? {
        let upstream = upstream(of: branch)
        if config(Self.pullRequestKey(branch)) != nil { return upstream }
        if let upstream, upstream.branch == branch { return upstream }
        if config("remote.origin.url") == nil { return nil }
        try validateBranch(branch)
        return GitPushDestination(remote: "origin", branch: branch)
    }

    func publish(branch: String, expected: GitPushDestination) throws {
        if try summary().branch != branch {
            throw gitError("The current branch changed; review the changes again")
        }
        guard let destination = try destination(branch: branch) else { throw gitError("No remote to push to") }
        if destination != expected {
            throw gitError("The push destination changed to \(destination.remote)/\(destination.branch); "
                + "review the changes again")
        }
        try validateBranch(destination.branch)
        var arguments = ["push"]
        if upstream(of: branch) != destination { arguments.append("--set-upstream") }
        arguments += ["--", destination.remote, "HEAD:refs/heads/\(destination.branch)"]
        try git.network(path, arguments)
    }

    func switchToBase(_ base: String) throws -> GitBaseSwitch {
        try validateBranch(base)
        if try summary().branch != base {
            let here = canonical(path)
            if let elsewhere = try worktrees().first(where: {
                $0.branch == base && canonical($0.directory.rawValue) != here
            }) {
                return .checkedOutElsewhere(elsewhere.directory)
            }
            do {
                try git.run(path, ["switch", "--", base])
            } catch let cause as ServiceError {
                throw gitError("Couldn't switch to \(base): \(cause.message)")
            }
        }
        do {
            try git.network(path, ["pull", "--ff-only"])
        } catch let cause as ServiceError {
            throw gitError("Switched to \(base), but couldn't fast-forward it: \(cause.message)")
        }
        return .updated
    }

    func upstream(of branch: String) -> GitPushDestination? {
        guard let remote = config("branch.\(branch).remote"), remote != ".",
              let merge = config("branch.\(branch).merge"), merge.hasPrefix("refs/heads/") else { return nil }
        return GitPushDestination(remote: remote, branch: String(merge.dropFirst(11)))
    }

    private func snapshot() throws -> String {
        let index = try TemporaryIndex(repository: self)
        let environment = ["GIT_INDEX_FILE": index.path]
        try git.run(path, ["add", "-A"], environment: environment)
        return try git.text(path, ["write-tree"], environment: environment)
    }

    private func stagedSnapshot() throws -> String {
        let index = try TemporaryIndex(repository: self)
        return try git.text(path, ["write-tree"], environment: ["GIT_INDEX_FILE": index.path])
    }

    private func previewFiles(base: String, tree: String, untracked: Set<String>) throws -> [GitPreviewFile] {
        let output = try git.run(path, ["diff", "--numstat", "-z", "--no-renames", base, tree, "--"])
        var files: [GitPreviewFile] = []
        for record in GitParsing.records(output) {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw gitError("Invalid Git change summary") }
            let path = String(fields[2])
            files.append(GitPreviewFile(path: ServerPath(path), added: UInt64(fields[0]), removed: UInt64(fields[1]),
                                        untracked: untracked.contains(path)))
            if files.count > Self.previewFileLimit {
                throw gitError("More than \(Self.previewFileLimit) changed files; narrow changes using Git")
            }
        }
        return files
    }
}

/// A copy of the repository's index, removed when released.
final class TemporaryIndex {
    let path: String
    private let index: String

    private static let counter = Counter()

    init(repository: GitRepository) throws {
        index = try repository.gitPath("index")
        path = try repository.gitPath("tab-preview-\(getpid())-\(Self.counter.next()).index")
        if FileManager.default.fileExists(atPath: index) {
            do {
                try FileManager.default.copyItem(atPath: index, toPath: path)
            } catch {
                throw gitError("Couldn't copy the Git index: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        unlink(path)
        unlink(path + ".lock")
    }

    /// Puts this copy back as the repository index. Taking Git's index lock
    /// first means a concurrent Git command is never overwritten.
    func restore() throws {
        let lock = index + ".lock"
        let descriptor = open(lock, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw gitError("The Git index is locked") }
        var restored = false
        if let copy = FileManager.default.contents(atPath: path) {
            restored = Self.writeAll(copy, to: descriptor) && fsync(descriptor) == 0
            close(descriptor)
            restored = restored && rename(lock, index) == 0
        } else {
            close(descriptor)
            restored = unlink(index) == 0 && unlink(lock) == 0
        }
        if !restored {
            unlink(lock)
            throw gitError("Couldn't restore the Git index")
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return true }
            var remaining = buffer.count
            while remaining > 0 {
                let written = write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }

    final class Counter: @unchecked Sendable {
        private var value: UInt64 = 0
        private let lock = NSLock()

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }
}
