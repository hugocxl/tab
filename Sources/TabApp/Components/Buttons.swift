import AppKit
import TabCore
import Combine

/// A native borderless glyph button, as in pane headers and panels: a 16pt
/// glyph in a 24pt square by default that shows the system hover bezel.
/// `onPress` runs on click.
public final class IconButton: NSButton {
    public var icon: AppIcon { didSet { updateImage() } }
    public var onPress: (() -> Void)?
    /// Tints the glyph with the accent, for toggles that are on.
    public var isActive = false { didSet { updateTint() } }
    public let side: CGFloat
    private let palette = PaletteObserver()

    public init(_ icon: AppIcon, label: String, side: CGFloat = 24, action: (() -> Void)? = nil) {
        self.icon = icon
        self.side = side
        onPress = action
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        target = self
        self.action = #selector(pressed)
        updateImage()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private func updateImage() {
        updateTint()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        palette.observe(self) { [weak self] in self?.updateTint() }
    }

    /// Draws the glyph pre-tinted in the theme's colors: AppKit would wash
    /// out a template image in an inactive window, unlike the theme's chrome.
    private func updateTint() {
        let theme = AppTheme.shared
        image = icon.image(size: Metrics.glyph)?.tinted(isActive ? theme.accent : theme.fgMuted)
    }

    @objc private func pressed() {
        onPress?()
    }
}

/// A glyph in a circle that fills while hovered or pressed, the chrome's
/// button in the sidebars and pane headers, with a glass tooltip showing its
/// label and `shortcut`. Subclasses handle `pressed()`.
class CircleButton: NSButton {
    var icon: AppIcon { didSet { updateAppearance() } }
    /// The action's shortcut, shown in the tooltip from the current keymap.
    var shortcut: ShortcutId?
    private var tooltipText: String?
    /// Tints the glyph with the accent, for toggles that are on.
    var isActive = false { didSet { if isActive != oldValue { updateAppearance() } } }
    let side: CGFloat
    let glyphSize: CGFloat
    private var isHovered = false { didSet { if isHovered != oldValue { updateAppearance() } } }
    private var hoverArea: NSTrackingArea?
    private let palette = PaletteObserver()

    init(icon: AppIcon, label: String, side: CGFloat, glyph: CGFloat) {
        self.icon = icon
        self.side = side
        glyphSize = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        title = ""
        tooltipText = label
        setAccessibilityLabel(label)
        wantsLayer = true
        layer?.cornerCurve = .circular
        target = self
        action = #selector(pressed)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Keeps the circle filled and the glyph bright, as for an open panel.
    var isFilled: Bool { false }
    /// Whether hovering and pressing fill the circle; a glyph that is a
    /// circle itself only brightens.
    var showsFill = true { didSet { updateAppearance() } }
    /// Fills the circle at rest too, deepening it while hovered.
    var restsFilled = false { didSet { updateAppearance() } }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    /// How far the drawn glyph reaches left and right of the button's center.
    var glyphExtent: (left: CGFloat, right: CGFloat) {
        guard let image = icon.image(size: glyphSize) else { return (0, 0) }
        let ink = image.inkBounds
        let origin = -(image.size.width / 2)
        return (-(origin + ink.minX), origin + ink.maxX)
    }

    /// The space between the glyphs of buttons side by side, measured
    /// between what is drawn: glyphs of one size differ in width and margins,
    /// so equal steps between buttons would leave uneven gaps.
    static let glyphSpacing: CGFloat = 20

    /// Places `buttons` left to right with `glyphSpacing` between glyphs,
    /// the first starting at `minX`.
    static func layOut(_ buttons: [CircleButton], leadingAt minX: CGFloat, y: CGFloat) {
        guard let first = buttons.first else { return }
        var center = minX + first.side / 2
        for (index, button) in buttons.enumerated() {
            if index > 0 {
                center += buttons[index - 1].glyphExtent.right + glyphSpacing + button.glyphExtent.left
            }
            button.frame = CGRect(x: (center - button.side / 2).rounded(), y: y, width: button.side, height: button.side)
        }
    }

    /// Places `buttons` left to right with `glyphSpacing` between glyphs,
    /// the last ending at `maxX`.
    static func layOut(_ buttons: [CircleButton], trailingAt maxX: CGFloat, y: CGFloat) {
        guard let last = buttons.last else { return }
        var center = maxX - last.side / 2
        for (index, button) in buttons.enumerated().reversed() {
            if index < buttons.count - 1 {
                center -= buttons[index + 1].glyphExtent.left + glyphSpacing + button.glyphExtent.right
            }
            button.frame = CGRect(x: (center - button.side / 2).rounded(), y: y, width: button.side, height: button.side)
        }
    }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { updateAppearance() } }
    }

    /// The tooltip's text: kept here so AppKit shows only the glass tooltip.
    override var toolTip: String? {
        get { tooltipText }
        set { tooltipText = newValue }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        if let tooltipText { GlassTooltip.schedule(tooltipText, shortcut: shortcut, for: self) }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        GlassTooltip.hide(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        GlassTooltip.hide(for: self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            isHovered = false
            GlassTooltip.hide(for: self)
        }
        palette.observe(self) { [weak self] in self?.updateAppearance() }
    }

    /// The glyph is pre-tinted in the theme's colors: AppKit would wash out
    /// a template image in an inactive window, unlike the theme's chrome.
    func updateAppearance() {
        let theme = AppTheme.shared
        let fill: NSColor?
        if isHighlighted || isFilled || (restsFilled && isHovered) {
            fill = theme.selection
        } else {
            fill = isHovered || restsFilled ? theme.hover : nil
        }
        layer?.backgroundColor = showsFill ? fill?.cgColor : nil
        let tint = isActive ? theme.accent : isFilled || isHovered ? theme.fg : theme.fgMuted
        image = icon.image(size: glyphSize)?.tinted(tint)
    }

    @objc func pressed() {}
}

/// A pane header's glyph button: a 22pt circle, smaller than the sidebars'.
/// `onPress` runs on click.
final class HeaderButton: CircleButton {
    var onPress: (() -> Void)?

    /// The header button's circle.
    static let side: CGFloat = 22

    init(_ icon: AppIcon, label: String, action: (() -> Void)? = nil) {
        onPress = action
        super.init(icon: icon, label: label, side: Self.side, glyph: Metrics.glyph)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func pressed() {
        onPress?()
    }
}

/// A native push button with a closure: `normal`, `primary` (accent bezel)
/// for the window's main action, `destructive` for removals, or `plain`
/// (borderless until hovered).
public final class PillButton: NSButton {
    public enum Style: Sendable {
        /// The standard push button.
        case normal
        /// Accent bezel, for the window's one main action.
        case primary
        /// Marked destructive, for actions that remove something.
        case destructive
        /// No bezel until hovered, such as Reset beside a shortcut.
        case plain
    }

    public var style: Style { didSet { applyStyle() } }
    public var onPress: (() -> Void)?
    public var onFocusChange: ((Bool) -> Void)?

    public init(_ title: String, style: Style = .normal, action: (() -> Void)? = nil) {
        self.style = style
        onPress = action
        super.init(frame: .zero)
        self.title = title
        setButtonType(.momentaryPushIn)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        self.action = #selector(pressed)
        applyStyle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    private func applyStyle() {
        bezelStyle = style == .plain ? .accessoryBarAction : .push
        showsBorderOnlyWhileMouseInside = style == .plain
        bezelColor = style == .primary ? .controlAccentColor : nil
        hasDestructiveAction = style == .destructive
        contentTintColor = style == .destructive ? .systemRed : nil
    }

    @objc private func pressed() {
        perform()
    }

    /// Runs the action as a click would.
    public func perform() {
        guard isEnabled else { return }
        onPress?()
    }
}

extension NSButton {
    /// Shows the title in `color`, which AppKit keeps in inactive windows,
    /// unlike its own label colors.
    func setTitleColor(_ color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = lineBreakMode
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font: font ?? AppFont.body,
            .paragraphStyle: paragraph,
        ])
    }
}

extension NSImage {
    /// The template image filled with `color`.
    func tinted(_ color: NSColor) -> NSImage {
        guard isTemplate else { return self }
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
