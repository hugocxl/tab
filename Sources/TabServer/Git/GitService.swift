import Darwin
import Foundation
import TabCore
import TabProtocol

/// Git for server projects: status, staging, commits, branches, remotes,
/// diffs, worktrees and pull requests, all through the `git` and `gh`
/// executables. Reads of one repository overlap; changes run one at a time.
public final class GitService: GitServiceProtocol, @unchecked Sendable {
    let catalog: WorktreeCatalog
    let events: ServiceEvents
    let git: GitCommand
    let github: GitHub
    let hooks: WorktreeHooks
    let operations = WorktreeOperations()

    private let repositoryLocks = LockTable<String, ReadWriteLock> { ReadWriteLock() }
    private let operationLocks = LockTable<OperationId, NSLock> { NSLock() }
    private let mutex = NSLock()
    private var receipts: [OperationId: Receipt] = [:]
    private var receiptOrder: [OperationId] = []
    private var watches: [ClientId: RepositoryWatch] = [:]

    static let maxReceipts = 256

    /// What a worktree action answered, so a retry with the same operation
    /// id gets the same answer instead of acting twice.
    private struct Receipt {
        var owner: ProjectId
        var intent: WorktreeIntent
        var result: Result<GitReply, Error>
    }

    /// `catalog` resolves projects and records worktree projects; `events`
    /// delivers `gitChanged` to watching clients.
    public convenience init(projects catalog: WorktreeCatalog, events: ServiceEvents) {
        self.init(projects: catalog, events: events, lookup: .system, hooks: WorktreeHooks())
    }

    init(projects catalog: WorktreeCatalog, events: ServiceEvents, lookup: ExecutableLookup, hooks: WorktreeHooks) {
        self.catalog = catalog
        self.events = events
        self.git = GitCommand(lookup: lookup)
        self.github = GitHub(lookup: lookup)
        self.hooks = hooks
    }

    /// Lets the core refuse catalog changes and sessions that would race a
    /// worktree action.
    public var operationGuard: WorktreeOperationGuard { operations }

    public func handle(_ request: GitRequest, client: ClientId) async throws -> GitReply {
        try request.validate()
        return try await runBlocking { try self.perform(request, client: client) }
    }

    public func clientDisconnected(_ client: ClientId) {
        mutex.lock()
        let watch = watches.removeValue(forKey: client)
        mutex.unlock()
        watch?.stop()
    }

    // MARK: - Dispatch

    func perform(_ request: GitRequest, client: ClientId) throws -> GitReply {
        switch request.action {
        case .worktree(let intent):
            return try worktree(owner: request.project, intent: intent)
        case .unwatch:
            clientDisconnected(client)
            return .done
        case .watch:
            try watch(request.project, client: client)
            return .done
        default:
            break
        }
        let project = try catalog.project(request.project)
        let directory = project.directory.rawValue
        guard Self.isDirectory(directory) else { throw gitError("Project directory is missing") }
        let repository = GitRepository(path: directory, git: git)
        if request.action == .initRepository {
            if project.kind == .worktree { throw gitError("Cannot initialize a registered worktree") }
            let key = try repository.isRepository() ? try repository.commonDirectory() : canonical(directory) + "/.git"
            return try repositoryLocks.lock(for: key).writing {
                _ = try catalog.project(request.project)
                try git.run(directory, ["init"])
                return .done
            }
        }
        guard try repository.isRepository() else {
            if request.action == .summary, project.kind != .worktree { return .summary(nil) }
            throw gitError("Git worktree is missing")
        }
        if project.kind == .worktree {
            guard let parentId = project.parentId else { throw gitError("Missing worktree parent") }
            let parent = try catalog.project(parentId)
            _ = try validateMember(repository: parent.directory.rawValue, directory: directory)
        }
        let root = GitRepository(path: try repository.topLevel(), git: git)
        let lock = repositoryLocks.lock(for: try root.commonDirectory())
        let body = {
            // The project may have been deleted while waiting for another operation.
            _ = try self.catalog.project(request.project)
            return try self.dispatch(request.action, project: project, repository: root)
        }
        return Self.isRead(request.action) ? try lock.reading(body) : try lock.writing(body)
    }

    static func isRead(_ action: GitAction) -> Bool {
        switch action {
        case .summary, .branches, .changes, .worktrees, .worktreeHooks, .inspectRemoval, .status, .repoInfo,
             .remoteBranches, .log, .diff, .rawDiff, .branchDiff, .changesPreview, .stagedPreview:
            return true
        case .pullRequest(let action):
            switch action {
            case .info, .number, .diff, .list: return true
            default: return false
            }
        default:
            return false
        }
    }

    private func dispatch(_ action: GitAction, project: ProjectDescriptor, repository: GitRepository) throws -> GitReply {
        switch action {
        case .summary: return .summary(try repository.summary())
        case .branches: return .branches(try repository.branches())
        case .changes: return .changes(try repository.changes())
        case .status(let local):
            let pullRequest: GitPullRequest? = local ? nil : {
                if case .pullRequest(let info)? = try? github.apply(.info, in: repository) { return info }
                return nil
            }()
            return .status(GitStatus(summary: try repository.summary(), defaultBranch: github.defaultBranch(repository),
                                     branches: try repository.branches(), files: try repository.fileStatus(),
                                     pullRequest: pullRequest))
        case .repoInfo: return .repoInfo(try repository.repoInfo())
        case .remoteBranches: return .remoteBranches(try repository.remoteBranches())
        case .log(let maxCount, let skip): return .log(try repository.log(maxCount: maxCount, skip: skip))
        case .diff(let request): return try repository.diff(request, raw: false)
        case .rawDiff(let request): return try repository.diff(request, raw: true)
        case .branchDiff(let base, let lineLimit):
            return .rawDiff(try repository.branchDiff(base: base, lineLimit: lineLimit))
        case .changesPreview(let lineLimit):
            return .changesPreview(try repository.preview(lineLimit: lineLimit, staged: false))
        case .stagedPreview(let lineLimit):
            return .changesPreview(try repository.preview(lineLimit: lineLimit, staged: true))
        case .commitAll(let message, let expectedHead, let expectedTree):
            return .commit(try repository.commitAll(message: message, expectedHead: expectedHead,
                                                    expectedTree: expectedTree))
        case .commitStaged(let message, let expectedHead, let expectedTree):
            return .commit(try repository.commitStaged(message: message, expectedHead: expectedHead,
                                                       expectedTree: expectedTree))
        case .publishBranch(let branch, let destination):
            try repository.publish(branch: branch, expected: destination)
            return .done
        case .switchToBase(let base): return .baseSwitch(try repository.switchToBase(base))
        case .pullRequest(let action): return try github.apply(action, in: repository)
        case .commit(let message, let stageAll, let amend):
            return .commit(try repository.commit(message: message, stageAll: stageAll, amend: amend))
        case .push(let setUpstream): try repository.push(setUpstream: setUpstream)
        case .pull: try repository.pull()
        case .fetch: try repository.fetch()
        case .checkout(let hash): try repository.checkout(hash)
        case .cherryPick(let hash): try repository.cherryPick(hash)
        case .revert(let hash): try repository.revert(hash)
        case .createTag(let name, let hash): try repository.createTag(name: name, hash: hash)
        case .switchBranch(let branch): try repository.switchBranch(branch)
        case .createBranch(let branch): try repository.createBranch(branch)
        case .deleteBranch(let branch): try repository.deleteLocalBranch(branch, force: false)
        case .deleteLocalBranch(let name, let force): try repository.deleteLocalBranch(name, force: force)
        case .deleteRemoteBranch(let branch): try repository.deleteRemoteBranch(branch)
        case .stage(let paths): try repository.apply(.stage, to: paths)
        case .unstage(let paths): try repository.apply(.unstage, to: paths)
        case .discard(let paths): try repository.apply(.discard, to: paths)
        case .worktrees:
            let children = catalog.children(of: project.id)
            return .worktrees(try repository.worktrees().map { worktree in
                var worktree = worktree
                let directory = canonical(worktree.directory.rawValue)
                worktree.registered = children.first { canonical($0.directory.rawValue) == directory }?.id
                return worktree
            })
        case .worktreeHooks(let teardown):
            let source = try project.parentId.map { try catalog.project($0) } ?? project
            return .worktreeHooks(try hooks.resolve(repository: source.directory.rawValue, teardown: teardown))
        case .inspectRemoval: return .removal(try inspectRemoval(project))
        case .worktree, .initRepository, .watch, .unwatch:
            throw ServiceError(.badRequest, "Unsupported Git action")
        }
        return .done
    }

    // MARK: - Watching

    private func watch(_ projectId: ProjectId, client: ClientId) throws {
        let project = try catalog.project(projectId)
        let repository = GitRepository(path: project.directory.rawValue, git: git)
        var watch: RepositoryWatch?
        if Self.isDirectory(repository.path), try repository.isRepository() {
            let events = self.events
            watch = try RepositoryWatch(roots: try RepositoryWatch.roots(of: repository)) {
                events.send(.gitChanged(project: projectId), to: client)
            }
        }
        mutex.lock()
        let previous = watches.removeValue(forKey: client)
        if let watch { watches[client] = watch }
        mutex.unlock()
        previous?.stop()
    }

    // MARK: - Helpers

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The worktree of `repository` whose folder is `directory`.
    func validateMember(repository: String, directory: String) throws -> GitWorktree {
        let target = canonical(directory)
        guard let entry = try GitRepository(path: repository, git: git).worktrees().first(where: {
            canonical($0.directory.rawValue) == target
        }) else { throw gitError("Directory is not a registered Git worktree") }
        return entry
    }

    func lock(forRepository path: String) throws -> ReadWriteLock {
        repositoryLocks.lock(for: try GitRepository(path: path, git: git).commonDirectory())
    }

    /// Runs a worktree action once per operation id; retries get the first answer.
    private func worktree(owner: ProjectId, intent: WorktreeIntent) throws -> GitReply {
        let token = operationLocks.lock(for: intent.operation)
        token.lock()
        defer { token.unlock() }
        mutex.lock()
        let previous = receipts[intent.operation]
        mutex.unlock()
        if let previous {
            guard previous.owner == owner, previous.intent == intent else {
                throw gitError("Operation token reused with different worktree request")
            }
            return try previous.result.get()
        }
        let result = Result { try performWorktree(owner: owner, intent: intent) }
        mutex.lock()
        receipts[intent.operation] = Receipt(owner: owner, intent: intent, result: result)
        receiptOrder.append(intent.operation)
        if receiptOrder.count > Self.maxReceipts { receipts.removeValue(forKey: receiptOrder.removeFirst()) }
        mutex.unlock()
        return try result.get()
    }
}
