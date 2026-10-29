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

    /// The sidebar toggle, shown in the top-left card while the sidebar is
    /// collapsed.
    var sidebarToggle: NSView? {
        didSet { if sidebarToggle !== oldValue { needsLayout = true } }
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
        let visible = tab?.visiblePanes ?? []
        for (id, card) in cards where !visible.contains(id) {
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

    /// Redraws headers whose titles or activity changed.
    func refreshHeaders() {
        for card in cards.values { card.refreshHeader() }
    }

    override func layout() {
        super.layout()
        emptyView.frame = content
        defer { placeSidebarToggle() }
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
    /// sidebar toggle.
    private func placeSidebarToggle() {
        let topLeft: PaneId? = tab?.zoomed ?? cards.first { _, card in
            abs(card.frame.minX - content.minX) < 0.5 && abs(card.frame.minY - content.minY) < 0.5
        }?.key
        let owner = emptyView.isHidden ? topLeft : nil
        for (id, card) in cards where id != owner && card.leadingView != nil { card.leadingView = nil }
        if emptyView.isHidden { emptyView.leadingView = nil }
        if let owner { cards[owner]?.leadingView = sidebarToggle } else if !emptyView.isHidden { emptyView.leadingView = sidebarToggle }
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

/// A project with no panes, as Codesh draws it in the pane card frame: the
/// window glyph, "Nothing open in <project>", a hint and New Terminal; or
/// that the folder is missing.
final class EmptyProjectView: ThemedView {
    var onNewTerminal: (() -> Void)?
    /// The sidebar toggle at the header position while the sidebar is collapsed.
    var leadingView: NSView? {
        didSet {
            guard leadingView !== oldValue else { return }
            if let oldValue, oldValue.superview === self { oldValue.removeFromSuperview() }
            if let leadingView { addSubview(leadingView) }
            needsLayout = true
        }
    }

    private let glyph = NSImageView()
    private let title = makeLabel("", font: AppFont.system(14, weight: .semibold))
    private let message = makeLabel("", font: AppFont.small)
    private let button = PillButton("New Terminal", style: .primary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Metrics.cardRadius
        layer?.borderWidth = Metrics.border
        layer?.cornerCurve = .continuous
        glyph.image = AppIcon.appWindow.image(size: 28)
        message.alignment = .center
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 0
        message.preferredMaxLayoutWidth = 360
        button.action = { [weak self] in self?.onNewTerminal?() }
        let stack = NSStackView(views: [glyph, title, message, button])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            message.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(project: Project, model: AppModel) {
        let missing = project.status == .missing
        title.stringValue = missing ? "Project folder is missing" : "Nothing open in \(project.name)"
        message.stringValue = missing
            ? "This project’s folder could not be found. Remove the project from the sidebar to clear its tabs."
            : "Open a terminal to start working in this project."
        button.isHidden = missing
        onNewTerminal = { [weak model] in model?.newTerminal(in: project.id) }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.card.cgColor
        layer?.borderColor = theme.cardBorder.cgColor
    }

    override func themeDidChange() {
        glyph.contentTintColor = theme.fgMuted
        title.textColor = theme.fg
        message.textColor = theme.fgMuted
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let leadingView else { return }
        let size = leadingView.intrinsicContentSize
        leadingView.frame = CGRect(x: Metrics.gutter, y: ((Metrics.headerHeight - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {}
}
