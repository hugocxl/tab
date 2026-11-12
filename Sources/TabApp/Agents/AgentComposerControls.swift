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
    var planning = false { didSet { needsDisplay = true } }
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
        ((planning ? "Plan changes" : "Ask anything · @ for context, / for commands") as NSString).draw(at: textContainerOrigin, withAttributes: [
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
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
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
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.small, .foregroundColor: color, .paragraphStyle: paragraph]
        let textHeight = ceil((labelText as NSString).size(withAttributes: attributes).height)
        (labelText as NSString).draw(in: NSRect(x: 25, y: floor((bounds.height - textHeight) / 2), width: max(0, bounds.width - 44), height: textHeight),
            withAttributes: attributes)
        AppIcon.chevronDown.image(size: 8, color: color)?.draw(
            in: NSRect(x: max(0, bounds.width - 16), y: floor(bounds.midY - 4), width: 8, height: 8),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// Keeps native button keyboard activation, focus masks and mouse tracking around custom artwork.
@MainActor
class AgentComposerButton: NSButton {
    var onFocusChange: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true); needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false); needsDisplay = true }
        return accepted
    }
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

/// Native composer actions; callers control placement, visibility and enabled state.
@MainActor
final class AgentRoundButton: AgentComposerButton {
    /// Stop remains available beside Send while drafting during active work.
    enum Kind { case send, stop, dictate }
    let kind: Kind
    var onPress: (() -> Void)?
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    /// Dictation is listening: the accent fill shows that a click finishes it.
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        switch kind {
        case .send: title = "Send"; toolTip = "Send message (Return)"
        case .stop: title = "Stop"; toolTip = "Stop this turn"
        case .dictate: title = "Dictate"; toolTip = "Dictate a message on this Mac"
        }
        setAccessibilityLabel(title)
        setButtonType(.momentaryPushIn)
        isBordered = false
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds)
        let solid = chatTheme.agentComposer.withAlphaComponent(1)
        let fill = !isEnabled ? chatTheme.fg.withAlphaComponent(0.10) : active ? chatTheme.accent : chatTheme.fg
        fill.setFill()
        circle.fill()
        if isEnabled && (hovered || isHighlighted) {
            solid.withAlphaComponent(isHighlighted ? 0.24 : 0.12).setFill()
            circle.fill()
        }
        let ink = !isEnabled ? chatTheme.fgDim : active ? chatTheme.accentForeground : solid
        let icon: AppIcon
        let size: CGFloat
        switch kind {
        case .send: icon = .arrowUp; size = 16
        case .stop: icon = .stop; size = 11
        case .dictate: icon = .waveform; size = 17
        }
        icon.image(size: size, color: ink)?.draw(
            in: NSRect(x: floor(bounds.midX - size / 2), y: floor(bounds.midY - size / 2), width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    @objc private func pressed() { perform() }
    func perform() { if isEnabled { onPress?() } }
}

/// One selector for the model and its reasoning effort, such as "Opus 5.5 · Medium".
/// The model and effort pop-ups stay the source of truth; this menu lists both and
/// sends their actions, so the controller handles a choice exactly as before.
@MainActor
final class AgentModelPicker: AgentComposerButton {
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    private let model: AgentTextPopUp
    private let effort: AgentTextPopUp

    init(model: AgentTextPopUp, effort: AgentTextPopUp) {
        self.model = model
        self.effort = effort
        super.init(frame: .zero)
        title = "Model and reasoning effort"
        setAccessibilityLabel(title)
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(showMenu)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    var labelText: String {
        let effortTitle = effort.labelText
        return effort.isEnabled && effortTitle != "Off" ? "\(model.labelText) · \(effortTitle)" : model.labelText
    }

    /// Call when either pop-up's title or enabled state changes.
    func refresh() {
        isEnabled = model.isEnabled || effort.isEnabled
        setAccessibilityValue(labelText)
        toolTip = "\(labelText) · Changes apply to the next message"
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let width = (labelText as NSString).size(withAttributes: [.font: AppFont.body]).width
        return NSSize(width: ceil(width) + 34, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.10 : 0.06).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        let color = isEnabled ? chatTheme.fgMuted : chatTheme.fgDim
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.body, .foregroundColor: color, .paragraphStyle: paragraph]
        let textHeight = ceil((labelText as NSString).size(withAttributes: attributes).height)
        (labelText as NSString).draw(in: NSRect(x: 12, y: floor((bounds.height - textHeight) / 2), width: max(0, bounds.width - 34), height: textHeight),
                                     withAttributes: attributes)
        AppIcon.chevronDown.image(size: 9, color: color)?.draw(
            in: NSRect(x: bounds.width - 20, y: floor(bounds.midY - 4.5), width: 9, height: 9),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    @objc private func showMenu() {
        guard isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let models = model.menu {
            for item in models.items {
                guard let copy = item.copy() as? NSMenuItem else { continue }
                // Top-level pop-up items act through the pop-up's own action.
                if copy.action == nil, copy.submenu == nil, !copy.isSeparatorItem {
                    copy.target = model.target
                    copy.action = model.action
                }
                if !model.isEnabled { disable(copy) }
                menu.addItem(copy)
            }
        }
        let efforts = effort.itemArray.enumerated().filter { !$0.element.isSeparatorItem }
        if !efforts.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Reasoning effort"))
            for (index, item) in efforts {
                let choice = NSMenuItem(title: item.title, action: #selector(chooseEffort(_:)), keyEquivalent: "")
                choice.target = self
                choice.tag = index
                choice.state = item === effort.selectedItem ? .on : .off
                choice.isEnabled = effort.isEnabled && item.isEnabled
                choice.toolTip = item.toolTip
                menu.addItem(choice)
            }
        }
        // The controller refreshes catalogs and holds menu rebuilds while the model menu is open.
        if let models = model.menu { models.delegate?.menuWillOpen?(models) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        if let models = model.menu { models.delegate?.menuDidClose?(models) }
    }

    private func disable(_ item: NSMenuItem) {
        item.isEnabled = false
        item.submenu?.items.forEach { disable($0) }
    }

    @objc private func chooseEffort(_ sender: NSMenuItem) {
        guard effort.isEnabled, effort.itemArray.indices.contains(sender.tag) else { return }
        effort.selectItem(at: sender.tag)
        if let action = effort.action { effort.sendAction(action, to: effort.target) }
        refresh()
    }

    override func performClick(_ sender: Any?) { showMenu() }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showMenu()
        return true
    }
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

/// A round, borderless composer icon button: attach, dictate, read aloud and queue actions.
/// `contentTintColor` overrides the muted ink, such as the accent while dictating.
@MainActor
final class AgentIconButton: AgentComposerButton {
    var onPress: (() -> Void)?
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    var icon: AppIcon { didSet { needsDisplay = true } }
    /// A resting disc behind the icon, as on the composer's attach button.
    var filled = false { didSet { needsDisplay = true } }
    private let iconSize: CGFloat

    init(icon: AppIcon, label: String, iconSize: CGFloat = 16) {
        self.icon = icon
        self.iconSize = iconSize
        super.init(frame: .zero)
        title = label
        toolTip = label
        setAccessibilityLabel(label)
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var contentTintColor: NSColor? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let resting: CGFloat = filled ? 0.08 : 0
        let alpha = isEnabled && (hovered || isHighlighted) ? resting + (isHighlighted ? 0.10 : 0.05) : resting
        if alpha > 0 {
            chatTheme.fg.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let ink = isEnabled ? (contentTintColor ?? (filled ? chatTheme.fg : chatTheme.fgMuted)) : chatTheme.fgDim.withAlphaComponent(0.6)
        icon.image(size: iconSize, color: ink)?.draw(
            in: NSRect(x: floor(bounds.midX - iconSize / 2), y: floor(bounds.midY - iconSize / 2), width: iconSize, height: iconSize),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    @objc private func pressed() { perform() }
    func perform() { if isEnabled { onPress?() } }
}

/// A removable plan-mode chip, tinted with the theme's accent.
@MainActor
final class AgentPlanButton: AgentComposerButton {
    var onPress: (() -> Void)?
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = "Plan"
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(pressed)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let text = ("Plan" as NSString).size(withAttributes: [.font: AppFont.small]).width
        return NSSize(width: ceil(10 + 14 + 5 + text + 8 + 8 + 9), height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = chatTheme.accent
        color.withAlphaComponent(hovered ? 0.20 : 0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let middle = bounds.midY
        AppIcon.listTodo.image(size: 14, color: color)?.draw(in: NSRect(x: 10, y: middle - 7, width: 14, height: 14),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: AppFont.small, .foregroundColor: color]
        let textHeight = ("Plan" as NSString).size(withAttributes: attributes).height
        ("Plan" as NSString).draw(at: NSPoint(x: 29, y: floor(middle - textHeight / 2)), withAttributes: attributes)
        AppIcon.close.image(size: 8, color: color)?.draw(in: NSRect(x: bounds.width - 17, y: middle - 4, width: 8, height: 8),
            from: .zero, operation: .sourceOver, fraction: hovered ? 1 : 0.65, respectFlipped: true, hints: nil)
    }
    @objc private func pressed() { onPress?() }
}
