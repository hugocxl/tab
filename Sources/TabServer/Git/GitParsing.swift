import Foundation
import TabProtocol

/// Parsers for Git's machine-readable output.
enum GitParsing {
    static let maxChangedFiles = 4096

    /// The branch headers of `status --porcelain=v2 --branch`.
    struct BranchHeaders: Equatable {
        var oid: String?
        var head: String?
        var upstream: String?
        var ahead: UInt64 = 0
        var behind: UInt64 = 0
        /// The upstream exists, so ahead and behind are known.
        var tracked = false
    }

    struct Status: Equatable {
        var branch = BranchHeaders()
        var files: [GitFile] = []
    }

    /// Splits NUL-terminated records, dropping empty ones.
    static func records(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
    }

    /// Parses `git status --porcelain=v2 -z [--branch]`.
    static func status(_ data: Data) throws -> Status {
        var result = Status()
        var records = records(data)[...]
        while let record = records.popFirst() {
            if record.hasPrefix("# ") {
                header(record.dropFirst(2), into: &result.branch)
                continue
            }
            guard let kind = record.first else { continue }
            switch kind {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9 else { throw gitError("Invalid Git status") }
                result.files.append(file(xy: fields[1], path: fields[8], original: nil))
            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                guard fields.count == 10, let original = records.popFirst() else {
                    throw gitError("Invalid Git status")
                }
                result.files.append(file(xy: fields[1], path: fields[9], original: original))
            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11 else { throw gitError("Invalid Git status") }
                result.files.append(file(xy: fields[1], path: fields[10], original: nil))
            case "?":
                result.files.append(GitFile(path: ServerPath(String(record.dropFirst(2))), index: .untracked,
                                            worktree: .untracked))
            case "!":
                continue
            default:
                throw gitError("Invalid Git status")
            }
            if result.files.count > maxChangedFiles {
                throw gitError("More than \(maxChangedFiles) changed files; narrow changes using Git")
            }
        }
        return result
    }

    private static func header(_ text: Substring, into branch: inout BranchHeaders) {
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid": branch.oid = value == "(initial)" ? nil : value
        case "branch.head": branch.head = value == "(detached)" ? nil : value
        case "branch.upstream": branch.upstream = value
        case "branch.ab":
            branch.tracked = true
            for count in value.split(separator: " ") {
                if count.hasPrefix("+") { branch.ahead = UInt64(count.dropFirst()) ?? 0 }
                if count.hasPrefix("-") { branch.behind = UInt64(count.dropFirst()) ?? 0 }
            }
        default: break
        }
    }

    private static func file(xy: Substring, path: Substring, original: Substring?) -> GitFile {
        let codes = Array(xy)
        func code(_ character: Character?) -> GitStatusCode {
            guard let character, character != "." else { return .unmodified }
            return GitStatusCode(porcelain: character)
        }
        return GitFile(path: ServerPath(String(path)), originalPath: original.map { ServerPath(String($0)) },
                       index: code(codes.first), worktree: code(codes.dropFirst().first))
    }

    /// `git diff --numstat -z [-M]`: path → (added, removed); `nil` counts for binary files.
    static func numstat(_ data: Data) throws -> [String: (UInt64?, UInt64?)] {
        var stats: [String: (UInt64?, UInt64?)] = [:]
        var records = String(decoding: data, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false)[...]
        while let record = records.popFirst() {
            if record.isEmpty { continue }
            let parts = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { throw gitError("Invalid Git line statistics") }
            var target = parts[2]
            if target.isEmpty {
                guard records.popFirst() != nil, let renamed = records.popFirst() else {
                    throw gitError("Missing rename target")
                }
                target = renamed
            }
            func count(_ text: Substring) throws -> UInt64? {
                if text == "-" { return nil }
                guard let value = UInt64(text) else { throw gitError("Invalid Git line statistics") }
                return value
            }
            stats[String(target)] = (try count(parts[0]), try count(parts[1]))
        }
        return stats
    }

    /// `git worktree list --porcelain -z`.
    static func worktrees(_ data: Data) -> [GitWorktree] {
        var result: [GitWorktree] = []
        for record in records(data) {
            if record.hasPrefix("worktree ") {
                result.append(GitWorktree(directory: ServerPath(String(record.dropFirst(9))), primary: result.isEmpty))
                continue
            }
            guard !result.isEmpty else { continue }
            let last = result.count - 1
            if record.hasPrefix("HEAD ") { result[last].head = String(record.dropFirst(5)) }
            if record.hasPrefix("branch refs/heads/") { result[last].branch = String(record.dropFirst(18)) }
            if record == "locked" || record.hasPrefix("locked ") { result[last].locked = true }
            if record == "bare" { result[last].bare = true }
            if record == "detached" { result[last].detached = true }
            if record == "prunable" || record.hasPrefix("prunable ") { result[last].prunable = true }
        }
        return result
    }

    /// Cuts a diff after `lineLimit` lines; truncated when anything was left out.
    static func bounded(_ data: Data, truncated: Bool, lineLimit: UInt32?) -> GitRawDiff {
        let bytes = [UInt8](data)
        var end = bytes.count
        var truncated = truncated
        if let limit = lineLimit {
            var lines: UInt32 = 0
            for index in bytes.indices where bytes[index] == 0x0a {
                lines += 1
                if lines == limit {
                    end = index + 1
                    break
                }
            }
            truncated = truncated || end < bytes.count
        }
        return GitRawDiff(diff: String(decoding: bytes[0 ..< end], as: UTF8.self), truncated: truncated)
    }

    /// A unified diff of one file as rows: hunk headers and their lines.
    static func diff(_ raw: GitRawDiff) -> GitDiff {
        var result = GitDiff(rows: [], truncated: raw.truncated)
        var old: UInt64 = 0
        var new: UInt64 = 0
        var inHunk = false
        for scalars in raw.diff.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(String.UnicodeScalarView(scalars))
            if line.unicodeScalars.last == "\r" { line.unicodeScalars.removeLast() }
            if line.hasPrefix("diff --git ") { inHunk = false }
            if line.hasPrefix("Binary files "), line.hasSuffix(" differ") {
                result.binary = true
                continue
            }
            if line.hasPrefix("@@ ") {
                let parts = line.split(separator: " ")
                func start(_ index: Int) -> UInt64 {
                    guard index < parts.count else { return 0 }
                    return UInt64(parts[index].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                old = start(1)
                new = start(2)
                inHunk = true
                result.rows.append(GitDiffRow(kind: .hunk, text: line))
                continue
            }
            guard inHunk, let first = line.unicodeScalars.first else { continue }
            let kind: GitDiffKind
            switch first {
            case " ": kind = .context
            case "+": kind = .addition
            case "-": kind = .deletion
            default: continue
            }
            let content = String(line.unicodeScalars.dropFirst())
            let hasOld = kind != .addition
            let hasNew = kind != .deletion
            result.rows.append(GitDiffRow(kind: kind, oldLineNumber: hasOld ? old : nil,
                                          newLineNumber: hasNew ? new : nil, oldText: hasOld ? content : nil,
                                          newText: hasNew ? content : nil, text: line))
            if hasOld { old += 1 }
            if hasNew { new += 1 }
            if kind == .addition { result.additions += 1 }
            if kind == .deletion { result.deletions += 1 }
        }
        return result
    }
}
