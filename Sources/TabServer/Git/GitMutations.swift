import Darwin
import Foundation
import TabProtocol

extension GitRepository {
    /// The Git config key that marks a branch made by checking out a pull request.
    static func pullRequestKey(_ branch: String) -> String { "branch.\(branch).tab-pr-number" }

    // MARK: - Branches

    func switchBranch(_ branch: String) throws {
        try validateBranch(branch)
        try git.run(path, ["switch", "--", branch])
    }

    func createBranch(_ branch: String) throws {
        try validateBranch(branch)
        try git.run(path, ["switch", "-c", branch])
    }

    func deleteLocalBranch(_ branch: String, force: Bool) throws {
        try validateBranch(branch)
        try git.run(path, ["branch", force ? "-D" : "-d", "--", branch])
    }

    func deleteRemoteBranch(_ branch: String) throws {
        try validateBranch(branch)
        try git.network(path, ["push", "--delete", "origin", "refs/heads/\(branch)"])
    }

    func createTag(name: String, hash: String) throws {
        try git.run(path, ["check-ref-format", "refs/tags/\(name)"])
        try git.run(path, ["tag", "--no-sign", "--", name, hash])
    }

    // MARK: - Index

    enum FileAction {
        case stage, unstage, discard
    }

    /// Stages, unstages or discards `paths`, all of them or none: every path
    /// is checked before anything changes. Empty `paths` means everything
    /// (discard of everything is refused by doing nothing).
    func apply(_ action: FileAction, to paths: [ServerPath]) throws {
        if paths.isEmpty {
            switch action {
            case .stage:
                try git.run(path, ["add", "-A"])
            case .unstage:
                if try summary().head != nil {
                    try git.run(path, ["reset", "HEAD", "--", "."])
                } else {
                    try git.run(path, ["rm", "--cached", "-r", "-f", "--ignore-unmatch", "--", "."])
                }
            case .discard:
                break
            }
            return
        }
        let current = try files()
        var tracked: [String] = []
        var untracked: [String] = []
        for relative in paths {
            let absolute = try safePath(relative)
            guard let file = current.first(where: { $0.path == relative }) else {
                throw gitError("File status changed; refresh and try again")
            }
            if action == .discard {
                if file.isConflicted || (file.isStaged && !file.isUnstaged) {
                    throw gitError("Unstage or resolve the file before discarding")
                }
                if file.isUntracked {
                    var info = stat()
                    guard lstat(absolute, &info) == 0 else {
                        throw gitError("Couldn't read \(relative.rawValue): \(String(cString: strerror(errno)))")
                    }
                    if (info.st_mode & S_IFMT) == S_IFDIR {
                        throw gitError("Refusing to recursively discard a directory")
                    }
                    untracked.append(absolute)
                    continue
                }
            }
            tracked.append(relative.rawValue)
            if action == .unstage, let original = file.originalPath {
                _ = try safePath(original)
                tracked.append(original.rawValue)
            }
        }
        if !tracked.isEmpty {
            let command: [String]
            switch action {
            case .stage: command = ["add", "--"]
            case .unstage:
                command = git.optionalText(path, ["rev-parse", "--verify", "HEAD"]) == nil
                    ? ["rm", "--cached", "-f", "--"] : ["reset", "HEAD", "--"]
            case .discard: command = ["restore", "--worktree", "--"]
            }
            try git.run(path, command + tracked)
        }
        for absolute in untracked where unlink(absolute) != 0 {
            throw gitError("Couldn't delete \(absolute): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Commits

    /// Commits the index (everything with `stageAll`) and returns the new
    /// HEAD. Amending with an empty message keeps HEAD's message.
    func commit(message: String, stageAll: Bool, amend: Bool) throws -> String {
        if amend, !(try git.run(path, ["ls-files", "--unmerged", "-z"])).isEmpty {
            throw gitError("Resolve merge conflicts before committing")
        }
        if stageAll { try git.run(path, ["add", "-A"]) }
        var arguments = ["commit"]
        if amend { arguments.append("--amend") }
        if amend && message.isEmpty {
            arguments.append("--no-edit")
        } else {
            arguments += ["-m", message.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        do {
            try git.run(path, arguments)
        } catch let error as ServiceError {
            throw Self.explainIdentity(error)
        }
        return try git.text(path, ["rev-parse", "HEAD"])
    }

    /// Git's "Please tell me who you are" as something to act on.
    static func explainIdentity(_ error: ServiceError) -> ServiceError {
        let message = error.message
        guard message.contains("Please tell me who you are") || message.contains("Author identity unknown")
            || message.contains("unable to auto-detect email address") || message.contains("empty ident name")
        else { return error }
        return ServiceError(error.code, "Set your Git name and email before committing: "
            + "git config --global user.name \"Your Name\" and git config --global user.email you@example.com")
    }

    // MARK: - Remotes

    func push(setUpstream: Bool) throws {
        if !setUpstream {
            let summary = try summary()
            if let branch = summary.branch, let upstream = summary.upstream,
               config(Self.pullRequestKey(branch)) != nil, let slash = upstream.firstIndex(of: "/") {
                let remote = String(upstream[..<slash])
                let remoteBranch = String(upstream[upstream.index(after: slash)...])
                try git.network(path, ["push", "--", remote, "HEAD:refs/heads/\(remoteBranch)"])
                return
            }
            do {
                try git.network(path, ["push"])
                return
            } catch let error as ServiceError where error.message.contains("has no upstream branch") {
                // Falls through to publishing the branch on origin.
            }
        }
        guard let branch = try summary().branch else { throw gitError("Cannot set upstream for a detached HEAD") }
        try validateBranch(branch)
        try git.network(path, ["push", "--set-upstream", "origin", branch])
    }

    func pull() throws {
        try git.network(path, ["pull"])
    }

    func fetch() throws {
        try git.network(path, ["fetch"])
    }

    // MARK: - History

    func checkout(_ hash: String) throws {
        try git.run(path, ["checkout", "--detach", hash])
    }

    func cherryPick(_ hash: String) throws {
        try git.run(path, ["cherry-pick", hash])
    }

    func revert(_ hash: String) throws {
        try git.run(path, ["revert", "--no-commit", hash])
    }

    // MARK: - Diffs

    /// A diff of one file (or, raw, of the whole tree): staged against HEAD,
    /// or the working tree against the index. Untracked files diff against
    /// nothing; conflicted files show our side.
    func diff(_ request: GitDiffRequest, raw: Bool) throws -> GitReply {
        var arguments = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/"]
        if let context = request.context { arguments.append("--unified=\(context)") }
        var noIndex = false
        if let relative = request.path {
            let absolute = try safePath(relative)
            let file = raw ? nil : try files().first { $0.path == relative }
            if !request.staged, file?.isConflicted == true { arguments.append("--ours") }
            if !request.staged, file?.isUntracked == true {
                var info = stat()
                guard lstat(absolute, &info) == 0 else { throw gitError("Couldn't read \(relative.rawValue)") }
                let type = info.st_mode & S_IFMT
                guard type == S_IFREG || type == S_IFLNK else { throw gitError("Diff requires a file") }
                noIndex = true
                arguments.append("--no-index")
            }
        }
        if request.staged { arguments.append("--cached") }
        arguments.append("--")
        if noIndex { arguments.append("/dev/null") }
        if let relative = request.path { arguments.append(relative.rawValue) }
        let (bytes, truncated) = try git.diff(path, arguments, noIndex: noIndex)
        let bounded = GitParsing.bounded(bytes, truncated: truncated, lineLimit: request.lineLimit)
        return raw ? .rawDiff(bounded) : .diff(GitParsing.diff(bounded))
    }

    /// Committed changes on this branch since it left `origin/<base>`.
    func branchDiff(base: String, lineLimit: UInt32?) throws -> GitRawDiff {
        try validateBranch(base)
        let (bytes, truncated) = try git.diff(path, [
            "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
            "refs/remotes/origin/\(base)...HEAD", "--",
        ], noIndex: false)
        return GitParsing.bounded(bytes, truncated: truncated, lineLimit: lineLimit)
    }
}
