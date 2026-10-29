import Darwin
import Foundation
import TabProtocol

/// Creating, registering and removing worktree projects.
extension GitService {
    func performWorktree(owner: ProjectId, intent: WorktreeIntent) throws -> GitReply {
        let subject = try catalog.project(owner)
        let removing: Bool
        let created: ProjectId?
        switch intent.action {
        case .create(let project, _, _, _), .register(let project, _), .checkoutPullRequest(let project, _, _):
            (removing, created) = (false, project)
        case .remove:
            (removing, created) = (true, nil)
        }
        let repositoryProject: ProjectDescriptor
        if removing {
            guard let parentId = subject.parentId else { throw gitError("Missing worktree parent") }
            repositoryProject = try catalog.project(parentId)
        } else {
            repositoryProject = subject
        }
        let repository = repositoryProject.directory.rawValue
        return try lock(forRepository: repository).writing {
            let reserved = [owner, repositoryProject.id] + (created.map { [$0] } ?? [])
            return try operations.reserve(reserved, removal: removing ? canonical(subject.directory.rawValue) : nil) {
                _ = try catalog.project(repositoryProject.id)
                _ = try catalog.project(owner)
                let approved = intent.options?.hooks
                if let approved {
                    try hooks.verify(repository: repository, teardown: removing, approved: approved)
                }
                switch intent.action {
                case .create(let project, let directory, let branch, let base):
                    return try create(parent: subject, project: project, directory: directory, branch: branch,
                                      base: base, name: intent.options?.name, hooks: approved)
                case .checkoutPullRequest(let project, let directory, let number):
                    try validateParent(subject, project: project, directory: directory)
                    if FileManager.default.fileExists(atPath: directory.rawValue) {
                        throw gitError("Worktree directory already exists")
                    }
                    let branch = try github.prepareWorktree(GitRepository(path: repository, git: git), number: number)
                    return try create(parent: subject, project: project, directory: directory, branch: branch,
                                      base: nil, name: nil, hooks: approved, validated: true)
                case .register(let project, let directory):
                    return try register(parent: subject, project: project, directory: directory,
                                        name: intent.options?.name)
                case .remove(let expected):
                    return try remove(subject, repository: repository, expected: expected, hooks: approved)
                }
            }
        }
    }

    // MARK: - Create and register

    private func create(parent: ProjectDescriptor, project: ProjectId, directory: ServerPath, branch: String,
                        base: String?, name: String?, hooks approved: [WorktreeHook]?,
                        validated: Bool = false) throws -> GitReply {
        let repository = GitRepository(path: parent.directory.rawValue, git: git)
        if !validated {
            try validateParent(parent, project: project, directory: directory)
            try repository.validateBranch(branch)
            if let base {
                if base.hasPrefix("-") { throw gitError("Invalid base branch") }
                try git.run(repository.path, ["rev-parse", "--verify", "\(base)^{commit}"])
            }
        }
        try Self.reserveFolder(directory.rawValue)
        let target = canonical(directory.rawValue)
        guard let reserved = Self.identity(target) else { throw gitError("Reserved worktree directory is missing") }
        do {
            try addWorktree(repository, target: target, branch: branch, base: base, reserved: reserved)
        } catch {
            if let current = Self.identity(target), current == reserved { rmdir(target) }
            throw error
        }
        let descriptor = ProjectDescriptor(id: project, directory: ServerPath(target), name: name ?? branch,
                                           kind: .worktree, parentId: parent.id)
        var setupFailure: String?
        if let approved, !approved.isEmpty {
            do {
                let checkedOut = try GitRepository(path: target, git: git).summary().branch ?? ""
                try hooks.run(approved, repository: parent.directory.rawValue, worktree: descriptor, branch: checkedOut)
            } catch let error as ServiceError {
                setupFailure = error.message
            }
        }
        try catalog.addWorktreeProject(descriptor)
        if let setupFailure { return .worktreeSetupFailed(project: descriptor, message: setupFailure) }
        return .project(descriptor)
    }

    private func register(parent: ProjectDescriptor, project: ProjectId, directory: ServerPath,
                          name: String?) throws -> GitReply {
        try validateParent(parent, project: project, directory: directory)
        let entry = try validateMember(repository: parent.directory.rawValue, directory: directory.rawValue)
        let target = canonical(directory.rawValue)
        if entry.primary || canonical(parent.directory.rawValue) == target {
            throw gitError("This worktree is already the parent project")
        }
        let folder = (target as NSString).lastPathComponent
        let descriptor = ProjectDescriptor(id: project, directory: ServerPath(target),
                                           name: name ?? entry.branch ?? (folder.isEmpty ? "Detached worktree" : folder),
                                           kind: .worktree, parentId: parent.id)
        try catalog.addWorktreeProject(descriptor)
        return .project(descriptor)
    }

    private func validateParent(_ parent: ProjectDescriptor, project: ProjectId, directory: ServerPath) throws {
        if parent.home || parent.parentId != nil || parent.kind != nil {
            throw gitError("Worktrees require an ordinary top-level parent")
        }
        if !directory.isAbsolute { throw gitError("Worktree directory must be absolute") }
        let target = canonical(directory.rawValue)
        if (try? catalog.project(project)) != nil
            || catalog.children(of: parent.id).contains(where: { canonical($0.directory.rawValue) == target }) {
            throw gitError("Worktree is already registered")
        }
    }

    private func addWorktree(_ repository: GitRepository, target: String, branch: String, base: String?,
                             reserved: FileIdentity) throws {
        if let entry = try? validateMember(repository: repository.path, directory: target) {
            if entry.primary || entry.branch != branch { throw gitError("Worktree changed during creation") }
            return
        }
        try git.run(repository.path, ["worktree", "prune"])
        var arguments = ["worktree", "add"]
        if base != nil { arguments += ["-b", branch] }
        arguments += ["--", target, base ?? branch]
        do {
            try git.run(repository.path, arguments)
        } catch {
            // A failing post-checkout hook still leaves a usable worktree.
            guard let entry = try? validateMember(repository: repository.path, directory: target),
                  !entry.primary, entry.branch == branch else { throw error }
        }
        if Self.identity(target) != reserved {
            throw gitError("Worktree directory was replaced during creation")
        }
    }

    /// Creates the empty folder a new worktree fills, refusing one that exists.
    static func reserveFolder(_ directory: String) throws {
        let parent = (directory as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            throw gitError("Couldn't create \(parent): \(error.localizedDescription)")
        }
        guard mkdir(directory, 0o755) == 0 else {
            if errno == EEXIST { throw gitError("Worktree directory already exists") }
            throw gitError("Couldn't create \(directory): \(String(cString: strerror(errno)))")
        }
    }

    // MARK: - Remove

    /// The worktree's identity and Git state, which a removal must still match.
    func inspectRemoval(_ project: ProjectDescriptor) throws -> WorktreeRemoval {
        guard project.kind == .worktree else { throw gitError("Only a child worktree can be removed from disk") }
        guard let parentId = project.parentId else { throw gitError("Missing worktree parent") }
        let parent = try catalog.project(parentId)
        let target = project.directory.rawValue
        let entry = try validateMember(repository: parent.directory.rawValue, directory: target)
        if entry.primary || entry.locked { throw gitError("Primary or locked worktrees cannot be removed") }
        var info = stat()
        guard lstat(target, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw gitError("Worktree directory was replaced")
        }
        let repository = GitRepository(path: target, git: git)
        let status = try git.run(target, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let summary = try repository.summary()
        return WorktreeRemoval(directory: project.directory, device: UInt64(UInt32(bitPattern: info.st_dev)),
                               inode: info.st_ino, dirty: !status.isEmpty, status: status, head: summary.head,
                               branch: summary.branch)
    }

    private func remove(_ project: ProjectDescriptor, repository: String, expected: WorktreeRemoval,
                        hooks approved: [WorktreeHook]?) throws -> GitReply {
        if try inspectRemoval(project) != expected {
            throw gitError("Worktree changed; inspect and confirm removal again")
        }
        let target = project.directory.rawValue
        try catalog.endSessions(project: project.id, directory: canonical(target))
        try WorktreeProcesses.stop(in: target)
        if try inspectRemoval(project) != expected {
            throw gitError("Worktree changed while stopping sessions; inspect removal again")
        }
        if let approved, !approved.isEmpty {
            try hooks.run(approved, repository: repository, worktree: project, branch: expected.branch ?? "")
        }
        let current = try inspectRemoval(project)
        if current.device != expected.device || current.inode != expected.inode || current.head != expected.head
            || current.branch != expected.branch {
            throw gitError("Worktree identity changed during teardown; files were preserved")
        }
        try git.run(repository, ["worktree", "remove", "--force", "--", target])
        try catalog.removeWorktreeProject(project.id)
        return .done
    }

    // MARK: - Folder identity

    struct FileIdentity: Equatable {
        var device: Int32
        var inode: UInt64
    }

    static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
