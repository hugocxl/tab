import AppKit
import TabCore
import TabProtocol

/// Where the Agents panel is shown.
public enum AgentsPanelPlacement: Equatable, Sendable {
    /// At the bottom of the expanded sidebar, with a draggable top edge.
    case sidebar
    /// A popup from the collapsed sidebar that closes on Escape or a click
    /// elsewhere.
    case popup
    /// In the right panel area, with a draggable leading edge.
    case right
    /// A floating panel over the window, with a remembered frame.
    case floating

    /// The placement `appearance` asks for.
    public init(_ appearance: Appearance, sidebarExpanded: Bool) {
        if appearance.agentsPanelDetached {
            self = .floating
        } else if appearance.agentsPanelDock == .right {
            self = .right
        } else {
            self = sidebarExpanded ? .sidebar : .popup
        }
    }
}

/// Sizes the Agents panel remembers, clamped to the window.
public enum AgentsPanelGeometry {
    public static let minimumWidth: CGFloat = 220
    public static let minimumHeight: CGFloat = 140
    public static let defaultRightWidth: CGFloat = 320
    public static let maximumRightWidth: CGFloat = 800
    /// The sidebar dock's height until the user drags it.
    public static let dockedMaximumHeight: CGFloat = 260
    /// x and y from the window's top-left corner, width, height.
    public static let defaultFrame: [Double] = [80, 80, 320, 360]

    /// The floating frame (origin at the window's top-left, y down) for a
    /// saved `[x, y, width, height]`, kept inside a window of `size`.
    public static func floatingFrame(_ saved: [Double]?, in size: CGSize) -> CGRect {
        let frame = saved.flatMap { $0.count == 4 && $0.allSatisfy(\.isFinite) ? $0 : nil } ?? defaultFrame
        let maxWidth = max(size.width, minimumWidth)
        let maxHeight = max(size.height, minimumHeight)
        let width = min(max(CGFloat(frame[2]), minimumWidth), maxWidth)
        let height = min(max(CGFloat(frame[3]), minimumHeight), maxHeight)
        return CGRect(
            x: min(max(CGFloat(frame[0]), 0), maxWidth - width),
            y: min(max(CGFloat(frame[1]), 0), maxHeight - height),
            width: width,
            height: height
        )
    }

    /// The sidebar dock's height, between the minimum and 70% of the window.
    public static func dockedHeight(_ height: CGFloat, windowHeight: CGFloat) -> CGFloat {
        min(max(height, minimumHeight), max(windowHeight * 0.7, minimumHeight))
    }

    /// The right panel's width, leaving the workspace at least 400pt.
    public static func rightWidth(_ width: CGFloat, windowWidth: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), max(min(maximumRightWidth, windowWidth - 400), minimumWidth))
    }
}

/// What the Agents panel needs from the app.
@MainActor
public protocol AgentsPanelHost: AnyObject {
    var theme: AppTheme { get }
    /// The saved appearance: dock side, sizes and frame.
    var appearance: Appearance { get }
    /// Changes and saves the appearance.
    func updateAppearance(_ change: (inout Appearance) -> Void)
    /// The current project and its focused terminal's session, to mark the
    /// row the user is looking at.
    var agentsPanelActive: (server: ServerId, project: ProjectId, session: SessionId?)? { get }
    /// Selects the agent's project and focuses its pane.
    func openAgent(_ agent: RunningAgent)
    /// Gives the keyboard back to the focused pane.
    func focusActivePane()
    /// Hides the panel, saving `agentsPanelVisible = false`.
    func hideAgentsPanel()
    /// Closes the collapsed sidebar's popup.
    func closeAgentsPopup()
    /// The panel moved, detached or reattached: the appearance is saved;
    /// show the panel where `AgentsPanelPlacement(appearance)` says.
    func agentsPanelPlacementDidChange()
}

/// The running-agents panel: rows of agents grouped by state, opened with a
/// click or the arrow keys and Return.
@MainActor
public final class AgentsPanelController: NSViewController, NSWindowDelegate {
    public private(set) weak var host: AgentsPanelHost?
    /// Where the panel is shown; the shell sets it when it places the view.
    public var placement: AgentsPanelPlacement = .sidebar { didSet { applyPlacement() } }
    /// Most urgent first.
    public private(set) var agents: [RunningAgent] = []
    private var selected: RunningAgent.Key?

    private let root = AgentsPanelRootView()
    private let header = AgentsPanelHeaderView()
    private let scroll = ScrollView()
    private let stack = NSStackView()
    private let topHandle = EdgeResizeHandle(edge: .top)
    private let leadingHandle = EdgeResizeHandle(edge: .leading)
    private var heightConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var dragStart: CGFloat = 0
    private var rows: [RunningAgent.Key: AgentsPanelRow] = [:]
    private var floating: AgentsFloatingWindow?
    private var saveFrame: DispatchWorkItem?

    public init(host: AgentsPanelHost) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func loadView() {
        root.theme = host?.theme ?? .shared
        root.controller = self
        header.theme = root.theme
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.content.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.content.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: scroll.content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.content.bottomAnchor, constant: -4),
        ])
        for subview in [header, scroll, topHandle, leadingHandle] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            topHandle.topAnchor.constraint(equalTo: root.topAnchor, constant: -3),
            topHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topHandle.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topHandle.heightAnchor.constraint(equalToConstant: 6),
            leadingHandle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: -3),
            leadingHandle.topAnchor.constraint(equalTo: root.topAnchor),
            leadingHandle.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leadingHandle.widthAnchor.constraint(equalToConstant: 6),
        ])
        header.onMove = { [weak self] in self?.moveDock() }
        header.onDetach = { [weak self] in self?.toggleDetached() }
        header.onClose = { [weak self] in self?.host?.hideAgentsPanel() }
        topHandle.onBegin = { [weak self] in self?.dragStart = self?.heightConstraint?.constant ?? 0 }
        topHandle.onDrag = { [weak self] delta in self?.resizeDocked(by: delta) }
        topHandle.onEnd = { [weak self] in self?.saveDockedHeight() }
        leadingHandle.onBegin = { [weak self] in self?.dragStart = self?.widthConstraint?.constant ?? 0 }
        leadingHandle.onDrag = { [weak self] delta in self?.resizeRight(by: delta) }
        leadingHandle.onEnd = { [weak self] in self?.saveRightWidth() }
        view = root
        heightConstraint = root.heightAnchor.constraint(equalToConstant: AgentsPanelGeometry.dockedMaximumHeight)
        heightConstraint?.priority = .defaultHigh
        widthConstraint = root.widthAnchor.constraint(equalToConstant: AgentsPanelGeometry.defaultRightWidth)
        widthConstraint?.priority = .defaultHigh
        applyPlacement()
        reload()
    }

    // MARK: Data

    /// Shows the agents of `sources`: every server's activity and the panes
    /// this app shows.
    /// Rebuilds the rows only when the running agents changed.
    public func update(_ sources: [AgentsPanelSource]) {
        let running = AgentsPanelModel.runningAgents(sources)
        guard running != agents else { return }
        agents = running
        reload()
    }

    /// Marks the row of the pane the user looks at; call when focus moves.
    public func activePaneDidChange() {
        updateRowStates()
    }

    private func reload() {
        guard isViewLoaded, let host else { return }
        header.update(summary: AgentsPanelModel.summary(agents), placement: placement, dock: host.appearance.agentsPanelDock)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        if agents.isEmpty {
            let empty = makeLabel("No agents running", font: AppFont.footnote, color: host.theme.fgMuted)
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(empty)
            empty.pinEdges(to: wrapper, insets: NSEdgeInsets(top: 4, left: Metrics.gutter + 4, bottom: Metrics.gutter, right: Metrics.gutter))
            stack.addArrangedSubview(wrapper)
        }
        var previous: AgentStatus?
        for agent in agents {
            if previous != agent.status { addFullWidth(AgentsSectionLabel(agent.status.title)) }
            previous = agent.status
            let row = makeRow(agent, theme: host.theme)
            rows[agent.key] = row
            addFullWidth(row)
        }
        updateRowStates()
        updateDockedHeight()
    }

    private func addFullWidth(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeRow(_ agent: RunningAgent, theme: AppTheme) -> AgentsPanelRow {
        let leading = NSStackView(views: [AgentStatusStyle.glyph(agent.status), AgentStatusStyle.logo(agent.provider, theme: theme)])
        leading.spacing = 4
        let row = AgentsPanelRow(leading: leading, title: agent.title, detail: agent.location,
                                 tooltip: "\(agent.provider.displayName) · \(agent.status.title)")
        let key = agent.key
        row.onClick = { [weak self] in self?.open(key) }
        return row
    }

    // MARK: Selection

    private var activeKey: RunningAgent.Key? {
        guard let active = host?.agentsPanelActive else { return nil }
        return agents.first { $0.server == active.server && $0.session == active.session }?.key
    }

    /// The keyboard selection: the last moved-to row, else the active one,
    /// else the first.
    var selectedKey: RunningAgent.Key? {
        if let selected, agents.contains(where: { $0.key == selected }) { return selected }
        return activeKey ?? agents.first?.key
    }

    private func updateRowStates() {
        let active = activeKey
        let focused = hasFocus
        let selection = focused ? selectedKey : nil
        for (key, row) in rows {
            row.isActive = key == active
            row.isSelected = key == selection
        }
    }

    /// Moves the keyboard selection by `delta` rows.
    func moveSelection(_ delta: Int) {
        guard !agents.isEmpty else {
            selected = nil
            return
        }
        let current = selectedKey.flatMap { key in agents.firstIndex { $0.key == key } } ?? 0
        let next = min(max(current + delta, 0), agents.count - 1)
        selected = agents[next].key
        updateRowStates()
        if let row = rows[agents[next].key] { row.scrollToVisible(row.bounds.insetBy(dx: 0, dy: -24)) }
    }

    func openSelection() {
        guard let key = selectedKey else { return }
        open(key)
    }

    private func open(_ key: RunningAgent.Key) {
        guard let host, let agent = agents.first(where: { $0.key == key }) else { return }
        selected = nil
        if placement == .popup { host.closeAgentsPopup() }
        host.openAgent(agent)
    }

    func dismiss() {
        if placement == .popup {
            host?.closeAgentsPopup()
        } else {
            host?.focusActivePane()
        }
    }

    /// Gives the panel the keyboard.
    public func focus() {
        selected = nil
        view.window?.makeFirstResponder(root)
    }

    public var hasFocus: Bool {
        guard isViewLoaded, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func focusDidChange() { updateRowStates() }

    // MARK: Placement

    private func applyPlacement() {
        guard isViewLoaded else { return }
        root.placement = placement
        topHandle.isHidden = placement != .sidebar
        leadingHandle.isHidden = placement != .right
        header.isDraggable = placement == .floating
        if let host { header.update(summary: AgentsPanelModel.summary(agents), placement: placement, dock: host.appearance.agentsPanelDock) }
        heightConstraint?.isActive = placement == .sidebar || placement == .popup
        widthConstraint?.isActive = placement == .right
        if placement == .right, let host {
            let saved = host.appearance.agentsPanelRightWidth.map { CGFloat($0) } ?? AgentsPanelGeometry.defaultRightWidth
            widthConstraint?.constant = AgentsPanelGeometry.rightWidth(saved, windowWidth: windowSize.width)
        }
        updateDockedHeight()
    }

    private var windowSize: CGSize {
        view.window?.contentView?.bounds.size ?? NSApp?.mainWindow?.contentView?.bounds.size ?? CGSize(width: 1200, height: 800)
    }

    private func updateDockedHeight() {
        guard placement == .sidebar || placement == .popup, let host else { return }
        if placement == .sidebar, let saved = host.appearance.agentsPanelDockedHeight, saved.isFinite {
            heightConstraint?.constant = AgentsPanelGeometry.dockedHeight(CGFloat(saved), windowHeight: windowSize.height)
            return
        }
        stack.layoutSubtreeIfNeeded()
        let natural = Metrics.headerHeight + stack.fittingSize.height + 4
        let maximum = placement == .popup ? 380 : AgentsPanelGeometry.dockedMaximumHeight
        heightConstraint?.constant = min(natural, maximum)
    }

    private func resizeDocked(by delta: CGFloat) {
        heightConstraint?.constant = AgentsPanelGeometry.dockedHeight(dragStart + delta, windowHeight: windowSize.height)
    }

    private func saveDockedHeight() {
        guard let height = heightConstraint?.constant else { return }
        host?.updateAppearance { $0.agentsPanelDockedHeight = Double(height) }
    }

    private func resizeRight(by delta: CGFloat) {
        widthConstraint?.constant = AgentsPanelGeometry.rightWidth(dragStart + delta, windowWidth: windowSize.width)
    }

    private func saveRightWidth() {
        guard let width = widthConstraint?.constant else { return }
        host?.updateAppearance { $0.agentsPanelRightWidth = Double(width) }
    }

    /// Move to Right, or back to the left sidebar; this also reattaches.
    func moveDock() {
        guard let host else { return }
        let dock: AgentsPanelDock = host.appearance.agentsPanelDock == .right ? .left : .right
        setDocking(dock: dock, detached: false)
    }

    /// Detach, or reattach on the last side.
    func toggleDetached() {
        guard let host else { return }
        setDocking(dock: host.appearance.agentsPanelDock, detached: !host.appearance.agentsPanelDetached)
    }

    private func setDocking(dock: AgentsPanelDock, detached: Bool) {
        guard let host else { return }
        if placement == .popup { host.closeAgentsPopup() }
        host.updateAppearance { appearance in
            appearance.agentsPanelDock = dock
            appearance.agentsPanelDetached = detached
            appearance.agentsPanelVisible = true
            if detached && appearance.agentsPanelFrame == nil {
                appearance.agentsPanelFrame = AgentsPanelGeometry.defaultFrame
            }
        }
        host.agentsPanelPlacementDidChange()
    }

    // MARK: Floating

    /// Shows the panel floating over `parent` at its remembered frame,
    /// moving with the window.
    public func showFloating(over parent: NSWindow) {
        guard let host else { return }
        closeFloating()
        placement = .floating
        let size = parent.contentLayoutRect.size
        let frame = AgentsPanelGeometry.floatingFrame(host.appearance.agentsPanelFrame, in: size)
        let panel = AgentsFloatingWindow(theme: host.theme)
        panel.contentView = view
        panel.setFrame(screenFrame(frame, parent: parent), display: false)
        panel.delegate = self
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        floating = panel
        focus()
    }

    /// Removes the floating panel, saving its frame.
    public func closeFloating() {
        guard let panel = floating else { return }
        saveFrame?.cancel()
        storeFloatingFrame()
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.contentView = nil
        panel.orderOut(nil)
        floating = nil
    }

    private func screenFrame(_ frame: CGRect, parent: NSWindow) -> NSRect {
        let layout = parent.convertToScreen(parent.contentLayoutRect)
        return NSRect(x: layout.minX + frame.minX, y: layout.maxY - frame.minY - frame.height, width: frame.width, height: frame.height)
    }

    private func storeFloatingFrame() {
        guard let panel = floating, let parent = panel.parent else { return }
        let layout = parent.convertToScreen(parent.contentLayoutRect)
        let frame = [panel.frame.minX - layout.minX, layout.maxY - panel.frame.maxY, panel.frame.width, panel.frame.height].map(Double.init)
        let clamped = AgentsPanelGeometry.floatingFrame(frame, in: layout.size)
        let saved = [clamped.minX, clamped.minY, clamped.width, clamped.height].map(Double.init)
        guard host?.appearance.agentsPanelFrame != saved else { return }
        host?.updateAppearance { $0.agentsPanelFrame = saved }
    }

    private func scheduleFrameSave() {
        saveFrame?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.storeFloatingFrame() }
        }
        saveFrame = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    public func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    public func windowDidEndLiveResize(_ notification: Notification) { scheduleFrameSave() }
}

/// The panel's view: card chrome per placement and the keyboard.
final class AgentsPanelRootView: ThemedView {
    weak var controller: AgentsPanelController?
    var placement: AgentsPanelPlacement = .sidebar { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        controller?.focusDidChange()
        return true
    }

    override func resignFirstResponder() -> Bool {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.controller?.focusDidChange() }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: controller?.moveSelection(1)
        case 126: controller?.moveSelection(-1)
        case 36, 76: controller?.openSelection()
        case 53: controller?.dismiss()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.dismiss()
    }

    override func draw(_ dirtyRect: NSRect) {
        switch placement {
        case .sidebar:
            theme.fg(alpha: 0.08).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        case .popup, .floating:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
            theme.raised.setFill()
            path.fill()
            theme.cardBorder.setStroke()
            path.stroke()
        case .right:
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
            theme.card.setFill()
            path.fill()
            theme.cardBorder.setStroke()
            path.stroke()
        }
    }
}

/// "Agents", the attention summary and the move, detach and close buttons.
/// While floating, dragging it moves the panel.
final class AgentsPanelHeaderView: ThemedView {
    var onMove: (() -> Void)?
    var onDetach: (() -> Void)?
    var onClose: (() -> Void)?
    var isDraggable = false
    private let titleLabel = makeLabel("Agents", font: AppFont.header)
    private let summaryLabel = makeLabel("", font: AppFont.footnote)
    private let moveButton = IconButton(.panelRight, label: "Move to Right")
    private let detachButton = IconButton(.maximize, label: "Detach")
    private let closeButton = IconButton(.close, label: "Hide")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        moveButton.onPress = { [weak self] in self?.onMove?() }
        detachButton.onPress = { [weak self] in self?.onDetach?() }
        closeButton.onPress = { [weak self] in self?.onClose?() }
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, summaryLabel, NSView(), moveButton, detachButton, closeButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.setCustomSpacing(Metrics.controlGap, after: titleLabel)
        addSubview(row)
        row.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: Metrics.gutter))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(summary: String, placement: AgentsPanelPlacement, dock: AgentsPanelDock) {
        summaryLabel.stringValue = summary
        let right = dock == .right
        moveButton.icon = right ? .panelLeft : .panelRight
        relabel(moveButton, right ? "Move to Left Sidebar" : "Move to Right")
        if placement == .floating {
            detachButton.icon = right ? .panelRight : .panelLeft
            relabel(detachButton, right ? "Reattach to Right Panel" : "Reattach to Sidebar")
        } else {
            detachButton.icon = .maximize
            relabel(detachButton, "Detach")
        }
    }

    private func relabel(_ button: IconButton, _ label: String) {
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    override func themeDidChange() {
        titleLabel.textColor = theme.fgMuted
        summaryLabel.textColor = theme.fgDim
    }

    override func mouseDown(with event: NSEvent) {
        guard isDraggable, let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(superview)
        window.performDrag(with: event)
    }
}

/// The detached panel: a borderless-looking, resizable panel that can take
/// the keyboard.
final class AgentsFloatingWindow: NSPanel {
    init(theme: AppTheme) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = theme.nsAppearance
        minSize = NSSize(width: AgentsPanelGeometry.minimumWidth, height: AgentsPanelGeometry.minimumHeight)
        setAccessibilityTitle("Agents")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
