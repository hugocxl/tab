import AppKit
import TabCore

/// The card at the bottom of the sidebar while an update is ready, waiting
/// for terminals to end, or installing: a title, what updating does to
/// running terminals, and full-width buttons for the choices that fit.
final class UpdateCardView: ThemedView {
    var onAction: ((UpdateCard.Action) -> Void)?
    var onDismiss: (() -> Void)?

    var card: UpdateCard? {
        didSet { if card != oldValue { rebuild() } }
    }

    private static let padding: CGFloat = 12
    private static let iconSide: CGFloat = 20
    private static let textInset = padding + iconSide + 8
    private static let buttonHeight: CGFloat = 28
    private static let buttonGap: CGFloat = 6

    private let icon = NSImageView()
    private let title = makeLabel("", font: AppFont.header)
    private let detail = makeLabel("", font: AppFont.footnote)
    private let close = IconButton(.close, label: "Dismiss", side: 22)
    private var buttons: [UpdateCardButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [title, detail] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
        }
        for view in [icon, title, detail, close] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        close.onPress = { [weak self] in self?.onDismiss?() }
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = theme.raised.cgColor
        layer.borderColor = theme.cardBorder.cgColor
        layer.borderWidth = Metrics.border
        layer.cornerRadius = Metrics.cardRadius
        layer.cornerCurve = .continuous
    }

    override func themeDidChange() {
        title.textColor = theme.fg
        detail.textColor = theme.fgMuted
        icon.image = Self.iconImage(theme)
        needsDisplay = true
    }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []
        guard let card else { return }
        title.stringValue = card.title
        detail.stringValue = card.detail
        close.isHidden = card.busy
        setAccessibilityLabel(card.title)
        for item in card.buttons {
            let button = UpdateCardButton(title: item.title, style: item.style)
            button.isEnabled = !card.busy
            button.onPress = { [weak self] in self?.onAction?(item.action) }
            addSubview(button)
            buttons.append(button)
        }
        needsLayout = true
    }

    // MARK: Layout

    /// The card's height at `width`: the detail wraps.
    func height(for width: CGFloat) -> CGFloat {
        guard let card else { return 0 }
        let buttonsHeight = CGFloat(card.buttons.count) * Self.buttonHeight + CGFloat(max(card.buttons.count - 1, 0)) * Self.buttonGap
        return detailTop(for: width) + textHeight(detail, width: detailWidth(width)) + Self.padding + buttonsHeight + Self.padding
    }

    /// The title sits beside the icon and stops short of the close button.
    private func titleWidth(_ width: CGFloat) -> CGFloat {
        let available = width - Self.textInset - Self.padding
        return max(card?.busy == true ? available : available - close.side, 1)
    }

    /// The detail runs the card's width below the title and icon.
    private func detailWidth(_ width: CGFloat) -> CGFloat { max(width - Self.padding * 2, 1) }

    private func detailTop(for width: CGFloat) -> CGFloat {
        Self.padding + max(textHeight(title, width: titleWidth(width)), Self.iconSide) + 6
    }

    private func textHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        (label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0).rounded(.up)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let padding = Self.padding
        let titleTop = padding
        let lineHeight = (title.font ?? AppFont.header).boundingRectForFont.height.rounded()
        icon.frame = NSRect(x: padding, y: titleTop + ((lineHeight - Self.iconSide) / 2).rounded(), width: Self.iconSide, height: Self.iconSide)
        let closeSide = close.side
        close.frame = NSRect(x: width - padding - closeSide + 4, y: titleTop + ((lineHeight - closeSide) / 2).rounded(),
                             width: closeSide, height: closeSide)
        let titleWidth = titleWidth(width)
        title.preferredMaxLayoutWidth = titleWidth
        title.frame = NSRect(x: Self.textInset, y: titleTop, width: titleWidth, height: textHeight(title, width: titleWidth))
        let detailWidth = detailWidth(width)
        let detailTop = detailTop(for: width)
        let detailHeight = textHeight(detail, width: detailWidth)
        detail.preferredMaxLayoutWidth = detailWidth
        detail.frame = NSRect(x: padding, y: detailTop, width: detailWidth, height: detailHeight)
        var y = detailTop + detailHeight + padding
        for button in buttons {
            button.frame = NSRect(x: padding, y: y, width: max(width - padding * 2, 0), height: Self.buttonHeight)
            y += Self.buttonHeight + Self.buttonGap
        }
    }

    private static func iconImage(_ theme: AppTheme) -> NSImage {
        let side = iconSide
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            theme.accent.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            if let arrow = AppIcon.arrowDown.image(size: 14, weight: .semibold)?.tinted(theme.accentForeground) {
                let target = NSRect(x: (rect.midX - arrow.size.width / 2).rounded(), y: (rect.midY - arrow.size.height / 2).rounded(),
                                    width: arrow.size.width, height: arrow.size.height)
                arrow.draw(in: target)
            }
            return true
        }
    }
}

/// A full-width button on the update card, drawn in the theme's accent:
/// filled for the main choice, soft for another, text only for cancelling.
final class UpdateCardButton: HoverView {
    var onPress: (() -> Void)?
    var isEnabled = true {
        didSet { needsDisplay = true }
    }

    private let title: String
    private let style: UpdateCard.Button.Style
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(title: String, style: UpdateCard.Button.Style) {
        self.title = title
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let active = isEnabled && (pressed || isHovered)
        let fill: NSColor?
        let text: NSColor
        switch style {
        case .primary:
            fill = theme.accent.blended(withFraction: pressed ? 0.2 : (active ? 0.1 : 0), of: theme.fg) ?? theme.accent
            text = theme.accentForeground
        case .secondary:
            fill = theme.accent.withAlphaComponent(pressed ? 0.3 : (active ? 0.22 : 0.14))
            text = theme.accent
        case .plain:
            fill = active ? theme.hover : nil
            text = theme.fgMuted
        }
        let alpha: CGFloat = isEnabled ? 1 : 0.6
        if let fill {
            fill.withAlphaComponent(fill.alphaComponent * alpha).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusLarge - 1, yRadius: Metrics.radiusLarge - 1).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AppFont.system(12, weight: .medium),
            .foregroundColor: text.withAlphaComponent(alpha),
            .paragraphStyle: paragraph,
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 8, y: ((bounds.height - height) / 2).rounded(), width: max(bounds.width - 16, 0), height: height),
                                 withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        guard wasPressed, isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onPress?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { isEnabled }
}
