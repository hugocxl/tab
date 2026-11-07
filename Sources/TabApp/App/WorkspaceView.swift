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
    private let rightSidebar = RightSidebarView()
    private let backdrop = GlassView(style: .window, behindWindow: true)
    private let veil = WindowVeilView()
    private let rim = WindowRimView()
    private var inWorkspaceTransition = false
    /// The window's notices: updates, the connection, toasts.
    let notices = NoticeStack()
    private var shownPanel: RightPanelKind?
    private var shownPanelProject: ProjectId?
    private var liveSidebarWidth: CGFloat?
    private var livePanelWidth: CGFloat?
    private var subscription: AnyCancellable?
    private var lastPanelLayout: (RightPanelKind?, CGFloat)?
    private var previousSidebarExpanded: Bool?
    private var previousPanel: RightPanelKind?
    private var resizeStartFrame: NSRect?
    private var resizeStartSidebarWidth: CGFloat = 0
    private var gestureMonitor: Any?
    private var swipeDistance: CGFloat = 0
    private var swipeHandled = false
    private let sidebarToggle = SidebarToggleSlot()
    private let rightSidebarToggle = HeaderButton(.panelRight, label: "Show Sidebar")

    init(model: AppModel, sidebar: SidebarViewController) {
        self.model = model
        self.sidebar = sidebar
        splits = SplitContainerView(model: model)
        super.init(frame: .zero)
        addSubview(backdrop)
        addSubview(veil)
        addSubview(rim)
        addSubview(sidebar.view)
        addSubview(splits)
        addSubview(rightSidebar)
        notices.position = model.settings.notifications.position
        addSubview(notices)
        sidebar.onResize = { [weak self] width in
            guard let self else { return }
            self.liveSidebarWidth = width
            if let width, self.model.appearance.preservePaneWidth, let window = self.window,
               !window.styleMask.contains(.fullScreen) {
                if self.resizeStartFrame == nil {
                    self.resizeStartFrame = window.frame
                    self.resizeStartSidebarWidth = self.model.sidebarWidth
                }
                if let original = self.resizeStartFrame {
                    var frame = original
                    frame.size.width += width - self.resizeStartSidebarWidth
                    if let screen = window.screen { frame.size.width = min(frame.width, screen.visibleFrame.maxX - frame.minX) }
                    window.setFrame(frame, display: true)
                }
            }
            if width == nil { self.resizeStartFrame = nil }
            self.needsLayout = true
        }
        rightSidebar.onResize = { [weak self] width in
            guard let self else { return }
            self.livePanelWidth = width
            if width == nil, let kind = self.shownPanel {
                self.model.setRightPanelWidth(kind, self.rightSidebar.frame.width)
            }
            self.needsLayout = true
        }
        rightSidebar.onSelect = { [weak model] kind in model?.toggleRightPanel(kind) }
        rightSidebar.onToggle = { [weak model] in model?.toggleRightSidebar() }
        sidebarToggle.button.shortcut = .toggleSidebar
        sidebarToggle.button.onPress = { [weak model] in model?.toggleSidebar() }
        rightSidebarToggle.onPress = { [weak model] in model?.toggleRightSidebar() }
        subscription = model.changes.sink { [weak self] changes in self?.modelChanged(changes) }
        splits.onLayout = { [weak self] animated in
            guard let self, !self.inWorkspaceTransition else { return }
            self.cutVeil(animated: animated)
        }
        splits.reload()
        syncPanel()
        updateConnectionNotice()
        updateUpdateNotice()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let gestureMonitor { NSEvent.removeMonitor(gestureMonitor); self.gestureMonitor = nil }
        guard window != nil else { return }
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window,
                  self.model.appearance.sidebarGesture == .swipe,
                  !event.modifierFlags.contains(.option), event.hasPreciseScrollingDeltas,
                  event.momentumPhase.isEmpty else { return event }
            if event.phase.contains(.began) { self.swipeDistance = 0; self.swipeHandled = false }
            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            self.swipeDistance += event.scrollingDeltaX
            if !self.swipeHandled, abs(self.swipeDistance) > 65 {
                self.swipeHandled = true
                let expanded = self.swipeDistance > 0
                if self.model.appearance.sidebarExpanded != expanded { self.model.toggleSidebar() }
            }
            return nil
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override var redrawsOnKeyChange: Bool { true }

    override func updateLayer() {
        backdrop.isHidden = !theme.glassEnabled
        backdrop.appearance = theme.nsAppearance
        backdrop.apply(theme.windowBackdrop(isKey: window?.isKeyWindow ?? true))
        veil.isHidden = !theme.glassEnabled
        veil.apply(theme.windowVeil(isKey: window?.isKeyWindow ?? true))
        rim.isHidden = !theme.glassEnabled
        layer?.backgroundColor = (theme.glassEnabled ? NSColor.clear : theme.chrome).cgColor
        window?.isOpaque = !theme.glassEnabled
        window?.backgroundColor = theme.glassEnabled ? .clear : theme.chrome
    }

    private func modelChanged(_ changes: Set<ModelChange>) {
        if changes.contains(.settings), InterfaceMotion.duration(model.appearance.animationStyle) == 0 {
            InterfaceMotion.cancel(in: self)
        }
        if changes.contains(.state) || changes.contains(.settings) {
            splits.reload()
        }
        if changes.contains(.activity) { updateUpdateNotice() }
        if changes.contains(.activity) || changes.contains(.state) {
            splits.refreshHeaders()
            updateConnectionNotice()
        }
        if changes.contains(.settings) { notices.position = model.settings.notifications.position }
        if !changes.isDisjoint(with: [.panel, .settings, .state]) { syncPanel() }
        needsLayout = true
    }

    /// Shows the right panel the model asks for, following the project.
    private func syncPanel() {
        let kind = model.rightPanel
        if kind != shownPanel {
            if let old = shownPanel {
                if kind == nil { InterfaceMotion.dismiss(rightSidebar, style: model.appearance.animationStyle, slide: 24) }
                model.rightPanelContent(old)?.didHide()
            }
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
        model.focusRightPanelIfRequested(kind)
    }

    private static let connectionNotice = "connection"
    private static let updateNotice = "update"

    /// Says while the current project's server is offline, until it is back.
    private func updateConnectionNotice() {
        let server = model.currentProject.serverId
        let notice: Notice
        switch model.connectionState(server) {
        case .reconnecting:
            let name = server.isLocal ? "This Mac’s server" : model.serverName(server) ?? "The server"
            notice = Notice(tone: .warning, icon: .spinner, message: "\(name) is offline. Reconnecting…", button: "Retry",
                            dismissible: false)
        case .needsUser(let message):
            notice = Notice(tone: .danger, icon: .symbol("exclamationmark.circle.fill"), message: UpdateChip.sentence(message),
                            button: "Try Again", dismissible: false)
        case .ready, .connecting, .idle:
            notices.remove(Self.connectionNotice)
            return
        }
        notices.show(notice, id: Self.connectionNotice, action: { [weak self] in self?.model.connection(server)?.retryNow() })
    }

    var sidebarWidth: CGFloat {
        model.appearance.sidebarExpanded ? (liveSidebarWidth ?? model.sidebarWidth) : 0
    }

    /// The right sidebar's frame, leaving the splits at least 240pt.
    private func rightSidebarFrame(_ kind: RightPanelKind) -> NSRect {
        let width = min(livePanelWidth ?? model.rightPanelWidth(kind), max(bounds.width - sidebarWidth - 240, RightPanelKind.minimumWidth))
        return NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        veil.frame = bounds
        rim.frame = bounds
        let oldSplitFrame = InterfaceMotion.frame(splits)
        let oldSidebarFrame = InterfaceMotion.frame(sidebar.view)
        let oldPanelFrame = InterfaceMotion.frame(rightSidebar)
        let changed = previousSidebarExpanded != nil &&
            (previousSidebarExpanded != model.appearance.sidebarExpanded || previousPanel != shownPanel)
        let style = model.appearance.animationStyle
        defer {
            if changed {
                inWorkspaceTransition = true
                splits.layoutForWorkspaceTransition()
                inWorkspaceTransition = false
                InterfaceMotion.animate(splits, from: oldSplitFrame, style: style)
                if model.appearance.sidebarExpanded {
                    InterfaceMotion.animate(sidebar.view, from: previousSidebarExpanded == true ? oldSidebarFrame : nil, style: style)
                }
                if shownPanel != nil { InterfaceMotion.animate(rightSidebar, from: previousPanel == nil ? nil : oldPanelFrame, style: style) }
                cutVeil(animated: true)
            } else {
                cutVeil(animated: false)
            }
            previousSidebarExpanded = model.appearance.sidebarExpanded
            previousPanel = shownPanel
        }
        let sidebarWidth = self.sidebarWidth
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
        notices.frame = bounds
    }

    /// Cuts the veil out under every glass surface, following the cards'
    /// animation when they move.
    private func cutVeil(animated: Bool) {
        guard theme.glassEnabled else { return }
        let holes = splits.surfaceFrames.map { splits.convert($0, to: veil) }
        veil.cutOut(holes, radius: Metrics.cardRadius, duration: animated ? InterfaceMotion.duration(model.appearance.animationStyle) : 0)
    }

    /// Shows the updater's chip among the notices.
    private func updateUpdateNotice() {
        guard let chip = model.updater.chip else {
            notices.remove(Self.updateNotice)
            return
        }
        notices.show(chip.notice, id: Self.updateNotice, action: { [weak model] in
            guard let action = model?.updater.chip?.button?.action else { return }
            if action == .showChangelog { model?.showSettingsAction?(.changelog) }
            model?.updater.handle(action)
        }, dismiss: { [weak model] in model?.updater.dismissChip() })
    }
}

/// The sidebar toggle as the top-left card shows it while the sidebar is
/// collapsed: past the window buttons, then a pane header button.
final class SidebarToggleSlot: NSView {
    let button = HeaderButton(.panelLeft, label: "Show Sidebar")
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
    override var intrinsicContentSize: NSSize { NSSize(width: reserve + HeaderButton.side, height: HeaderButton.side) }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: reserve, y: 0, width: HeaderButton.side, height: HeaderButton.side)
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

/// The chrome's tint and darkening over the window backdrop, cut out under
/// every glass surface so its glass samples the backdrop alone and the
/// desktop's colors project through it.
private final class WindowVeilView: ThemedView {
    private let planes = [CALayer(), CALayer()]
    private let masks = [CAShapeLayer(), CAShapeLayer()]
    private var holeCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for (plane, mask) in zip(planes, masks) {
            mask.fillRule = .evenOdd
            plane.mask = mask
            layer?.addSublayer(plane)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ recipe: GlassRecipe) {
        planes[0].backgroundColor = recipe.tint.cgColor
        planes[1].isHidden = recipe.fill == nil
        planes[1].backgroundColor = recipe.fill?.color.cgColor
        planes[1].compositingFilter = recipe.fill?.blend
    }

    /// Leaves `holes` clear, moving there over `duration` when the number
    /// of holes is unchanged, as the cards they follow do.
    func cutOut(_ holes: [CGRect], radius: CGFloat, duration: TimeInterval) {
        let path = CGMutablePath()
        path.addRect(bounds)
        for hole in holes { path.addRoundedRect(in: hole, cornerWidth: radius, cornerHeight: radius) }
        let animates = duration > 0 && holes.count == holeCount
        holeCount = holes.count
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for mask in masks {
            let previous = mask.presentation()?.path ?? mask.path
            mask.frame = bounds
            mask.path = path
            guard animates, let previous, previous != path else {
                mask.removeAnimation(forKey: "interface")
                continue
            }
            let motion = CABasicAnimation(keyPath: "path")
            motion.fromValue = previous
            motion.toValue = path
            motion.duration = duration
            motion.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            mask.add(motion, forKey: "interface")
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for plane in planes { plane.frame = bounds }
        CATransaction.commit()
    }
}

/// The light along the inside of a glass window's edge, strongest at the
/// top: a shadow cast inward by a ring around the window, clipped to it.
private final class WindowRimView: ThemedView {
    private let ring = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.masksToBounds = true
        ring.shadowColor = NSColor.white.cgColor
        layer?.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.compositingFilter = theme.isLight ? "plusL" : "overlayBlendMode"
        ring.shadowOpacity = theme.isLight ? 0.15 : 0.6
        ring.shadowRadius = theme.isLight ? 1 : 2.5
        ring.shadowOffset = CGSize(width: 0, height: theme.isLight ? 0.5 : 1.5)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds.insetBy(dx: -20, dy: -20))
        // Wound the other way, so the window's own area stays a hole.
        path.addLines(between: [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.minX, y: bounds.maxY),
                                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.minY)])
        path.closeSubpath()
        ring.shadowPath = path
        CATransaction.commit()
    }
}
