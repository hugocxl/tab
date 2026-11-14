import Foundation
import TabProtocol

/// Worktree snapshots use an isolated index, as in the source renderer's GitVcsDriver. Never reset,
/// stash, checkout, or stage through the user's index. Call from a blocking worker.
struct AgentCheckpointStore: Sendable {
    struct Snapshot: Codable, Hashable, Sendable {
        var tree: String
        var reference: String
        var directory: String
    }


    private let git = GitCommand()
    private let config = ["-c", "core.fsmonitor=false", "-c", "core.splitIndex=false",
                          "-c", "core.untrackedCache=false", "-c", "core.sparseCheckout=false"]

    func capture(directory: String) throws -> Snapshot {
        let root = try git.text(directory, ["rev-parse", "--show-toplevel"])
        let index = try git.text(directory, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
        let temporary = URL(fileURLWithPath: index).deletingLastPathComponent()
            .appendingPathComponent("tab-checkpoint-index-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(atPath: temporary.path + ".lock")
        }
        let environment = ["GIT_INDEX_FILE": temporary.path]
        // The last capture's index for this folder knows the files earlier turns changed,
        // so only what changed since is hashed again rather than everything unstaged.
        let cache = URL(fileURLWithPath: index).deletingLastPathComponent()
            .appendingPathComponent("tab-checkpoint-index-" + Self.folderKey(directory))
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.copyItem(at: cache, to: temporary)
        } else if FileManager.default.fileExists(atPath: index) {
            try FileManager.default.copyItem(atPath: index, toPath: temporary.path)
        } else {
            try git.run(root, config + ["read-tree", "--empty"], environment: environment)
        }
        // Stage from the project directory, preserving other files in a parent
        // repository. The real index (including conflicts) remains untouched.
        try git.run(directory, config + ["add", "--all", "--", "."], environment: environment)
        let tree = try git.text(root, config + ["write-tree"], environment: environment)
        let staged = temporary.appendingPathExtension("next")
        if (try? FileManager.default.copyItem(at: temporary, to: staged)) != nil,
           (try? FileManager.default.replaceItemAt(cache, withItemAt: staged)) == nil {
            try? FileManager.default.moveItem(at: staged, to: cache)
            try? FileManager.default.removeItem(at: staged)
        }
        let reference = "refs/tab/checkpoints/" + UUID().uuidString.lowercased()
        try git.run(root, ["update-ref", reference, tree])
        return Snapshot(tree: tree, reference: reference, directory: directory)
    }

    /// A short stable name for a folder, for its cached checkpoint index.
    static func folderKey(_ directory: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in directory.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return String(hash, radix: 16)
    }

    /// Summary capture needs only numstat; detailed patches are read on demand.
    func files(from before: Snapshot, to after: Snapshot) throws -> [AgentTurnCheckpoint.File] {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let stats = try git.run(before.directory, ["diff", "--numstat", "-z", "--no-renames",
                                                  "--relative", before.tree, after.tree, "--", "."])
        return stats.split(separator: 0).compactMap { record in
            let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return .init(path: String(decoding: fields[2], as: UTF8.self),
                         additions: UInt64(String(decoding: fields[0], as: UTF8.self)),
                         deletions: UInt64(String(decoding: fields[1], as: UTF8.self)))
        }
    }

    func diff(from before: Snapshot, to after: Snapshot, path: String) throws -> GitDiff {
        guard before.directory == after.directory else { throw gitError("Checkpoint directories differ") }
        let (data, truncated) = try git.diff(before.directory,
            ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--relative",
             "--src-prefix=a/", "--dst-prefix=b/", "--unified=3", before.tree, after.tree, "--", path], noIndex: false)
        return GitParsing.diff(GitRawDiff(diff: String(decoding: data, as: UTF8.self), truncated: truncated))
    }

    /// A file as a tree holds it: its mode and blob, or nil when the tree doesn't have it.
    struct Entry: Equatable, Sendable {
        var mode: String
        var blob: String
    }

    /// `path`, relative to the snapshot's directory, in `tree`.
    func entry(in tree: String, path: String, directory: String) throws -> Entry? {
        let output = try git.run(directory, ["ls-tree", "-z", tree, "--", path])
        guard let record = output.split(separator: 0).first,
              let tab = record.firstIndex(of: 9) else { return nil }
        let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
        guard fields.count == 3, fields[1] == "blob" else {
            throw gitError("\(path) is not a file in this checkpoint")
        }
        return Entry(mode: String(fields[0]), blob: String(fields[2]))
    }

    /// The working copy of `path` as Git would store it now, or nil when it is gone.
    func current(path: String, directory: String) throws -> Entry? {
        let url = try Self.file(path, in: directory)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let hash = try git.run(directory, ["hash-object", "--stdin"], input: Data(target.utf8))
            return Entry(mode: "120000", blob: String(decoding: hash, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else { return Entry(mode: "040000", blob: "") }
        let executable = ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o111 != 0
        return Entry(mode: executable ? "100755" : "100644", blob: try git.text(directory, ["hash-object", "--", path]))
    }

    /// The paths among `paths` whose working copy no longer matches the turn's after state.
    func changedSince(_ after: Snapshot, paths: [String]) throws -> [String] {
        try paths.filter { path in
            let expected = try entry(in: after.tree, path: path, directory: after.directory)
            let now = try current(path: path, directory: after.directory)
            return expected?.blob != now?.blob || (expected != nil && now != nil && Self.executable(expected) != Self.executable(now))
        }
    }

    /// Puts each of `paths` back as the `before` snapshot had it: its content and mode, or
    /// removes a file the turn added. Only the working copies of those paths change; the
    /// index, branches and every other file are left alone.
    func restore(_ before: Snapshot, paths: [String]) throws {
        // Check every path before changing any, so a refusal leaves nothing half reverted.
        let targets = try paths.map { path -> (path: String, url: URL) in
            let url = try Self.file(path, in: before.directory)
            if (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory {
                throw gitError("\(path) is a folder now, so it was left alone")
            }
            return (path, url)
        }
        for (path, url) in targets {
            let entry = try entry(in: before.tree, path: path, directory: before.directory)
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                try FileManager.default.removeItem(at: url)
            }
            guard let entry else { continue }
            let data = try git.run(before.directory, ["cat-file", "blob", entry.blob])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if entry.mode == "120000" {
                try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: String(decoding: data, as: UTF8.self))
                continue
            }
            guard entry.mode.hasPrefix("100") else { throw gitError("\(path) can't be restored from this checkpoint") }
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: entry.mode == "100755" ? 0o755 : 0o644], ofItemAtPath: url.path)
        }
    }

    private static func executable(_ entry: Entry?) -> Bool { entry?.mode == "100755" }

    /// `path` inside `directory`; anything that would leave it is refused.
    static func file(_ path: String, in directory: String) throws -> URL {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/").contains(".."), url.path.hasPrefix(root.path + "/") else {
            throw AgentRuntimeError("\(path) is outside this project")
        }
        // A folder on the way that became a symbolic link must not lead out of the project.
        let realRoot = root.resolvingSymlinksInPath().path
        let realParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard realParent == realRoot || realParent.hasPrefix(realRoot + "/") else {
            throw AgentRuntimeError("\(path) is outside this project")
        }
        return url
    }

    func remove(_ snapshot: Snapshot) throws {
        let prefix = "refs/tab/checkpoints/"
        guard snapshot.reference.hasPrefix(prefix),
              UUID(uuidString: String(snapshot.reference.dropFirst(prefix.count))) != nil,
              [40, 64].contains(snapshot.tree.count), snapshot.tree.allSatisfy(\.isHexDigit) else {
            throw gitError("Invalid private checkpoint reference")
        }
        guard git.optionalText(snapshot.directory, ["rev-parse", "--verify", snapshot.reference]) != nil else { return }
        // Expected-value deletion cannot remove a ref somebody replaced.
        try git.run(snapshot.directory, ["update-ref", "-d", snapshot.reference, snapshot.tree])
    }
}

/// Detailed comparisons stay server-side; transcript summaries can be bounded
/// without losing the full checkpoint or coupling history size to diff size.
struct AgentCheckpointRecord: Codable, Sendable {
    var before: AgentCheckpointStore.Snapshot
    var after: AgentCheckpointStore.Snapshot
    var files: [AgentTurnCheckpoint.File]
}

struct AgentCheckpointPending: Codable, Sendable {
    var turnID: String
    var before: AgentCheckpointStore.Snapshot
}

extension AgentCheckpointRecord {
    func summary(id: String) -> AgentTurnCheckpoint {
        let visible = Array(files.filter { $0.path.utf8.count <= 1024 }.prefix(64))
        return AgentTurnCheckpoint(id: id, files: visible, totalFiles: files.count,
            additions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }, truncated: visible.count != files.count)
    }
}
