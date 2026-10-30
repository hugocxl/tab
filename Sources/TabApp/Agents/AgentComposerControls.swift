import AppKit

/// Native text input with a drawn placeholder: no overlay intercepts selection or clicks.
@MainActor
final class AgentComposerTextView: NSTextView {
    var onEdit: (() -> Void)?
    var placeholderColor = NSColor.secondaryLabelColor

    /// The composer sends text only; do not import styled runs or file attachments.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    override func didChangeText() {
        super.didChangeText()
        onEdit?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        ("Message the agent…" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? AppFont.system(14), .foregroundColor: placeholderColor,
        ])
    }
}

/// An actual NSPopUpButton and native menu, with the quiet text-only trigger used by the composer.
@MainActor
final class AgentTextPopUp: NSPopUpButton {
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    private let controlLabel: String
    private var hoverTracking: NSTrackingArea?
    private var hovered = false

    init(label: String) {
        controlLabel = label
        super.init(frame: .zero, pullsDown: false)
        isBordered = false
        font = AppFont.small
        setAccessibilityLabel(label)
        setAccessibilityHelp("Choose \(label.lowercased())")
        toolTip = label
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override var intrinsicContentSize: NSSize {
        let width = ((titleOfSelectedItem ?? controlLabel) as NSString).size(withAttributes: [.font: AppFont.small]).width
        return NSSize(width: ceil(width) + 22, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.10 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = isEnabled ? chatTheme.fgMuted : chatTheme.fgDim
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        ((titleOfSelectedItem ?? controlLabel) as NSString).draw(in: NSRect(x: 4, y: 6, width: max(0, bounds.width - 22), height: 18),
            withAttributes: [.font: AppFont.small, .foregroundColor: color, .paragraphStyle: paragraph])
        color.setStroke()
        let path = NSBezierPath()
        let x = max(0, bounds.width - 11)
        let y = bounds.midY
        path.move(to: NSPoint(x: x - 3, y: y - 1.5))
        path.line(to: NSPoint(x: x, y: y + 1.5))
        path.line(to: NSPoint(x: x + 3, y: y - 1.5))
        path.lineWidth = 1.2
        path.stroke()
    }
}

/// Keeps native button keyboard activation, focus masks and mouse tracking around custom artwork.
@MainActor
class AgentComposerButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private(set) var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 1, dy: 1) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// Shares one trailing position for send and interrupt; callers control visibility and enabled state.
@MainActor
final class AgentRoundButton: AgentComposerButton {
    enum Kind { case send, stop }
    let kind: Kind
    var onPress: (() -> Void)?
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        title = kind == .send ? "Send" : "Stop"
        setAccessibilityLabel(title)
        toolTip = kind == .send ? "Send message (Return)" : "Stop this turn"
        setButtonType(.momentaryPushIn)
        isBordered = false
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let fill = isEnabled ? (kind == .stop ? chatTheme.danger : chatTheme.accent) : chatTheme.fg.withAlphaComponent(0.10)
        fill.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.16 : 0.08).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        }
        let ink = isEnabled ? chatTheme.accentForeground : chatTheme.fgDim
        ink.setStroke()
        ink.setFill()
        if kind == .stop {
            NSBezierPath(roundedRect: NSRect(x: bounds.midX - 4, y: bounds.midY - 4, width: 8, height: 8), xRadius: 1.5, yRadius: 1.5).fill()
        } else {
            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: NSPoint(x: bounds.midX, y: bounds.midY + 6))
            path.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 5))
            path.move(to: NSPoint(x: bounds.midX - 4, y: bounds.midY + 1))
            path.line(to: NSPoint(x: bounds.midX, y: bounds.midY - 4))
            path.line(to: NSPoint(x: bounds.midX + 4, y: bounds.midY + 1))
            path.stroke()
        }
    }

    @objc private func pressed() { perform() }
    func perform() { if isEnabled { onPress?() } }
}

@MainActor
final class AgentEndButton: AgentComposerButton {
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Scroll to end"
        setAccessibilityLabel(title)
        setButtonType(.momentaryPushIn)
        isBordered = false
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        chatTheme.card.setFill()
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        capsule.fill()
        if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.10 : 0.055).setFill()
            capsule.fill()
        }
        chatTheme.border.setStroke()
        capsule.lineWidth = 1
        capsule.stroke()
        ("↓  Scroll to end" as NSString).draw(at: NSPoint(x: 14, y: 6),
            withAttributes: [.font: AppFont.small, .foregroundColor: chatTheme.fgMuted])
    }

    @objc private func pressed() { if isEnabled { onPress?() } }
}
