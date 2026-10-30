import AppKit

/// Keeps NSPopUpButton's menu/selection API while presenting a richer reasoning picker.
/// The menu remains the source of truth; this control never invents supported levels.
@MainActor
final class AgentReasoningPopUp: AgentTextPopUp {
    /// Set only when the provider has advertised an actual default (the menu item's title).
    var defaultValueTitle: String?
    private var reasoningPopover: NSPopover?

    override init(label: String) {
        super.init(label: label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { showReasoningPicker() }
    override func performClick(_ sender: Any?) { showReasoningPicker() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 125, 126: showReasoningPicker()
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showReasoningPicker()
        return true
    }

    private func showReasoningPicker() {
        guard isEnabled, window != nil else { return }
        if let reasoningPopover, reasoningPopover.isShown {
            reasoningPopover.performClose(nil)
            return
        }
        let choices = itemArray.filter { !$0.isSeparatorItem && $0.isEnabled }
        guard !choices.isEmpty else { return }

        let content = AgentReasoningPickerView(
            items: choices,
            selectedItem: selectedItem,
            defaultValueTitle: defaultValueTitle,
            theme: chatTheme
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.frame.size
        content.onChoose = { [weak self, weak popover] item in
            guard let self, self.isEnabled,
                  self.itemArray.contains(where: { $0 === item }), item.isEnabled else {
                popover?.performClose(nil)
                return
            }
            self.select(item)
            self.invalidateIntrinsicContentSize()
            self.needsDisplay = true
            popover?.performClose(nil)
            self.window?.makeFirstResponder(self)
            // Match NSPopUpButton: update selection before sending the control's action.
            if let action = self.action { self.sendAction(action, to: self.target) }
        }
        content.onCancel = { [weak self, weak popover] in
            popover?.performClose(nil)
            if let self { self.window?.makeFirstResponder(self) }
        }
        reasoningPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
        content.window?.makeFirstResponder(content)
    }
}

@MainActor
private final class AgentReasoningPickerView: NSView {
    var onChoose: ((NSMenuItem) -> Void)?
    var onCancel: (() -> Void)?
    private let theme: AppTheme
    private var rows: [AgentReasoningRow] = []
    private var focusedIndex: Int

    init(items: [NSMenuItem], selectedItem: NSMenuItem?, defaultValueTitle: String?, theme: AppTheme) {
        self.theme = theme
        focusedIndex = items.firstIndex(where: { $0 === selectedItem }) ?? 0
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 42 + CGFloat(items.count) * 34 + 8))
        let heading = NSTextField(labelWithString: "Reasoning")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = theme.fgMuted
        heading.frame = NSRect(x: 16, y: 13, width: 208, height: 18)
        addSubview(heading)
        for (index, item) in items.enumerated() {
            let row = AgentReasoningRow(
                item: item, selected: item === selectedItem,
                isDefault: defaultValueTitle != nil && item.title == defaultValueTitle,
                theme: theme
            )
            row.frame = NSRect(x: 8, y: 42 + CGFloat(index) * 34, width: 224, height: 34)
            row.target = self
            row.action = #selector(chooseRow(_:))
            row.onNavigate = { [weak self] event in self?.keyDown(with: event) }
            rows.append(row)
            addSubview(row)
        }
        updateFocus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        theme.card.setFill()
        bounds.fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: focusedIndex = (focusedIndex + 1) % rows.count; updateFocus()
        case 126: focusedIndex = (focusedIndex + rows.count - 1) % rows.count; updateFocus()
        case 36, 76, 49: onChoose?(rows[focusedIndex].item)
        case 53: onCancel?()
        default: super.keyDown(with: event)
        }
    }

    private func updateFocus() {
        for (index, row) in rows.enumerated() { row.keyboardFocused = index == focusedIndex }
    }

    @objc private func chooseRow(_ sender: AgentReasoningRow) { onChoose?(sender.item) }
}

@MainActor
private final class AgentReasoningRow: NSButton {
    let item: NSMenuItem
    var onNavigate: ((NSEvent) -> Void)?
    var keyboardFocused = false { didSet { needsDisplay = true } }
    private let selected: Bool
    private let isDefault: Bool
    private let theme: AppTheme
    private var hovered = false
    private var hoverTracking: NSTrackingArea?

    init(item: NSMenuItem, selected: Bool, isDefault: Bool, theme: AppTheme) {
        self.item = item
        self.selected = selected
        self.isDefault = isDefault
        self.theme = theme
        super.init(frame: .zero)
        title = item.title
        toolTip = item.toolTip
        isBordered = false
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        setAccessibilityLabel(item.title + (isDefault ? ", default" : ""))
        setAccessibilityValue(selected ? "Selected" : "Not selected")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        if [125, 126, 53].contains(event.keyCode) {
            onNavigate?(event)
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0, dy: 1)
        if selected || hovered || keyboardFocused || isHighlighted {
            let color = selected ? theme.accent : theme.fg
            color.withAlphaComponent(selected ? 0.13 : (isHighlighted ? 0.10 : 0.055)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        }
        let ink = selected ? theme.fg : theme.fgMuted
        drawSymbol(symbolName, in: NSRect(x: 10, y: 9, width: 16, height: 16), color: ink)
        let font = NSFont.systemFont(ofSize: 13, weight: selected ? .medium : .regular)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in: NSRect(x: 36, y: 9, width: isDefault ? 104 : 155, height: 18),
                                withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
        if isDefault {
            let badge = NSRect(x: min(36 + titleWidth + 8, 143), y: 9, width: 48, height: 17)
            theme.fg.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            ("Default" as NSString).draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2),
                                       withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: theme.fgMuted])
        }
        if selected {
            drawSymbol("checkmark", in: NSRect(x: bounds.width - 25, y: 10, width: 14, height: 14), color: theme.accent)
        }
    }

    private var symbolName: String {
        switch item.title.lowercased().replacingOccurrences(of: " ", with: "") {
        case "auto", "automatic": return "sparkles"
        case "low", "minimal", "none": return "gauge.with.dots.needle.0percent"
        case "medium": return "gauge.with.dots.needle.33percent"
        case "high": return "gauge.with.dots.needle.67percent"
        case "extrahigh", "xhigh", "max", "ultra": return "gauge.with.dots.needle.100percent"
        default: return "brain"
        }
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "brain", accessibilityDescription: nil)
        image?.withSymbolConfiguration(configuration)?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
