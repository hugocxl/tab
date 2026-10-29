import Foundation

/// A Git operation, always resolved through a server project's folder.
public struct GitRequest: Hashable, Codable, Sendable {
    public var project: ProjectId
    public var action: GitAction

    public init(project: ProjectId, action: GitAction) {
        self.project = project
        self.action = action
    }
}

public enum GitAction: Hashable, Codable, Sendable {
    case summary
    case branches
    case remoteBranches
    case changes
    case switchBranch(String)
    case createBranch(String)
    /// Deletes a local branch that is merged.
    case deleteBranch(String)
    case deleteLocalBranch(name: String, force: Bool)
    case deleteRemoteBranch(String)
    case stage([ServerPath])
    case unstage([ServerPath])
    case discard([ServerPath])
    /// Commits the index (or everything with `stageAll`). Amending with an
    /// empty message keeps HEAD's message.
    case commit(message: String, stageAll: Bool, amend: Bool)
    /// A parsed diff of one file.
    case diff(GitDiffRequest)
    /// The working tree (or staged) diff as text, optionally of one file.
    case rawDiff(GitDiffRequest)
    case log(maxCount: UInt32, skip: UInt32)
    case status(local: Bool)
    case repoInfo
    case initRepository
    case pull
    case push(setUpstream: Bool)
    case fetch
    case checkout(String)
    case cherryPick(String)
    case revert(String)
    case createTag(name: String, hash: String)
    case worktrees
    case worktree(WorktreeIntent)
    /// Inspects the project's worktree before removing it.
    case inspectRemoval
    /// The hooks configured for worktrees, for explicit approval.
    case worktreeHooks(teardown: Bool)
    case pullRequest(GitPullRequestAction)
    /// Replaces this connection's working tree watch with the project's.
    case watch
    case unwatch
    /// Switches to a merged pull request's base branch and fast-forwards it.
    case switchToBase(String)
    /// Committed changes on this branch relative to an origin branch.
    case branchDiff(base: String, lineLimit: UInt32?)
    /// Every working-tree change, computed without touching the index.
    case changesPreview(lineLimit: UInt32?)
    /// Only the staged changes, computed without touching the index.
    case stagedPreview(lineLimit: UInt32?)
    /// Stages everything and commits only while the tree matches its preview.
    case commitAll(message: String, expectedHead: String?, expectedTree: String)
    /// Commits the index only while it matches its staged preview.
    case commitStaged(message: String, expectedHead: String?, expectedTree: String)
    /// Pushes the current branch to the destination its preview reported.
    case publishBranch(branch: String, destination: GitPushDestination)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "summary": self = .summary
        case "branches": self = .branches
        case "remoteBranches": self = .remoteBranches
        case "changes": self = .changes
        case "switchBranch": self = .switchBranch(try c("branch"))
        case "createBranch": self = .createBranch(try c("branch"))
        case "deleteBranch": self = .deleteBranch(try c("branch"))
        case "deleteLocalBranch": self = .deleteLocalBranch(name: try c("name"), force: try c("force"))
        case "deleteRemoteBranch": self = .deleteRemoteBranch(try c("branch"))
        case "stage": self = .stage(try c("paths"))
        case "unstage": self = .unstage(try c("paths"))
        case "discard": self = .discard(try c("paths"))
        case "commit": self = .commit(message: try c("message"), stageAll: try c("stageAll"), amend: try c("amend"))
        case "diff": self = .diff(try c("request"))
        case "rawDiff": self = .rawDiff(try c("request"))
        case "log": self = .log(maxCount: try c("maxCount"), skip: try c("skip"))
        case "status": self = .status(local: try c("local"))
        case "repoInfo": self = .repoInfo
        case "init": self = .initRepository
        case "pull": self = .pull
        case "push": self = .push(setUpstream: try c("setUpstream"))
        case "fetch": self = .fetch
        case "checkout": self = .checkout(try c("hash"))
        case "cherryPick": self = .cherryPick(try c("hash"))
        case "revert": self = .revert(try c("hash"))
        case "createTag": self = .createTag(name: try c("name"), hash: try c("hash"))
        case "worktrees": self = .worktrees
        case "worktree": self = .worktree(try c("intent"))
        case "inspectRemoval": self = .inspectRemoval
        case "worktreeHooks": self = .worktreeHooks(teardown: try c("teardown"))
        case "pullRequest": self = .pullRequest(try c("action"))
        case "watch": self = .watch
        case "unwatch": self = .unwatch
        case "switchToBase": self = .switchToBase(try c("branch"))
        case "branchDiff": self = .branchDiff(base: try c("base"), lineLimit: try c("lineLimit"))
        case "changesPreview": self = .changesPreview(lineLimit: try c("lineLimit"))
        case "stagedPreview": self = .stagedPreview(lineLimit: try c("lineLimit"))
        case "commitAll":
            self = .commitAll(message: try c("message"), expectedHead: try c("expectedHead"),
                              expectedTree: try c("expectedTree"))
        case "commitStaged":
            self = .commitStaged(message: try c("message"), expectedHead: try c("expectedHead"),
                                 expectedTree: try c("expectedTree"))
        case "publishBranch": self = .publishBranch(branch: try c("branch"), destination: try c("destination"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .summary: try TaggedEncoding(encoder, "summary")
        case .branches: try TaggedEncoding(encoder, "branches")
        case .remoteBranches: try TaggedEncoding(encoder, "remoteBranches")
        case .changes: try TaggedEncoding(encoder, "changes")
        case .switchBranch(let branch):
            var c = try TaggedEncoding(encoder, "switchBranch")
            try c(branch, "branch")
        case .createBranch(let branch):
            var c = try TaggedEncoding(encoder, "createBranch")
            try c(branch, "branch")
        case .deleteBranch(let branch):
            var c = try TaggedEncoding(encoder, "deleteBranch")
            try c(branch, "branch")
        case .deleteLocalBranch(let name, let force):
            var c = try TaggedEncoding(encoder, "deleteLocalBranch")
            try c(name, "name")
            try c(force, "force")
        case .deleteRemoteBranch(let branch):
            var c = try TaggedEncoding(encoder, "deleteRemoteBranch")
            try c(branch, "branch")
        case .stage(let paths):
            var c = try TaggedEncoding(encoder, "stage")
            try c(paths, "paths")
        case .unstage(let paths):
            var c = try TaggedEncoding(encoder, "unstage")
            try c(paths, "paths")
        case .discard(let paths):
            var c = try TaggedEncoding(encoder, "discard")
            try c(paths, "paths")
        case .commit(let message, let stageAll, let amend):
            var c = try TaggedEncoding(encoder, "commit")
            try c(message, "message")
            try c(stageAll, "stageAll")
            try c(amend, "amend")
        case .diff(let request):
            var c = try TaggedEncoding(encoder, "diff")
            try c(request, "request")
        case .rawDiff(let request):
            var c = try TaggedEncoding(encoder, "rawDiff")
            try c(request, "request")
        case .log(let maxCount, let skip):
            var c = try TaggedEncoding(encoder, "log")
            try c(maxCount, "maxCount")
            try c(skip, "skip")
        case .status(let local):
            var c = try TaggedEncoding(encoder, "status")
            try c(local, "local")
        case .repoInfo: try TaggedEncoding(encoder, "repoInfo")
        case .initRepository: try TaggedEncoding(encoder, "init")
        case .pull: try TaggedEncoding(encoder, "pull")
        case .push(let setUpstream):
            var c = try TaggedEncoding(encoder, "push")
            try c(setUpstream, "setUpstream")
        case .fetch: try TaggedEncoding(encoder, "fetch")
        case .checkout(let hash):
            var c = try TaggedEncoding(encoder, "checkout")
            try c(hash, "hash")
        case .cherryPick(let hash):
            var c = try TaggedEncoding(encoder, "cherryPick")
            try c(hash, "hash")
        case .revert(let hash):
            var c = try TaggedEncoding(encoder, "revert")
            try c(hash, "hash")
        case .createTag(let name, let hash):
            var c = try TaggedEncoding(encoder, "createTag")
            try c(name, "name")
            try c(hash, "hash")
        case .worktrees: try TaggedEncoding(encoder, "worktrees")
        case .worktree(let intent):
            var c = try TaggedEncoding(encoder, "worktree")
            try c(intent, "intent")
        case .inspectRemoval: try TaggedEncoding(encoder, "inspectRemoval")
        case .worktreeHooks(let teardown):
            var c = try TaggedEncoding(encoder, "worktreeHooks")
            try c(teardown, "teardown")
        case .pullRequest(let action):
            var c = try TaggedEncoding(encoder, "pullRequest")
            try c(action, "action")
        case .watch: try TaggedEncoding(encoder, "watch")
        case .unwatch: try TaggedEncoding(encoder, "unwatch")
        case .switchToBase(let branch):
            var c = try TaggedEncoding(encoder, "switchToBase")
            try c(branch, "branch")
        case .branchDiff(let base, let lineLimit):
            var c = try TaggedEncoding(encoder, "branchDiff")
            try c(base, "base")
            try c(lineLimit, "lineLimit")
        case .changesPreview(let lineLimit):
            var c = try TaggedEncoding(encoder, "changesPreview")
            try c(lineLimit, "lineLimit")
        case .stagedPreview(let lineLimit):
            var c = try TaggedEncoding(encoder, "stagedPreview")
            try c(lineLimit, "lineLimit")
        case .commitAll(let message, let expectedHead, let expectedTree):
            var c = try TaggedEncoding(encoder, "commitAll")
            try c(message, "message")
            try c(expectedHead, "expectedHead")
            try c(expectedTree, "expectedTree")
        case .commitStaged(let message, let expectedHead, let expectedTree):
            var c = try TaggedEncoding(encoder, "commitStaged")
            try c(message, "message")
            try c(expectedHead, "expectedHead")
            try c(expectedTree, "expectedTree")
        case .publishBranch(let branch, let destination):
            var c = try TaggedEncoding(encoder, "publishBranch")
            try c(branch, "branch")
            try c(destination, "destination")
        }
    }
}

public struct GitDiffRequest: Hashable, Codable, Sendable {
    /// Relative to the project; required for a parsed diff.
    public var path: ServerPath?
    public var staged: Bool
    public var lineLimit: UInt32?
    /// Lines of context around changes; `nil` uses Git's default.
    public var context: UInt32?

    public init(path: ServerPath? = nil, staged: Bool = false, lineLimit: UInt32? = nil, context: UInt32? = nil) {
        self.path = path
        self.staged = staged
        self.lineLimit = lineLimit
        self.context = context
    }
}

// MARK: - Worktrees

public struct WorktreeIntent: Hashable, Codable, Sendable {
    public var operation: OperationId
    public var action: WorktreeAction
    public var options: WorktreeOptions?

    public init(operation: OperationId = OperationId(), action: WorktreeAction, options: WorktreeOptions? = nil) {
        self.operation = operation
        self.action = action
        self.options = options
    }
}

public enum WorktreeAction: Hashable, Codable, Sendable {
    /// `base == nil` checks out an existing branch; otherwise creates
    /// `branch` from `base`.
    case create(project: ProjectId, directory: ServerPath, branch: String, base: String?)
    /// Adds a worktree made outside Tab as a project.
    case register(project: ProjectId, directory: ServerPath)
    /// Removes the worktree and its files, if it still matches the inspection.
    case remove(expected: WorktreeRemoval)
    case checkoutPullRequest(project: ProjectId, directory: ServerPath, number: UInt64)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "create":
            self = .create(project: try c("project"), directory: try c("directory"), branch: try c("branch"),
                           base: try c("base"))
        case "register": self = .register(project: try c("project"), directory: try c("directory"))
        case "remove": self = .remove(expected: try c("expected"))
        case "checkoutPullRequest":
            self = .checkoutPullRequest(project: try c("project"), directory: try c("directory"),
                                        number: try c("number"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .create(let project, let directory, let branch, let base):
            var c = try TaggedEncoding(encoder, "create")
            try c(project, "project")
            try c(directory, "directory")
            try c(branch, "branch")
            try c(base, "base")
        case .register(let project, let directory):
            var c = try TaggedEncoding(encoder, "register")
            try c(project, "project")
            try c(directory, "directory")
        case .remove(let expected):
            var c = try TaggedEncoding(encoder, "remove")
            try c(expected, "expected")
        case .checkoutPullRequest(let project, let directory, let number):
            var c = try TaggedEncoding(encoder, "checkoutPullRequest")
            try c(project, "project")
            try c(directory, "directory")
            try c(number, "number")
        }
    }
}

public struct WorktreeOptions: Hashable, Codable, Sendable {
    /// The new project's name.
    public var name: String?
    /// `nil` skips hooks; otherwise approves exactly these commands.
    public var hooks: [WorktreeHook]?

    public init(name: String? = nil, hooks: [WorktreeHook]? = nil) {
        self.name = name
        self.hooks = hooks
    }
}

/// A setup or teardown command, approved as an exact, ordered preview.
public struct WorktreeHook: Hashable, Codable, Sendable {
    public var command: String
    public var name: String?
    /// From the project's `.tab/worktree.json` rather than the user's.
    public var project: Bool

    public init(command: String, name: String? = nil, project: Bool) {
        self.command = command
        self.name = name
        self.project = project
    }
}

/// An inspection that binds a removal to the folder's identity and Git state.
public struct WorktreeRemoval: Hashable, Codable, Sendable {
    public var directory: ServerPath
    public var device: UInt64
    public var inode: UInt64
    /// Uncommitted changes would be lost.
    public var dirty: Bool
    /// `git status --porcelain` output at inspection.
    public var status: Data
    public var head: String?
    public var branch: String?

    public init(directory: ServerPath, device: UInt64, inode: UInt64, dirty: Bool, status: Data = Data(),
                head: String? = nil, branch: String? = nil) {
        self.directory = directory
        self.device = device
        self.inode = inode
        self.dirty = dirty
        self.status = status
        self.head = head
        self.branch = branch
    }
}

public struct GitWorktree: Hashable, Codable, Sendable {
    public var directory: ServerPath
    public var head: String?
    public var branch: String?
    public var primary: Bool
    public var locked: Bool
    public var bare: Bool
    public var detached: Bool
    public var prunable: Bool
    /// The project that shows this worktree, if any.
    public var registered: ProjectId?

    public init(directory: ServerPath, head: String? = nil, branch: String? = nil, primary: Bool = false,
                locked: Bool = false, bare: Bool = false, detached: Bool = false, prunable: Bool = false,
                registered: ProjectId? = nil) {
        self.directory = directory
        self.head = head
        self.branch = branch
        self.primary = primary
        self.locked = locked
        self.bare = bare
        self.detached = detached
        self.prunable = prunable
        self.registered = registered
    }
}

// MARK: - Repository state

public struct GitSummary: Hashable, Codable, Sendable {
    public var branch: String?
    public var head: String?
    public var upstream: String?
    public var ahead: UInt64
    public var behind: UInt64
    public var changed: UInt32
    public var staged: UInt32
    public var unstaged: UInt32
    public var untracked: UInt32
    public var conflicted: UInt32
    /// The last commit's subject; absent on unborn branches.
    public var commitSubject: String?
    /// The last commit's committer time, in Unix seconds.
    public var commitTimestamp: UInt64?

    public init(branch: String? = nil, head: String? = nil, upstream: String? = nil, ahead: UInt64 = 0,
                behind: UInt64 = 0, changed: UInt32 = 0, staged: UInt32 = 0, unstaged: UInt32 = 0,
                untracked: UInt32 = 0, conflicted: UInt32 = 0, commitSubject: String? = nil,
                commitTimestamp: UInt64? = nil) {
        self.branch = branch
        self.head = head
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.changed = changed
        self.staged = staged
        self.unstaged = unstaged
        self.untracked = untracked
        self.conflicted = conflicted
        self.commitSubject = commitSubject
        self.commitTimestamp = commitTimestamp
    }
}

public struct GitBranch: Hashable, Codable, Sendable {
    public var name: String
    public var current: Bool
    /// Checked out in some worktree.
    public var checkedOut: Bool
    /// The repository's default branch.
    public var isDefault: Bool

    public init(name: String, current: Bool = false, checkedOut: Bool = false, isDefault: Bool = false) {
        self.name = name
        self.current = current
        self.checkedOut = checkedOut
        self.isDefault = isDefault
    }
}

/// One side of a porcelain status entry.
public enum GitStatusCode: OpenEnum {
    case unmodified
    case modified
    case typeChanged
    case added
    case deleted
    case renamed
    case copied
    case unmerged
    case untracked
    case ignored
    case unknown(String)

    public static let knownCases: [GitStatusCode] = [
        .unmodified, .modified, .typeChanged, .added, .deleted, .renamed, .copied, .unmerged, .untracked, .ignored,
    ]

    public var rawValue: String {
        switch self {
        case .unmodified: "unmodified"
        case .modified: "modified"
        case .typeChanged: "typeChanged"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .copied: "copied"
        case .unmerged: "unmerged"
        case .untracked: "untracked"
        case .ignored: "ignored"
        case .unknown(let value): value
        }
    }

    /// The `git status --porcelain` letter.
    public var porcelain: Character {
        switch self {
        case .unmodified: " "
        case .modified: "M"
        case .typeChanged: "T"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .unmerged: "U"
        case .untracked: "?"
        case .ignored: "!"
        case .unknown: "X"
        }
    }

    public init(porcelain: Character) {
        self = Self.knownCases.first { $0.porcelain == porcelain } ?? .unknown(String(porcelain))
    }
}

public struct GitFile: Hashable, Codable, Sendable {
    /// Relative to the repository root.
    public var path: ServerPath
    /// The source of a rename or copy.
    public var originalPath: ServerPath?
    public var index: GitStatusCode
    public var worktree: GitStatusCode
    public var added: UInt64?
    public var removed: UInt64?

    public init(path: ServerPath, originalPath: ServerPath? = nil, index: GitStatusCode, worktree: GitStatusCode,
                added: UInt64? = nil, removed: UInt64? = nil) {
        self.path = path
        self.originalPath = originalPath
        self.index = index
        self.worktree = worktree
        self.added = added
        self.removed = removed
    }

    public var isUntracked: Bool { index == .untracked }

    public var isConflicted: Bool {
        index == .unmerged || worktree == .unmerged
            || (index == .added && worktree == .added) || (index == .deleted && worktree == .deleted)
    }

    public var isStaged: Bool { !isUntracked && index != .unmodified }
    public var isUnstaged: Bool { !isUntracked && worktree != .unmodified }
}

public struct GitLineStat: Hashable, Codable, Sendable {
    public var additions: UInt64?
    public var deletions: UInt64?
    public var binary: Bool

    public init(additions: UInt64? = nil, deletions: UInt64? = nil, binary: Bool = false) {
        self.additions = additions
        self.deletions = deletions
        self.binary = binary
    }
}

public struct GitFileStatus: Hashable, Codable, Sendable {
    public var file: GitFile
    public var staged: GitLineStat
    public var unstaged: GitLineStat

    public init(file: GitFile, staged: GitLineStat = GitLineStat(), unstaged: GitLineStat = GitLineStat()) {
        self.file = file
        self.staged = staged
        self.unstaged = unstaged
    }
}

public struct GitStatus: Hashable, Codable, Sendable {
    public var summary: GitSummary
    public var defaultBranch: String?
    public var branches: [GitBranch]
    public var files: [GitFileStatus]
    public var pullRequest: GitPullRequest?

    public init(summary: GitSummary, defaultBranch: String? = nil, branches: [GitBranch] = [],
                files: [GitFileStatus] = [], pullRequest: GitPullRequest? = nil) {
        self.summary = summary
        self.defaultBranch = defaultBranch
        self.branches = branches
        self.files = files
        self.pullRequest = pullRequest
    }
}

public struct GitRepoInfo: Hashable, Codable, Sendable {
    public var root: ServerPath
    public var gitDir: ServerPath
    public var isWorktree: Bool
    public var currentBranch: String?

    public init(root: ServerPath, gitDir: ServerPath, isWorktree: Bool = false, currentBranch: String? = nil) {
        self.root = root
        self.gitDir = gitDir
        self.isWorktree = isWorktree
        self.currentBranch = currentBranch
    }
}

public enum GitRefKind: OpenEnum {
    case localBranch
    case remoteBranch
    case tag
    case head
    case unknown(String)

    public static let knownCases: [GitRefKind] = [.localBranch, .remoteBranch, .tag, .head]

    public var rawValue: String {
        switch self {
        case .localBranch: "localBranch"
        case .remoteBranch: "remoteBranch"
        case .tag: "tag"
        case .head: "head"
        case .unknown(let value): value
        }
    }
}

public struct GitRef: Hashable, Codable, Sendable {
    public var name: String
    public var kind: GitRefKind

    public init(name: String, kind: GitRefKind) {
        self.name = name
        self.kind = kind
    }
}

public struct GitCommit: Hashable, Codable, Sendable {
    public var hash: String
    public var shortHash: String
    public var subject: String
    public var authorName: String
    /// ISO 8601.
    public var authorDate: String
    public var parentHashes: [String]
    public var refs: [GitRef]

    public init(hash: String, shortHash: String, subject: String, authorName: String, authorDate: String,
                parentHashes: [String] = [], refs: [GitRef] = []) {
        self.hash = hash
        self.shortHash = shortHash
        self.subject = subject
        self.authorName = authorName
        self.authorDate = authorDate
        self.parentHashes = parentHashes
        self.refs = refs
    }
}

public struct GitRawDiff: Hashable, Codable, Sendable {
    public var diff: String
    /// Cut at the line limit.
    public var truncated: Bool

    public init(diff: String, truncated: Bool = false) {
        self.diff = diff
        self.truncated = truncated
    }
}

public enum GitDiffKind: OpenEnum {
    /// A `@@` hunk header.
    case hunk
    case context
    case addition
    case deletion
    case unknown(String)

    public static let knownCases: [GitDiffKind] = [.hunk, .context, .addition, .deletion]

    public var rawValue: String {
        switch self {
        case .hunk: "hunk"
        case .context: "context"
        case .addition: "addition"
        case .deletion: "deletion"
        case .unknown(let value): value
        }
    }
}

public struct GitDiffRow: Hashable, Codable, Sendable {
    public var kind: GitDiffKind
    public var oldLineNumber: UInt64?
    public var newLineNumber: UInt64?
    public var oldText: String?
    public var newText: String?
    public var text: String

    public init(kind: GitDiffKind, oldLineNumber: UInt64? = nil, newLineNumber: UInt64? = nil,
                oldText: String? = nil, newText: String? = nil, text: String) {
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
        self.oldText = oldText
        self.newText = newText
        self.text = text
    }
}

/// A parsed diff of one file: hunk headers followed by their lines.
public struct GitDiff: Hashable, Codable, Sendable {
    public var rows: [GitDiffRow]
    public var additions: UInt64
    public var deletions: UInt64
    public var truncated: Bool
    /// Git compared the file as binary, so it has no rows.
    public var binary: Bool

    public init(rows: [GitDiffRow], additions: UInt64 = 0, deletions: UInt64 = 0, truncated: Bool = false,
                binary: Bool = false) {
        self.rows = rows
        self.additions = additions
        self.deletions = deletions
        self.truncated = truncated
        self.binary = binary
    }

    /// Rows grouped by hunk header.
    public var hunks: [ArraySlice<GitDiffRow>] {
        var hunks: [ArraySlice<GitDiffRow>] = []
        var start = rows.startIndex
        for index in rows.indices where rows[index].kind == .hunk && index != start {
            hunks.append(rows[start ..< index])
            start = index
        }
        if start < rows.endIndex { hunks.append(rows[start...]) }
        return hunks
    }
}

public struct GitPushDestination: Hashable, Codable, Sendable {
    public var remote: String
    public var branch: String

    public init(remote: String, branch: String) {
        self.remote = remote
        self.branch = branch
    }
}

public struct GitPreviewFile: Hashable, Codable, Sendable {
    public var path: ServerPath
    public var added: UInt64?
    public var removed: UInt64?
    public var untracked: Bool

    public init(path: ServerPath, added: UInt64? = nil, removed: UInt64? = nil, untracked: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.untracked = untracked
    }
}

/// Every change as it would be committed, computed without touching the index.
public struct GitChangesPreview: Hashable, Codable, Sendable {
    public var branch: String?
    public var head: String?
    /// The tree the commit would have; commit only while it still matches.
    public var tree: String
    public var diff: GitRawDiff
    public var files: [GitPreviewFile]
    public var destination: GitPushDestination?

    public init(branch: String? = nil, head: String? = nil, tree: String, diff: GitRawDiff,
                files: [GitPreviewFile] = [], destination: GitPushDestination? = nil) {
        self.branch = branch
        self.head = head
        self.tree = tree
        self.diff = diff
        self.files = files
        self.destination = destination
    }
}

public enum GitBaseSwitch: Hashable, Codable, Sendable {
    case updated
    /// The base branch is checked out by another worktree, so nothing changed.
    case checkedOutElsewhere(ServerPath)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "updated": self = .updated
        case "checkedOutElsewhere": self = .checkedOutElsewhere(try c("directory"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .updated: try TaggedEncoding(encoder, "updated")
        case .checkedOutElsewhere(let directory):
            var c = try TaggedEncoding(encoder, "checkedOutElsewhere")
            try c(directory, "directory")
        }
    }
}

// MARK: - Pull requests

public enum GitPullRequestFilter: String, Hashable, Codable, Sendable, CaseIterable {
    case open
    case closed
    case merged
    case all
}

public enum GitMergeMethod: String, Hashable, Codable, Sendable, CaseIterable {
    case merge
    case squash
    case rebase
}

/// Pull request operations through `gh`.
public enum GitPullRequestAction: Hashable, Codable, Sendable {
    /// The current branch's pull request.
    case info
    /// The current branch's pull request number.
    case number
    case diff(number: UInt64, lineLimit: UInt32?)
    case list(filter: GitPullRequestFilter, limit: UInt32, checks: Bool)
    case create(title: String, body: String, baseBranch: String?, draft: Bool)
    /// Refuses when the head moved past `expectedHead`.
    case merge(number: UInt64, method: GitMergeMethod, deleteBranch: Bool, expectedHead: String?)
    case close(number: UInt64)
    case checkout(number: UInt64)
    case updateBranch(number: UInt64, expectedHead: String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "info": self = .info
        case "number": self = .number
        case "diff": self = .diff(number: try c("number"), lineLimit: try c("lineLimit"))
        case "list": self = .list(filter: try c("filter", default: .open), limit: try c("limit"), checks: try c("checks"))
        case "create":
            self = .create(title: try c("title"), body: try c("body"), baseBranch: try c("baseBranch"),
                           draft: try c("draft"))
        case "merge":
            self = .merge(number: try c("number"), method: try c("method", default: .merge),
                          deleteBranch: try c("deleteBranch"), expectedHead: try c("expectedHead"))
        case "close": self = .close(number: try c("number"))
        case "checkout": self = .checkout(number: try c("number"))
        case "updateBranch": self = .updateBranch(number: try c("number"), expectedHead: try c("expectedHead"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .info: try TaggedEncoding(encoder, "info")
        case .number: try TaggedEncoding(encoder, "number")
        case .diff(let number, let lineLimit):
            var c = try TaggedEncoding(encoder, "diff")
            try c(number, "number")
            try c(lineLimit, "lineLimit")
        case .list(let filter, let limit, let checks):
            var c = try TaggedEncoding(encoder, "list")
            try c(filter, "filter")
            try c(limit, "limit")
            try c(checks, "checks")
        case .create(let title, let body, let baseBranch, let draft):
            var c = try TaggedEncoding(encoder, "create")
            try c(title, "title")
            try c(body, "body")
            try c(baseBranch, "baseBranch")
            try c(draft, "draft")
        case .merge(let number, let method, let deleteBranch, let expectedHead):
            var c = try TaggedEncoding(encoder, "merge")
            try c(number, "number")
            try c(method, "method")
            try c(deleteBranch, "deleteBranch")
            try c(expectedHead, "expectedHead")
        case .close(let number):
            var c = try TaggedEncoding(encoder, "close")
            try c(number, "number")
        case .checkout(let number):
            var c = try TaggedEncoding(encoder, "checkout")
            try c(number, "number")
        case .updateBranch(let number, let expectedHead):
            var c = try TaggedEncoding(encoder, "updateBranch")
            try c(number, "number")
            try c(expectedHead, "expectedHead")
        }
    }
}

public struct GitChecks: Hashable, Codable, Sendable {
    public var passing: UInt32
    public var failing: UInt32
    public var pending: UInt32

    public init(passing: UInt32 = 0, failing: UInt32 = 0, pending: UInt32 = 0) {
        self.passing = passing
        self.failing = failing
        self.pending = pending
    }
}

public struct GitPullRequest: Hashable, Codable, Sendable {
    public var number: UInt64
    public var url: String
    public var title: String
    public var author: String
    public var headBranch: String
    public var headOid: String
    public var baseBranch: String
    /// `OPEN`, `CLOSED` or `MERGED`, as `gh` reports it.
    public var state: String
    public var draft: Bool
    public var updatedAt: String?
    public var mergeable: Bool?
    public var mergeState: String
    public var crossRepository: Bool
    public var checks: GitChecks

    public init(number: UInt64, url: String, title: String, author: String = "", headBranch: String,
                headOid: String = "", baseBranch: String, state: String, draft: Bool = false,
                updatedAt: String? = nil, mergeable: Bool? = nil, mergeState: String = "",
                crossRepository: Bool = false, checks: GitChecks = GitChecks()) {
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.headOid = headOid
        self.baseBranch = baseBranch
        self.state = state
        self.draft = draft
        self.updatedAt = updatedAt
        self.mergeable = mergeable
        self.mergeState = mergeState
        self.crossRepository = crossRepository
        self.checks = checks
    }
}

// MARK: - Replies

public enum GitReply: Hashable, Codable, Sendable {
    /// `nil` means a folder without a Git repository.
    case summary(GitSummary?)
    case branches([GitBranch])
    case changes([GitFile])
    case worktrees([GitWorktree])
    case removal(WorktreeRemoval)
    /// The project a worktree action created or registered.
    case project(ProjectDescriptor)
    case done
    case status(GitStatus)
    case repoInfo(GitRepoInfo)
    case remoteBranches([String])
    case log([GitCommit])
    case rawDiff(GitRawDiff)
    case diff(GitDiff)
    /// The new commit's hash.
    case commit(String)
    case pullRequest(GitPullRequest?)
    case pullRequestNumber(UInt64?)
    case pullRequests([GitPullRequest])
    case changesPreview(GitChangesPreview)
    case baseSwitch(GitBaseSwitch)
    case worktreeHooks([WorktreeHook])
    /// The worktree was created but its setup failed; it remains available.
    case worktreeSetupFailed(project: ProjectDescriptor, message: String)

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "summary": self = .summary(try c("summary"))
        case "branches": self = .branches(try c("branches"))
        case "changes": self = .changes(try c("files"))
        case "worktrees": self = .worktrees(try c("worktrees"))
        case "removal": self = .removal(try c("removal"))
        case "project": self = .project(try c("project"))
        case "done": self = .done
        case "status": self = .status(try c("status"))
        case "repoInfo": self = .repoInfo(try c("info"))
        case "remoteBranches": self = .remoteBranches(try c("branches"))
        case "log": self = .log(try c("commits"))
        case "rawDiff": self = .rawDiff(try c("diff"))
        case "diff": self = .diff(try c("diff"))
        case "commit": self = .commit(try c("hash"))
        case "pullRequest": self = .pullRequest(try c("pullRequest"))
        case "pullRequestNumber": self = .pullRequestNumber(try c("number"))
        case "pullRequests": self = .pullRequests(try c("pullRequests"))
        case "changesPreview": self = .changesPreview(try c("preview"))
        case "baseSwitch": self = .baseSwitch(try c("result"))
        case "worktreeHooks": self = .worktreeHooks(try c("hooks"))
        case "worktreeSetupFailed": self = .worktreeSetupFailed(project: try c("project"), message: try c("message"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .summary(let summary):
            var c = try TaggedEncoding(encoder, "summary")
            try c(summary, "summary")
        case .branches(let branches):
            var c = try TaggedEncoding(encoder, "branches")
            try c(branches, "branches")
        case .changes(let files):
            var c = try TaggedEncoding(encoder, "changes")
            try c(files, "files")
        case .worktrees(let worktrees):
            var c = try TaggedEncoding(encoder, "worktrees")
            try c(worktrees, "worktrees")
        case .removal(let removal):
            var c = try TaggedEncoding(encoder, "removal")
            try c(removal, "removal")
        case .project(let project):
            var c = try TaggedEncoding(encoder, "project")
            try c(project, "project")
        case .done: try TaggedEncoding(encoder, "done")
        case .status(let status):
            var c = try TaggedEncoding(encoder, "status")
            try c(status, "status")
        case .repoInfo(let info):
            var c = try TaggedEncoding(encoder, "repoInfo")
            try c(info, "info")
        case .remoteBranches(let branches):
            var c = try TaggedEncoding(encoder, "remoteBranches")
            try c(branches, "branches")
        case .log(let commits):
            var c = try TaggedEncoding(encoder, "log")
            try c(commits, "commits")
        case .rawDiff(let diff):
            var c = try TaggedEncoding(encoder, "rawDiff")
            try c(diff, "diff")
        case .diff(let diff):
            var c = try TaggedEncoding(encoder, "diff")
            try c(diff, "diff")
        case .commit(let hash):
            var c = try TaggedEncoding(encoder, "commit")
            try c(hash, "hash")
        case .pullRequest(let pullRequest):
            var c = try TaggedEncoding(encoder, "pullRequest")
            try c(pullRequest, "pullRequest")
        case .pullRequestNumber(let number):
            var c = try TaggedEncoding(encoder, "pullRequestNumber")
            try c(number, "number")
        case .pullRequests(let pullRequests):
            var c = try TaggedEncoding(encoder, "pullRequests")
            try c(pullRequests, "pullRequests")
        case .changesPreview(let preview):
            var c = try TaggedEncoding(encoder, "changesPreview")
            try c(preview, "preview")
        case .baseSwitch(let result):
            var c = try TaggedEncoding(encoder, "baseSwitch")
            try c(result, "result")
        case .worktreeHooks(let hooks):
            var c = try TaggedEncoding(encoder, "worktreeHooks")
            try c(hooks, "hooks")
        case .worktreeSetupFailed(let project, let message):
            var c = try TaggedEncoding(encoder, "worktreeSetupFailed")
            try c(project, "project")
            try c(message, "message")
        }
    }
}
