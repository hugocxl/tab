import AppKit
import Combine
import TabCore

/// The window's content: the sidebar, the current project's split layout,
/// and the right sidebar with Files and Source Control.
@MainActor
final class WorkspaceView: ThemedView {
    unowned let model: AppModel
    let sidebar: SidebarViewController
    let splits: SplitContainerView
    private let material = NSVisualEffectView()
    private let rightSidebar = RightSidebarView()
    private let banner = BannerView()
    private var shownPanel: RightPanelKind?
    private var shownPanelProject: ProjectId?
    private var liveSidebarWidth: CGFloat?
    private var livePanelWidth: CGFloat?
    private var subscription: AnyCancellable?
    private var lastPanelLayout: (RightPanelKind?, CGFloat)?
    private let sidebarToggle = SidebarToggleSlot()
    private let rightSidebarToggle = ChromeButton(.panelRight, label: "Show Sidebar")

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
        addSubview(rightSidebar)
        addSubview(banner)
        sidebar.onResize = { [weak self] width in
            self?.liveSidebarWidth = width
            self?.needsLayout = true
        }
        rightSidebar.onResize = { [weak self] width in
            guard let self else { return }
            self.livePanelWidth = width
            if width == nil, let kind = self.shownPanel {
                self.model.setRightPanelWidth(kind, self.rightSidebar.cardWidth)
            }
            self.needsLayout = true
        }
        rightSidebar.onSelect = { [weak model] kind in model?.selectRightPanel(kind) }
        rightSidebar.onToggle = { [weak model] in model?.toggleRightSidebar() }
        sidebarToggle.button.onPress = { [weak model] _ in model?.toggleSidebar() }
        rightSidebarToggle.onPress = { [weak model] _ in model?.toggleRightSidebar() }
        subscription = model.changes.sink { [weak self] changes in self?.modelChanged(changes) }
        splits.reload()
        syncPanel()
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
        if !changes.isDisjoint(with: [.panel, .settings, .state]) { syncPanel() }
        needsLayout = true
    }

    /// Shows the right panel the model asks for, following the project.
    private func syncPanel() {
        let kind = model.rightPanel
        if kind != shownPanel {
            if let old = shownPanel { model.rightPanelContent(old)?.didHide() }
            // Sized before the content arrives: constraints solved at zero
            // width leave controls such as checkboxes collapsed.
            if let kind { rightSidebar.frame = rightSidebarFrame(kind) }
            rightSidebar.content = kind.flatMap { model.rightPanelContent($0) }?.view
            rightSidebar.selected = kind
            shownPanel = kind
            shownPanelProject = nil
            if let kind { model.rightPanelContent(kind)?.didShow() }
        }
        guard let kind, let content = model.rightPanelContent(kind) else { return }
        let project = model.currentProject
        if shownPanelProject != project.id {
            shownPanelProject = project.id
            content.projectDidChange(project.home ? nil : project)
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

    /// The right sidebar's frame: the card's width plus the window gutter,
    /// leaving the splits at least 240pt.
    private func rightSidebarFrame(_ kind: RightPanelKind) -> NSRect {
        let width = min(livePanelWidth ?? model.rightPanelWidth(kind), max(bounds.width - sidebarWidth - 240, RightPanelKind.minimumWidth))
        return NSRect(x: bounds.width - Metrics.gutter - width, y: 0, width: width + Metrics.gutter, height: bounds.height)
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
        var right = bounds.width
        if let kind = shownPanel {
            rightSidebar.isHidden = false
            rightSidebar.frame = rightSidebarFrame(kind)
            right = rightSidebar.frame.minX
        } else {
            rightSidebar.isHidden = true
        }
        splits.rightSidebarToggle = shownPanel == nil ? rightSidebarToggle : nil
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
        button.onPress = { [weak self] in self?.action?() }
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
