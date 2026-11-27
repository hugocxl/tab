import AppKit
import TabCore
import TabProtocol

/// The current project's split layout: one card per visible pane with 8pt
/// gutters, inside one 8pt inset. Gutters resize their split by dragging;
/// Command-dragging a pane swaps it with another or docks it on an edge.
/// Frames come from the layout tree once per layout pass.
///
/// Each recently shown tab keeps its cards on a canvas of its own, hidden
/// while another tab shows. Showing a tab again unhides its canvas: no card
/// is made, no pane content moves between views, and nothing redraws that
/// did not change, so switching among many tabs costs about the same as one.
final class SplitContainerView: ThemedView {
    unowned let model: AppModel
    private var cards: [PaneId: PaneCardView] = [:]
    /// The cards of recently shown tabs, by tab; only the shown tab's is visible.
    private var canvases: [TabId: TabCanvasView] = [:]
    /// Tabs with a canvas, the most recently shown last.
    private var canvasOrder: [TabId] = []
    private let emptyView = EmptyProjectView()
    private let creatingView = WorktreeCreatingView()
    private let preview = DropPreviewView()
    /// The accent line on the gutter under the pointer or being dragged.
    private let dividerLine = DividerLineView()
    private var dividers: [SplitGeometry.Divider] = []
    private var hovered: [Branch]?
    private var resizing: (path: [Branch], ratio: Double)?
    private var trackingAreasByDivider: [NSTrackingArea] = []
    /// The gutters the tracking areas follow.
    private var trackedGrips: [DividerGrip] = []

    private struct DividerGrip: Equatable {
        var path: [Branch]
        var grip: CGRect
    }
    private var shownTab: TabId?
    private var shownCreation: UUID?
    private var animateNextLayout = false
    /// Another tab came in since the last layout pass, which shows it still.
    private var switchedTab = false
    private var hasLaidOut = false
    /// The cards shown by the last layout pass, which animate from their frames.
    private var laidOut: Set<PaneId> = []
    private var prewarmScheduled = false
    /// When another tab last came in; readying hidden tabs waits for a pause.
    private var lastSwitch: CFTimeInterval = 0

    /// How many tabs keep their cards while hidden. Beyond it, the tab shown
    /// longest ago gives up its cards and makes them again when shown. A
    /// card costs little beside its content, which lives on regardless.
    static let keptTabs = 128

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
        creatingView.isHidden = true
        addSubview(creatingView)
        dividerLine.isHidden = true
        addSubview(dividerLine)
        preview.isHidden = true
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    private var tab: Tab? { model.activeTab }
    private var content: CGRect { bounds.insetBy(dx: Metrics.gutter, dy: Metrics.gutter) }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    /// The shown tab's canvas.
    private var shownCanvas: TabCanvasView? {
        guard creatingView.isHidden, let shownTab else { return nil }
        return canvases[shownTab]
    }

    /// The cards on screen now.
    private var visibleCards: [PaneId: PaneCardView] {
        guard let canvas = shownCanvas, !canvas.isHidden else { return [:] }
        var visible: [PaneId: PaneCardView] = [:]
        for case let card as PaneCardView in canvas.subviews where !card.isHidden { visible[card.pane] = card }
        return visible
    }

    /// Matches the cards to the model's current tab.
    func reload() {
        pruneCanvases()
        if let creation = model.activeWorktreeCreation {
            if shownCreation != creation.id {
                if let canvas = shownCanvas { InterfaceMotion.cancel(in: canvas, depth: 1) }
                switchedTab = true
                shownCreation = creation.id
            }
            animateNextLayout = false
            hideCanvases(except: nil)
            emptyView.isHidden = true
            creatingView.isHidden = false
            let projectTitle = model.state.project(creation.parent).map { model.title(of: $0) }
            creatingView.update(creation, projectTitle: projectTitle)
            resizing = nil
            needsLayout = true
            return
        }
        let leavingCreation = shownCreation != nil
        if leavingCreation {
            switchedTab = true
            shownCreation = nil
        }
        creatingView.isHidden = true

        let tab = self.tab
        // Another tab shows at once: the panes are already there, so fading
        // them in would only delay them.
        let switchingTab = leavingCreation || (shownTab != nil && tab != nil && shownTab != tab?.id)
        if switchingTab {
            if let canvas = shownCanvas { InterfaceMotion.cancel(in: canvas, depth: 1) }
            switchedTab = true
            lastSwitch = CACurrentMediaTime()
        }
        animateNextLayout = hasLaidOut && !switchedTab
        hideCanvases(except: tab?.id)
        let visible = tab?.visiblePanes ?? []
        if let tab {
            let canvas = self.canvas(for: tab.id)
            if switchingTab { InterfaceMotion.cancel(in: canvas, depth: 1) }
            let panes = Set(tab.panes.map(\.id))
            let shown = Set(visible)
            for case let card as PaneCardView in canvas.subviews {
                if !panes.contains(card.pane) {
                    if !switchingTab, !card.isHidden { InterfaceMotion.dismiss(card, style: model.appearance.animationStyle) }
                    removeCard(card.pane)
                } else if !shown.contains(card.pane), !card.isHidden {
                    // A zoomed sibling waits hidden for the zoom to end.
                    card.isHidden = true
                }
            }
            for id in visible {
                let card = cards[id] ?? {
                    let card = PaneCardView(pane: id, model: model)
                    cards[id] = card
                    return card
                }()
                if card.superview !== canvas { canvas.addSubview(card) }
                if card.isHidden { card.isHidden = false }
                if let controller = model.controller(for: id) { card.show(controller) }
                card.isActive = model.activePane == id
                card.isZoomed = tab.zoomed == id
            }
            canvas.isHidden = false
        }
        emptyView.isHidden = !visible.isEmpty
        if visible.isEmpty { emptyView.update(project: model.currentProject, model: model) }
        if shownTab != tab?.id {
            shownTab = tab?.id
            resizing = nil
        }
        needsLayout = true
        schedulePrewarm()
    }

    // MARK: Readying hidden tabs

    /// Builds a hidden tab's cards ahead of its first showing, laid out at the
    /// current size, and lets its panes fetch and draw what they show, so
    /// switching to it only unhides them. Returns whether it did.
    @discardableResult
    func prepare(_ tabId: TabId) -> Bool {
        guard window != nil, bounds.width > 0, bounds.height > 0, canvases[tabId] == nil,
              canvasOrder.count < Self.keptTabs,
              let project = model.state.projects.first(where: { $0.tabs.contains { $0.id == tabId } }),
              project.status == .available, let tab = project.tabs.first(where: { $0.id == tabId }) else { return false }
        let canvas = TabCanvasView(frame: bounds)
        canvas.isHidden = true
        canvases[tabId] = canvas
        // Shown longest ago, so tabs readied ahead give way to tabs visited.
        canvasOrder.insert(tabId, at: 0)
        addSubview(canvas, positioned: .below, relativeTo: preview)
        let frames = tab.zoomed.map { [($0, content)] } ?? SplitGeometry.frames(tab.layout, in: content, scale: scale)
        for (id, frame) in frames {
            guard cards[id] == nil, let controller = model.controller(for: id) else { continue }
            let card = PaneCardView(pane: id, model: model)
            cards[id] = card
            canvas.addSubview(card)
            card.show(controller)
            card.isZoomed = tab.zoomed == id
            card.frame = frame
        }
        // A hidden view isn't laid out, and nothing draws before this turn
        // ends, so the canvas shows only while its panes take their sizes.
        canvas.isHidden = false
        canvas.layoutSubtreeIfNeeded()
        canvas.isHidden = true
        for case let card as PaneCardView in canvas.subviews {
            (card.controller as? PanePrewarming)?.prewarm()
        }
        return true
    }

    /// Readies the next hidden tab a moment from now, one tab at a time, so
    /// the work fits between frames and yields to the user's switching.
    private func schedulePrewarm() {
        guard !prewarmScheduled else { return }
        prewarmScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { self?.prewarmNext() }
        }
    }

    private func prewarmNext() {
        prewarmScheduled = false
        // Readying resumes with the next change once the app is in use again.
        guard NSApp.isActive, window?.isVisible == true else { return }
        guard CACurrentMediaTime() - lastSwitch > 0.4 else { return schedulePrewarm() }
        guard let next = nextTabToPrepare() else { return }
        prepare(next)
        schedulePrewarm()
    }

    /// How many cards on each side of the shown one get readied unasked. A
    /// readied terminal holds its drawn rows, so farther tabs wait for the
    /// pointer to rest on their card.
    static let readiedNeighbors = 4

    /// The hidden tab to ready next: the sidebar's cards nearest the shown
    /// one first, as moving to the next or previous card goes there. Tabs
    /// with a browser or a simulator wait until the pointer is on their card,
    /// since readying them loads pages or streams video.
    private func nextTabToPrepare() -> TabId? {
        guard canvasOrder.count < Self.keptTabs else { return nil }
        let state = model.state
        let tabs: [TabId] = model.sidebarListing.targets.compactMap { target in
            switch target {
            case .tab(let id): return id
            case .project(let id):
                guard let project = state.project(id) else { return nil }
                let selected = state.window.selectedTab[id]
                return (project.tabs.first { $0.id == selected } ?? project.tabs.first)?.id
            }
        }
        let current = tabs.firstIndex { $0 == shownTab } ?? 0
        let nearest = tabs.indices.filter { abs($0 - current) <= Self.readiedNeighbors }
            .sorted { abs($0 - current) < abs($1 - current) }
        for index in nearest {
            let id = tabs[index]
            guard canvases[id] == nil,
                  let project = state.projects.first(where: { $0.tabs.contains { $0.id == id } }),
                  project.status == .available, model.connectionState(project.serverId).isReady,
                  let tab = project.tabs.first(where: { $0.id == id }) else { continue }
            let quiet = tab.panes.allSatisfy { pane in
                switch PaneKind(pane.content) {
                case .terminal, .agent, .editor, .diff: return true
                case .browser, .simulator: return false
                }
            }
            if quiet { return id }
        }
        return nil
    }

    /// The canvas holding `tab`'s cards, made if needed, as the most recently shown.
    private func canvas(for tab: TabId) -> TabCanvasView {
        canvasOrder.removeAll { $0 == tab }
        canvasOrder.append(tab)
        if let canvas = canvases[tab] { return canvas }
        let canvas = TabCanvasView(frame: bounds)
        canvas.isHidden = true
        canvases[tab] = canvas
        addSubview(canvas, positioned: .below, relativeTo: preview)
        while canvasOrder.count > Self.keptTabs, let oldest = canvasOrder.first { dropCanvas(oldest) }
        return canvas
    }

    /// Hides every canvas but `tab`'s, taking the keyboard from a pane on
    /// one, as removing the pane from the window would.
    private func hideCanvases(except tab: TabId?) {
        for (id, canvas) in canvases where id != tab && !canvas.isHidden {
            if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: canvas) {
                window.makeFirstResponder(nil)
            }
            canvas.isHidden = true
        }
    }

    /// Forgets the canvases of closed tabs and the cards of closed panes.
    private func pruneCanvases() {
        var tabs: Set<TabId> = []
        var panes: Set<PaneId> = []
        for project in model.state.projects {
            for tab in project.tabs {
                tabs.insert(tab.id)
                for pane in tab.panes { panes.insert(pane.id) }
            }
        }
        for id in canvases.keys where !tabs.contains(id) { dropCanvas(id) }
        for id in cards.keys where !panes.contains(id) {
            // The shown tab's closed panes leave with their dismiss motion.
            if let card = cards[id], card.superview !== shownCanvas || card.isHidden || shownCanvas?.isHidden != false {
                removeCard(id)
            }
        }
    }

    private func dropCanvas(_ tab: TabId) {
        guard let canvas = canvases.removeValue(forKey: tab) else { return }
        canvasOrder.removeAll { $0 == tab }
        for case let card as PaneCardView in canvas.subviews { removeCard(card.pane) }
        canvas.removeFromSuperview()
    }

    private func removeCard(_ pane: PaneId) {
        guard let card = cards.removeValue(forKey: pane) else { return }
        card.removeFromSuperview()
    }

    /// Called after each layout pass with whether the cards animate to their
    /// new frames, so the workspace can keep its veil cut out under them.
    var onLayout: ((_ animated: Bool) -> Void)?

    /// The glass surfaces' frames, in this view's coordinates.
    var surfaceFrames: [CGRect] {
        if !creatingView.isHidden { return [creatingView.frame] }
        return emptyView.isHidden ? visibleCards.values.map(\.frame) : [emptyView.frame]
    }

    /// The workspace animates this whole surface when a sidebar changes.
    func layoutForWorkspaceTransition() {
        animateNextLayout = false
        layoutSubtreeIfNeeded()
    }

    /// Redraws headers whose titles or activity changed. Hidden tabs'
    /// headers catch up when shown.
    func refreshHeaders() {
        for card in visibleCards.values { card.refreshHeader() }
    }

    override func layout() {
        super.layout()
        let shouldAnimate = animateNextLayout && window != nil && InterfaceMotion.duration(model.appearance.animationStyle) > 0
        let visible = visibleCards
        // A card that was hidden, such as a zoomed pane's sibling, comes in
        // as a new one does.
        let previous = shouldAnimate ? visible.filter { laidOut.contains($0.key) }.mapValues { InterfaceMotion.frame($0) } : [:]
        defer {
            if shouldAnimate {
                for (id, card) in visible {
                    InterfaceMotion.animate(card, from: previous[id], style: model.appearance.animationStyle)
                }
            }
            laidOut = Set(visible.keys)
            animateNextLayout = false
            switchedTab = false
            hasLaidOut = true
            onLayout?(shouldAnimate)
        }
        emptyView.frame = content
        creatingView.frame = content
        if let canvas = shownCanvas, canvas.frame != bounds { canvas.frame = bounds }
        defer { placeSidebarToggles() }
        guard creatingView.isHidden, let tab else {
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
        showDividerLine()
    }

    /// Leads the top-left card's header, or the empty card, with the
    /// sidebar toggle, and ends the top-right card's with the right
    /// sidebar's.
    private func placeSidebarToggles() {
        let creating = !creatingView.isHidden
        let empty = !creating && !emptyView.isHidden
        let placeholder = creating || empty
        let visible = visibleCards
        let leftOwner = placeholder ? nil : topCard(in: visible) { abs($0.minX - content.minX) < 0.5 }
        let rightOwner = placeholder ? nil : topCard(in: visible) { abs($0.maxX - content.maxX) < 0.5 }
        for (id, card) in cards {
            if id != leftOwner && card.leadingView != nil { card.leadingView = nil }
            if id != rightOwner && card.trailingView != nil { card.trailingView = nil }
        }
        if let leftOwner { cards[leftOwner]?.leadingView = sidebarToggle }
        if let rightOwner { cards[rightOwner]?.trailingView = rightSidebarToggle }
        creatingView.leadingView = creating ? sidebarToggle : nil
        creatingView.trailingView = creating ? rightSidebarToggle : nil
        emptyView.leadingView = empty ? sidebarToggle : nil
        emptyView.trailingView = empty ? rightSidebarToggle : nil
    }

    /// The zoomed card, or the card on the top edge whose frame matches.
    private func topCard(in visible: [PaneId: PaneCardView], _ matches: (CGRect) -> Bool) -> PaneId? {
        if let zoomed = tab?.zoomed { return zoomed }
        return visible.first { _, card in abs(card.frame.minY - content.minY) < 0.5 && matches(card.frame) }?.key
    }

    // MARK: Gutters

    private func updateDividerTracking() {
        // Unchanged gutters keep their tracking, cursors and drawing.
        let grips = dividers.map { DividerGrip(path: $0.path, grip: $0.grip) }
        guard grips != trackedGrips else { return }
        trackedGrips = grips
        for area in trackingAreasByDivider { removeTrackingArea(area) }
        trackingAreasByDivider = dividers.map { divider in
            let area = NSTrackingArea(rect: divider.grip, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                      owner: self, userInfo: ["path": divider.path.map(\.rawValue)])
            addTrackingArea(area)
            return area
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(divider.grip, cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard resizing == nil, let raw = event.trackingArea?.userInfo?["path"] as? [String] else { return }
        hovered = raw.compactMap(Branch.init(rawValue:))
        showDividerLine()
    }

    override func mouseExited(with event: NSEvent) {
        guard event.trackingArea?.userInfo?["path"] != nil else { return }
        hovered = nil
        showDividerLine()
    }

    /// Shows the line on the gutter being dragged, else the one under the
    /// pointer. A small view of its own, so the container has nothing to draw.
    private func showDividerLine() {
        let path = resizing?.path ?? hovered
        guard let path, let divider = dividers.first(where: { $0.path == path }) else {
            dividerLine.isHidden = true
            return
        }
        if dividerLine.frame != divider.line { dividerLine.frame = divider.line }
        dividerLine.isHidden = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = dividers.first(where: { $0.grip.contains(point) }), let tab, let window else {
            super.mouseDown(with: event)
            return
        }
        let start = point
        resizing = (divider.path, divider.ratio)
        showDividerLine()
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
        }
        needsLayout = true
        showDividerLine()
    }

    // MARK: Moving panes

    /// A Command-click on a pane may start dragging it to another place.
    /// Returns whether the click was taken; a click that never moves goes
    /// on to the pane as a Command-click.
    /// A click anywhere in a pane makes it the active one, whatever its kind.
    func activatePane(for event: NSEvent) {
        guard creatingView.isHidden, let tab, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let pane = tab.zoomed ?? SplitGeometry.frames(tab.layout, in: content, scale: scale)
            .first(where: { $0.1.contains(point) })?.0
        guard let pane, cards[pane]?.frame.contains(point) == true else { return }
        model.activatePane(pane)
    }

    func handleCommandMouseDown(_ event: NSEvent) -> Bool {
        guard creatingView.isHidden, event.modifierFlags.contains(.command), let tab, tab.zoomed == nil, tab.panes.count > 1,
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

/// One tab's cards, as large as the split container.
final class TabCanvasView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Clicks between cards go to the split container, for its gutters.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The gutter line: the accent at 40%.
final class DividerLineView: ThemedView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.accent.withAlphaComponent(0.4).cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The drop indicator: the accent at 18% with a 2pt outline.
final class DropPreviewView: ThemedView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.accent.withAlphaComponent(0.18).cgColor
        layer?.borderColor = theme.accent.withAlphaComponent(0.8).cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = Metrics.cardRadius
        layer?.cornerCurve = .continuous
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
                ? "Your workspace for terminals, AI agents, browsers, and simulators. Pick a place to begin."
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
