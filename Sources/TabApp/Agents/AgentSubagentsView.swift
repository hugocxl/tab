import AppKit
import TabProtocol

/// Agents the conversation's agent started that are still running, above the composer,
/// so work in the background stays visible after the turn ends. A row reveals the
/// transcript's tool row that started its agent.
@MainActor
final class AgentSubagentsView: ThemedView {
    var onReveal: ((String) -> Void)?
    private static let inset: CGFloat = 6
    private static let rowHeight: CGFloat = 30
    private static let visibleRows = 3
    private let card = AgentSurfaceCard(style: .agentPanel)
    private let scroll = NSScrollView()
    private let rows = AgentSubagentRows()
    private var subagents: [AgentSubagent] = []
    private var rowViews: [String: AgentSubagentRow] = [:]
    private(set) var preferredHeight: CGFloat = 0

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
        setAccessibilityLabel("Running agents")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Reuses each agent's row, so progress updates leave its spinner running.
    func update(_ subagents: [AgentSubagent]) {
        let running = subagents.filter { $0.status == .running }
        guard running != self.subagents else { return }
        let structureChanged = running.map(\.id) != self.subagents.map(\.id)
        self.subagents = running
        isHidden = running.isEmpty
        preferredHeight = running.isEmpty ? 0 : CGFloat(min(running.count, Self.visibleRows)) * Self.rowHeight + Self.inset * 2
        let ids = Set(running.map(\.id))
        for (id, row) in rowViews where !ids.contains(id) {
            row.removeFromSuperview()
            rowViews[id] = nil
        }
        for subagent in running {
            let row = rowViews[subagent.id] ?? makeRow()
            rowViews[subagent.id] = row
            if row.superview == nil { rows.addSubview(row) }
            row.show(subagent)
        }
        if structureChanged { needsLayout = true }
    }

    private func makeRow() -> AgentSubagentRow {
        let row = AgentSubagentRow()
        row.onPress = { [weak self] id in self?.onReveal?(id) }
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

/// One running agent: a spinner, what it was asked to do, what it's doing now and
/// how much it has done.
@MainActor
final class AgentSubagentRow: NSView {
    var onPress: ((String) -> Void)?
    private let spinner = NSProgressIndicator()
    private let title = makeLabel("", font: AppFont.body)
    private let activity = makeLabel("", font: AppFont.small)
    private let stats = makeLabel("", font: AppFont.small)
    private var toolUseID: String?
    private var theme: AppTheme = .shared
    private var hovered = false { didSet { if hovered != oldValue { updateHover() } } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        title.lineBreakMode = .byTruncatingTail
        activity.lineBreakMode = .byTruncatingTail
        for view in [spinner, title, activity, stats] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        spinner.startAnimation(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ subagent: AgentSubagent) {
        toolUseID = subagent.toolUseID
        title.stringValue = subagent.description
        activity.stringValue = subagent.activity ?? (subagent.background ? "Working in the background" : "Starting")
        var parts: [String] = []
        if subagent.background { parts.append("Background") }
        if let uses = subagent.toolUses, uses > 0 { parts.append(uses == 1 ? "1 tool" : "\(uses) tools") }
        if let tokens = subagent.tokens, tokens > 0 { parts.append(Self.tokens(tokens)) }
        stats.stringValue = parts.joined(separator: " · ")
        toolTip = [subagent.agentType.map { "\($0) agent" }, subagent.description, subagent.activity]
            .compactMap { $0 }.joined(separator: "\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(subagent.description), \(activity.stringValue)")
        needsLayout = true
    }

    private static func tokens(_ count: Int) -> String {
        count >= 1_000_000 ? String(format: "%.1fM tokens", Double(count) / 1_000_000)
            : count >= 1_000 ? "\(count / 1_000)k tokens" : "\(count) tokens"
    }

    func apply(_ theme: AppTheme) {
        self.theme = theme
        title.textColor = theme.fg
        activity.textColor = theme.fgDim
        stats.textColor = theme.fgMuted
        spinner.appearance = theme.nsAppearance
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

    override var acceptsFirstResponder: Bool { toolUseID != nil }
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
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        ring.lineWidth = 2
        ring.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let toolUseID else { return }
        onPress?(toolUseID)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let toolUseID else { return false }
        onPress?(toolUseID)
        return true
    }

    private func updateHover() {
        layer?.backgroundColor = hovered && toolUseID != nil ? theme.fg.withAlphaComponent(0.05).cgColor : nil
    }

    override func layout() {
        super.layout()
        let middle = floor((bounds.height - 16) / 2)
        spinner.frame = NSRect(x: 8, y: floor((bounds.height - 14) / 2), width: 14, height: 14)
        var right = bounds.width - 10
        stats.isHidden = stats.stringValue.isEmpty
        if !stats.isHidden {
            let width = ceil(stats.intrinsicContentSize.width)
            right -= width
            stats.frame = NSRect(x: right, y: middle, width: width, height: 16)
            right -= 12
        }
        let x: CGFloat = 30
        // The task keeps at least half the room; what it's doing now takes the rest.
        let available = max(0, right - x)
        let titleWidth = min(ceil(title.intrinsicContentSize.width), max(available / 2, available - ceil(activity.intrinsicContentSize.width) - 10))
        title.frame = NSRect(x: x, y: floor((bounds.height - 17) / 2), width: titleWidth, height: 17)
        let activityX = x + titleWidth + 10
        activity.frame = NSRect(x: activityX, y: middle, width: max(0, right - activityX), height: 16)
    }
}
