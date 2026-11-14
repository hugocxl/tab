import AppKit

/// One tool call: its kind, the tool's name, then the operation in a code chip.
/// Hovering shows a plate and a `+`; an open call shows `−`. Drawn directly to avoid
/// native bezel padding and inactive tinting.
@MainActor
final class AgentToolHeader: NSButton {
    var onPress: (() -> Void)?
    var labelColor = NSColor.labelColor
    var iconColor = NSColor.secondaryLabelColor { didSet { updateGlyph() } }
    var focusColor = NSColor.controlAccentColor
    var chipColor = NSColor.secondaryLabelColor
    var plateColor = NSColor.quaternaryLabelColor
    var activityIcon: AppIcon = .wrench
    /// The operation, such as a command or a path; drawn in a code chip while closed.
    var operation: String? { didSet { if oldValue != operation { needsDisplay = true } } }
    /// A muted note after the operation, such as why a tool did not run.
    var suffix: String? { didSet { if oldValue != suffix { needsDisplay = true } } }
    var expanded = false { didSet { if oldValue != expanded { needsDisplay = true; updateGlyph() } } }
    var hovered = false { didSet { if oldValue != hovered { needsDisplay = true; updateGlyph() } } }
    /// The tool is still working: the icon slot shows the activity glyph, which
    /// animates in Core Animation without redrawing the header.
    var running = false { didSet { if oldValue != running { needsDisplay = true; updateGlyph() } } }
    private let glyph = ActivityGlyph()
    var timestamp: Date? { didSet { if oldValue != timestamp { updateTimestamp() } } }
    private(set) var timestampTooltip: String?

    static let chipFont = AppFont.mono(12)
    static let maximumChipWidth: CGFloat = 560
    private static let iconWidth: CGFloat = 30

    private func updateTimestamp() {
        guard let timestamp else { timestampTooltip = nil; return }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        timestampTooltip = formatter.string(from: timestamp)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        font = AppFont.system(14)
        target = self
        action = #selector(pressed)
        setButtonType(.momentaryPushIn)
        focusRingType = .none
        glyph.isHidden = true
        glyph.frame = NSRect(x: 10, y: 9, width: 12, height: 12)
        addSubview(glyph)
    }

    /// Hovering, focus or an open row show the disclosure sign in place of the glyph.
    private var showsGlyph: Bool {
        running && !(isEnabled && (expanded || hovered || window?.firstResponder === self))
    }

    private func updateGlyph() {
        glyph.isHidden = !showsGlyph
        if !glyph.isHidden { glyph.style = .spinner(iconColor) }
    }

    override func layout() {
        super.layout()
        glyph.frame = NSRect(x: 10, y: floor((bounds.height - 12) / 2), width: 12, height: 12)
        updateGlyph()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var isFlipped: Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? AppFont.system(14), .foregroundColor: labelColor]
    }

    private var chipText: String? { expanded ? nil : operation.flatMap { $0.isEmpty ? nil : $0 } }

    /// The width the header needs, so its plate and click target hug the content.
    func naturalWidth(maximum: CGFloat) -> CGFloat {
        var width = Self.iconWidth + ceil((title as NSString).size(withAttributes: titleAttributes).width) + 10
        if let chipText {
            width += 8 + min(Self.maximumChipWidth, ceil((chipText as NSString).size(withAttributes: [.font: Self.chipFont]).width) + 14)
        }
        if let suffix, !suffix.isEmpty {
            width += 8 + ceil(((" · " + suffix) as NSString).size(withAttributes: titleAttributes).width)
        }
        return min(maximum, width)
    }

    override func draw(_ dirtyRect: NSRect) {
        let focused = window?.firstResponder === self
        if isEnabled && (hovered || expanded || focused) {
            plateColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let icon: AppIcon = !isEnabled ? activityIcon : expanded ? .minus : hovered || focused ? .plus : activityIcon
        if !showsGlyph { icon.image(size: 15, scale: AppIcon.inlineScale, theme: .shared, tint: iconColor)?.draw(
            in: NSRect(x: 9, y: (bounds.height - 15) / 2, width: 15, height: 15), from: .zero,
            operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
        let attributes = titleAttributes
        let titleSize = (title as NSString).size(withAttributes: attributes)
        var x = Self.iconWidth
        let maxX = bounds.width - 8
        (title as NSString).draw(with: NSRect(x: x, y: (bounds.height - titleSize.height) / 2,
            width: max(0, min(ceil(titleSize.width), maxX - x)), height: titleSize.height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        x += ceil(titleSize.width) + 8
        if let chipText, x < maxX - 24 {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let chipAttributes: [NSAttributedString.Key: Any] = [.font: Self.chipFont, .foregroundColor: chipColor, .paragraphStyle: paragraph]
            let textSize = (chipText as NSString).size(withAttributes: chipAttributes)
            let chipWidth = min(Self.maximumChipWidth, ceil(textSize.width) + 14, maxX - x)
            let chip = NSRect(x: x, y: (bounds.height - 22) / 2, width: chipWidth, height: 22)
            plateColor.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            (chipText as NSString).draw(with: NSRect(x: chip.minX + 7, y: (bounds.height - textSize.height) / 2,
                width: max(0, chip.width - 14), height: textSize.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: chipAttributes)
            x = chip.maxX + 8
        }
        if let suffix, !suffix.isEmpty, x < maxX {
            let muted: [NSAttributedString.Key: Any] = [.font: font ?? AppFont.system(14), .foregroundColor: chipColor]
            let size = (("· " + suffix) as NSString).size(withAttributes: muted)
            (("· " + suffix) as NSString).draw(with: NSRect(x: x, y: (bounds.height - size.height) / 2, width: maxX - x, height: size.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: muted)
        }
        if focused {
            focusColor.withAlphaComponent(0.7).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        updateGlyph()
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        updateGlyph()
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { pressed() }
        else { super.keyDown(with: event) }
    }

    @objc private func pressed() { if isEnabled { onPress?() } }

    /// The row's actions, built when the menu opens.
    var menuProvider: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? super.menu(for: event) }
}
