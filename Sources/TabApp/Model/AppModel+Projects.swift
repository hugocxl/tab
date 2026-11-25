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

    /// Whether the left sidebar is visible in the current tab.
    public var sidebarExpanded: Bool {
        activeTab?.zoomed == nil && appearance.sidebarExpanded
    }

    public func toggleSidebar() {
        let expanded = !sidebarExpanded
        if activeTab?.zoomed != nil { toggleZoom() }
        updateAppearance { $0.sidebarExpanded = expanded }
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

    /// Creates a worktree of `parent` and opens it, the server running its
    /// `open` commands. `base` nil checks out an existing branch.
    public func createWorktree(parent: ProjectId, name: String, branch: String, base: String?,
                               directory: String) async -> String? {
        guard sideClient(for: parent) != nil else { return "Connect to the server to create a worktree." }
        let creationId = beginWorktreeCreation(WorktreeCreation(
            parent: parent, name: name, branch: branch, base: base,
            status: "Creating worktree…"
        ))
        defer { endWorktreeCreation(creationId) }
        let intent = WorktreeIntent(
            action: .create(project: ProjectId(), directory: ServerPath(directory), branch: branch, base: base),
            options: WorktreeOptions(name: name, runCommands: true)
        )
        return await runWorktreeCreation(creationId: creationId, parent: parent, intent: intent, opening: nil, setup: nil)
    }

    @discardableResult
    private func beginWorktreeCreation(_ creation: WorktreeCreation) -> UUID {
        worktreeCreations.append(creation)
        selectedWorktreeCreation = creation.id
        syncVisible()
        notify(.state)
        return creation.id
    }

    private func updateWorktreeCreation(_ id: UUID, _ change: (inout WorktreeCreation) -> Void) {
        guard let index = worktreeCreations.firstIndex(where: { $0.id == id }) else { return }
        var updated = worktreeCreations[index]
        change(&updated)
        guard updated != worktreeCreations[index] else { return }
        worktreeCreations[index] = updated
        notify(.state)
    }

    private func endWorktreeCreation(_ id: UUID) {
        let removed = worktreeCreations.contains { $0.id == id }
        worktreeCreations.removeAll { $0.id == id }
        if selectedWorktreeCreation == id {
            selectedWorktreeCreation = nil
            syncVisible()
            notify(.state)
        } else if removed {
            notify(.state)
        }
    }

    /// Sends a worktree creation and opens what it made: the project, or
    /// with `opening` a new pane of that kind in it. `setup` runs in a new
    /// terminal where the user can watch, beside an agent pane.
    private func runWorktreeCreation(creationId: UUID, parent: ProjectId, intent: WorktreeIntent,
                                     opening: PaneKind?, setup: [BranchCommand]?) async -> String? {
        guard let side = sideClient(for: parent) else { return "Connect to the server to create a worktree." }
        do {
            let reply = try await side.git(GitRequest(project: parent, action: .worktree(intent)))
            let created: ProjectDescriptor?
            switch reply {
            case .project(let descriptor): created = descriptor
            case .worktreeSetupFailed(let descriptor, let message):
                report("Worktree created, but its open commands failed: \(message)")
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
            // Remove the placeholder right as the real worktree opens so the
            // coalesced state notification swaps them in one frame.
            endWorktreeCreation(creationId)
            if let opening {
                let command = setup.flatMap { $0.isEmpty ? nil : $0 }.map {
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
    /// fetched from its remote first when `fetchBase`, where the settings put
    /// worktrees. An existing branch is checked out instead, or its worktree
    /// opened when one already has it. An empty `name` gets a short random
    /// one. The settings' `open` commands run in its first terminal, where
    /// the user can watch them.
    public func quickWorktree(parent: ProjectId, name: String, base chosen: String? = nil, fetchBase: Bool = false,
                              opening: PaneKind = .terminal) {
        guard let side = sideClient(for: parent) else { return report("Connect to the server to create a worktree.") }
        let typed = Self.quickBranchName(name)
        let creationId = beginWorktreeCreation(WorktreeCreation(
            parent: parent,
            name: typed.isEmpty ? WorktreeCreation.placeholderName : typed,
            branch: typed.isEmpty ? nil : typed,
            base: chosen,
            opening: opening,
            status: "Preparing worktree…"
        ))
        Task {
            defer { endWorktreeCreation(creationId) }
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
                if existing.checkedOut {
                    endWorktreeCreation(creationId)
                    return await openWorktree(of: parent, branch: worktreeName, opening: opening)
                }
            } else {
                base = chosen ?? branches.first(where: \.isDefault)?.name ?? branches.first(where: \.current)?.name
            }
            updateWorktreeCreation(creationId) { creation in
                creation.name = worktreeName
                creation.branch = worktreeName
                creation.base = base
                creation.status = base != nil && fetchBase
                    ? "Fetching latest \(base!) and creating worktree…"
                    : "Creating worktree…"
            }
            let settings = await branchSettings(parent: parent)
            guard let directory = quickWorktreeDirectory(parent: parent, branch: worktreeName, settings: settings) else { return }
            let intent = WorktreeIntent(
                action: .create(project: ProjectId(), directory: ServerPath(directory), branch: worktreeName, base: base),
                options: WorktreeOptions(name: worktreeName, fetchBase: base != nil && fetchBase ? true : nil)
            )
            if let message = await runWorktreeCreation(creationId: creationId, parent: parent, intent: intent,
                                                       opening: opening, setup: settings?.worktreeCommands.open) {
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
        guard sideClient(for: parent) != nil else { return report("Connect to the server to create a worktree.") }
        let name = "pr-\(number)"
        let creationId = beginWorktreeCreation(WorktreeCreation(
            parent: parent, name: name, branch: name, pullRequest: number,
            opening: opening, status: "Checking out pull request #\(number)…"
        ))
        Task {
            defer { endWorktreeCreation(creationId) }
            let settings = await branchSettings(parent: parent)
            guard let directory = quickWorktreeDirectory(parent: parent, branch: name, settings: settings) else { return }
            let intent = WorktreeIntent(action: .checkoutPullRequest(project: ProjectId(), directory: ServerPath(directory), number: number))
            if let message = await runWorktreeCreation(creationId: creationId, parent: parent, intent: intent,
                                                       opening: opening, setup: settings?.worktreeCommands.open) {
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

    /// Where a quick worktree on `branch` goes; nil, after saying why, when
    /// the settings' location is invalid.
    private func quickWorktreeDirectory(parent: ProjectId, branch: String, settings: BranchSettings?) -> String? {
        do {
            return try worktreeDirectory(parent: parent, location: settings?.worktreeLocation, branch: branch)
        } catch {
            report(error.message)
            return nil
        }
    }

    /// One line, typed into whatever shell the terminal runs, that runs
    /// `commands` in order as the server would: each in the user's shell
    /// with the variables server commands get, stopping at the first
    /// failure. The script travels as base64 for `/bin/sh` to decode, so
    /// neither the login shell's quoting (fish, nu) nor its line editor
    /// (tabs, newlines) touches it, and the commands keep the terminal as
    /// their input.
    static func setupCommand(_ commands: [BranchCommand], worktree: ProjectDescriptor, repository: String, branch: String) -> String {
        let variables = [
            "TAB_PROJECT_PATH=\(repository)", "TAB_BRANCH=\(branch)", "TAB_BRANCH_PATH=\(worktree.directory.rawValue)",
            "TAB_WORKTREE_ID=\(worktree.id.description)", "TAB_WORKTREE_NAME=\(worktree.name)",
        ]
        let script = commands.map { "\"${SHELL:-/bin/sh}\" -c " + Executable.commandLine([$0.command]) }.joined(separator: " && ")
        let decode = #"eval "$(printf %s "$1" | base64 -D)""#
        return Executable.commandLine(["env"] + variables + ["/bin/sh", "-c", decode, "tab-open", Data(script.utf8).base64EncodedString()])
    }

    /// Re-reads `server`'s projects after a worktree change.
    private func applyLatestCatalog(_ server: ServerId) async {
        guard let main = connections[server]?.main, let catalog = try? await main.catalog() else { return }
        applyCatalog(server, catalog)
    }

    /// The branch settings of `parent`'s project, from its server; nil,
    /// after saying why, when they can't be read, and empty from a server
    /// too old to read them.
    public func branchSettings(parent: ProjectId) async -> BranchSettings? {
        switch await loadBranchSettings(parent: parent) {
        case .success(let settings): return settings
        case .failure(let error):
            report(error.message)
            return nil
        }
    }

    public func loadBranchSettings(parent: ProjectId) async -> Result<BranchSettings, ModelError> {
        guard let side = sideClient(for: parent) else { return .failure(ModelError("The server is not connected.")) }
        do {
            guard case .branchSettings(let settings) = try await side.git(GitRequest(project: parent, action: .branchSettings))
            else { return .failure(ModelError("The server gave an unexpected reply.")) }
            return .success(settings)
        } catch ClientError.server(let reply) where reply.code == .unsupported {
            return .success(BranchSettings())
        } catch {
            return .failure(ModelError(error.message))
        }
    }

    /// Removes a worktree and its files after confirmation, warning about
    /// uncommitted changes; the server runs its `close` commands.
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
    /// changes, no ignored files, a branch. When the
    /// worktree can't be removed, its panes still close. Panes in `approved`
    /// already agreed to close. Closing the last pane requires confirmation
    /// even for a clean worktree, and keeps it open if inspection fails.
    public func closeWorktree(_ project: ProjectId, approved: Set<PaneId> = [], requiresConfirmation: Bool = false) {
        guard let target = state.project(project), target.kind == .worktree,
              pendingWorktreeRemovals.insert(project).inserted else { return }
        let panes = target.tabs.flatMap(\.panes).map(\.id)
        Task {
            defer { pendingWorktreeRemovals.remove(project) }
            guard await panesWillClose(panes.filter { !approved.contains($0) }) else { return }
            guard target.status == .available, sideClient(for: project) != nil else {
                if requiresConfirmation {
                    report("The worktree cannot be closed while its server or folder is unavailable.")
                } else {
                    await commitClose(panes)
                }
                return
            }
            if case .failed(let message) = await removeWorktree(project, closing: panes, requiresConfirmation: requiresConfirmation) {
                report("The worktree stays on disk: \(message)")
                if !requiresConfirmation {
                    await commitClose(state.project(project)?.tabs.flatMap(\.panes).map(\.id) ?? [])
                }
            }
        }
    }

    /// Closes a worktree's tab for `tab tab close`, whose user may be at
    /// another computer and never see a question here. Anything closing
    /// would lose fails the command, saying what, unless `force` says the
    /// user agreed. The panes close and the worktree goes after the reply,
    /// which the caller couldn't hear once its pane closes. Panes in
    /// `approved` already agreed to close.
    func closeWorktreeOnRequest(_ project: ProjectId, approved: Set<PaneId>, force: Bool) async throws {
        guard let target = state.project(project), target.kind == .worktree else {
            throw ModelError("that tab isn't a worktree's")
        }
        guard target.status == .available, sideClient(for: project) != nil else {
            throw ModelError("the worktree's server or folder is unavailable")
        }
        guard pendingWorktreeRemovals.insert(project).inserted else { throw ModelError("the worktree is already closing") }
        var closing = false
        defer { if !closing { pendingWorktreeRemovals.remove(project) } }
        let inspection = try await inspectRemoval(project)
        let losses = Self.losses(inspection)
        if !force, !losses.isEmpty {
            throw ModelError("closing \(target.name) removes the worktree and deletes its folder, and "
                + losses.joined(separator: "; ")
                + ". Its branch stays. Ask the user, and with their yes run tab tab close --force")
        }
        let panes = target.tabs.flatMap(\.panes).map(\.id)
        guard await panesWillClose(panes.filter { !approved.contains($0) }) else {
            throw ModelError("the user kept the tab open")
        }
        closing = true
        Task {
            defer { pendingWorktreeRemovals.remove(project) }
            guard case .failed(let message) = await performRemoval(project, inspection.removal, closing: panes) else {
                return
            }
            report("The worktree stays on disk: \(message)")
            await commitClose(state.project(project)?.tabs.flatMap(\.panes).map(\.id) ?? [])
        }
    }

    private enum RemovalOutcome { case removed, cancelled, failed(String) }

    /// What removing a worktree would do: Git's view of it.
    struct RemovalInspection {
        var removal: WorktreeRemoval
    }

    private func inspectRemoval(_ project: ProjectId) async throws -> RemovalInspection {
        guard let side = sideClient(for: project) else { throw ModelError("The server is not connected.") }
        let reply: GitReply
        do {
            reply = try await side.git(GitRequest(project: project, action: .inspectRemoval))
        } catch {
            throw ModelError(error.message)
        }
        guard case .removal(let removal) = reply else { throw ModelError("The server gave an unexpected reply.") }
        return RemovalInspection(removal: removal)
    }

    /// What removing a worktree loses beyond what a build makes again, or
    /// can't be told, each as a clause; empty when nothing is.
    static func losses(_ inspection: RemovalInspection) -> [String] {
        let removal = inspection.removal
        var losses: [String] = []
        if removal.dirty { losses.append("its uncommitted changes are discarded") }
        if removal.branch == nil { losses.append("it isn't on a branch, so commits made in it may be lost") }
        let ignored = removal.ignoredPaths ?? []
        let lost = ignored.filter { !isRebuildable($0) }
        if !lost.isEmpty {
            losses.append("files Git ignores are deleted: " + lost.prefix(5).joined(separator: ", ")
                + (lost.count > 5 ? " and more" : ""))
        } else if removal.ignoredPaths == nil || ignored.count >= 50 {
            // The server lists at most 50 ignored paths, so a full list may hide more.
            losses.append("files Git ignores may be deleted")
        }
        return losses
    }

    /// Removes a worktree after inspecting it. `closing` holds the panes of
    /// a tab being closed, closed just before the files go; nil is Remove
    /// Worktree, which always asks.
    private func removeWorktree(_ project: ProjectId, closing: [PaneId]?, requiresConfirmation: Bool = false) async -> RemovalOutcome {
        guard let target = state.project(project), target.kind == .worktree else {
            return .failed("The server is not connected.")
        }
        let inspection: RemovalInspection
        do {
            inspection = try await inspectRemoval(project)
        } catch {
            if closing == nil { report(error.message) }
            return .failed(error.message)
        }
        let removal = inspection.removal
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
        let mustAsk = requiresConfirmation || closing == nil || !Self.losses(inspection).isEmpty
            || git[project]?.summary?.base == nil
        if mustAsk {
            let confirmed = await presenter?.confirm(
                title: closing != nil ? "Close Worktree?" : "Remove Worktree and Files?", message: message,
                confirm: closing != nil ? "Close and Remove" : "Remove", destructive: true
            ) ?? false
            guard confirmed else { return .cancelled }
        }
        return await performRemoval(project, removal, closing: closing)
    }

    /// Closes `closing`, the worktree's panes, then removes the worktree as
    /// `removal` found it, the server running its `close` commands first.
    private func performRemoval(_ project: ProjectId, _ removal: WorktreeRemoval,
                                closing: [PaneId]?) async -> RemovalOutcome {
        guard let target = state.project(project), let side = sideClient(for: project) else {
            return .failed("The server is not connected.")
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
        let intent = WorktreeIntent(action: .remove(expected: removal), options: WorktreeOptions(runCommands: true))
        do {
            let reply = try await side.git(GitRequest(project: project, action: .worktree(intent)))
            if case .commandsFailed(let message) = reply {
                report("“\(target.name)” was removed, but its close commands failed: \(message)")
            }
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

    /// Where a worktree of `parent` on `branch` goes for `location`, a
    /// settings path template; nil is the default.
    public func worktreeDirectory(parent: ProjectId, location: String?, branch: String) throws -> String {
        guard let project = state.project(parent) else { throw AppError.unknownProject(parent) }
        return try TabConfig.worktreeDirectory(
            location: location, projectName: project.name, projectDirectory: project.directory.rawValue, branch: branch,
            home: project.serverId.isLocal ? nil : state.serverHome(project.serverId)?.directory.rawValue
        )
    }

    /// `path`, a folder typed for one worktree of `parent`, as an absolute
    /// path on the project's computer.
    public func worktreeFolder(parent: ProjectId, path: String) throws -> String {
        guard let project = state.project(parent) else { throw AppError.unknownProject(parent) }
        return TabConfig.resolve(project.directory.rawValue, path,
                                 home: project.serverId.isLocal ? nil : state.serverHome(project.serverId)?.directory.rawValue)
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
