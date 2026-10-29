import AppKit
import QuartzCore

/// A small status glyph: a dot, a spinning arc while work runs, or a ring
/// filled to a percentage. The spinner turns with a Core Animation rotation,
/// so it costs no redraws.
final class ActivityGlyph: NSView {
    enum Style: Equatable {
        case none
        case dot(NSColor, diameter: CGFloat)
        case spinner(NSColor)
        case ring(fraction: CGFloat, NSColor)
    }

    var style: Style = .none {
        didSet { if style != oldValue { apply() } }
    }

    private let shape = CAShapeLayer()
    private let track = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(shape)
        track.fillColor = nil
        shape.fillColor = nil
        shape.lineCap = .round
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let side = min(bounds.width, bounds.height)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.frame = bounds
        track.frame = bounds
        shape.removeAnimation(forKey: "spin")
        track.path = nil
        switch style {
        case .none:
            shape.path = nil
        case let .dot(color, diameter):
            let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            shape.path = CGPath(ellipseIn: rect, transform: nil)
            shape.fillColor = color.cgColor
            shape.strokeColor = nil
        case .spinner(let color):
            let radius = side / 2 - 1.5
            shape.path = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 1.5
            shape.strokeStart = 0
            shape.strokeEnd = 0.7
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            shape.add(spin, forKey: "spin")
        case let .ring(fraction, color):
            let radius = side / 2 - 1.5
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            track.path = CGPath(ellipseIn: rect, transform: nil)
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            track.lineWidth = 1.5
            shape.path = CGPath(ellipseIn: rect, transform: nil)
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 1.5
            shape.strokeStart = 0
            shape.strokeEnd = min(max(fraction, 0), 1)
        }
    }
}
