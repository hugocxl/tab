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
        if let added {
            noteRecent(added)
            refreshGit(added)
        }
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

    /// Removes a project; its server ends its terminals when it removes it.
    public func removeProject(_ project: ProjectId) {
        guard state.project(project) != nil else { return }
        let children = state.projects.filter { $0.parentId == project }.map(\.id)
        edit { state in
            for child in children { _ = try state.removeProject(child) }
            _ = try state.removeProject(project)
        }
    }

    /// Ends `sessions` on a server that is connected.
    func endSessions(_ sessions: [SessionId], on server: ServerId) {
        guard !sessions.isEmpty, let main = connections[server]?.main else { return }
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
            if !state.showsTabs(of: state.currentProject) { try state.selectProject(state.home.id) }
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
        let intent = WorktreeIntent(
            action: .create(project: ProjectId(), directory: ServerPath(directory), branch: branch, base: base),
            options: WorktreeOptions(name: name, hooks: hooks)
        )
        return await runWorktreeCreation(parent: parent, label: name, intent: intent, opening: nil, setup: nil)
    }

    /// Sends a worktree creation and opens what it made: the project, or
    /// with `opening` a new pane of that kind in it. `setup` runs in a new
    /// terminal where the user can watch, beside an agent pane.
    private func runWorktreeCreation(parent: ProjectId, label: String, intent: WorktreeIntent,
                                     opening: PaneKind?, setup: [WorktreeHook]?) async -> String? {
        guard let side = sideClient(for: parent) else { return "Connect to the server to create a worktree." }
        worktreeCreations[parent, default: []].append(label)
        notify(.state)
        defer {
            worktreeCreations[parent]?.removeAll { $0 == label }
            notify(.state)
        }
        do {
            let reply = try await side.git(GitRequest(project: parent, action: .worktree(intent)))
            let created: ProjectDescriptor?
            switch reply {
            case .project(let descriptor): created = descriptor
            case .worktreeSetupFailed(let descriptor, let message):
                report("Worktree created, but its setup failed: \(message)")
                created = descriptor
            default: created = nil
            }
            if let server = state.projectServer(parent) { await applyLatestCatalog(server) }
            guard let created else { return nil }
            guard state.project(created.id) != nil else {
                report("“\(created.name)” was created, but Tab couldn't load it yet; it appears once the server reconnects.")
                return nil
            }
            // Only a repository with a remote had something to fetch.
            if intent.options?.fetchBase == true, case .create(_, _, _, let base?) = intent.action,
               git[parent]?.summary?.upstream != nil,
               case .summary(let summary?)? = try? await side.git(GitRequest(project: created.id, action: .summary)),
               summary.base == base {
                presenter?.showToast("Couldn't fetch the latest \(base), so “\(created.name)” starts from your local copy.", error: false)
            }
            if let opening {
                let command = setup.map {
                    Self.setupCommand($0, worktree: created, repository: state.project(parent)?.directory.rawValue ?? "",
                                      branch: git[created.id]?.summary?.branch ?? created.name)
                }
                if opening == .agent, command == nil {
                    newAgent(in: created.id)
                } else {
                    newTerminal(in: created.id, command: command, directory: created.directory)
                    if opening == .agent { newPane(.agent, in: created.id) }
                }
            } else {
                selectProject(created.id)
            }
            refreshGit(created.id)
            return nil
        } catch {
            return error.message
        }
    }

    /// Creates a worktree of `parent` in one step and opens an `opening`
    /// pane in it: branch `name` from `base` (the default branch when nil),
    /// fetched from its remote first when `fetchBase`, in the project's last
    /// worktree location. An existing branch is checked out instead, or its
    /// worktree opened when one already has it. An empty `name` gets a short
    /// random one. Setup commands run in the terminal once approved, and
    /// approval is remembered until they change.
    public func quickWorktree(parent: ProjectId, name: String, base chosen: String? = nil, fetchBase: Bool = false,
                              opening: PaneKind = .terminal) {
        guard let side = sideClient(for: parent) else { return report("Connect to the server to create a worktree.") }
        let typed = Self.quickBranchName(name)
        Task {
            let branches: [GitBranch]
            do {
                branches = try await side.gitBranches(parent)
            } catch {
                return report(error.message)
            }
            var worktreeName = typed
            while worktreeName.isEmpty || (typed.isEmpty && branches.contains { $0.name == worktreeName }) {
                worktreeName = "wt-" + UUID().uuidString.prefix(4).lowercased()
            }
            var base: String?
            if let existing = branches.first(where: { $0.name == worktreeName }) {
                if existing.checkedOut { return await openWorktree(of: parent, branch: worktreeName, opening: opening) }
            } else {
                base = chosen ?? branches.first(where: \.isDefault)?.name ?? branches.first(where: \.current)?.name
            }
            guard let directory = quickWorktreeDirectory(parent: parent, name: worktreeName) else { return }
            let setup = await approvedSetup(parent: parent, name: worktreeName)
            let intent = WorktreeIntent(
                action: .create(project: ProjectId(), directory: ServerPath(directory), branch: worktreeName, base: base),
                options: WorktreeOptions(name: worktreeName, fetchBase: base != nil && fetchBase ? true : nil)
            )
            if let message = await runWorktreeCreation(parent: parent, label: worktreeName, intent: intent,
                                                       opening: opening, setup: setup) {
                report(message)
            }
        }
    }

    /// What a typed name becomes as a branch: trimmed, with spaces as `-`.
    /// Slashes stay, so `feat/login` names that branch; its folder is made
    /// safe separately.
    static func quickBranchName(_ typed: String) -> String {
        typed.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// Checks out pull request `number` of `parent` into a new worktree and
    /// opens a pane of `opening` in it, as `quickWorktree` does.
    public func pullRequestWorktree(parent: ProjectId, number: UInt64, opening: PaneKind = .terminal) {
        let name = "pr-\(number)"
        Task {
            guard let directory = quickWorktreeDirectory(parent: parent, name: name) else { return }
            let setup = await approvedSetup(parent: parent, name: name)
            let intent = WorktreeIntent(action: .checkoutPullRequest(project: ProjectId(), directory: ServerPath(directory), number: number))
            if let message = await runWorktreeCreation(parent: parent, label: name, intent: intent,
                                                       opening: opening, setup: setup) {
                report(message)
            }
        }
    }

    /// Opens the worktree that has `branch` checked out, adding it to the
    /// sidebar when Tab doesn't show it yet.
    private func openWorktree(of parent: ProjectId, branch: String, opening: PaneKind) async {
        guard let side = sideClient(for: parent) else { return }
        do {
            guard case .worktrees(let worktrees) = try await side.git(GitRequest(project: parent, action: .worktrees)),
                  let found = worktrees.first(where: { $0.branch == branch }) else {
                return report("Branch “\(branch)” is checked out somewhere Tab can't find.")
            }
            if found.primary { return selectProject(parent) }
            if let registered = found.registered { return open(worktree: registered, opening: opening) }
            let intent = WorktreeIntent(action: .register(project: ProjectId(), directory: found.directory))
            guard case .project(let added) = try await side.git(GitRequest(project: parent, action: .worktree(intent))) else { return }
            if let server = state.projectServer(parent) { await applyLatestCatalog(server) }
            open(worktree: added.id, opening: opening)
        } catch {
            report(error.message)
        }
    }

    /// Shows a worktree, with an `opening` pane when nothing in it is open.
    private func open(worktree: ProjectId, opening: PaneKind) {
        guard let project = state.project(worktree) else { return }
        if project.tabs.contains(where: { !$0.panes.isEmpty }) {
            selectProject(worktree)
        } else if opening == .agent {
            newAgent(in: worktree)
        } else {
            newTerminal(in: worktree, directory: project.directory)
        }
    }

    private func quickWorktreeDirectory(parent: ProjectId, name: String) -> String? {
        let location = settings.worktrees.projects[parent] ?? WorktreeLocation()
        do {
            return try worktreeDirectory(parent: parent, location: location, name: name, branch: name)
        } catch {
            report(error.message)
            return nil
        }
    }

    /// The setup commands to run in a new worktree of `parent`: the ones the
    /// user approved before when they haven't changed, else after asking.
    /// Nil when there are none or the user declines.
    private func approvedSetup(parent: ProjectId, name: String) async -> [WorktreeHook]? {
        let hooks: [WorktreeHook]
        switch await worktreeHooks(parent: parent, teardown: false) {
        case .success(let list): hooks = list
        case .failure(let error):
            report("Setup commands could not be loaded, so “\(name)” is created without them: \(error.message)")
            return nil
        }
        guard !hooks.isEmpty else { return nil }
        let commands = hooks.map(\.command)
        if settings.worktrees.approvedSetup[parent] == commands { return hooks }
        let list = Self.hookList(hooks)
        let run = await presenter?.confirm(
            title: "Run Setup Commands?",
            message: "The new worktree “\(name)” can run these setup commands in its terminal:\n\(list)\n\n"
                + "Tab remembers your choice until they change. Cancel creates it without them.",
            confirm: "Run", destructive: false
        ) ?? false
        guard run else { return nil }
        var updated = settings
        updated.worktrees.approvedSetup[parent] = commands
        do {
            try updated.saveWorktrees(to: dirs.settings)
            settings = updated
        } catch {
            report(error)
        }
        return hooks
    }

    /// One line, typed into whatever shell the terminal runs, that runs
    /// `hooks` in order as the server would: each in the user's shell with
    /// the variables server hooks get, stopping at the first failure. The
    /// script travels as base64 for `/bin/sh` to decode, so neither the
    /// login shell's quoting (fish, nu) nor its line editor (tabs, newlines)
    /// touches it, and the commands keep the terminal as their input.
    static func setupCommand(_ hooks: [WorktreeHook], worktree: ProjectDescriptor, repository: String, branch: String) -> String {
        let variables = [
            "TAB_PROJECT_PATH=\(repository)", "TAB_WORKTREE_ID=\(worktree.id.description)",
            "TAB_WORKTREE_PATH=\(worktree.directory.rawValue)", "TAB_WORKTREE_NAME=\(worktree.name)",
            "TAB_WORKTREE_BRANCH=\(branch)",
        ]
        let script = hooks.map { "\"${SHELL:-/bin/sh}\" -c " + Executable.commandLine([$0.command]) }.joined(separator: " && ")
        let decode = #"eval "$(printf %s "$1" | base64 -D)""#
        return Executable.commandLine(["env"] + variables + ["/bin/sh", "-c", decode, "tab-setup", Data(script.utf8).base64EncodedString()])
    }

    /// Hooks as the questions about them list them.
    static func hookList(_ hooks: [WorktreeHook]) -> String {
        hooks.map { "[\($0.project ? "Project" : "Per-machine")] \($0.command)" }.joined(separator: "\n")
    }

    /// Re-reads `server`'s projects after a worktree change.
    private func applyLatestCatalog(_ server: ServerId) async {
        guard let main = connections[server]?.main, let catalog = try? await main.catalog() else { return }
        applyCatalog(server, catalog)
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
        guard pendingWorktreeRemovals.insert(project).inserted else { return }
        Task {
            defer { pendingWorktreeRemovals.remove(project) }
            _ = await removeWorktree(project, closing: nil)
        }
    }

    /// Closes a worktree's tab by removing the worktree and its files; its
    /// branch stays. Each pane is asked first, as closing it would, and the
    /// user too unless Tab made the worktree and nothing would be lost: no
    /// changes, no ignored files, a branch, no teardown commands. When the
    /// worktree can't be removed, its panes still close.
    public func closeWorktree(_ project: ProjectId) {
        guard let target = state.project(project), target.kind == .worktree,
              pendingWorktreeRemovals.insert(project).inserted else { return }
        let panes = target.tabs.flatMap(\.panes).map(\.id)
        Task {
            defer { pendingWorktreeRemovals.remove(project) }
            guard await panesWillClose(panes) else { return }
            guard target.status == .available, sideClient(for: project) != nil else {
                await commitClose(panes)
                return
            }
            if case .failed(let message) = await removeWorktree(project, closing: panes) {
                report("The worktree stays on disk: \(message)")
                await commitClose(state.project(project)?.tabs.flatMap(\.panes).map(\.id) ?? [])
            }
        }
    }

    private enum RemovalOutcome { case removed, cancelled, failed(String) }

    /// Removes a worktree after inspecting it. `closing` holds the panes of
    /// a tab being closed, closed just before the files go; nil is Remove
    /// Worktree, which always asks.
    private func removeWorktree(_ project: ProjectId, closing: [PaneId]?) async -> RemovalOutcome {
        guard let target = state.project(project), target.kind == .worktree, let side = sideClient(for: project) else {
            return .failed("The server is not connected.")
        }
        let removal: WorktreeRemoval
        do {
            guard case .removal(let found) = try await side.git(GitRequest(project: project, action: .inspectRemoval)) else {
                return .failed("The server gave an unexpected reply.")
            }
            removal = found
        } catch {
            if closing == nil { report(error.message) }
            return .failed(error.message)
        }
        let hooks = await worktreeHooks(parent: project, teardown: true)
        let kept = removal.branch.map { " Its branch “\($0)” is kept." } ?? ""
        var message: String
        if closing != nil {
            message = removal.dirty
                ? "“\(target.name)” has uncommitted changes. Closing it removes the worktree, discards them and deletes its files.\(kept)"
                : "Closing “\(target.name)” removes the worktree and deletes its files.\(kept)"
        } else {
            message = removal.dirty
                ? "Remove worktree “\(target.name)” and permanently discard its uncommitted changes? Its terminals end and its files are deleted."
                : "Remove worktree “\(target.name)” and delete its files? Its terminals end."
        }
        // Closing removes silently only what Tab made and can tell is safe:
        // a worktree on its own branch, with no changes, and nothing Git
        // ignores beyond folders a build makes again.
        let lost = (removal.ignoredPaths ?? []).filter { !Self.isRebuildable($0) }
        if !lost.isEmpty {
            message += "\n\nFiles Git ignores are deleted too: " + lost.prefix(5).joined(separator: ", ")
                + (lost.count > 5 ? " and more." : ".")
        }
        if removal.branch == nil { message += "\n\nIt isn't on a branch, so commits made in it may be lost." }
        var approved: [WorktreeHook]?
        // The server lists at most 50 ignored paths, so a full list may hide more.
        var mustAsk = closing == nil || removal.dirty || removal.branch == nil || removal.ignoredPaths == nil
            || (removal.ignoredPaths?.count ?? 0) >= 50 || !lost.isEmpty || git[project]?.summary?.base == nil
        switch hooks {
        case .success(let list) where !list.isEmpty:
            message += "\n\nTeardown commands that will run:\n" + Self.hookList(list)
            approved = list
            mustAsk = true
        case .success:
            approved = nil
        case .failure(let error):
            message += "\n\nTeardown hooks could not be loaded: \(error)"
            mustAsk = true
        }
        if mustAsk {
            let confirmed = await presenter?.confirm(
                title: closing != nil ? "Close Worktree?" : "Remove Worktree and Files?", message: message,
                confirm: closing != nil ? "Close and Remove" : "Remove", destructive: true
            ) ?? false
            guard confirmed else { return .cancelled }
        }
        worktreeRemovals.insert(project)
        notify(.state)
        defer {
            worktreeRemovals.remove(project)
            notify(.state)
        }
        if let closing {
            // Panes opened while the question was up get asked too.
            let current = state.project(project)?.tabs.flatMap(\.panes).map(\.id) ?? []
            guard await panesWillClose(current.filter { !closing.contains($0) }), await commitClose(current) else {
                return .cancelled
            }
        }
        let sessions = target.tabs.flatMap(\.panes).compactMap(\.content.session)
        let intent = WorktreeIntent(action: .remove(expected: removal), options: WorktreeOptions(hooks: approved))
        do {
            _ = try await side.git(GitRequest(project: project, action: .worktree(intent)))
            endSessions(sessions, on: target.serverId)
            await applyLatestCatalog(target.serverId)
            return .removed
        } catch {
            if closing == nil { report(error.message) }
            return .failed(error.message)
        }
    }

    /// Folders that dependency managers and builds fill and fill again,
    /// which closing a worktree may delete without asking.
    static let rebuildableFolders: Set<String> = [
        "node_modules", ".build", "dist", "target", ".next", ".nuxt", ".turbo", ".cache",
        ".parcel-cache", "DerivedData", ".gradle", "Pods", ".venv", "venv", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".swiftpm", ".dart_tool",
    ]

    /// An ignored path as `git status` lists it: a whole folder ends in `/`.
    static func isRebuildable(_ path: String) -> Bool {
        guard path.hasSuffix("/") else { return false }
        return rebuildableFolders.contains(String(path.dropLast().split(separator: "/").last ?? ""))
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
