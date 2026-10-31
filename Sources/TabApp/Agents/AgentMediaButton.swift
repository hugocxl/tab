import AppKit

@MainActor
final class AgentMediaButton: NSButton {
    enum Glyph { case previous, next, close }
    let glyph: Glyph
    var onPress: (() -> Void)?
    var narrow = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    init(_ glyph: Glyph, label: String) {
        self.glyph = glyph
        super.init(frame: .zero)
        isBordered = false; title = ""; setButtonType(.momentaryPushIn)
        target = self; action = #selector(pressed)
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func pressed() { perform() }
    func perform() { if isEnabled { onPress?() } }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        let active = hovered || isHighlighted
        let rect = isHighlighted ? bounds.insetBy(dx: bounds.width * 0.015, dy: bounds.height * 0.015) : bounds
        let shape = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if glyph == .close {
            NSColor.black.withAlphaComponent(active ? 0.8 : 0.65).setFill(); shape.fill()
            NSColor.white.withAlphaComponent(0.2).setStroke(); shape.lineWidth = 1; shape.stroke()
        } else if active { NSColor.white.withAlphaComponent(0.1).setFill(); shape.fill() }
        let size: CGFloat = glyph == .close ? (narrow ? 18 : 16) : 20
        let x = rect.midX - size / 2, y = rect.midY - size / 2, scale = size / 24
        let path = NSBezierPath()
        func point(_ a: CGFloat, _ b: CGFloat) -> NSPoint { NSPoint(x: x + a * scale, y: y + b * scale) }
        switch glyph {
        case .close:
            path.move(to: point(18, 6)); path.line(to: point(6, 18))
            path.move(to: point(6, 6)); path.line(to: point(18, 18))
        case .previous:
            path.move(to: point(15, 18)); path.line(to: point(9, 12)); path.line(to: point(15, 6))
        case .next:
            path.move(to: point(9, 18)); path.line(to: point(15, 12)); path.line(to: point(9, 6))
        }
        NSColor.white.withAlphaComponent(glyph == .close || active ? 1 : 0.9).setStroke()
        path.lineWidth = 2 * scale; path.lineCapStyle = .round; path.lineJoinStyle = .round; path.stroke()
        if window?.firstResponder === self {
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2; ring.stroke()
        }
    }
}
