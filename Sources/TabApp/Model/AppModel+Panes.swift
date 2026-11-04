import AppKit
import TabClient
import TabCore
import TabProtocol

extension AppModel {
    // MARK: Opening terminals

    /// A new terminal (Cmd+T): a pane in the current project's tab, or a
    /// new tab when Home shows. It starts in the focused terminal's folder
    /// when there is one.
    public func newTerminal() {
        newTerminal(in: currentProject.id)
    }

    /// A new terminal in `project`, switching to it.
    public func newTerminal(in project: ProjectId, command: String? = nil, directory: ServerPath? = nil) {
        guard let target = state.project(project) else { return }
        let directory = directory ?? newPaneDirectory(in: target)
        var created: PaneId?
        edit { state in
            let tab = try state.openTerminalTab(project)
            created = state.window.activePane ?? state.project(project)?.tabs.first { $0.id == tab }?.layout.leaves.last
            if let pane = created {
                _ = state.prepareCreation(pane, directory: directory)
                if let command { try state.setStartupCommand(pane, command) }
            }
            state.revealCurrentProject()
        }
        connectOnDemand(target.serverId)
        focusActiveContent()
    }

    /// A new Home terminal (Cmd+N).
    public func newHomeTerminal() {
        newTerminal(in: state.home.id)
    }

    /// Where a new terminal in `project` starts: the focused terminal's
    /// folder when it is on the same server, else the project's.
    func newPaneDirectory(in project: Project) -> ServerPath {
        guard let pane = activePane,
              state.paneServer(pane) == project.serverId,
              let directory = (panes.controller(for: pane) as? TerminalPane)?.directory
        else { return project.directory }
        return directory
    }

    /// Splits the active pane with a new terminal on `edge` (Cmd+D, Cmd+Shift+D).
    public func split(_ edge: Direction) {
        guard let pane = activePane, let projectId = state.paneProject(pane), let project = state.project(projectId) else {
            newTerminal()
            return
        }
        let directory = newPaneDirectory(in: project)
        edit { state in
            let new = try state.splitPane(pane, edge: edge)
            _ = state.prepareCreation(new, directory: directory)
        }
        focusActiveContent()
    }

    /// Opens a running session of `project` that this app doesn't show.
    public func openExistingSession(_ session: SessionId, in project: ProjectId) {
        edit { state in
            guard let target = state.project(project) else { return }
            if target.home {
                let tab = try state.openTerminalTab(project)
                guard let pane = state.project(project)?.tabs.first(where: { $0.id == tab })?.layout.leaves.first else { return }
                try state.setPaneSession(pane, session)
                try state.focusPane(pane)
            } else {
                let pane = Pane(title: "Terminal", content: .terminal(session: session))
                try state.openPaneInContainer(project, pane: pane, focusLeaf: state.window.activePane)
                try state.selectProject(project)
                try state.focusPane(pane.id)
            }
        }
        focusActiveContent()
    }

    // MARK: New tabs and panes

    /// Opens a new tab (a new sidebar card) showing one `kind` pane. Only
    /// Home holds several tabs, so the tab goes in the Home shown now, or
    /// this Mac's.
    @discardableResult
    public func newTab(_ kind: PaneKind) -> PaneId? {
        let home = currentProject.home ? currentProject.id : state.home.id
        switch kind {
        case .terminal:
            newTerminal(in: home)
            return activePane
        case .agent: return newAgent(in: home)
        case .browser: return openBrowser(project: home)
        case .device: return openDevice(project: home)
        case .editor, .diff: return nil
        }
    }

    /// Adds a `kind` pane to an existing tab, on `edge` of the pane it
    /// shows: the Home tab `tab`, or `project`'s tab. A project with no tab
    /// yet gets one holding the pane.
    @discardableResult
    public func newPane(_ kind: PaneKind, in project: ProjectId, tab: TabId? = nil, edge: Direction = .right) -> PaneId? {
        guard let target = state.project(project) else { return nil }
        let shown = tab.flatMap { id in target.tabs.first { $0.id == id } } ?? (target.home ? nil : target.tabs.first)
        let anchor = shown.flatMap { tab in
            activePane.flatMap { tab.layout.contains($0) ? $0 : nil } ?? state.shownPane(tab) ?? tab.layout.leaves.last
        }
        guard let anchor else {
            switch kind {
            case .terminal:
                newTerminal(in: project)
                return activePane
            case .agent: return newAgent(in: project)
            case .browser: return openBrowser(project: project)
            case .device: return openDevice(project: project)
            case .editor, .diff: return nil
            }
        }
        let content: PaneContent
        switch kind {
        case .terminal: content = .terminal(session: nil)
        case .agent: content = .agent(session: SessionId(), provider: .claude)
        case .device: content = .device(DevicePane())
        case .browser:
            do {
                content = .browser(try newBrowserState(url: nil, profile: nil))
            } catch {
                report(error)
                return nil
            }
        case .editor, .diff: return nil
        }
        let pane = Pane(title: kind == .browser ? "New Browser" : content.nativeTitle ?? kind.name, content: content)
        let directory = newPaneDirectory(in: target)
        guard edit({ state in
            try state.insertSplitPane(after: anchor, pane, edge: edge)
            if kind == .terminal { _ = state.prepareCreation(pane.id, directory: directory) }
            try state.focusPane(pane.id)
            state.revealCurrentProject()
        }) else { return nil }
        if kind == .terminal || kind == .agent { connectOnDemand(target.serverId) }
        focusActiveContent()
        return pane.id
    }

    // MARK: Other pane kinds

    /// Opens an agent pane in a project's tab, or a new tab in Home; its initial
    /// provider is an internal seed for the composer.
    @discardableResult
    public func newAgent(in project: ProjectId? = nil, provider: TabCore.AgentChatProvider = .claude) -> PaneId? {
        let target = project ?? currentProject.id
        guard let project = state.project(target) else { return nil }
        var opened: PaneId?
        guard edit({ opened = try $0.openAgent(target, provider: provider) }) else { return nil }
        connectOnDemand(project.serverId)
        focusActiveContent()
        return opened
    }

    /// Shows a running terminal or agent conversation for `tab session open`
    /// and `tab agent`: focuses the pane already showing it, else opens one
    /// beside the pane showing `beside` on the same server, else in its project.
    @discardableResult
    public func show(_ request: AppPane) -> PaneId? {
        if let shown = state.paneShowing(request.session) {
            focusPane(shown)
            return shown
        }
        guard let project = state.project(request.project) else { return nil }
        let provider = request.provider ?? .claude
        let content: PaneContent = request.kind == .agent
            ? .agent(session: request.session, provider: provider) : .terminal(session: request.session)
        let anchor = request.beside.flatMap(state.paneShowing).flatMap { state.paneServer($0) == project.serverId ? $0 : nil }
        var opened: PaneId?
        if let anchor {
            let pane = Pane(title: request.kind == .agent ? "Agent" : "Terminal", content: content)
            guard edit({ state in
                try state.insertSplitPane(after: anchor, pane, edge: .right)
                try state.focusPane(pane.id)
                state.revealCurrentProject()
            }) else { return nil }
            opened = pane.id
        } else if request.kind == .agent {
            guard edit({ opened = try $0.openAgent(project.id, session: request.session, provider: provider) }) else { return nil }
        } else {
            openExistingSession(request.session, in: project.id)
            opened = state.paneShowing(request.session)
        }
        connectOnDemand(project.serverId)
        focusActiveContent()
        return opened
    }

    /// Puts `prompt` in the composer of the agent pane `pane`, once the pane

    /// shows and its composer takes text, for the user to review and send.
    func draftAgentPrompt(_ prompt: String, in pane: PaneId, attempts: Int = 40) {
        if let agent = controller(for: pane) as? AgentPaneController,
           (try? AgentConversationTemplateAction.append(prompt, expectedPrompt: "", surface: agent.surface)) != nil {
            return
        }
        guard attempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.draftAgentPrompt(prompt, in: pane, attempts: attempts - 1)
        }
    }

    /// Opens the existing server-owned conversation targeted by a body citation/link.
    @discardableResult
    func openExistingAgent(_ snapshot: AgentChatSnapshot) -> PaneId? {
        guard let project = state.project(snapshot.project) else { return nil }
        var opened: PaneId?
        guard edit({ opened = try $0.openAgent(project.id, session: snapshot.session, provider: snapshot.provider) }) else { return nil }
        connectOnDemand(project.serverId)
        focusActiveContent()
        return opened
    }

    /// Opens a file in an editor pane beside the focused pane, or focuses
    /// the project's editor for it. `line` and `column` are 1-based.
    @discardableResult
    public func openEditor(project: ProjectId, path: String, line: Int? = nil, column: Int? = nil) -> PaneId? {
        var opened: PaneId?
        guard edit({ opened = try $0.openEditorPane(project, path: RemoteFileCopy.reference(for: path) ?? Self.relative(path, in: $0.project(project))) }),
              let pane = opened else { return nil }
        if let line { editorLocations[pane] = (line, column ?? 1) }
        (controller(for: pane) as? EditorLocationReceiver)?.reveal(line: line, column: column)
        focusActiveContent()
        return pane
    }

    /// Opens a file's working tree or staged diff, or focuses the open one.
    @discardableResult
    public func openDiff(project: ProjectId, path: String, staged: Bool) -> PaneId? {
        var opened: PaneId?
        guard edit({ opened = try $0.openDiffPane(project, path: Self.relative(path, in: $0.project(project)), staged: staged) })
        else { return nil }
        focusActiveContent()
        return opened
    }

    /// Opens a browser pane in `project` (the current one by default).
    @discardableResult
    public func openBrowser(url: String? = nil, project: ProjectId? = nil, profile: String? = nil, select: Bool = true) -> PaneId? {
        let browser: BrowserPane
        do {
            browser = try newBrowserState(url: url, profile: profile == "" ? nil : profile)
        } catch {
            report(error)
            return nil
        }
        let target = project ?? currentProject.id
        var opened: PaneId?
        guard edit({ opened = try $0.openBrowser(target, browser, select: select).1 })
        else { return nil }
        if select { focusActiveContent() }
        return opened
    }

    /// Opens a device pane in `project` (the current one by default),
    /// showing the simulator picker.
    @discardableResult
    public func openDevice(project: ProjectId? = nil, select: Bool = true) -> PaneId? {
        let target = project ?? currentProject.id
        var opened: PaneId?
        guard edit({ opened = try $0.openDevice(target, DevicePane(), select: select).1 }) else { return nil }
        if select { focusActiveContent() }
        return opened
    }

    /// The line and column an editor pane was opened at, taken once.
    public func takeEditorLocation(_ pane: PaneId) -> (line: Int, column: Int)? {
        editorLocations.removeValue(forKey: pane)
    }

    static func relative(_ path: String, in project: Project?) -> String {
        guard path.hasPrefix("/"), let root = project?.directory.rawValue else { return path }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: Focus

    /// Focuses `pane`, selecting its project and tab.
    public func focusPane(_ pane: PaneId) {
        guard state.window.activePane != pane || state.currentProject.id != state.paneProject(pane) else {
            controller(for: pane)?.focusContent()
            return
        }
        edit { try $0.focusPane(pane) }
        controller(for: pane)?.focusContent()
    }

    /// Makes `pane` the active one when a click lands in it, leaving the
    /// keyboard to whatever the click gives it, as a terminal gaining focus
    /// does for itself.
    public func activatePane(_ pane: PaneId) {
        guard state.window.activePane != pane || state.currentProject.id != state.paneProject(pane) else { return }
        edit { try $0.focusPane(pane) }
    }

    /// Gives the keyboard to the active pane's content.
    public func focusActiveContent() {
        guard let pane = activePane else { return }
        Task { [weak self] in
            for attempt in 0..<100 {
                guard let self, self.activePane == pane, let controller = self.controller(for: pane) else { return }
                if attempt > 0 {
                    guard let window = self.presenter?.window, window.isKeyWindow,
                          window.firstResponder == nil || window.firstResponder === window else { return }
                }
                controller.focusContent()
                guard controller is EditorPaneContent, !controller.hasFocus else { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Gives the keyboard to the active pane when nothing in the window has
    /// it, such as when the window first becomes key after launch.
    public func focusActiveContentIfIdle() {
        guard let window = presenter?.window, window.firstResponder == nil || window.firstResponder === window else { return }
        focusActiveContent()
    }

    /// Focuses the pane on `direction` of the active one (Cmd+Opt+Arrows).
    public func focus(_ direction: Direction) {
        guard let pane = activePane, let neighbor = state.neighbor(of: pane, direction) else { return }
        focusPane(neighbor)
    }

    public func toggleZoom(_ pane: PaneId? = nil) {
        guard let pane = pane ?? activePane else { return }
        edit { try $0.toggleZoom(pane) }
        focusActiveContent()
    }

    public func equalizeSplits() {
        guard let pane = activePane else { return }
        edit { try $0.equalizeSplits(pane) }
    }

    /// Sets a split's ratio while its gutter is dragged.
    public func setRatio(tab: TabId, path: [Branch], ratio: Double) {
        edit { try $0.setRatio(tab, path: path, ratio: ratio) }
    }

    /// Drops `pane` on `target`: on an edge, or swapping places.
    public func drop(_ pane: PaneId, on target: DropTarget) {
        edit { state in
            switch target {
            case .swap(let other): try state.movePane(pane, onto: other, edge: nil)
            case let .dock(anchor, edge, level): try state.dockPane(pane, beside: anchor, edge: edge, level: level)
            }
        }
    }

    // MARK: Closing

    /// Closes `pane` after its content agrees, such as a confirmation that a
    /// program is running. A terminal ends unless another pane shows it, or
    /// detaches when Settings closes terminals that way.
    public func closePane(_ pane: PaneId? = nil) {
        guard let pane = pane ?? activePane else { return }
        Task {
            guard await controller(for: pane)?.willClose() ?? true else { return }
            guard await controller(for: pane)?.commitClose() ?? true else { return }
            remove(pane)
            focusActiveContent()
        }
    }

    func remove(_ pane: PaneId) {
        guard let found = state.pane(pane) else { return }
        if found.content.isTerminal {
            if settings.window.closeBehavior == .detach {
                edit { try $0.detachPane(pane) }
            } else {
                edit { try $0.closeSessionPane(pane) }
            }
        } else {
            edit { try $0.closePane(pane) }
        }
        panes.remove(pane)
    }

    /// Closes every pane of the current project, or the current Home
    /// terminal (Cmd+Shift+W).
    public func closeTab() {
        guard let tab = activeTab else { return }
        let ids = tab.panes.map(\.id)
        Task {
            for id in ids {
                guard await controller(for: id)?.willClose() ?? true else { return }
            }
            for id in ids {
                guard await controller(for: id)?.commitClose() ?? true else { return }
                remove(id)
            }
            focusActiveContent()
        }
    }

    /// Closes the pane but leaves its terminal running.
    public func detachTerminal(_ pane: PaneId? = nil) {
        guard let pane = pane ?? activePane, state.pane(pane)?.content.isTerminal == true else { return }
        edit { try $0.detachPane(pane) }
        panes.remove(pane)
        focusActiveContent()
    }

    // MARK: Projects and tabs

    /// Shows `project`, connecting its server when needed.
    public func selectProject(_ project: ProjectId) {
        guard let target = state.project(project), target.status == .available else { return }
        edit { state in
            try state.selectProject(project)
            state.revealCurrentProject()
        }
        noteRecent(project)
        connectOnDemand(target.serverId)
        focusActiveContent()
    }

    /// Shows a Home terminal.
    public func selectTab(_ tab: TabId) {
        guard let project = state.projects.first(where: { $0.tabs.contains { $0.id == tab } }) else { return }
        edit { try $0.selectTab(project.id, tab) }
        connectOnDemand(project.serverId)
        focusActiveContent()
    }

    /// Selects a sidebar card.
    public func select(_ target: SidebarListing.Target) {
        switch target {
        case .tab(let tab): selectTab(tab)
        case .project(let project): selectProject(project)
        }
    }

    /// Cmd+1–9: the sidebar's nth card.
    public func selectCard(_ index: Int) {
        let targets = sidebarListing.targets
        guard targets.indices.contains(index) else { return }
        select(targets[index])
    }

    /// Ctrl+1–9: the sidebar's nth project.
    public func selectProject(at index: Int) {
        let projects = navigationProjects
        guard projects.indices.contains(index) else { return }
        selectProject(preferredWorktree(projects[index]))
    }

    /// Next or previous card (Cmd+] / Cmd+[).
    public func cycleCard(forward: Bool) {
        let targets = sidebarListing.targets
        guard !targets.isEmpty else { return }
        let current: SidebarListing.Target = currentProject.home
            ? activeTab.map { .tab($0.id) } ?? .project(currentProject.id)
            : .project(currentProject.id)
        let next = targets.firstIndex(of: current).map { index in
            forward ? (index + 1) % targets.count : (index - 1 + targets.count) % targets.count
        } ?? (forward ? 0 : targets.count - 1)
        select(targets[next])
    }

    /// Next or previous project (Ctrl+] / Ctrl+[).
    public func cycleProject(forward: Bool) {
        let projects = navigationProjects
        guard !projects.isEmpty else { return }
        let current = currentProject.parentId ?? currentProject.id
        let next = projects.firstIndex(of: current).map { index in
            forward ? (index + 1) % projects.count : (index - 1 + projects.count) % projects.count
        } ?? 0
        selectProject(preferredWorktree(projects[next]))
    }

    /// Listed top-level projects whose folders are there.
    public var navigationProjects: [ProjectId] {
        listingBuilder().listedParents().filter { $0.status == .available }.map(\.id)
    }

    /// The worktree of `parent` to show: the current one, else the most
    /// recently used, else the parent.
    public func preferredWorktree(_ parent: ProjectId) -> ProjectId {
        let current = currentProject
        if (current.id == parent || current.parentId == parent) && current.status == .available { return current.id }
        return appearance.worktreeRecent.first { id in
            guard let candidate = state.project(id) else { return false }
            return (candidate.id == parent || candidate.parentId == parent) && candidate.status == .available
        } ?? parent
    }

    func noteRecent(_ project: ProjectId) {
        guard appearance.projectRecent.first != project || appearance.worktreeRecent.first != project else { return }
        updateAppearance { appearance in
            appearance.projectRecent.removeAll { $0 == project }
            appearance.projectRecent.insert(project, at: 0)
            appearance.projectRecent = Array(appearance.projectRecent.prefix(50))
            appearance.worktreeRecent.removeAll { $0 == project }
            appearance.worktreeRecent.insert(project, at: 0)
            appearance.worktreeRecent = Array(appearance.worktreeRecent.prefix(50))
        }
    }
}

/// An editor pane that can jump to a line once open.
@MainActor
public protocol EditorLocationReceiver: AnyObject {
    func reveal(line: Int?, column: Int?)
}

/// Where a dragged pane lands.
public enum DropTarget: Equatable, Sendable {
    case swap(PaneId)
    /// Beside `pane`, or beside the enclosing row or column `level` picks.
    case dock(pane: PaneId, edge: Direction, level: Int)
}
