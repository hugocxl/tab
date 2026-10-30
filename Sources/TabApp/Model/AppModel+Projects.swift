import AppKit
import TabClient
import TabCore
import TabProtocol

extension AppModel {
    // MARK: Projects

    /// Adds a folder as a project of `server` and shows it; a folder that
    /// already is one is selected instead.
    @discardableResult
    public func addProject(_ directory: String, server: ServerId = .local) -> ProjectId? {
        let path = server.isLocal ? URL(fileURLWithPath: directory).standardizedFileURL.path : directory
        let canonical = server.isLocal ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        if let existing = state.projects.first(where: {
            guard $0.serverId == server else { return false }
            let saved = $0.directory.rawValue
            return saved == path || (server.isLocal && URL(fileURLWithPath: saved).resolvingSymlinksInPath().path == canonical)
        }) {
            edit { state in
                state.refreshProjectStatuses()
                state.joinActiveWorkspace(existing.id)
            }
            selectProject(existing.id)
            return existing.id
        }
        if server.isLocal, path == state.home.directory.rawValue {
            selectProject(state.home.id)
            return state.home.id
        }
        var added: ProjectId?
        guard edit({ added = try $0.addProject(server: server, directory: path) }) else { return nil }
        if let added { noteRecent(added) }
        return added
    }

    /// Renames a project; empty names are refused.
    public func renameProject(_ project: ProjectId, to name: String) {
        edit { try $0.renameProject(project, to: name) }
    }

    /// Moves a project before `target` in the sidebar, among its own
    /// server's projects.
    public func moveProject(_ project: ProjectId, before target: ProjectId) {
        guard project != target, let destination = state.projects.firstIndex(where: { $0.id == target }),
              let source = state.projects.firstIndex(where: { $0.id == project }),
              state.project(project)?.serverId.isLocal == state.project(target)?.serverId.isLocal
        else { return }
        let index = source < destination ? destination : destination
        edit { try $0.moveProject(project, to: index) }
    }

    /// Removes a project after confirmation, ending its terminals.
    public func confirmRemoveProject(_ project: ProjectId) {
        guard let target = state.project(project), !target.home else { return }
        Task {
            let confirmed = await presenter?.confirm(
                title: "Remove “\(title(of: target))”?",
                message: "Its terminals end and it leaves the sidebar. Its folder and files stay where they are.",
                confirm: "Remove Project",
                destructive: true
            ) ?? true
            guard confirmed else { return }
            removeProject(project)
        }
    }

    /// Removes a project and ends its terminals.
    public func removeProject(_ project: ProjectId) {
        guard let target = state.project(project) else { return }
        var sessions: [SessionId] = []
        let children = state.projects.filter { $0.parentId == project }.map(\.id)
        guard edit({ state in
            for child in children { sessions += try state.removeProject(child) }
            sessions += try state.removeProject(project)
        }) else { return }
        endSessions(sessions, on: target.serverId)
    }

    func endSessions(_ sessions: [SessionId], on server: ServerId) {
        guard !sessions.isEmpty else { return }
        guard let main = connections[server]?.main else {
            edit { state in for session in sessions { state.queueDiscard(server, session) } }
            return
        }
        Task {
            for session in sessions { try? await main.endSession(session) }
        }
    }

    // MARK: Workspaces

    @discardableResult
    public func createWorkspace(_ name: String, adding project: ProjectId? = nil) -> WorkspaceId? {
        var created: WorkspaceId?
        guard edit({ state in
            created = try state.createWorkspace(name)
            if let project, let created { try state.setWorkspaceMember(created, project: project, member: true) }
        }) else { return nil }
        return created
    }

    public func renameWorkspace(_ id: WorkspaceId, to name: String) {
        edit { try $0.renameWorkspace(id, to: name) }
    }

    public func deleteWorkspace(_ id: WorkspaceId) {
        edit { try $0.deleteWorkspace(id) }
    }

    /// Filters the sidebar to a workspace; `nil` lists every project.
    public func selectWorkspace(_ id: WorkspaceId?) {
        edit { state in
            try state.selectWorkspace(id)
            if !state.isListed(state.currentProject) { try state.selectProject(state.home.id) }
        }
    }

    public func selectRemoteServersWorkspace() {
        edit { $0.selectRemoteServers() }
    }

    public func setWorkspaceMember(_ id: WorkspaceId, project: ProjectId, member: Bool) {
        edit { try $0.setWorkspaceMember(id, project: project, member: member) }
    }

    /// Whether the fixed Remote Servers workspace is offered.
    public var offersRemoteServersWorkspace: Bool {
        state.projects.contains(where: \.isRemoteHome)
    }

    // MARK: Sidebar

    public func toggleSidebar() {
        updateAppearance { $0.sidebarExpanded.toggle() }
    }

    public func setSidebarWidth(_ width: CGFloat) {
        let clamped = min(max(width, Metrics.sidebarMinimumWidth), Metrics.sidebarMaximumWidth)
        updateAppearance { $0.sidebarExpandedWidth = Double(clamped) }
    }

    public var sidebarWidth: CGFloat {
        let width = appearance.sidebarExpandedWidth.map { CGFloat($0) } ?? Metrics.sidebarExpandedWidth
        return min(max(width, Metrics.sidebarMinimumWidth), Metrics.sidebarMaximumWidth)
    }

    public func setSidebarHost(_ host: SidebarHost) {
        updateAppearance { $0.sidebarHost = host }
        if !host.matches(currentProject.serverId) {
            edit { try $0.selectProject($0.home.id) }
        }
    }

    // MARK: Worktrees

    /// The project new worktrees go under: the current repository.
    public var newWorktreeTarget: ProjectId? {
        let current = currentProject
        let root = current.parentId ?? current.id
        guard let project = state.project(root), !project.home, project.status == .available,
              git[root]?.isRepository ?? false else { return nil }
        return root
    }

    /// Creates a worktree of `parent` and opens it. `base` nil checks out
    /// an existing branch.
    public func createWorktree(parent: ProjectId, name: String, branch: String, base: String?,
                               directory: String, hooks: [WorktreeHook]?) async -> String? {
        guard let side = sideClient(for: parent) else { return "Connect to the server to create a worktree." }
        worktreeCreations[parent, default: []].append(name)
        notify(.state)
        defer {
            worktreeCreations[parent]?.removeAll { $0 == name }
            notify(.state)
        }
        let intent = WorktreeIntent(
            action: .create(project: ProjectId(), directory: ServerPath(directory), branch: branch, base: base),
            options: WorktreeOptions(name: name, hooks: hooks)
        )
        do {
            let reply = try await side.git(GitRequest(project: parent, action: .worktree(intent)))
            let created: ProjectId?
            switch reply {
            case .project(let descriptor): created = descriptor.id
            case .worktreeSetupFailed(let descriptor, let message):
                report("Worktree created, but its setup failed: \(message)")
                created = descriptor.id
            default: created = nil
            }
            if let server = state.projectServer(parent), let main = connections[server]?.main,
               let catalog = try? await main.catalog() {
                applyCatalog(server, catalog)
            }
            if let created {
                selectProject(created)
                refreshGit(created)
            }
            return nil
        } catch {
            return error.message
        }
    }

    /// The setup hooks a new worktree of `parent` would run.
    public func worktreeHooks(parent: ProjectId, teardown: Bool) async -> Result<[WorktreeHook], ModelError> {
        guard let side = sideClient(for: parent) else { return .failure(ModelError("The server is not connected.")) }
        do {
            let reply = try await side.git(GitRequest(project: parent, action: .worktreeHooks(teardown: teardown)))
            guard case .worktreeHooks(let hooks) = reply else { return .success([]) }
            return .success(hooks)
        } catch {
            return .failure(ModelError(error.message))
        }
    }

    /// Removes a worktree and its files after confirmation, warning about
    /// uncommitted changes and running teardown hooks the user enables.
    public func confirmRemoveWorktree(_ project: ProjectId) {
        guard let target = state.project(project), target.kind == .worktree, let side = sideClient(for: project) else { return }
        Task {
            let removal: WorktreeRemoval
            do {
                let reply = try await side.git(GitRequest(project: project, action: .inspectRemoval))
                guard case .removal(let found) = reply else { return }
                removal = found
            } catch {
                report(error.message)
                return
            }
            let hooks = await worktreeHooks(parent: project, teardown: true)
            var message = removal.dirty
                ? "Remove worktree “\(target.name)” and permanently discard its uncommitted changes? Its terminals end and its files are deleted."
                : "Remove worktree “\(target.name)” and delete its files? Its terminals end."
            var approved: [WorktreeHook]?
            switch hooks {
            case .success(let list) where !list.isEmpty:
                message += "\n\nTeardown commands that will run:\n" + list.map {
                    "[\($0.project ? "Project" : "Per-machine")] \($0.command)"
                }.joined(separator: "\n")
                approved = list
            case .success:
                approved = nil
            case .failure(let error):
                message += "\n\nTeardown hooks could not be loaded: \(error)"
            }
            let confirmed = await presenter?.confirm(
                title: "Remove Worktree and Files?", message: message, confirm: "Remove", destructive: true
            ) ?? false
            guard confirmed else { return }
            worktreeRemovals.insert(project)
            notify(.state)
            defer {
                worktreeRemovals.remove(project)
                notify(.state)
            }
            let sessions = target.tabs.flatMap(\.panes).compactMap(\.content.session)
            let intent = WorktreeIntent(action: .remove(expected: removal), options: WorktreeOptions(hooks: approved))
            do {
                _ = try await side.git(GitRequest(project: project, action: .worktree(intent)))
                endSessions(sessions, on: target.serverId)
                if let main = connections[target.serverId]?.main, let catalog = try? await main.catalog() {
                    applyCatalog(target.serverId, catalog)
                }
            } catch {
                report(error.message)
            }
        }
    }

    /// Where a worktree named `name` on `branch` goes for a location choice.
    public func worktreeDirectory(parent: ProjectId, location: WorktreeLocation, name: String, branch: String) throws -> String {
        guard let project = state.project(parent) else { throw AppError.unknownProject(parent) }
        return try settings.worktrees.directory(
            projectName: project.name, projectDirectory: project.directory.rawValue,
            location: location, name: name, branch: branch,
            home: project.serverId.isLocal ? nil : state.serverHome(project.serverId)?.directory.rawValue
        )
    }

    /// Remembers a project's worktree location choice.
    public func saveWorktreeLocation(_ location: WorktreeLocation, for project: ProjectId) {
        var updated = settings
        updated.worktrees.projects[project] = location.isDefault ? nil : location
        do {
            try updated.saveWorktrees(to: dirs.settings)
            settings = updated
        } catch {
            report(error)
        }
    }

    // MARK: Theme

    /// Uses `name` for the current system appearance.
    public func setTheme(_ name: String) {
        updateAppearance { appearance in
            if theme.systemIsDark {
                appearance.darkTheme = name
            } else {
                appearance.lightTheme = name
            }
        }
    }
}
