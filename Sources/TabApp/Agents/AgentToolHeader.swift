import AppKit

/// source WorkLogLine geometry, drawn directly to avoid native bezel padding and inactive tinting.
@MainActor
final class AgentToolHeader: NSButton {
    var onPress: (() -> Void)?
    var labelColor = NSColor.labelColor
    var iconColor = NSColor.secondaryLabelColor
    var focusColor = NSColor.controlAccentColor
    var activityIcon: AgentConversationIcon = .wrench
    /// A muted note after the title, such as why a tool did not run.
    var suffix: String? { didSet { if oldValue != suffix { needsDisplay = true } } }
    var expanded = false
    var hovered = false { didSet { needsDisplay = true } }
    var timestampColor = NSColor.secondaryLabelColor
    var timestamp: Date? { didSet { if oldValue != timestamp { updateTimestamp() } } }
    private(set) var timestampText = ""
    private(set) var timestampTooltip: String?
    private func updateTimestamp() {
        guard let timestamp else { timestampText = ""; timestampTooltip = nil; toolTip = nil; needsDisplay = true; return }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let time = formatter.string(from: timestamp)
        if Calendar.current.isDateInToday(timestamp) || timestamp > Date() { timestampText = time }
        else if Calendar.current.isDateInYesterday(timestamp) { timestampText = "yesterday at " + time }
        else {
            let sameYear = Calendar.current.component(.year, from: timestamp) == Calendar.current.component(.year, from: Date())
            formatter.timeStyle = .none
            formatter.setLocalizedDateFormatFromTemplate(sameYear ? "Md" : "yMd")
            timestampText = formatter.string(from: timestamp) + " " + time
        }
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        timestampTooltip = formatter.string(from: timestamp)
        toolTip = timestampTooltip
        needsDisplay = true
    }
    var showsTimestamp: Bool { !timestampText.isEmpty && (hovered || window?.firstResponder === self) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        font = AppFont.system(14)
        target = self
        action = #selector(pressed)
        setButtonType(.momentaryPushIn)
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        activityIcon.image(size: 16, color: iconColor)?.draw(
            in: NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? AppFont.system(14), .foregroundColor: labelColor, .paragraphStyle: paragraph,
        ]
        let lineHeight = ("Ag" as NSString).size(withAttributes: attributes).height
        let timestampAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor: timestampColor,
        ]
        let timestampSize = (timestampText as NSString).size(withAttributes: timestampAttributes)
        let trailingWidth: CGFloat = showsTimestamp ? ceil(timestampSize.width) + 10 : 0
        let line = NSMutableAttributedString(string: title, attributes: attributes)
        if let suffix, !suffix.isEmpty {
            var muted = attributes
            muted[.foregroundColor] = timestampColor
            line.append(NSAttributedString(string: " · " + suffix, attributes: muted))
        }
        line.draw(with: NSRect(x: 32, y: (bounds.height - lineHeight) / 2,
            width: max(0, bounds.width - 58 - trailingWidth), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if showsTimestamp {
            (timestampText as NSString).draw(at: NSPoint(x: max(32, bounds.width - 26 - timestampSize.width),
                y: (bounds.height - timestampSize.height) / 2), withAttributes: timestampAttributes)
        }
        if isEnabled {
            (expanded ? AgentConversationIcon.chevronDown : .chevronRight).image(size: 12, color: iconColor)?.draw(
                in: NSRect(x: bounds.width - 16, y: (bounds.height - 12) / 2, width: 12, height: 12), from: .zero,
                operation: .sourceOver, fraction: 0.7, respectFlipped: true, hints: nil)
        }
        if window?.firstResponder === self {
            focusColor.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { pressed() }
        else { super.keyDown(with: event) }
    }

    @objc private func pressed() { if isEnabled { onPress?() } }
}
