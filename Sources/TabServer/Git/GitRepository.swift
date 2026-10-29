import Darwin
import Foundation
import TabProtocol

/// Reads and changes one repository working tree.
struct GitRepository: Sendable {
    let path: String
    let git: GitCommand

    init(path: String, git: GitCommand) {
        self.path = path
        self.git = git
    }

    // MARK: - Probing

    func isRepository() throws -> Bool {
        do {
            return try git.text(path, ["rev-parse", "--is-inside-work-tree"]) == "true"
        } catch let error as ServiceError where error.message.contains("not a git repository") {
            return false
        }
    }

    /// The working tree's top folder.
    func topLevel() throws -> String {
        try git.text(path, ["rev-parse", "--show-toplevel"])
    }

    /// An absolute path from `rev-parse --path-format=absolute <flag>`.
    func absolute(_ flag: String) throws -> String {
        try git.text(path, ["rev-parse", "--path-format=absolute", flag])
    }

    /// The canonical shared `.git` folder, which keys repository locks.
    func commonDirectory() throws -> String {
        canonical(try absolute("--git-common-dir"))
    }

    /// `rev-parse --git-path <name>` as an absolute path.
    func gitPath(_ name: String) throws -> String {
        let value = try git.text(path, ["rev-parse", "--git-path", name])
        return value.hasPrefix("/") ? value : (path as NSString).appendingPathComponent(value)
    }

    func config(_ key: String) -> String? {
        guard let value = git.optionalText(path, ["config", "--get", key]), !value.isEmpty else { return nil }
        return value
    }

    func validateBranch(_ branch: String) throws {
        if branch.hasPrefix("-") || (branch.contains("@") && branch.contains("{")) {
            throw gitError("Invalid branch name")
        }
        try git.run(path, ["check-ref-format", "--branch", branch])
    }

    // MARK: - Status

    func statusOutput() throws -> Data {
        try git.run(path, ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"])
    }

    func status() throws -> GitParsing.Status {
        try GitParsing.status(try statusOutput())
    }

    func files() throws -> [GitFile] {
        try status().files
    }

    func summary() throws -> GitSummary {
        let status = try status()
        var summary = GitSummary(branch: status.branch.head, head: status.branch.oid,
                                 upstream: status.branch.tracked ? status.branch.upstream : nil)
        if status.branch.tracked {
            summary.ahead = status.branch.ahead
            summary.behind = status.branch.behind
        }
        if let head = summary.head {
            let commit = try git.text(path, ["log", "-1", "--format=%ct%n%s", head, "--"])
            if let newline = commit.firstIndex(of: "\n") {
                summary.commitTimestamp = UInt64(commit[..<newline])
                summary.commitSubject = String(commit[commit.index(after: newline)...])
            }
        }
        for file in status.files {
            summary.changed += 1
            if file.isStaged { summary.staged += 1 }
            if file.isUnstaged { summary.unstaged += 1 }
            if file.isUntracked { summary.untracked += 1 }
            if file.isConflicted { summary.conflicted += 1 }
        }
        return summary
    }

    func branches() throws -> [GitBranch] {
        let defaultBranch = git.optionalText(path, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])
            .flatMap { $0.hasPrefix("origin/") ? String($0.dropFirst(7)) : nil }
        let output = try git.text(path, ["for-each-ref", "--format=%(refname:short)%00%(HEAD)", "refs/heads/"])
        let checkedOut = Set(try worktrees().compactMap(\.branch))
        var result: [GitBranch] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw gitError("Invalid Git branch record") }
            let name = String(parts[0])
            let isDefault = defaultBranch.map { $0 == name } ?? (name == "main" || name == "master")
            result.append(GitBranch(name: name, current: parts[1] == "*", checkedOut: checkedOut.contains(name),
                                    isDefault: isDefault))
        }
        return result
    }

    func lineStats(staged: Bool) throws -> [String: (UInt64?, UInt64?)] {
        var arguments = ["diff", "--numstat", "-z", "-M", "--no-ext-diff", "--no-textconv"]
        if staged { arguments.append("--cached") }
        arguments.append("--")
        return try GitParsing.numstat(try git.run(path, arguments))
    }

    /// Changed files with added and removed line counts.
    func changes() throws -> [GitFile] {
        try changes(staged: try lineStats(staged: true), unstaged: try lineStats(staged: false))
    }

    private func changes(staged: [String: (UInt64?, UInt64?)], unstaged: [String: (UInt64?, UInt64?)]) throws
        -> [GitFile] {
        var files = try files()
        for index in files.indices {
            let key = files[index].path.rawValue
            if files[index].isUntracked {
                if let lines = Self.untrackedLines(absolute(of: files[index].path)) {
                    files[index].added = lines
                    files[index].removed = 0
                }
                continue
            }
            let first = staged[key] ?? (0, 0)
            let second = unstaged[key] ?? (0, 0)
            files[index].added = Self.sum(first.0, second.0)
            files[index].removed = Self.sum(first.1, second.1)
        }
        return files
    }

    func fileStatus() throws -> [GitFileStatus] {
        let staged = try lineStats(staged: true)
        let unstaged = try lineStats(staged: false)
        func stat(_ value: (UInt64?, UInt64?)?) -> GitLineStat {
            let (additions, deletions) = value ?? (0, 0)
            return GitLineStat(additions: additions, deletions: deletions, binary: additions == nil && deletions == nil)
        }
        return try changes(staged: staged, unstaged: unstaged).map { file in
            let unstagedStat = file.isUntracked
                ? GitLineStat(additions: file.added, deletions: file.removed,
                              binary: Self.untrackedBinary(absolute(of: file.path)))
                : stat(unstaged[file.path.rawValue])
            return GitFileStatus(file: file, staged: stat(staged[file.path.rawValue]), unstaged: unstagedStat)
        }
    }

    func worktrees() throws -> [GitWorktree] {
        GitParsing.worktrees(try git.run(path, ["worktree", "list", "--porcelain", "-z"]))
    }

    func absolute(of relative: ServerPath) -> String {
        (path as NSString).appendingPathComponent(relative.rawValue)
    }

    private static func sum(_ first: UInt64?, _ second: UInt64?) -> UInt64? {
        guard let first, let second else { return nil }
        let (value, overflow) = first.addingReportingOverflow(second)
        return overflow ? nil : value
    }

    static let untrackedLineLimit = 1024 * 1024

    /// Lines in a small text file; `nil` for folders, binaries and big files.
    static func untrackedLines(_ path: String) -> UInt64? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= untrackedLineLimit,
              let data = FileManager.default.contents(atPath: path), data.count <= untrackedLineLimit,
              !data.contains(0) else { return nil }
        var lines = UInt64(data.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 })
        if let last = data.last, last != 0x0a { lines += 1 }
        return lines
    }

    static func untrackedBinary(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let prefix = (try? handle.read(upToCount: 8000)) ?? Data()
        return prefix.contains(0)
    }

    // MARK: - Details

    func repoInfo() throws -> GitRepoInfo {
        let gitDirectory = try absolute("--git-dir")
        let common = try absolute("--git-common-dir")
        return GitRepoInfo(root: ServerPath(path), gitDir: ServerPath(gitDirectory),
                           isWorktree: canonical(gitDirectory) != canonical(common),
                           currentBranch: try summary().branch)
    }

    func remoteBranches() throws -> [String] {
        let output = Self.textOf(try git.network(path, ["ls-remote", "--heads", "origin"]))
        var branches: [String] = []
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { throw gitError("Invalid remote branch") }
            let reference = line[line.index(after: tab)...]
            guard reference.hasPrefix("refs/heads/") else { throw gitError("Invalid remote branch") }
            branches.append(String(reference.dropFirst(11)))
        }
        return branches.sorted()
    }

    /// The remote's default branch, else the local `origin/HEAD`.
    func remoteDefaultBranch() -> String? {
        if let data = try? git.network(path, ["ls-remote", "--symref", "origin", "HEAD"]) {
            for line in Self.textOf(data).split(separator: "\n") where line.hasPrefix("ref: refs/heads/") {
                let rest = line.dropFirst("ref: refs/heads/".count)
                if rest.hasSuffix("\tHEAD") { return String(rest.dropLast(5)) }
            }
        }
        guard let local = git.optionalText(path, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]),
              local.hasPrefix("origin/") else { return nil }
        return String(local.dropFirst(7))
    }

    func log(maxCount: UInt32, skip: UInt32) throws -> [GitCommit] {
        if maxCount == 0 { return [] }
        let summary = try summary()
        if summary.head == nil, summary.branch != nil { return [] }
        let output = try git.run(path, [
            "log", "--no-show-signature", "--no-notes", "-z", "--format=%H%x00%h%x00%s%x00%an%x00%aI%x00%P",
            "--max-count=\(maxCount)", "--skip=\(skip)", "--",
        ])
        if output.isEmpty { return [] }
        var text = Self.textOf(output)
        if text.hasSuffix("\0") { text.removeLast() }
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        guard fields.count % 6 == 0 else { throw gitError("Invalid Git log") }
        let references = try git.text(path, [
            "for-each-ref", "--format=%(objectname)%00%(*objectname)%00%(refname)",
            "refs/heads/", "refs/remotes/", "refs/tags/",
        ])
        var refs: [String: [GitRef]] = [:]
        for record in references.split(separator: "\n") {
            let parts = record.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw gitError("Invalid Git ref") }
            let reference = parts[2]
            let name: Substring
            let kind: GitRefKind
            if reference.hasPrefix("refs/heads/") {
                (name, kind) = (reference.dropFirst(11), .localBranch)
            } else if reference.hasPrefix("refs/remotes/") {
                (name, kind) = (reference.dropFirst(13), .remoteBranch)
            } else if reference.hasPrefix("refs/tags/") {
                (name, kind) = (reference.dropFirst(10), .tag)
            } else {
                continue
            }
            let hash = String(parts[1].isEmpty ? parts[0] : parts[1])
            refs[hash, default: []].append(GitRef(name: String(name), kind: kind))
        }
        if let head = summary.head {
            refs[head, default: []].append(GitRef(name: "HEAD", kind: .head))
        }
        return stride(from: 0, to: fields.count, by: 6).map { start in
            let hash = String(fields[start])
            return GitCommit(hash: hash, shortHash: String(fields[start + 1]), subject: String(fields[start + 2]),
                             authorName: String(fields[start + 3]), authorDate: String(fields[start + 4]),
                             parentHashes: fields[start + 5].split(separator: " ").map(String.init),
                             refs: refs[hash] ?? [])
        }
    }

    static func textOf(_ data: Data) -> String {
        GitCommand.trimmed(data)
    }

    // MARK: - Paths

    /// An absolute path for a repository-relative one that stays inside the
    /// working tree: no `..`, no `.git`, and no symbolic links on the way.
    func safePath(_ relative: ServerPath) throws -> String {
        let components = relative.rawValue.split(separator: "/", omittingEmptySubsequences: false)
        if relative.rawValue.isEmpty || relative.isAbsolute
            || components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == ".git" }) {
            throw gitError("Invalid repository-relative path")
        }
        var current = path
        for component in components.dropLast() {
            current = (current as NSString).appendingPathComponent(String(component))
            var info = stat()
            if lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw gitError("Path traverses a symbolic link")
            }
        }
        return (path as NSString).appendingPathComponent(relative.rawValue)
    }
}

/// The path with symbolic links resolved, or itself when it doesn't exist.
func canonical(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
