import AppKit
import TabCore
import TabProtocol

/// Native text input with a drawn placeholder: no overlay intercepts selection or clicks.
@MainActor
final class AgentComposerTextView: NSTextView {
    var onEdit: (() -> Void)?
    var onAttachFiles: (([URL]) -> Void)?
    /// The second argument is the image MIME type, not a filename.
    var onAttachImage: ((Data, String) -> Void)?
    /// A click on a quotation chip asks to show the quoted message.
    var onOpenCitation: ((AgentAssistantCitation) -> Void)?
    /// Copied assistant text of this conversation pastes as a quotation when this returns true.
    var onPasteContext: ((NSPasteboard) -> Bool)?
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

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        AgentComposerCitation.prepareEdit(in: textStorage, range: affectedCharRange)
        return true
    }

    override func paste(_ sender: Any?) {
        if receiveAttachment(from: .general) { return }
        if onPasteContext?(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
              let citation = citation(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onOpenCitation?(citation)
    }

    /// The quotation chip drawn at `point`, in view coordinates.
    func citation(at point: NSPoint) -> AgentAssistantCitation? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length, let href = storage.attribute(.agentAssistantCitation, at: index, effectiveRange: nil) as? String else { return nil }
        return AgentAssistantCitation.parse(href)
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
        ("Ask to make changes, @mention files, run /commands" as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? AppFont.system(14, weight: .light), .foregroundColor: placeholderColor,
        ])
    }
}

/// Content-sized native picker with a quiet icon, label and disclosure chevron.
@MainActor
class AgentTextPopUp: NSPopUpButton {
    var chatTheme: AppTheme = .shared { didSet { refreshLogos(); needsDisplay = true } }
    var icon: AppIcon = .cpu { didSet { needsDisplay = true } }
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
        focusRingType = .none
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
        if let brandImage {
            brandImage.draw(in: NSRect(x: 4, y: floor((bounds.height - 16) / 2), width: 16, height: 16),
                            from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5,
                            respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            // The former 12pt symbol was drawn directly into this 14pt box.
            // Keep that fitted size instead of applying the conversation inset twice.
            icon.image(size: 14, scale: 1, theme: chatTheme, tint: color)?
            .draw(in: NSRect(x: 5, y: floor((bounds.height - 14) / 2), width: 14, height: 14),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        (labelText as NSString).draw(in: NSRect(x: 25, y: floor((bounds.height - 16) / 2), width: max(0, bounds.width - 44), height: 18),
            withAttributes: [.font: AppFont.small, .foregroundColor: color, .paragraphStyle: paragraph])
        AppIcon.chevronDown.image(size: 8, color: color)?.draw(
            in: NSRect(x: max(0, bounds.width - 15), y: bounds.midY - 4, width: 8, height: 8),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Keeps native button keyboard activation, focus masks and mouse tracking around custom artwork.
@MainActor
class AgentComposerButton: NSButton {
    private var hoverTracking: NSTrackingArea?
    private(set) var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
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
        let icon: AppIcon = kind == .stop ? .stop : .arrowUp
        let size: CGFloat = kind == .stop ? 10 : 14
        icon.image(size: size, color: ink)?.draw(
            in: NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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
        AppIcon.arrowDown.image(size: 12, color: chatTheme.fgMuted)?.draw(
            in: NSRect(x: 14, y: 7, width: 12, height: 12), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        ("Scroll to end" as NSString).draw(at: NSPoint(x: 30, y: 6),
            withAttributes: [.font: AppFont.small, .foregroundColor: chatTheme.fgMuted])
    }

    @objc private func pressed() { if isEnabled { onPress?() } }
}
