import AppKit
import TabClient
import TabCore
import TabProtocol

/// A terminal pane: a `TerminalSessionController` attached through its
/// server's main connection, made once the server created the session and
/// again after a reconnect, keeping the last screen meanwhile.
@MainActor
final class TerminalPane: PaneContentController {
    let pane: PaneId
    let server: ServerId
    let project: ProjectId
    weak var model: AppModel?
    let view: NSView
    var titleDidChange: (() -> Void)?

    private let host: TerminalHostView
    private(set) var session: TerminalSessionController?
    private var backend: ObjectIdentifier?
    private var visible = false
    private var lastGrid: RunGrid?
    private var fontSize: Double?

    init(context: PaneContext) {
        pane = context.pane.id
        server = context.project.serverId
        project = context.project.id
        model = context.model
        host = TerminalHostView()
        view = host
        refresh()
    }

    // MARK: PaneContentController

    var title: String {
        if let session, !session.displayTitle.isEmpty { return session.displayTitle }
        return model?.state.pane(pane)?.title ?? "Terminal"
    }

    var icon: NSImage? {
        guard let agent = model?.agent(in: pane) else { return nil }
        return AgentLogo.image(for: agent.provider, lightBackground: AppTheme.shared.palette.isLight)
    }

    var progress: TerminalProgress? { model?.progress(in: pane) }

    var directory: ServerPath? { session?.directory }

    /// The grid size to create the session with, from the pane's size.
    var estimatedSize: Size? {
        guard let session, session.view.bounds.width > 0 else { return nil }
        return session.view.viewport
    }

    var hasFocus: Bool { session?.view.isFocused ?? false }

    func focusContent() {
        guard let session else {
            view.window?.makeFirstResponder(host)
            return
        }
        view.window?.makeFirstResponder(session.view)
    }

    func didShow() {
        visible = true
        refresh()
        guard let session else { return }
        session.setVisible(true)
        if session.state == .detached { attachWhenLaidOut(session) }
    }

    func didHide() {
        visible = false
        session?.setVisible(false)
    }

    func dispose() {
        session?.detach()
        session = nil
    }

    var headerActions: [PaneAction] {
        guard let model, model.state.pane(pane)?.proxy == true else { return [] }
        return [PaneAction(id: "proxy", icon: .network, label: "Uses the proxy", isActive: true) { [weak model] in
            model?.proxyController.showSetUp()
        }]
    }

    var contextMenu: NSMenu? { nil }

    /// Terminal key bindings and the terminal's own shortcuts come before the
    /// app's while the terminal has the keyboard.
    func handleKeyFirst(_ event: NSEvent) -> Bool {
        guard let view = session?.view, view.isFocused, view.handledShortcut(event) != nil else { return false }
        return view.performKeyEquivalent(with: event)
    }

    /// Asks before closing while a program other than the shell runs.
    func willClose() async -> Bool {
        guard let model, model.settings.window.confirmRunningProcess,
              let process = session?.process, !process.isShell, !process.name.isEmpty,
              model.settings.window.closeBehavior == .closeSession
        else { return true }
        return await model.presenter?.confirm(
            title: "Close this terminal?",
            message: "“\(process.name)” is still running in it. Closing the terminal ends it.",
            confirm: "Close",
            destructive: true
        ) ?? true
    }

    // MARK: Session

    /// Makes or remakes the session controller when the pane has a session
    /// and its server is connected.
    func refresh() {
        guard let model else { return }
        let sessionId = model.state.pane(pane)?.content.session
        let connection = model.connections[server]
        guard let sessionId, let client = connection?.main, connection?.state.isReady == true else {
            if session == nil { host.status = statusText() }
            return
        }
        let identity = ObjectIdentifier(client)
        if let session, session.session == sessionId, backend == identity { return }
        let responder = host.window?.firstResponder
        let unfocused = responder == nil || responder === host.window
        let hadFocus = responder === host || (session.map { responder === $0.view } ?? false)
            || unfocused && model.activePane == pane
        if let old = session {
            lastGrid = old.view.grid
            fontSize = old.view.fontSize
            old.detach()
        }
        let controller = TerminalSessionController(
            session: sessionId, backend: client.terminalBackend, settings: model.terminalSettings,
            palette: palette(), remote: !server.isLocal, directory: nil, cachedGrid: lastGrid
        )
        controller.view.basePadding = 2
        controller.view.shortcuts = Self.shortcuts(model.settings.keymap)
        if let fontSize { controller.view.setFontSize(fontSize) }
        controller.delegate = self
        controller.view.delegate = self
        session = controller
        backend = identity
        host.content = controller.containerView
        if hadFocus { host.window?.makeFirstResponder(controller.view) }
        host.status = nil
        if visible {
            attachWhenLaidOut(controller)
        } else {
            controller.setVisible(false)
        }
        titleDidChange?()
    }

    /// Attaches once the view has its size, so the session gets the pane's
    /// grid rather than an empty one.
    private func attachWhenLaidOut(_ controller: TerminalSessionController, attempt: Int = 0) {
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) { [weak self, weak controller] in
            MainActor.assumeIsolated {
                guard let self, let controller, self.session === controller, self.visible else { return }
                self.host.layoutSubtreeIfNeeded()
                guard controller.view.viewport.cols > 0, controller.view.viewport.rows > 0 else {
                    self.attachWhenLaidOut(controller, attempt: attempt + 1)
                    return
                }
                controller.attach()
            }
        }
    }

    func connectionChanged() {
        refresh()
        if let state = model?.connectionState(server), state.isOffline {
            host.status = session == nil ? statusText() : nil
            host.banner = "Disconnected"
        } else {
            host.banner = nil
        }
    }

    func progressChanged() { titleDidChange?() }

    func apply(settings: TerminalSettings) {
        session?.apply(settings: settings, palette: palette())
    }

    private func statusText() -> String {
        guard let model else { return "" }
        switch model.connectionState(server) {
        case .ready: return model.state.pane(pane)?.content.session == nil ? "Starting…" : "Connecting…"
        case .connecting, .idle: return "Connecting…"
        case .reconnecting: return "Disconnected"
        case .needsUser(let message): return message
        }
    }

    private func palette() -> TerminalPalette {
        let theme = AppTheme.shared
        return TerminalPalette(
            scheme: theme.scheme, options: model?.terminalSettings.options ?? TerminalOptions(),
            dark: !theme.palette.isLight, background: RGBColor(theme.card)
        )
    }

    /// The terminal's shortcuts as the keymap binds them.
    static func shortcuts(_ keymap: Keymap) -> [KeyChord: TerminalCommand] {
        let commands: [(ShortcutId, TerminalCommand)] = [
            (.copy, .copy), (.paste, .paste), (.find, .find), (.findNext, .findNext), (.findPrevious, .findPrevious),
            (.previousPrompt, .previousPrompt), (.nextPrompt, .nextPrompt), (.scrollToBottom, .scrollToBottom),
            (.selectCommandOutput, .selectCommandOutput),
            (.increaseFontSize, .increaseFontSize(1)), (.decreaseFontSize, .decreaseFontSize(1)),
        ]
        var shortcuts: [KeyChord: TerminalCommand] = [:]
        for (id, command) in commands {
            let context = id.definition.contexts.first ?? nil
            for key in keymap.keys(id.rawValue, context: context) {
                if let chord = try? KeyChord(key) { shortcuts[chord] = command }
            }
            if id == .findPrevious, let chord = keymap.chord(id) { shortcuts[chord] = command }
        }
        if let reset = try? KeyChord("cmd-0") { shortcuts[reset] = .resetFontSize }
        return shortcuts
    }

    /// Runs a terminal command on this pane, from the menu bar or palette.
    func perform(_ command: TerminalCommand) {
        session?.view.perform(command)
    }
}

extension TerminalPane: TerminalSessionControllerDelegate {
    func terminalSession(_ session: TerminalSessionController, didChangeState state: TerminalSessionState) {
        if case .ended = state, let model, let id = model.state.pane(pane)?.content.session {
            model.sessionEnded(server, id)
        }
        if case .failed(let message) = state {
            host.status = message
        } else if self.session === session {
            host.status = nil
        }
        titleDidChange?()
    }

    func terminalSession(_ session: TerminalSessionController, didChangeTitle title: String) {
        updateTitle()
    }

    func terminalSession(_ session: TerminalSessionController, didChangeDirectory directory: ServerPath) {
        updateTitle()
    }

    func terminalSession(_ session: TerminalSessionController, didChangeForegroundProcess process: ForegroundProcess) {
        updateTitle()
    }

    func terminalSession(_ session: TerminalSessionController, didChangeFontSize size: Double) {
        fontSize = size
    }

    func terminalSessionRequestsReload(_ session: TerminalSessionController) {
        guard let model else { return }
        if let settings = try? TerminalSettings.load(model.dirs.terminalSettings) {
            model.apply(terminalSettings: settings)
        }
    }

    private func updateTitle() {
        guard let model, let session else { return }
        let title = session.displayTitle
        if !title.isEmpty, model.state.pane(pane)?.title != TerminalTitle.sanitizeOrDefault(title) {
            model.edit { try $0.setPaneTitle(pane, title) }
        }
        titleDidChange?()
    }
}

extension TerminalPane: TerminalViewDelegate {
    func terminalView(_ view: TerminalView, openURL url: URL) {
        guard let model else { return }
        if model.settings.browser.enabled, model.settings.browser.openTerminalLinks, ["http", "https"].contains(url.scheme ?? "") {
            model.openBrowser(url: url.absoluteString, project: project)
            return
        }
        NSWorkspace.shared.open(url)
    }

    func terminalView(_ view: TerminalView, openFile path: String, line: Int?, column: Int?) {
        guard let model else { return }
        if model.settings.openers.file == OpenerSettings.tabEditor,
           let owner = model.state.projects.first(where: {
               $0.serverId == server && (path == $0.directory.rawValue || path.hasPrefix($0.directory.rawValue + "/"))
                   && !$0.home
           }) {
            model.openEditor(project: owner.id, path: path, line: line, column: column)
            return
        }
        let url = URL(fileURLWithPath: path)
        if model.settings.openers.file == OpenerSettings.tabEditor {
            NSWorkspace.shared.open(url)
            return
        }
        let app = URL(fileURLWithPath: model.settings.openers.file)
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func terminalView(_ view: TerminalView, openRemoteFile path: String, line: Int?, column: Int?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        model?.presenter?.showToast("Copied the remote path \(path)", error: false)
    }

    func terminalViewContextMenuItems(_ view: TerminalView) -> TerminalContextMenu.ShellItems {
        var items = TerminalContextMenu.ShellItems()
        if let model, let tab = model.activeTab, tab.panes.count < 2 {
            items.disabled = [.equalizeSplits, .toggleZoom]
        }
        if model?.activeTab?.zoomed == pane { items.titles[.toggleZoom] = "Restore Pane" }
        guard let model else { return items }
        let proxy = proxyItem(model)
        items.shown.removeAll { $0 == .applyProxy }
        if proxy != .setUp, let index = items.shown.firstIndex(of: .setUpProxy) {
            items.shown.insert(.applyProxy, at: index + 1)
            items.titles[.applyProxy] = proxy.title
            if !proxy.isEnabled { items.disabled.insert(.applyProxy) }
        }
        return items
    }

    func terminalView(_ view: TerminalView, perform item: TerminalContextMenu.Item) {
        guard let model else { return }
        model.focusPane(pane)
        switch item {
        case .splitRight: model.split(.right)
        case .splitDown: model.split(.down)
        case .toggleZoom: model.toggleZoom(pane)
        case .equalizeSplits: model.equalizeSplits()
        case .detach: model.detachTerminal(pane)
        case .close: model.closePane(pane)
        case .setUpProxy: model.proxyController.showSetUp()
        case .applyProxy: model.proxyController.perform(proxyItem(model), pane: pane)
        case .copy, .paste, .selectAll, .selectCommandOutput, .find, .clear: break
        }
    }

    private func proxyItem(_ model: AppModel) -> ProxyMenuItem {
        let supports = model.connections[server]?.main?.supportsSessionEnvironment ?? false
        let live = session?.state == .live
        return model.proxy.menuItem(paneUsesProxy: model.state.pane(pane)?.proxy ?? false, canRestart: live,
                                    serverSupportsEnvironment: supports)
    }

    func terminalView(_ view: TerminalView, didChangeFocus focused: Bool) {
        guard focused, let model, model.activePane != pane else { return }
        model.focusPane(pane)
    }
}

/// Holds a terminal's content, or a status line before it has one, with
/// an offline banner over it.
final class TerminalHostView: ThemedView {
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let content {
                content.frame = bounds
                content.autoresizingMask = [.width, .height]
                addSubview(content, positioned: .below, relativeTo: nil)
            }
        }
    }

    var status: String? {
        didSet {
            statusLabel.stringValue = status ?? ""
            statusLabel.isHidden = status == nil
        }
    }

    var banner: String? {
        didSet {
            bannerLabel.stringValue = banner ?? ""
            bannerView.isHidden = banner == nil
        }
    }

    private let statusLabel = makeLabel("", font: AppFont.body)
    private let bannerView = ThemedBackground(color: { $0.raised })
    private let bannerLabel = makeLabel("", font: AppFont.footnoteMedium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusLabel.alignment = .center
        statusLabel.isHidden = true
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        bannerView.cornerRadius = 6
        bannerView.translatesAutoresizingMaskIntoConstraints = false
        bannerView.isHidden = true
        bannerView.addSubview(bannerLabel)
        addSubview(bannerView)
        NSLayoutConstraint.activate([
            bannerView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bannerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            bannerLabel.leadingAnchor.constraint(equalTo: bannerView.leadingAnchor, constant: 8),
            bannerLabel.trailingAnchor.constraint(equalTo: bannerView.trailingAnchor, constant: -8),
            bannerLabel.topAnchor.constraint(equalTo: bannerView.topAnchor, constant: 3),
            bannerLabel.bottomAnchor.constraint(equalTo: bannerView.bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { content == nil }

    override func themeDidChange() {
        statusLabel.textColor = theme.fgDim
        bannerLabel.textColor = theme.warning
    }
}
