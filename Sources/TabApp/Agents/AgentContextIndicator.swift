import AppKit

/// Like T3's ContextWindowMeter, measures the latest prompt, not lifetime billed tokens.
@MainActor
final class AgentContextIndicator: AgentComposerButton {
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    private(set) var usedTokens: Int?
    private(set) var contextWindow: Int?
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Context window"
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(showDetails)
        update(usedTokens: nil, contextWindow: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    var fractionUsed: Double? {
        guard let usedTokens, let contextWindow, contextWindow > 0 else { return nil }
        return Double(usedTokens) / Double(contextWindow)
    }

    private var summary: String {
        guard let usedTokens else { return "Usage will appear when the provider reports it." }
        let count = usedTokens.formatted()
        guard let contextWindow, let fractionUsed else { return "\(count) tokens used · capacity not reported" }
        let percentage = (fractionUsed * 100).formatted(.number.precision(.fractionLength(0...(fractionUsed < 0.1 ? 1 : 0))))
        return "\(percentage)% used · \(count) / \(contextWindow.formatted()) tokens"
    }

    func update(usedTokens: Int?, contextWindow: Int?) {
        let used = usedTokens.flatMap { $0 >= 0 ? $0 : nil }
        let capacity = contextWindow.flatMap { $0 > 0 ? $0 : nil }
        let changed = self.usedTokens != used || self.contextWindow != capacity
        self.usedTokens = used
        self.contextWindow = capacity
        toolTip = "Context window\n\(summary)"
        setAccessibilityLabel("Context window")
        setAccessibilityValue(summary)
        if changed { popover?.close() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || isHighlighted {
            chatTheme.fg.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 8
        chatTheme.fg.withAlphaComponent(0.18).setStroke()
        let track = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        track.lineWidth = 2.5
        track.stroke()
        if let fractionUsed {
            (fractionUsed > 0.9 ? chatTheme.danger : chatTheme.fgMuted).setStroke()
            if fractionUsed > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: -90,
                              endAngle: -90 + CGFloat(min(1, fractionUsed)) * 360, clockwise: false)
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                arc.stroke()
            }
        } else {
            chatTheme.fgDim.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
        }
    }

    @objc private func showDetails() {
        guard window != nil else { return }
        if popover?.isShown == true { popover?.close(); return }
        let controller = NSViewController()
        let background = ThemedBackground(color: { $0.floating })
        background.theme = chatTheme
        background.frame = NSRect(x: 0, y: 0, width: 310, height: 100)
        let heading = makeLabel("Context window", font: AppFont.system(13, weight: .medium))
        heading.textColor = chatTheme.fg
        heading.frame = NSRect(x: 16, y: 14, width: 278, height: 20)
        background.addSubview(heading)
        let detail = NSTextField(wrappingLabelWithString: summary)
        detail.font = AppFont.small
        detail.textColor = chatTheme.fgMuted
        detail.frame = NSRect(x: 16, y: 42, width: 278, height: 42)
        background.addSubview(detail)
        controller.view = background
        let panel = NSPopover()
        panel.behavior = .transient
        panel.contentViewController = controller
        popover = panel
        panel.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }
}
