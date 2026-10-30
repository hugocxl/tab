import AppKit
import TabCore

/// Native text input with a drawn placeholder: no overlay intercepts selection or clicks.
@MainActor
final class AgentComposerTextView: NSTextView {
    var onEdit: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    /// The second argument is the image MIME type, not a filename.
    var onAttachImage: ((Data, String) -> Void)?
    var placeholderColor = NSColor.secondaryLabelColor
    private var acceptingAttachmentDrop = false { didSet { needsDisplay = true } }
    private let ownedStorage: NSTextStorage?

    override init(frame frameRect: NSRect = .zero, textContainer container: NSTextContainer? = nil) {
        let resolved: NSTextContainer
        if let container {
            ownedStorage = nil
            resolved = container
        } else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            resolved = NSTextContainer(containerSize: NSSize(width: max(1, frameRect.width), height: .greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(resolved)
            ownedStorage = storage
        }
        super.init(frame: frameRect, textContainer: resolved)
        registerForDraggedTypes(AgentAttachmentPasteboard.types)
    }

    required init?(coder: NSCoder) {
        ownedStorage = nil
        super.init(coder: coder)
        registerForDraggedTypes(AgentAttachmentPasteboard.types)
    }

    override func paste(_ sender: Any?) {
        if !receiveAttachment(from: .general) { pasteAsPlainText(sender) }
    }

    @discardableResult
    func receiveAttachment(from pasteboard: NSPasteboard) -> Bool {
        AgentAttachmentPasteboard.receive(pasteboard, onFiles: onAttachFiles, onImage: onAttachImage)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateAttachmentDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateAttachmentDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { acceptingAttachmentDrop = false; super.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if AgentAttachmentPasteboard.canRead(sender.draggingPasteboard) { return updateAttachmentDrop(sender) == .copy }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptingAttachmentDrop = false
        if receiveAttachment(from: sender.draggingPasteboard) { return true }
        return super.performDragOperation(sender)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        acceptingAttachmentDrop = false
        super.concludeDragOperation(sender)
    }

    private func updateAttachmentDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard AgentAttachmentPasteboard.canRead(sender.draggingPasteboard) else {
            acceptingAttachmentDrop = false
            return super.draggingUpdated(sender)
        }
        acceptingAttachmentDrop = sender.draggingSourceOperationMask.contains(.copy)
        return acceptingAttachmentDrop ? .copy : []
    }

    override func didChangeText() {
        super.didChangeText()
        onEdit?()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if acceptingAttachmentDrop {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            let outline = NSBezierPath(roundedRect: visibleRect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            outline.fill()
            NSColor.controlAccentColor.setStroke()
            outline.lineWidth = 2
            outline.stroke()
        }
        guard string.isEmpty, !hasMarkedText() else { return }
        ("Message the agent…" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? AppFont.system(14), .foregroundColor: placeholderColor,
        ])
    }
}

/// Content-sized native picker with a quiet icon, label and disclosure chevron.
@MainActor
class AgentTextPopUp: NSPopUpButton {
    var chatTheme: AppTheme = .shared { didSet { refreshLogos(); needsDisplay = true } }
    var symbol = "cpu" { didSet { needsDisplay = true } }
    var providerLogo: AgentProvider? { didSet { refreshLogos(); needsDisplay = true } }
    var menuLogos: [Int: AgentProvider] = [:] { didSet { refreshLogos() } }
    private var brandImage: NSImage?

    private func refreshLogos() {
        brandImage = providerLogo.flatMap { AgentLogo.image(for: $0, lightBackground: chatTheme.palette.isLight) }
        for (index, provider) in menuLogos {
            let image = AgentLogo.image(for: provider, lightBackground: chatTheme.palette.isLight)
            image?.size = NSSize(width: 16, height: 16)
            image?.isTemplate = false
            item(at: index)?.image = image
        }
    }
    var displayedTitle: String? {
        didSet {
            invalidateIntrinsicContentSize()
            setAccessibilityValue(labelText)
            superview?.needsLayout = true
            needsDisplay = true
        }
    }
    var labelText: String { displayedTitle ?? titleOfSelectedItem ?? controlLabel }
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
        let width = (labelText as NSString).size(withAttributes: [.font: AppFont.small]).width
        return NSSize(width: ceil(width) + 46, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.10 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let color = isEnabled ? chatTheme.fgMuted : chatTheme.fgDim
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let brandImage {
            brandImage.draw(in: NSRect(x: 4, y: floor((bounds.height - 16) / 2), width: 16, height: 16),
                            from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5,
                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)?
            .draw(in: NSRect(x: 5, y: floor((bounds.height - 14) / 2), width: 14, height: 14),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (labelText as NSString).draw(in: NSRect(x: 25, y: floor((bounds.height - 16) / 2), width: max(0, bounds.width - 44), height: 18),
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
