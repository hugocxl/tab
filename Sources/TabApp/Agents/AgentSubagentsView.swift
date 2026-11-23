import AppKit
import TabProtocol

/// Agents the conversation's agent started, above the composer, so work in the
/// background stays visible after the turn ends. Running agents show what they do and
/// for how long; finished ones stay with their outcome until the next prompt or until
/// dismissed. A row opens the agent's own steps.
@MainActor
final class AgentSubagentsView: ThemedView {
    /// Opens an agent's steps.
    var onOpen: ((AgentSubagent) -> Void)?
    /// Reveals the transcript's tool row that started an agent.
    var onReveal: ((String) -> Void)?
    private static let inset = AgentPanelMetrics.inset
    private static let rowHeight = AgentPanelMetrics.rowHeight
    private static let visibleRows = 3
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let scroll = NSScrollView()
    private let rows = AgentSubagentRows()
    private var subagents: [AgentSubagent] = []
    private var rowViews: [String: AgentSubagentRow] = [:]
    /// Finished agents the user dismissed in this pane.
    private var dismissed: Set<String> = []
    private var latest: [AgentSubagent] = []
    private(set) var preferredHeight: CGFloat = 0

    /// The agents on show: running ones, then finished ones not dismissed.
    var shown: [AgentSubagent] { subagents }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = rows
        addSubview(card)
        card.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agents")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Reuses each agent's row, so progress updates leave its spinner running.
    func update(_ subagents: [AgentSubagent]) {
        latest = subagents
        // A server that predates finished agents sends running ones only.
        dismissed.formIntersection(subagents.map(\.id))
        let visible = subagents.filter { $0.status == .running } + subagents.filter { $0.status != .running && !dismissed.contains($0.id) }
        guard visible != self.subagents else { return }
        let structureChanged = visible.map(\.id) != self.subagents.map(\.id)
        self.subagents = visible
        isHidden = visible.isEmpty
        preferredHeight = visible.isEmpty ? 0 : CGFloat(min(visible.count, Self.visibleRows)) * Self.rowHeight + Self.inset * 2
        let ids = Set(visible.map(\.id))
        for (id, row) in rowViews where !ids.contains(id) {
            row.removeFromSuperview()
            rowViews[id] = nil
        }
        for subagent in visible {
            let row = rowViews[subagent.id] ?? makeRow()
            rowViews[subagent.id] = row
            if row.superview == nil { rows.addSubview(row) }
            row.show(subagent)
        }
        if structureChanged { needsLayout = true }
    }

    func dismiss(_ id: String) {
        dismissed.insert(id)
        let previous = preferredHeight
        update(latest)
        if preferredHeight != previous { superview?.superview?.needsLayout = true; window?.contentView?.needsLayout = true }
    }

    private func makeRow() -> AgentSubagentRow {
        let row = AgentSubagentRow()
        row.onOpen = { [weak self] agent in self?.onOpen?(agent) }
        row.onPress = { [weak self] id in self?.onReveal?(id) }
        row.onDismiss = { [weak self] id in self?.dismiss(id) }
        row.apply(theme)
        return row
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let inset = Self.inset
        scroll.frame = NSRect(x: 0, y: inset, width: bounds.width, height: max(0, bounds.height - inset * 2))
        let width = max(1, scroll.contentSize.width)
        for (index, subagent) in subagents.enumerated() {
            rowViews[subagent.id]?.frame = NSRect(x: inset, y: CGFloat(index) * Self.rowHeight,
                                                  width: width - inset * 2, height: Self.rowHeight)
        }
        rows.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(subagents.count) * Self.rowHeight)
    }

    override func themeDidChange() {
        appearance = theme.nsAppearance
        card.theme = theme
        for row in rowViews.values { row.apply(theme) }
    }
}

@MainActor
private final class AgentSubagentRows: NSView {
    override var isFlipped: Bool { true }
}

/// One agent: a spinner or its outcome, what it was asked to do, what it's doing now
/// or how it ended, and how much it has done for how long.
@MainActor
final class AgentSubagentRow: NSView {
    var onOpen: ((AgentSubagent) -> Void)?
    /// Reveals the tool row that started the agent.
    var onPress: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    /// A spinning ring while it runs, then its outcome, as the notice's icon draws them.
    private let icon = NoticeIcon()
    private let title = makeLabel("", font: AgentPanelMetrics.titleFont)
    private let activity = makeLabel("", font: AgentPanelMetrics.detailFont)
    private let stats = makeLabel("", font: AgentPanelMetrics.metaFont)
    private let close = AgentIconButton(icon: .close, label: "Dismiss", iconSize: 13)
    private(set) var subagent: AgentSubagent?
    private var theme: AppTheme = .shared
    private var hovered = false { didSet { if hovered != oldValue { updateHover() } } }
    private var tracking: NSTrackingArea?
    private var ticking = false

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = AgentPanelMetrics.rowRadius
        layer?.cornerCurve = .continuous
        icon.glyphSize = AgentPanelMetrics.glyphSize
        title.lineBreakMode = .byTruncatingTail
        activity.lineBreakMode = .byTruncatingTail
        close.onPress = { [weak self] in
            guard let id = self?.subagent?.id else { return }
            self?.onDismiss?(id)
        }
        for view in [icon, title, activity, stats, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var running: Bool { subagent?.status == .running }

    func show(_ subagent: AgentSubagent) {
        self.subagent = subagent
        title.stringValue = subagent.description
        let type = subagent.agentType.map { $0 + " · " } ?? ""
        switch subagent.status {
        case .running:
            activity.stringValue = type + (subagent.activity ?? (subagent.background ? "Working in the background" : "Starting"))
        case .completed: activity.stringValue = type + (subagent.activity.map { "Done · " + $0 } ?? "Done")
        case .failed: activity.stringValue = type + (subagent.activity.map { "Failed · " + $0 } ?? "Failed")
        case .stopped: activity.stringValue = type + "Stopped"
        }
        close.isHidden = running
        refreshStats()
        updateTicking()
        toolTip = [subagent.agentType.map { "\($0) agent" }, subagent.description, subagent.activity,
                   subagent.agentType == "Shell" ? "Click to see its output" : "Click to see its steps"].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(subagent.description), \(activity.stringValue), \(stats.stringValue)")
        apply(theme)
        needsLayout = true
    }

    /// How much the agent did and for how long; a running agent's time counts up.
    private func refreshStats() {
        guard let subagent else { return }
        var parts: [String] = []
        // "Working in the background" already says so while it has nothing newer to report.
        if subagent.background, !(running && subagent.activity == nil) { parts.append("Background") }
        if let uses = subagent.toolUses, uses > 0 { parts.append(uses == 1 ? "1 tool" : "\(uses) tools") }
        if let tokens = subagent.tokens, tokens > 0 { parts.append(Self.tokens(tokens)) }
        if let started = subagent.startedAt {
            let end = subagent.status == .running ? Date() : subagent.finishedAt ?? Date()
            parts.append(AgentTurnTime.seconds(end.timeIntervalSince(started)))
        }
        let text = parts.joined(separator: " · ")
        guard stats.stringValue != text else { return }
        stats.stringValue = text
        needsLayout = true
    }

    private func updateTicking() {
        let wants = running && subagent?.startedAt != nil && window != nil
        guard wants != ticking else { return }
        ticking = wants
        if wants { AgentSecondTicker.shared.subscribe(self) { [weak self] in self?.refreshStats() } }
        else { AgentSecondTicker.shared.unsubscribe(self) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM tokens", Double(count) / 1_000_000)
            : count >= 1_000 ? "\(count / 1_000)k tokens" : "\(count) tokens"
    }

    func apply(_ theme: AppTheme) {
        self.theme = theme
        let failed = subagent?.status == .failed
        title.textColor = theme.fg
        activity.textColor = failed ? theme.danger : theme.fgDim
        stats.textColor = theme.fgMuted
        close.chatTheme = theme
        icon.theme = theme
        switch subagent?.status {
        case .completed: (icon.icon, icon.color) = (.icon(.circleCheckFill), theme.success)
        case .failed: (icon.icon, icon.color) = (.icon(.circleXFill), theme.danger)
        case .stopped: (icon.icon, icon.color) = (.icon(.minusCircle), theme.fgDim)
        case .running, nil: (icon.icon, icon.color) = (.spinner, theme.fgDim)
        }
        updateHover()
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override var acceptsFirstResponder: Bool { subagent != nil }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
    override func insertNewline(_ sender: Any?) { _ = accessibilityPerformPress() }
    override func insertText(_ insertString: Any) {
        if insertString as? String == " " { _ = accessibilityPerformPress() }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard window?.firstResponder === self else { return }
        theme.accent.withAlphaComponent(0.7).setStroke()
        let radius = AgentPanelMetrics.rowRadius - 1
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: radius, yRadius: radius)
        ring.lineWidth = 2
        ring.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        _ = accessibilityPerformPress()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let subagent else { return nil }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(subagent.agentType == "Shell" ? "Show Output" : "Show Steps") { [weak self] in self?.onOpen?(subagent) })
        if let toolUseID = subagent.toolUseID {
            menu.addItem(ClosureMenuItem("Show in Conversation") { [weak self] in self?.onPress?(toolUseID) })
        }
        if subagent.status != .running {
            menu.addItem(ClosureMenuItem("Dismiss") { [weak self] in self?.onDismiss?(subagent.id) })
        }
        return menu
    }

    /// Opens the agent's steps, or a shell's command and output; with nothing to show
    /// them by, reveals its tool row.
    override func accessibilityPerformPress() -> Bool {
        guard let subagent else { return false }
        if let onOpen, subagent.toolUseID != nil { onOpen(subagent); return true }
        guard let toolUseID = subagent.toolUseID else { return false }
        onPress?(toolUseID)
        return true
    }

    private func updateHover() {
        layer?.backgroundColor = hovered && subagent != nil ? theme.fg.withAlphaComponent(0.05).cgColor : nil
    }

    override func layout() {
        super.layout()
        let metrics = AgentPanelMetrics.self
        func centered(_ label: NSTextField) -> CGFloat { floor((bounds.height - ceil(label.intrinsicContentSize.height)) / 2) }
        icon.frame = NSRect(x: metrics.iconX, y: floor((bounds.height - metrics.iconSide) / 2), width: metrics.iconSide, height: metrics.iconSide)
        var right = bounds.width - metrics.iconX
        if !close.isHidden {
            // The same button the queue's rows end with.
            right = bounds.width - 3 - 26
            close.frame = NSRect(x: right, y: floor((bounds.height - 26) / 2), width: 26, height: 26)
            right -= 6
        }
        stats.isHidden = stats.stringValue.isEmpty
        if !stats.isHidden {
            let width = stats.singleLineWidth
            right -= width
            stats.frame = NSRect(x: right, y: centered(stats), width: width, height: ceil(stats.intrinsicContentSize.height))
            right -= metrics.textGap
        }
        let x = metrics.textX
        // The task keeps at least half the room; what it's doing now takes the rest.
        let available = max(0, right - x)
        let titleWidth = min(title.singleLineWidth, max(available / 2, available - activity.singleLineWidth - metrics.textGap))
        title.frame = NSRect(x: x, y: centered(title), width: titleWidth, height: ceil(title.intrinsicContentSize.height))
        let activityX = x + titleWidth + metrics.textGap
        activity.frame = NSRect(x: activityX, y: centered(activity), width: max(0, right - activityX),
                                height: ceil(activity.intrinsicContentSize.height))
    }
}
