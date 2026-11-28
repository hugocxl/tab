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
    /// Takes a long pasted text as an attachment; false pastes it inline.
    var onPasteLongText: ((String) -> Bool)?
    /// Items added to the message box's context menu, such as stashing the draft.
    var extraMenuItems: (() -> [NSMenuItem])?
    /// Reports whether an attachment drag is currently active over the text view.
    var onAttachmentDropHighlightChange: ((Bool) -> Void)?
    var planning = false { didSet { needsDisplay = true } }
    var placeholderColor = NSColor.secondaryLabelColor
    private var acceptingAttachmentDrop = false {
        didSet {
            guard acceptingAttachmentDrop != oldValue else { return }
            onAttachmentDropHighlightChange?(acceptingAttachmentDrop)
        }
    }
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
        if let text = NSPasteboard.general.string(forType: .string), onPasteLongText?(text) == true { return }
        pasteAsPlainText(sender)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let items = extraMenuItems?(), !items.isEmpty else { return menu }
        let result = menu ?? NSMenu()
        result.addItem(.separator())
        items.forEach(result.addItem)
        return result
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateAttachmentDrop(sender, entered: true) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateAttachmentDrop(sender, entered: false) }
    override func draggingExited(_ sender: NSDraggingInfo?) { acceptingAttachmentDrop = false; super.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { acceptingAttachmentDrop = false; super.draggingEnded(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if AgentAttachmentPasteboard.canRead(sender.draggingPasteboard) { return updateAttachmentDrop(sender, entered: false) == .copy }
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

    private func updateAttachmentDrop(_ sender: NSDraggingInfo, entered: Bool) -> NSDragOperation {
        guard AgentAttachmentPasteboard.canRead(sender.draggingPasteboard) else {
            acceptingAttachmentDrop = false
            return entered ? super.draggingEntered(sender) : super.draggingUpdated(sender)
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
    var menuLogos: [Int: AgentProviderConfig] = [:] { didSet { refreshLogos() } }
    /// The selected account, whose accent color marks its logo in the model picker.
    var providerConfig: AgentProviderConfig?
    private var brandImage: NSImage?

    private func refreshLogos() {
        brandImage = providerLogo.flatMap { AgentLogo.image(for: $0, lightBackground: chatTheme.palette.isLight) }
        for (index, provider) in menuLogos {
            item(at: index)?.image = AgentLogo.menuImage(for: provider, lightBackground: chatTheme.palette.isLight)
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

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: min(8, bounds.height / 2), yRadius: min(8, bounds.height / 2)).fill()
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

/// The composer's bottom row: every control has one height, one font and a full-rounded
/// pill or circle fill that always shows.
enum AgentComposerMetrics {
    static let controlHeight: CGFloat = 32
    /// Between the composer card's edge and its controls.
    static let padding: CGFloat = 10
    static var font: NSFont { AppFont.body }
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
        // Keyboard focus shows the system ring around the drawn capsule or circle.
        focusRingType = .exterior
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Which part of a capsule the control draws: the whole of it, or one side of a
    /// capsule split between two adjacent controls that read as one.
    enum Segment { case whole, leading, trailing }
    var segment: Segment = .whole { didSet { if segment != oldValue { needsDisplay = true } } }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { controlShape().fill() }

    /// The control's capsule, or its side of a split capsule.
    func controlShape() -> NSBezierPath {
        let radius = bounds.height / 2
        guard segment != .whole else { return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius) }
        let path = NSBezierPath()
        let (minX, maxX, minY, maxY) = (bounds.minX, bounds.maxX, bounds.minY, bounds.maxY)
        if segment == .leading {
            path.move(to: NSPoint(x: maxX, y: minY))
            path.line(to: NSPoint(x: maxX, y: maxY))
            path.line(to: NSPoint(x: minX + radius, y: maxY))
            path.appendArc(withCenter: NSPoint(x: minX + radius, y: bounds.midY), radius: radius, startAngle: 90, endAngle: 270)
        } else {
            path.move(to: NSPoint(x: minX, y: minY))
            path.line(to: NSPoint(x: maxX - radius, y: minY))
            path.appendArc(withCenter: NSPoint(x: maxX - radius, y: bounds.midY), radius: radius, startAngle: 270, endAngle: 90)
            path.line(to: NSPoint(x: minX, y: maxY))
        }
        path.close()
        return path
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    /// The composer row's fill: always shown, stronger on hover and press. `tint` colors
    /// it, such as the accent while plan mode or dictation is on.
    func drawControlFill(_ theme: AppTheme, tint: NSColor? = nil) {
        let interactive = isEnabled && (hovered || isHighlighted)
        let rest: CGFloat = tint == nil ? 0.06 : 0.14
        let alpha = rest + (interactive ? (isHighlighted ? 0.08 : 0.04) : 0)
        (tint ?? theme.fg).withAlphaComponent(alpha).setFill()
        controlShape().fill()
        // A hairline divides a split capsule's leading side from its trailing one.
        guard segment == .leading else { return }
        theme.fg.withAlphaComponent(0.14).setFill()
        let scale = window?.backingScaleFactor ?? 2
        NSRect(x: bounds.maxX - 1 / scale, y: bounds.midY - 8, width: 1 / scale, height: 16).fill()
    }
}

/// The composer's one primary action: send, stop or dictate share a slot, and the pane
/// shows one at a time. Callers control placement, visibility and enabled state.
@MainActor
final class AgentRoundButton: AgentComposerButton {
    enum Kind { case send, stop, dictate }
    let kind: Kind
    var onPress: (() -> Void)?
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    /// Dictation is listening: the accent ink shows that a click finishes it.
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

    /// An idle Dictate is quieter than Stop and active controls.
    private var quiet: Bool { kind == .dictate && !active }

    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor
        if kind == .send && isEnabled {
            let alpha: CGFloat = isHighlighted ? 0.80 : (hovered ? 0.90 : 1)
            chatTheme.accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
            ink = chatTheme.accentForeground
        } else {
            drawControlFill(chatTheme, tint: active ? chatTheme.accent : nil)
            ink = !isEnabled ? chatTheme.fgDim : active ? chatTheme.accent : quiet ? chatTheme.fgMuted : chatTheme.fg
        }
        let icon: AppIcon
        let size: CGFloat
        switch kind {
        case .send: icon = .arrowUp; size = 16
        case .stop: icon = .square; size = 14
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
/// The model and effort pop-ups stay the source of truth; this menu lists both, with
/// each provider's logo and the efforts in an Effort submenu, and sends their actions,
/// so the controller handles a choice exactly as before.
@MainActor
final class AgentModelPicker: AgentComposerButton {
    var chatTheme: AppTheme = .shared { didSet { needsDisplay = true } }
    private let model: AgentTextPopUp
    private let effort: AgentReasoningPopUp

    init(model: AgentTextPopUp, effort: AgentReasoningPopUp) {
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
        guard let effortTitle = effortText else { return model.labelText }
        return "\(model.labelText) · \(effortTitle)"
    }

    /// The effort shown after the model, lowercased and quieter, such as "Opus 5.5 medium".
    private var effortText: String? {
        let title = effort.labelText
        return effort.isEnabled && title != "Off" ? title : nil
    }

    private static let logoSide: CGFloat = 16
    private static var modelFont: NSFont { AppFont.system(AgentComposerMetrics.font.pointSize, weight: .medium) }

    /// The selected provider's mark before the model name, with its account's accent
    /// dot when it has one, as in the menu, so the account in use is clear.
    private var logo: NSImage? {
        guard let provider = model.providerLogo else { return nil }
        if let config = model.providerConfig, config.kind.activityProvider == provider, config.accentColor != nil {
            return AgentLogo.image(for: config, lightBackground: chatTheme.palette.isLight)
        }
        return AgentLogo.image(for: provider, size: Self.logoSide, theme: chatTheme)
    }

    private var textStart: CGFloat { model.providerLogo == nil ? 12 : 10 + Self.logoSide + 6 }

    private func label(color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSMutableAttributedString(string: model.labelText, attributes: [
            .font: Self.modelFont, .foregroundColor: color, .paragraphStyle: paragraph])
        if let effortText {
            text.append(NSAttributedString(string: "  " + effortText.lowercased(), attributes: [
                .font: AgentComposerMetrics.font, .foregroundColor: chatTheme.fgDim, .paragraphStyle: paragraph]))
        }
        return text
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
        let width = label(color: chatTheme.fgMuted).size().width
        return NSSize(width: textStart + ceil(width) + 26, height: AgentComposerMetrics.controlHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawControlFill(chatTheme)
        let color = isEnabled ? chatTheme.fgMuted : chatTheme.fgDim
        if let logo {
            logo.draw(in: NSRect(x: 10, y: floor((bounds.height - Self.logoSide) / 2), width: Self.logoSide, height: Self.logoSide),
                      from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.5,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        let text = label(color: color)
        let textHeight = ceil(text.size().height)
        text.draw(in: NSRect(x: textStart, y: floor((bounds.height - textHeight) / 2),
                             width: max(0, bounds.width - textStart - 26), height: textHeight))
        AppIcon.chevronDown.image(size: 9, color: chatTheme.fgDim)?.draw(
            in: NSRect(x: bounds.width - 21, y: floor(bounds.midY - 4.5), width: 9, height: 9),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    @objc private func showMenu() { showSelectionMenu(effortOnly: false) }

    func showSelectionMenu(effortOnly: Bool) {
        guard isEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !effortOnly, let models = model.menu {
            for (index, item) in models.items.enumerated() {
                guard let copy = item.copy() as? NSMenuItem else { continue }
                if let provider = model.menuLogos[index] {
                    copy.image = AgentLogo.menuImage(for: provider, lightBackground: chatTheme.palette.isLight)
                    showImage(copy)
                }
                // Top-level pop-up items act through the pop-up's own action.
                if copy.action == nil, copy.submenu == nil, !copy.isSeparatorItem {
                    copy.target = model.target
                    copy.action = model.action
                }
                if !model.isEnabled { disable(copy) }
                menu.addItem(copy)
            }
        }
        let efforts = effortChoices()
        if effortOnly {
            menu.addItem(.sectionHeader(title: "Reasoning effort"))
            efforts.forEach { menu.addItem($0) }
        } else if !efforts.isEmpty {
            menu.addItem(.separator())
            let heading = NSMenuItem(title: "Effort", action: nil, keyEquivalent: "")
            heading.image = AppIcon.brain.image(size: 16, color: chatTheme.fgMuted)
            showImage(heading)
            heading.badge = effort.selectedItem.map { NSMenuItemBadge(string: $0.title) }
            heading.isEnabled = effort.isEnabled
            let submenu = NSMenu(title: "Effort")
            submenu.autoenablesItems = false
            let note = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            note.attributedTitle = NSAttributedString(
                string: "Higher effort is more thorough,\nbut slower and uses your limits faster.",
                attributes: [.font: AppFont.small, .foregroundColor: NSColor.secondaryLabelColor])
            note.isEnabled = false
            submenu.addItem(note)
            efforts.forEach { submenu.addItem($0) }
            heading.submenu = submenu
            menu.addItem(heading)
        }
        // The controller refreshes catalogs and holds menu rebuilds while the model menu is open.
        if let models = model.menu { models.delegate?.menuWillOpen?(models) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
        if let models = model.menu { models.delegate?.menuDidClose?(models) }
    }

    /// One item per effort, checked on the current one and badged on the model's default.
    private func effortChoices() -> [NSMenuItem] {
        effort.itemArray.enumerated().filter { !$0.element.isSeparatorItem }.map { index, item in
            let choice = NSMenuItem(title: item.title, action: #selector(chooseEffort(_:)), keyEquivalent: "")
            choice.target = self
            choice.tag = index
            choice.state = item === effort.selectedItem ? .on : .off
            choice.isEnabled = effort.isEnabled && item.isEnabled
            choice.toolTip = item.toolTip
            if item.title == effort.defaultValueTitle { choice.badge = NSMenuItemBadge(string: "Default") }
            return choice
        }
    }

    /// macOS 27 hides menu item images unless asked; the provider logo and its accent dot
    /// tell accounts apart, so they always show.
    private func showImage(_ item: NSMenuItem) {
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
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
    /// A composer-row control: a circle whose fill always shows.
    var filled = false {
        didSet {
            needsDisplay = true
        }
    }
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
        if filled {
            drawControlFill(chatTheme)
        } else if isEnabled && (hovered || isHighlighted) {
            chatTheme.fg.withAlphaComponent(isHighlighted ? 0.10 : 0.05).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let ink = isEnabled ? (contentTintColor ?? chatTheme.fgMuted) : chatTheme.fgDim.withAlphaComponent(0.6)
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
    /// Plan mode is on: the accent chip with a close mark. Off, a quiet chip turns it on.
    var active = true {
        didSet {
            guard oldValue != active else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
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
        let text = ("Plan" as NSString).size(withAttributes: [.font: AgentComposerMetrics.font]).width
        return NSSize(width: ceil(10 + 14 + 6 + text + (active ? 8 + 8 + 9 : 12)), height: AgentComposerMetrics.controlHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawControlFill(chatTheme, tint: active ? chatTheme.accent : nil)
        let color = active ? chatTheme.accent : chatTheme.fgMuted
        let middle = bounds.midY
        AppIcon.listTodo.image(size: 14, color: color)?.draw(in: NSRect(x: 10, y: middle - 7, width: 14, height: 14),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let attributes: [NSAttributedString.Key: Any] = [.font: AgentComposerMetrics.font, .foregroundColor: color]
        let textHeight = ("Plan" as NSString).size(withAttributes: attributes).height
        ("Plan" as NSString).draw(at: NSPoint(x: 30, y: floor(middle - textHeight / 2)), withAttributes: attributes)
        guard active else { return }
        AppIcon.close.image(size: 8, color: color)?.draw(in: NSRect(x: bounds.width - 17, y: middle - 4, width: 8, height: 8),
            from: .zero, operation: .sourceOver, fraction: hovered ? 1 : 0.65, respectFlipped: true, hints: nil)
    }
    @objc private func pressed() { onPress?() }
}
