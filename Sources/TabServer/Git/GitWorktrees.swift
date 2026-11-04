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
        // Fetching talks to the network, so it happens before the lock that
        // other worktree actions on this repository wait for.
        var fetchedStart: String?
        if case .create(_, _, _, let base?) = intent.action, intent.options?.fetchBase == true, !base.hasPrefix("-") {
            fetchedStart = remoteStart(GitRepository(path: repository, git: git), base: base)
        }
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
                                      base: base, name: intent.options?.name, hooks: approved, start: fetchedStart)
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
                        base: String?, name: String?, hooks approved: [WorktreeHook]?, start fetched: String? = nil,
                        validated: Bool = false) throws -> GitReply {
        let repository = GitRepository(path: parent.directory.rawValue, git: git)
        var start = base
        if !validated {
            try validateParent(parent, project: project, directory: directory)
            try repository.validateBranch(branch)
            if let base {
                if base.hasPrefix("-") { throw gitError("Invalid base branch") }
                try git.run(repository.path, ["rev-parse", "--verify", "\(base)^{commit}"])
                if let fetched { start = fetched }
            }
        }
        let branchExisted = git.optionalText(repository.path, ["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]) != nil
        try Self.reserveFolder(directory.rawValue)
        let target = canonical(directory.rawValue)
        guard let reserved = Self.identity(target) else { throw gitError("Reserved worktree directory is missing") }
        do {
            try addWorktree(repository, target: target, branch: branch, base: start, reserved: reserved)
        } catch {
            if let current = Self.identity(target), current == reserved { rmdir(target) }
            if !branchExisted { deleteUnusedBranch(repository, branch) }
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
        do {
            try catalog.addWorktreeProject(descriptor)
        } catch {
            // Without a project nothing shows the worktree, so undo it.
            _ = git.optionalText(repository.path, ["worktree", "remove", "--force", "--", target])
            if !branchExisted { deleteUnusedBranch(repository, branch) }
            throw error
        }
        if let setupFailure { return .worktreeSetupFailed(project: descriptor, message: setupFailure) }
        return .project(descriptor)
    }

    /// Fetches the branch `base` tracks (else the same name on `origin`)
    /// and returns the fresh remote copy as a start point. Nil, which starts
    /// from the local branch, when there is no remote or the fetch fails, so
    /// a stale or deleted remote branch is never used.
    private func remoteStart(_ repository: GitRepository, base: String) -> String? {
        let remotes = git.optionalText(repository.path, ["remote"])?.split(separator: "\n").map(String.init) ?? []
        let tracked = git.optionalText(repository.path, ["config", "--get", "branch.\(base).remote"]).flatMap { remotes.contains($0) ? $0 : nil }
        let merge = tracked == nil ? nil : git.optionalText(repository.path, ["config", "--get", "branch.\(base).merge"])
        let name = merge.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil } ?? base
        guard let remote = tracked ?? (remotes.contains("origin") ? "origin" : nil),
              !remote.hasPrefix("-"), !name.hasPrefix("-") else { return nil }
        let ref = "refs/remotes/\(remote)/\(name)"
        do {
            try git.network(repository.path, ["fetch", "--no-tags", "--", remote, "+refs/heads/\(name):\(ref)"])
        } catch {
            return nil
        }
        guard git.optionalText(repository.path, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"]) != nil else { return nil }
        return "\(remote)/\(name)"
    }

    /// Deletes a branch a failed creation made, unless a worktree uses it.
    private func deleteUnusedBranch(_ repository: GitRepository, _ branch: String) {
        guard let worktrees = try? repository.worktrees(), !worktrees.contains(where: { $0.branch == branch }) else { return }
        _ = git.optionalText(repository.path, ["branch", "-D", "--", branch])
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
        // A remote start point would otherwise become the new branch's upstream.
        if base != nil { arguments += ["--no-track", "-b", branch] }
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
        if let base {
            // Only a label for the sidebar: losing it costs nothing.
            _ = git.optionalText(repository.path, ["config", GitRepository.baseKey(branch), base])
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

    /// The worktree's identity and Git state, which a removal must still
    /// match. `ignored` also lists what Git ignores, for the question.
    func inspectRemoval(_ project: ProjectDescriptor, ignored: Bool = true) throws -> WorktreeRemoval {
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
                               branch: summary.branch, ignoredPaths: ignored ? try ignoredPaths(in: target) : nil)
    }

    /// Up to 50 ignored paths; `--untracked-files=normal` reports a folder
    /// Git ignores whole as one `dir/` entry.
    private func ignoredPaths(in directory: String) throws -> [String] {
        let output = try git.run(directory, ["status", "--porcelain=v1", "-z", "--ignored=matching", "--untracked-files=normal"])
        let entries = output.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
        return Array(entries.filter { $0.hasPrefix("!! ") }.map { String($0.dropFirst(3)) }.prefix(50))
    }

    private func remove(_ project: ProjectDescriptor, repository: String, expected: WorktreeRemoval,
                        hooks approved: [WorktreeHook]?) throws -> GitReply {
        if try !matches(inspectRemoval(project, ignored: false), expected) {
            throw gitError("Worktree changed; inspect and confirm removal again")
        }
        let target = project.directory.rawValue
        try catalog.endSessions(project: project.id, directory: canonical(target))
        try WorktreeProcesses.stop(in: target)
        if try !matches(inspectRemoval(project, ignored: false), expected) {
            throw gitError("Worktree changed while stopping sessions; inspect removal again")
        }
        if let approved, !approved.isEmpty {
            try hooks.run(approved, repository: repository, worktree: project, branch: expected.branch ?? "")
        }
        let current = try inspectRemoval(project, ignored: false)
        if current.device != expected.device || current.inode != expected.inode || current.head != expected.head
            || current.branch != expected.branch {
            throw gitError("Worktree identity changed during teardown; files were preserved")
        }
        try git.run(repository, ["worktree", "remove", "--force", "--", target])
        try catalog.removeWorktreeProject(project.id)
        return .done
    }

    /// Whether a fresh inspection still matches the confirmed one. Ignored
    /// files only inform the question, and programs keep writing them, so
    /// they don't count.
    private func matches(_ current: WorktreeRemoval, _ expected: WorktreeRemoval) -> Bool {
        var current = current
        current.ignoredPaths = expected.ignoredPaths
        return current == expected
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
