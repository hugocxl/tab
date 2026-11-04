import AppKit
import TabCore
import TabProtocol

/// The current project's split layout: one card per visible pane with 8pt
/// gutters, inside one 8pt inset. Gutters resize their split by dragging;
/// Command-dragging a pane swaps it with another or docks it on an edge.
/// Frames come from the layout tree once per layout pass.
final class SplitContainerView: ThemedView {
    unowned let model: AppModel
    private var cards: [PaneId: PaneCardView] = [:]
    private let emptyView = EmptyProjectView()
    private let preview = DropPreviewView()
    private var dividers: [SplitGeometry.Divider] = []
    private var hovered: [Branch]?
    private var resizing: (path: [Branch], ratio: Double)?
    private var trackingAreasByDivider: [NSTrackingArea] = []
    private var shownTab: TabId?
    private var animateNextLayout = false
    private var hasLaidOut = false

    /// The sidebar toggle, shown in the top-left card while the sidebar is
    /// collapsed.
    var sidebarToggle: NSView? {
        didSet { if sidebarToggle !== oldValue { needsLayout = true } }
    }
    /// The right sidebar's toggle, shown in the top-right card while the
    /// right sidebar is collapsed.
    var rightSidebarToggle: NSView? {
        didSet { if rightSidebarToggle !== oldValue { needsLayout = true } }
    }

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        addSubview(emptyView)
        preview.isHidden = true
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    private var tab: Tab? { model.activeTab }
    private var content: CGRect { bounds.insetBy(dx: Metrics.gutter, dy: Metrics.gutter) }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// Matches the cards to the model's current tab.
    func reload() {
        let tab = self.tab
        animateNextLayout = hasLaidOut
        let visible = tab?.visiblePanes ?? []
        for (id, card) in cards where !visible.contains(id) {
            InterfaceMotion.dismiss(card, style: model.appearance.animationStyle)
            card.removeFromSuperview()
            cards[id] = nil
        }
        for id in visible {
            let card = cards[id] ?? {
                let card = PaneCardView(pane: id, model: model)
                cards[id] = card
                addSubview(card, positioned: .below, relativeTo: preview)
                return card
            }()
            if let controller = model.controller(for: id) { card.show(controller) }
            card.isActive = model.activePane == id
            card.isZoomed = tab?.zoomed == id
        }
        emptyView.isHidden = !visible.isEmpty
        if visible.isEmpty { emptyView.update(project: model.currentProject, model: model) }
        if shownTab != tab?.id {
            shownTab = tab?.id
            resizing = nil
        }
        needsLayout = true
    }

    /// The workspace animates this whole surface when a sidebar changes.
    func layoutForWorkspaceTransition() {
        animateNextLayout = false
        layoutSubtreeIfNeeded()
    }

    /// Redraws headers whose titles or activity changed.
    func refreshHeaders() {
        for card in cards.values { card.refreshHeader() }
    }

    override func layout() {
        super.layout()
        let shouldAnimate = animateNextLayout && window != nil && InterfaceMotion.duration(model.appearance.animationStyle) > 0
        let previous = shouldAnimate ? cards.mapValues { InterfaceMotion.frame($0) } : [:]
        defer {
            if shouldAnimate {
                for (id, card) in cards {
                    InterfaceMotion.animate(card, from: previous[id], style: model.appearance.animationStyle)
                }
            }
            animateNextLayout = false
            hasLaidOut = true
        }
        emptyView.frame = content
        defer { placeSidebarToggles() }
        guard let tab else {
            dividers = []
            updateDividerTracking()
            return
        }
        var layout = tab.layout
        if let resizing { try? layout.setRatio(at: resizing.path, to: resizing.ratio) }
        if let zoomed = tab.zoomed {
            cards[zoomed]?.frame = content
            dividers = []
        } else {
            for (pane, frame) in SplitGeometry.frames(layout, in: content, scale: scale) {
                cards[pane]?.frame = frame
            }
            dividers = SplitGeometry.dividers(layout, in: content, scale: scale)
        }
        updateDividerTracking()
    }

    /// Leads the top-left card's header, or the empty card, with the
    /// sidebar toggle, and ends the top-right card's with the right
    /// sidebar's.
    private func placeSidebarToggles() {
        let empty = !emptyView.isHidden
        let leftOwner = empty ? nil : topCard { abs($0.minX - content.minX) < 0.5 }
        let rightOwner = empty ? nil : topCard { abs($0.maxX - content.maxX) < 0.5 }
        for (id, card) in cards {
            if id != leftOwner && card.leadingView != nil { card.leadingView = nil }
            if id != rightOwner && card.trailingView != nil { card.trailingView = nil }
        }
        if let leftOwner { cards[leftOwner]?.leadingView = sidebarToggle }
        if let rightOwner { cards[rightOwner]?.trailingView = rightSidebarToggle }
        emptyView.leadingView = empty ? sidebarToggle : nil
        emptyView.trailingView = empty ? rightSidebarToggle : nil
    }

    /// The zoomed card, or the card on the top edge whose frame matches.
    private func topCard(_ matches: (CGRect) -> Bool) -> PaneId? {
        if let zoomed = tab?.zoomed { return zoomed }
        return cards.first { _, card in abs(card.frame.minY - content.minY) < 0.5 && matches(card.frame) }?.key
    }

    // MARK: Gutters

    private func updateDividerTracking() {
        for area in trackingAreasByDivider { removeTrackingArea(area) }
        trackingAreasByDivider = dividers.map { divider in
            let area = NSTrackingArea(rect: divider.grip, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: ["path": divider.path.map(\.rawValue)])
            addTrackingArea(area)
            return area
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(divider.grip, cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard resizing == nil, let raw = event.trackingArea?.userInfo?["path"] as? [String] else { return }
        hovered = raw.compactMap(Branch.init(rawValue:))
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["path"] != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = resizing?.path ?? hovered
        guard let path, let divider = dividers.first(where: { $0.path == path }) else { return }
        theme.accent.withAlphaComponent(0.4).setFill()
        divider.line.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = dividers.first(where: { $0.grip.contains(point) }), let tab, let window else {
            super.mouseDown(with: event)
            return
        }
        let start = point
        resizing = (divider.path, divider.ratio)
        needsDisplay = true
        let extent = divider.axis == .horizontal ? divider.bounds.width : divider.bounds.height
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let location = convert(next.locationInWindow, from: nil)
            let delta = divider.axis == .horizontal ? location.x - start.x : location.y - start.y
            let ratio = SplitGeometry.ratio(from: divider.ratio, delta: delta, extent: extent)
            if next.type == .leftMouseUp {
                resizing = nil
                model.setRatio(tab: tab.id, path: divider.path, ratio: ratio)
                break
            }
            resizing = (divider.path, ratio)
            needsLayout = true
            needsDisplay = true
        }
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Moving panes

    /// A Command-click on a pane may start dragging it to another place.
    /// Returns whether the click was taken; a click that never moves goes
    /// on to the pane as a Command-click.
    /// A click anywhere in a pane makes it the active one, whatever its kind.
    func activatePane(for event: NSEvent) {
        guard let tab, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pane = tab.zoomed ?? SplitGeometry.frames(tab.layout, in: content, scale: scale)
            .first(where: { $0.1.contains(point) })?.0
        guard let pane, cards[pane]?.frame.contains(point) == true else { return }
        model.activatePane(pane)
    }

    func handleCommandMouseDown(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let tab, tab.zoomed == nil, tab.panes.count > 1,
              let window, event.window === window else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard let source = SplitGeometry.frames(tab.layout, in: content, scale: scale)
            .first(where: { $0.1.contains(point) })?.0 else { return false }
        model.focusPane(source)
        var dragging = false
        var target: DropTarget?
        var lastEvent = event
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            lastEvent = next
            let location = convert(next.locationInWindow, from: nil)
            if !dragging, hypot(location.x - point.x, location.y - point.y) >= 4 {
                dragging = true
                NSCursor.closedHand.push()
            }
            if next.type == .leftMouseUp { break }
            guard dragging else { continue }
            target = DropTargets.target(tab.layout, bounds: content, scale: scale, point: location)
            showPreview(target, layout: tab.layout, source: source)
        }
        preview.isHidden = true
        guard dragging else {
            window.sendEvent(event)
            window.sendEvent(lastEvent)
            return true
        }
        NSCursor.pop()
        if let target, DropTargets.apply(target, to: tab.layout, moving: source) != nil {
            model.drop(source, on: target)
        }
        return true
    }

    private func showPreview(_ target: DropTarget?, layout: Layout<PaneId>, source: PaneId) {
        guard let target, let result = DropTargets.apply(target, to: layout, moving: source),
              let frame = SplitGeometry.frames(result, in: content, scale: scale).first(where: { $0.0 == source })?.1
        else {
            preview.isHidden = true
            return
        }
        preview.frame = frame
        preview.isHidden = false
    }
}

/// The drop indicator: the accent at 18% with a 2pt outline.
final class DropPreviewView: ThemedView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.accent.withAlphaComponent(0.18).cgColor
        layer?.borderColor = theme.accent.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = Metrics.cardRadius
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A project whose tab has no panes yet, drawn in the pane card frame: the
/// window glyph, "Nothing open in <project>", a hint and a button per pane
/// kind; or that the folder is missing.
final class EmptyProjectView: ThemedView {
    private let glass = GlassView(style: .pane)
    /// Adds a pane of the kind chosen.
    var onNewPane: ((PaneKind) -> Void)?
    /// The sidebar toggle at the header position while the sidebar is collapsed.
    var leadingView: NSView? {
        didSet {
            guard leadingView !== oldValue else { return }
            if let oldValue, oldValue.superview === self { oldValue.removeFromSuperview() }
            if let leadingView { addSubview(leadingView) }
            needsLayout = true
        }
    }
    /// The right sidebar's toggle, at the top right while it is collapsed.
    var trailingView: NSView? {
        didSet {
            guard trailingView !== oldValue else { return }
            if let oldValue, oldValue.superview === self { oldValue.removeFromSuperview() }
            if let trailingView { addSubview(trailingView) }
            needsLayout = true
        }
    }

    private let glyph = NSImageView()
    private let title = makeLabel("", font: AppFont.system(14, weight: .semibold))
    private let message = makeLabel("", font: AppFont.small)
    private let tips = makeLabel("", font: AppFont.small)
    private let buttons = NSStackView()
    private var actionButtons: [PaneKind: PillButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(glass)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.borderWidth = Metrics.border
        layer?.cornerCurve = .continuous
        glyph.image = AppIcon.appWindow.image(size: 28)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        message.preferredMaxLayoutWidth = 420
        tips.alignment = .center
        tips.lineBreakMode = .byWordWrapping
        tips.maximumNumberOfLines = 0
        tips.preferredMaxLayoutWidth = 420
        buttons.orientation = .horizontal
        buttons.spacing = Metrics.controlGap
        for kind in PaneKind.created {
            let button = PillButton("\(kind.name) Pane", style: kind == .terminal ? .primary : .normal)
            button.onPress = { [weak self] in self?.onNewPane?(kind) }
            buttons.addArrangedSubview(button)
            actionButtons[kind] = button
        }
        let stack = NSStackView(views: [glyph, title, message, buttons, tips])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            tips.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(project: Project, model: AppModel) {
        let missing = project.status == .missing
        let onboarding = project.home && !missing
        for (kind, button) in actionButtons {
            button.title = "\(kind.name) \(onboarding ? "Tab" : "Pane")"
        }
        title.stringValue = missing ? "Project folder is missing" : onboarding ? "Welcome to Tab" : "Nothing open in \(project.name)"
        message.stringValue = missing
            ? "This project’s folder could not be found. Remove the project from the sidebar to clear its tabs."
            : onboarding
                ? "Your workspace for terminals, AI agents, browsers, and devices. Pick a place to begin."
                : "Open a pane to start working in this project."
        tips.stringValue = onboarding
            ? "A tab is a card in the sidebar. Panes live inside a tab and can be split side by side.\n\nAdd a code folder with Add Project, or press ⌘T for a terminal."
            : ""
        tips.isHidden = !onboarding
        buttons.isHidden = missing
        onNewPane = { [weak model] kind in model?.newPane(kind, in: project.id) }
    }

    override var wantsUpdateLayer: Bool { true }
    override var redrawsOnKeyChange: Bool { true }

    override func updateLayer() {
        glass.isHidden = !theme.glassPanes
        glass.appearance = theme.nsAppearance
        glass.apply(theme.paneGlass(isKey: window?.isKeyWindow ?? true, isActive: true))
        layer?.backgroundColor = theme.paneBackground.cgColor
        layer?.borderWidth = theme.glassPanes ? 0 : Metrics.border
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func themeDidChange() {
        glyph.contentTintColor = theme.fgMuted
        title.textColor = theme.fg
        message.textColor = theme.fgMuted
        tips.textColor = theme.fgMuted
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        if let leadingView {
            let size = leadingView.intrinsicContentSize
            leadingView.frame = CGRect(x: Metrics.gutter, y: ((Metrics.headerHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
        }
        if let trailingView {
            let size = trailingView.intrinsicContentSize
            trailingView.frame = CGRect(x: bounds.width - Metrics.gutter - size.width, y: ((Metrics.headerHeight - size.height) / 2).rounded(),
                                        width: size.width, height: size.height)
        }
    }

    override func mouseDown(with event: NSEvent) {}
}
