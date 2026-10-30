import AppKit
import Combine
import TabCore

/// The window's content: the sidebar, the current project's split layout,
/// and the right panel pinned beside it like Files in the reference window.
@MainActor
final class WorkspaceView: ThemedView {
    unowned let model: AppModel
    let sidebar: SidebarViewController
    let splits: SplitContainerView
    private let material = NSVisualEffectView()
    private let panelHost = RightPanelHostView()
    private let banner = BannerView()
    private var shownPanel: RightPanelKind?
    private var shownPanelProject: ProjectId?
    private var liveSidebarWidth: CGFloat?
    private var livePanelWidth: CGFloat?
    private var subscription: AnyCancellable?
    private var lastPanelLayout: (RightPanelKind?, CGFloat)?
    private let sidebarToggle = SidebarToggleSlot()
    /// The Agents panel while it pops up beside the collapsed sidebar.
    private weak var agentsPopup: NSView?
    private var agentsPopupLeading: NSLayoutConstraint?
    private var popupMonitor: Any?

    init(model: AppModel, sidebar: SidebarViewController) {
        self.model = model
        self.sidebar = sidebar
        splits = SplitContainerView(model: model)
        super.init(frame: .zero)
        material.material = .underWindowBackground
        material.blendingMode = .behindWindow
        material.state = .active
        addSubview(material)
        addSubview(sidebar.view)
        addSubview(splits)
        addSubview(panelHost)
        addSubview(banner)
        sidebar.onResize = { [weak self] width in
            self?.liveSidebarWidth = width
            self?.needsLayout = true
        }
        panelHost.onResize = { [weak self] width in
            guard let self else { return }
            self.livePanelWidth = width
            if width == nil, let kind = self.shownPanel {
                self.model.setRightPanelWidth(kind, self.panelHost.frame.width)
            }
            self.needsLayout = true
        }
        sidebarToggle.button.action = { [weak model] _ in model?.toggleSidebar() }
        subscription = model.changes.sink { [weak self] changes in self?.modelChanged(changes) }
        splits.reload()
        syncPanel()
        syncAgentsPopup()
        updateBanner()
        syncVibrancy()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.chrome.cgColor
    }

    private func syncVibrancy() {
        let enabled = model.terminalVibrancy > 0
        material.isHidden = !enabled
        window?.isOpaque = !enabled
        window?.backgroundColor = enabled ? .clear : theme.chrome
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncVibrancy()
    }

    private func modelChanged(_ changes: Set<ModelChange>) {
        if changes.contains(.settings) { syncVibrancy() }
        if changes.contains(.state) || changes.contains(.settings) {
            splits.reload()
        }
        if changes.contains(.activity) || changes.contains(.state) {
            splits.refreshHeaders()
            updateBanner()
        }
        if !changes.isDisjoint(with: [.panel, .settings, .state]) {
            syncPanel()
            syncAgentsPopup()
        }
        needsLayout = true
    }

    // MARK: Agents popup

    /// Pops the Agents panel up at the bottom left of the workspace while
    /// it is open with the sidebar collapsed, as Codesh's popup placement:
    /// 300pt wide, at most 380pt tall, closed by Escape or a click elsewhere.
    private func syncAgentsPopup() {
        let appearance = model.appearance
        let shown = model.agentsPopupOpen && appearance.agentsPanelVisible
            && AgentsPanelPlacement(appearance, sidebarExpanded: appearance.sidebarExpanded) == .popup
        guard shown else {
            if let popup = agentsPopup, popup.superview === self { popup.removeFromSuperview() }
            agentsPopup = nil
            agentsPopupLeading = nil
            stopPopupMonitor()
            return
        }
        let controller = model.agentsPanel
        let panel = controller.view
        controller.placement = .popup
        guard panel.superview !== self else { return }
        panel.removeFromSuperview()
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        let leading = panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: sidebarWidth + Metrics.gutter)
        NSLayoutConstraint.activate([
            leading,
            panel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.gutter),
            panel.widthAnchor.constraint(equalToConstant: Self.agentsPopupWidth),
        ])
        panel.shadow = Self.popupShadow
        agentsPopup = panel
        agentsPopupLeading = leading
        startPopupMonitor()
    }

    static let agentsPopupWidth: CGFloat = 300

    private static var popupShadow: NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 16
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        return shadow
    }

    private func startPopupMonitor() {
        guard popupMonitor == nil else { return }
        popupMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let popup = self.agentsPopup, event.window === self.window else { return }
                let point = popup.convert(event.locationInWindow, from: nil)
                if !popup.bounds.contains(point) { self.model.closeAgentsPopup() }
            }
            return event
        }
    }

    private func stopPopupMonitor() {
        guard let popupMonitor else { return }
        NSEvent.removeMonitor(popupMonitor)
        self.popupMonitor = nil
    }

    /// Shows the right panel the model asks for, following the project.
    private func syncPanel() {
        let kind = model.rightPanel
        if kind != shownPanel {
            if let old = shownPanel { model.rightPanelContent(old)?.didHide() }
            panelHost.content = kind.flatMap { model.rightPanelContent($0) }?.view
            shownPanel = kind
            shownPanelProject = nil
            if let kind { model.rightPanelContent(kind)?.didShow() }
        }
        guard let kind, let content = model.rightPanelContent(kind) else { return }
        let project = model.currentProject
        if shownPanelProject != project.id {
            shownPanelProject = project.id
            content.projectDidChange(project.home && (kind == .files || kind == .sourceControl) ? nil : project)
        }
    }

    private func updateBanner() {
        let server = model.currentProject.serverId
        switch model.connectionState(server) {
        case .reconnecting:
            banner.show("\(server.isLocal ? "This Mac's server" : model.serverName(server) ?? "The server") is offline. Reconnecting…",
                        action: "Retry") { [weak self] in self?.model.connection(server)?.retryNow() }
        case .needsUser(let message):
            banner.show(message, action: "Try Again") { [weak self] in self?.model.connection(server)?.retryNow() }
        case .ready, .connecting, .idle:
            banner.hide()
        }
    }

    var sidebarWidth: CGFloat {
        model.appearance.sidebarExpanded ? (liveSidebarWidth ?? model.sidebarWidth) : 0
    }

    override func layout() {
        super.layout()
        let sidebarWidth = self.sidebarWidth
        material.frame = NSRect(x: sidebarWidth, y: 0, width: max(bounds.width - sidebarWidth, 0), height: bounds.height)
        let expanded = model.appearance.sidebarExpanded
        sidebar.view.isHidden = !expanded
        sidebar.view.frame = NSRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height)
        sidebarToggle.reserve = max(sidebar.trafficLightsEnd - 2 * Metrics.gutter, 0)
        splits.sidebarToggle = expanded ? nil : sidebarToggle
        agentsPopupLeading?.constant = sidebarWidth + Metrics.gutter
        var right = bounds.width
        if let kind = shownPanel {
            let width = min(livePanelWidth ?? model.rightPanelWidth(kind), max(bounds.width - sidebarWidth - 240, RightPanelKind.minimumWidth))
            panelHost.isHidden = false
            panelHost.frame = NSRect(x: bounds.width - Metrics.gutter - width, y: Metrics.gutter, width: width,
                                     height: max(bounds.height - 2 * Metrics.gutter, 0))
            right = panelHost.frame.minX
        } else {
            panelHost.isHidden = true
        }
        splits.frame = NSRect(x: sidebarWidth, y: 0, width: max(right - sidebarWidth, 0), height: bounds.height)
        let bannerWidth = min(splits.frame.width - 32, 520)
        banner.frame = NSRect(x: splits.frame.midX - bannerWidth / 2, y: 40, width: bannerWidth, height: 32)
    }
}

/// The sidebar toggle as the top-left card shows it while the sidebar is
/// collapsed: past the window buttons, then the 28pt chrome button.
final class SidebarToggleSlot: NSView {
    let button = ChromeButton(.panelLeft, label: "Show Sidebar")
    var reserve: CGFloat = 0 {
        didSet {
            guard reserve != oldValue else { return }
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: reserve + ChromeButton.side, height: ChromeButton.side) }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: reserve, y: 0, width: ChromeButton.side, height: ChromeButton.side)
    }
}

/// The right panel's frame: a card with the panel color and its left edge
/// as a resize handle.
final class RightPanelHostView: ThemedView {
    var content: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let content else { return }
            content.frame = bounds
            content.autoresizingMask = [.width, .height]
            addSubview(content, positioned: .below, relativeTo: handle)
        }
    }

    var onResize: ((CGFloat?) -> Void)?
    private let handle = PanelResizeHandle()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        addSubview(handle)
        handle.onDrag = { [weak self] delta in
            guard let self else { return }
            guard let delta else {
                self.onResize?(nil)
                return
            }
            let start = self.handle.startWidth
            self.onResize?(min(max(start - delta, RightPanelKind.minimumWidth), RightPanelKind.maximumWidth))
        }
        handle.onBegin = { [weak self] in self?.handle.startWidth = self?.frame.width ?? 0 }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NativeStyle.panel(theme).cgColor
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func layout() {
        super.layout()
        handle.frame = NSRect(x: 0, y: 0, width: 5, height: bounds.height)
    }
}

/// A vertical edge dragged horizontally; reports the pointer's travel.
final class PanelResizeHandle: NSView {
    var onDrag: ((CGFloat?) -> Void)?
    var onBegin: (() -> Void)?
    var startWidth: CGFloat = 0

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        onBegin?()
        let start = event.locationInWindow.x
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            onDrag?(next.locationInWindow.x - start)
            if next.type == .leftMouseUp { break }
        }
        onDrag?(nil)
    }
}

/// A banner over the workspace, such as "server offline", with an action.
final class BannerView: ThemedView {
    private let label = makeLabel("", font: AppFont.system(12, weight: .medium))
    private let button = PillButton("Retry")
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = true
        button.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        addSubview(button)
        button.action = { [weak self] in self?.action?() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ message: String, action title: String, _ action: @escaping () -> Void) {
        label.stringValue = message
        button.title = title
        self.action = action
        isHidden = false
        needsLayout = true
    }

    func hide() { isHidden = true }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.raised.cgColor
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func themeDidChange() {
        label.textColor = theme.warning
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: bounds.width - size.width - 4, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: 12, y: (bounds.height - height) / 2, width: max(button.frame.minX - 20, 0), height: height)
    }
}
