import AppKit
import Combine
import TabClient
import TabCore
import TabProtocol

/// The one main window: full-size content, hidden title, the window
/// buttons inset on the sidebar's top row, the saved frame. It presents
/// dialogs, the palette and toasts for the model.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, AppPresenter, WindowActions {
    public let model: AppModel
    let sidebar: SidebarViewController
    let workspace: WorkspaceView
    let actions: Actions
    let keys: KeyDispatcher
    private let palette: PaletteController
    private let paletteSource: PaletteSource
    private var pendingFolderBrowser: ServerId?
    private var settingsWindow: SettingsWindowController?
    let settingsHost: SettingsHostImpl
    private lazy var settingsStore = SettingsStore(dirs: model.dirs, host: settingsHost, theme: model.theme)
    private(set) lazy var dictation = DictationController(host: self)
    private var subscriptions: Set<AnyCancellable> = []

    /// The window buttons' top-left corner, centring them on the 36pt
    /// header row 8pt from the top, as Codesh places them.
    static let trafficLights = CGPoint(x: 2 * Metrics.gutter, y: Metrics.gutter + (Metrics.headerHeight - 14) / 2)
    /// The space between the window buttons' origins, as AppKit first
    /// lays them out.
    private var windowButtonStep: CGFloat?

    public init(model: AppModel) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        workspace = WorkspaceView(model: model, sidebar: sidebar)
        actions = Actions(model: model)
        keys = KeyDispatcher(model: model, actions: actions)
        settingsHost = SettingsHostImpl(model: model)
        let window = MainWindow(contentRect: Self.initialFrame(model), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 640, height: 400)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.title = Release.appName
        window.collectionBehavior = [.fullScreenPrimary]
        window.appearance = model.theme.nsAppearance
        palette = PaletteController(parent: window)
        paletteSource = PaletteSource(model: model)
        super.init(window: window)
        window.delegate = self
        window.contentView = workspace
        window.onLayout = { [weak self] in self?.placeWindowButtons() }
        sidebar.actions = self
        actions.window = self
        keys.window = window
        keys.commandMouseDown = { [weak self] event in
            guard let self, !self.palette.isOpen else { return false }
            return self.workspace.splits.handleCommandMouseDown(event)
        }
        keys.paletteKeyDown = { [weak self] event in
            guard let self, self.palette.isOpen else { return nil }
            return self.palette.handleKey(event)
        }
        keys.install()
        palette.source = paletteSource
        paletteSource.palette = palette
        paletteSource.actions = self
        paletteSource.perform = { [weak self] id in self?.actions.perform(id) }
        palette.actionsChord = model.settings.keymap.chord(.commandPaletteActions)
        settingsHost.store = settingsStore
        model.presenter = self
        model.showSettingsAction = { [weak self] category in self?.showSettings(category) }
        model.changes.sink { [weak self] changes in self?.modelChanged(changes) }.store(in: &subscriptions)
        model.theme.$palette.sink { [weak self] _ in self?.window?.appearance = self?.model.theme.nsAppearance }
            .store(in: &subscriptions)
        updateTitle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func initialFrame(_ model: AppModel) -> NSRect {
        if let bounds = model.state.window.bounds {
            let frame = NSRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        }
        let size = model.settings.window.defaultSize
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        return NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height)
    }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        placeWindowButtons()
        workspace.layoutSubtreeIfNeeded()
        model.focusActiveContent()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true, !self.palette.isOpen else { return }
            self.model.focusActiveContentIfIdle()
        }
        for problem in model.loadProblems { showToast(problem, error: true) }
    }

    private func modelChanged(_ changes: Set<ModelChange>) {
        if let server = pendingFolderBrowser, model.connectionState(server).isReady {
            pendingFolderBrowser = nil
            showRemoteFolderBrowser(server)
        }
        if changes.contains(.state) { updateTitle() }
        if changes.contains(.settings) {
            palette.actionsChord = model.settings.keymap.chord(.commandPaletteActions)
        }
        if changes.contains(.state) || changes.contains(.activity) {
            dictation.targetDidChange()
            if palette.isOpen, palette.page == .root { palette.refresh() }
        }
        if changes.contains(.panel) || changes.contains(.settings) { placeAgentsPanel() }
    }

    private func updateTitle() {
        let project = model.currentProject
        let title = project.home ? (model.activeTab?.title(active: model.activePane) ?? Release.appName) : model.title(of: project)
        if window?.title != title { window?.title = title }
        window?.representedURL = project.serverId.isLocal ? URL(fileURLWithPath: project.directory.rawValue) : nil
        window?.standardWindowButton(.documentIconButton)?.isHidden = true
    }

    // MARK: Window buttons

    /// Puts the close, minimize and zoom buttons on the sidebar's top row.
    func placeWindowButtons() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else {
            sidebar.trafficLightsEnd = Metrics.gutter
            return
        }
        let height = Self.trafficLights.y * 2 + close.frame.height
        let frame = NSRect(x: 0, y: window.frame.height - height, width: window.frame.width, height: height)
        if container.frame != frame { container.frame = frame }
        if windowButtonStep == nil, let minimize = window.standardWindowButton(.miniaturizeButton) {
            windowButtonStep = minimize.frame.minX - close.frame.minX
        }
        let step = windowButtonStep ?? close.frame.width + 6
        var x = Self.trafficLights.x
        var end = x
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let origin = NSPoint(x: x, y: (height - button.frame.height) / 2)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
            end = x + button.frame.width
            x += step
        }
        sidebar.trafficLightsEnd = end + 7
    }

    // MARK: NSWindowDelegate

    public func windowDidResize(_ notification: Notification) {
        placeWindowButtons()
        palette.parentFrameChanged()
        saveFrame()
    }

    public func windowDidMove(_ notification: Notification) {
        palette.parentFrameChanged()
        saveFrame()
    }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        model.saveWindowFrame(window.frame)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        model.windowDidChangeActive(true)
        model.focusActiveContentIfIdle()
    }

    public func windowDidResignKey(_ notification: Notification) {
        model.windowDidChangeActive(false)
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        sidebar.trafficLightsEnd = Metrics.gutter
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        placeWindowButtons()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: AppPresenter

    public var terminalActivityObscured: Bool { palette.isOpen || window?.attachedSheet != nil }

    public func confirm(title: String, message: String, confirm: String, destructive: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            ConfirmSheet.present(on: window, title: title, message: message, confirm: confirm, destructive: destructive,
                                 theme: model.theme) { continuation.resume(returning: $0) }
        }
    }

    public func showToast(_ message: String, error: Bool) {
        guard let view = window?.contentView else { return }
        Toast.show(message, style: error ? .error : .info, in: view, duration: error ? 5 : 2.5)
    }

    public func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    public func showRemoteFolderBrowser(_ server: ServerId) {
        guard let window else { return }
        model.connectOnDemand(server)
        guard model.connectionState(server).isReady else {
            pendingFolderBrowser = server
            return
        }
        let start = model.state.serverHome(server)?.directory ?? ServerPath("/")
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
        panel.appearance = model.theme.nsAppearance
        guard let browser = model.remoteController.makeFolderBrowser(server: server, start: start, choose: { [weak self] path in
            self?.model.addProject(path.rawValue, server: server)
        }) else { return }
        browser.dismiss = { [weak window, weak panel] in
            guard let panel else { return }
            window?.endSheet(panel)
        }
        let background = ThemedBackground(color: { $0.bg })
        background.addSubview(browser)
        browser.pinEdges(to: background)
        panel.contentView = background
        window.beginSheet(panel)
    }

    // MARK: WindowActions

    public func openPalette(_ page: PalettePage) {
        palette.toggle(page)
    }

    public func newWorktree(parent: ProjectId) {
        NewWorktreeDialog.present(model: model, parent: parent, on: window)
    }

    public func rename(project: ProjectId, anchor: NSView?) {
        guard let target = model.state.project(project) else { return }
        let title = target.parentId == nil ? "Rename Project" : "Rename Worktree"
        TextPrompt.show(title: title, value: target.name, confirm: "Rename", anchor: anchor, in: window) { [weak self] name in
            guard let self else { return nil }
            guard !name.isEmpty else { return "Enter a name." }
            self.model.renameProject(project, to: name)
            return nil
        }
    }

    public func newWorkspace(adding project: ProjectId?, anchor: NSView?) {
        TextPrompt.show(title: "New Workspace", value: "", confirm: "Create", anchor: anchor, in: window) { [weak self] name in
            guard let self else { return nil }
            guard !name.isEmpty else { return "Enter a name." }
            let created = self.model.createWorkspace(name, adding: project)
            if project == nil, let created { self.model.selectWorkspace(created) }
            return nil
        }
    }

    public func renameWorkspace(_ id: WorkspaceId, anchor: NSView?) {
        guard let workspace = model.state.workspace(id) else { return }
        TextPrompt.show(title: "Rename Workspace", value: workspace.name, confirm: "Rename", anchor: anchor, in: window) { [weak self] name in
            guard !name.isEmpty else { return "Enter a name." }
            self?.model.renameWorkspace(id, to: name)
            return nil
        }
    }

    public func addProject(anchor: NSView?) {
        guard !model.settings.servers.isEmpty, let anchor else {
            openPalette(.addProject(.local))
            return
        }
        var remote: [NSMenuItem] = serversByGroup(model.settings.servers, entry: { $0 }).flatMap { group, servers in
            let items: [NSMenuItem] = servers.map { server in
                ClosureMenuItem(server.name) { [weak self] in self?.openPalette(.addProject(server.id)) }
            }
            return group.map { [NSMenuItem.submenu($0, items)] } ?? items
        }
        remote.append(.separator())
        remote.append(ClosureMenuItem("Manage Remote Servers…") { [weak self] in self?.model.showServersPane() })
        let menu = NSMenu.make([
            ClosureMenuItem("Local") { [weak self] in self?.openPalette(.addProject(.local)) },
            .submenu("Remote", remote),
        ])
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height), in: anchor)
    }

    public func showSettings() {
        showSettings(nil)
    }

    func showSettings(_ category: SettingsCategory?) {
        let controller = settingsWindow ?? SettingsWindowController(store: settingsStore)
        settingsWindow = controller
        controller.show(category)
    }

    // MARK: Agents panel

    private func placeAgentsPanel() {
        let appearance = model.appearance
        let placement = AgentsPanelPlacement(appearance, sidebarExpanded: appearance.sidebarExpanded)
        if placement == .floating && appearance.agentsPanelVisible, let window {
            model.agentsPanel.placement = .floating
            model.agentsPanel.showFloating(over: window)
        } else {
            model.agentsPanel.closeFloating()
        }
    }

    // MARK: Quitting

    /// Ends this Mac's terminals, then quits without another confirmation.
    func endAllSessionsAndQuit() {
        guard let main = model.connections[.local]?.main, model.connectionState(.local).isReady else {
            model.report("Connect to the server before ending all sessions.")
            return
        }
        Task {
            do {
                for session in try await main.sessions() { try await main.endSession(session.id) }
                NSApp.terminate(nil)
            } catch {
                model.report("Could not end all sessions: \(error.localizedDescription)")
            }
        }
    }

    func toggleDictation() {
        dictation.toggle()
    }
}

extension MainWindowController: DictationHost {
    public var dictationTarget: DictationTarget? {
        guard let pane = model.activePane, let terminal = model.panes.controller(for: pane) as? TerminalPane else { return nil }
        return terminal.dictationTarget(overlayActive: dictation.isActive)
    }

    public var dictationOverlayContainer: NSView? { window?.contentView }

    public var voiceSettings: VoiceSettings { model.settings.voice }

    public func insertDictation(_ text: String, sendReturn: Bool, into target: DictationTarget) async throws {
        guard target == dictationTarget, let pane = model.activePane,
              let terminal = model.panes.controller(for: pane) as? TerminalPane, let session = terminal.session else {
            throw ModelError("The terminal is no longer there.")
        }
        session.view.pasteText(text)
        if sendReturn, let id = model.state.pane(pane)?.content.session, let main = model.client(for: model.currentProject.id) {
            try await main.writeInput(session: id, bytes: Data("\r".utf8))
        }
    }

    public func showDictationError(_ message: String) {
        showToast(message, error: true)
    }

    public func dictationDidEnd() {
        model.focusActiveContent()
    }
}

/// The main window; it places its buttons again whenever AppKit lays out
/// the title bar.
final class MainWindow: NSWindow {
    var onLayout: (() -> Void)?

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        onLayout?()
    }
}
