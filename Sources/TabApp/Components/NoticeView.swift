import AppKit
import QuartzCore
import TabCore

/// What an in-app notification says: a tone, an icon, one line, at most one
/// button, and whether it can be closed. Every notice looks the same,
/// whether it is about updating, the connection, or a copied path.
public struct Notice: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case neutral, info, success, warning, danger }

    public enum Icon: Equatable, Sendable {
        /// Work of unknown length.
        case spinner
        /// A download, from 0 to 1.
        case progress(Double)
        /// An SF Symbol, drawn in the tone's color.
        case symbol(String)
    }

    public var tone: Tone
    public var icon: Icon
    public var message: String
    public var button: String?
    public var dismissible: Bool

    public init(tone: Tone, icon: Icon, message: String, button: String? = nil, dismissible: Bool = true) {
        self.tone = tone
        self.icon = icon
        self.message = message
        self.button = button
        self.dismissible = dismissible
    }
}

/// A notice as a capsule: an icon, one line that scrolls when it doesn't
/// fit, at most one button, and a close button. Diffused glass tinted with
/// the notice's tone, as are its buttons.
final class NoticeView: ThemedView {
    var onAction: (() -> Void)?
    var onDismiss: (() -> Void)?

    var notice: Notice? {
        didSet { if notice != oldValue { apply() } }
    }

    /// Behind another notice in a collapsed stack, only the capsule shows.
    var contentHidden = false {
        didSet {
            guard contentHidden != oldValue else { return }
            for view in [icon, message, button, close] as [NSView] { view.animator().alphaValue = contentHidden ? 0 : 1 }
        }
    }

    static let height: CGFloat = 40
    /// Every notice's widest: the "available" update's, with room for a
    /// two-digit version. Longer messages scroll within it.
    static let maximumWidth = width(message: "\(Release.appName) 0.00.0 is available.", button: "Update", closes: true)
    private static let iconSide: CGFloat = 18
    private static let iconInset: CGFloat = 13
    private static let iconTextGap: CGFloat = 10
    private static let textButtonGap: CGFloat = 12
    private static let controlHeight: CGFloat = 24
    private static let controlGap: CGFloat = 6
    private static let trailingInset: CGFloat = 8
    /// Narrower than this, the message hides and stays in the tooltip.
    private static let minimumTextWidth: CGFloat = 24
    static let font = AppFont.system(13, weight: .medium)

    private let glass = GlassView(style: .chip)
    private let icon = NoticeIcon()
    private let message = MarqueeLabel()
    private let button = NoticeButton(kind: .text(""))
    private let close = NoticeButton(kind: .close)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.cornerRadius = Self.height / 2
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Metrics.border
        addSubview(glass)
        for view in [icon, message, button, close] as [NSView] { addSubview(view) }
        button.onPress = { [weak self] in self?.onAction?() }
        close.onPress = { [weak self] in self?.onDismiss?() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    private var toneColor: NSColor {
        switch notice?.tone ?? .neutral {
        case .neutral: return theme.fg
        case .info: return theme.info
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        }
    }

    private var tinted: Bool { (notice?.tone ?? .neutral) != .neutral }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = (tinted ? toneColor.withAlphaComponent(0.1) : theme.fg(alpha: 0.03)).cgColor
        layer.borderColor = theme.fg(alpha: 0.08).cgColor
    }

    override func themeDidChange() {
        glass.appearance = theme.nsAppearance
        applyColors()
    }

    private func apply() {
        guard let notice else { return }
        icon.icon = notice.icon
        message.text = notice.message
        toolTip = notice.message
        setAccessibilityLabel(notice.message)
        button.isHidden = notice.button == nil
        if let title = notice.button { button.kind = .text(title) }
        close.isHidden = !notice.dismissible
        applyColors()
        needsLayout = true
    }

    private func applyColors() {
        let tone = toneColor
        glass.tint = tinted ? tone.withAlphaComponent(0.2) : nil
        icon.color = tone
        message.color = tone
        let controls = NoticeButton.Colors(fill: tone.withAlphaComponent(tinted ? 0.18 : 0.1), glyph: tone)
        button.colors = controls
        close.colors = controls
        needsDisplay = true
    }

    /// The width that shows the whole message on one line.
    var fittingWidth: CGFloat {
        guard let notice else { return 0 }
        return Self.width(message: notice.message, button: notice.button, closes: notice.dismissible)
    }

    /// The width of a notice showing all of `message`, laid out as `layout()` does.
    static func width(message: String, button: String?, closes: Bool) -> CGFloat {
        let text = ceil((message as NSString).size(withAttributes: [.font: font]).width)
        var width = iconInset + iconSide + iconTextGap + text
        if let button { width += textButtonGap + NoticeButton.width(title: button) }
        switch (button != nil, closes) {
        case (true, true): width += controlGap + controlHeight + trailingInset
        case (false, true): width += textButtonGap + controlHeight + trailingInset
        case (true, false): width += trailingInset
        case (false, false): width += iconInset
        }
        return ceil(width)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        let midY = bounds.height / 2
        icon.frame = NSRect(x: Self.iconInset, y: midY - Self.iconSide / 2, width: Self.iconSide, height: Self.iconSide)
        var trailing = bounds.width - Self.trailingInset
        if !close.isHidden {
            close.frame = NSRect(x: trailing - Self.controlHeight, y: midY - Self.controlHeight / 2,
                                 width: Self.controlHeight, height: Self.controlHeight)
            trailing = close.frame.minX - Self.controlGap
        }
        if !button.isHidden {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(x: trailing - width, y: midY - Self.controlHeight / 2, width: width, height: Self.controlHeight)
            trailing = button.frame.minX - Self.textButtonGap
        } else if !close.isHidden {
            trailing += Self.controlGap - Self.textButtonGap
        } else {
            trailing = bounds.width - Self.iconInset
        }
        let start = icon.frame.maxX + Self.iconTextGap
        let width = trailing - start
        message.isHidden = width < Self.minimumTextWidth
        message.frame = NSRect(x: start - MarqueeLabel.fade, y: 0, width: max(width, 0) + MarqueeLabel.fade + MarqueeLabel.overhang,
                               height: bounds.height)
    }
}

/// A notice's icon: a symbol, a download's progress ring, or a spinning ring.
final class NoticeIcon: NSView {
    var icon: Notice.Icon = .spinner {
        didSet { if icon != oldValue { update() } }
    }

    var color: NSColor = .labelColor {
        didSet { if color != oldValue { update() } }
    }

    private let symbol = NSImageView()
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private static let lineWidth: CGFloat = 2
    private static let spinKey = "spin"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        symbol.imageScaling = .scaleNone
        addSubview(symbol)
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = Self.lineWidth
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        symbol.frame = bounds
        let inset = Self.lineWidth / 2 + 1
        let circle = bounds.insetBy(dx: inset, dy: inset)
        // The ring starts at the top and runs clockwise on screen.
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                    startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: false)
        for shape in [track, ring] {
            shape.frame = bounds
            shape.path = path
        }
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }

    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch icon {
        case .symbol(let name):
            symbol.isHidden = false
            track.isHidden = true
            ring.isHidden = true
            ring.removeAnimation(forKey: Self.spinKey)
            symbol.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
            symbol.contentTintColor = color
        case .progress(let fraction):
            symbol.isHidden = true
            track.isHidden = false
            ring.isHidden = false
            ring.removeAnimation(forKey: Self.spinKey)
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            ring.strokeColor = color.cgColor
            CATransaction.setDisableActions(false)
            ring.strokeEnd = max(min(fraction, 1), 0.02)
        case .spinner:
            symbol.isHidden = true
            track.isHidden = false
            ring.isHidden = false
            track.strokeColor = color.withAlphaComponent(0.25).cgColor
            ring.strokeColor = color.cgColor
            ring.strokeEnd = 0.3
            guard ring.animation(forKey: Self.spinKey) == nil else { return }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = CGFloat.pi * 2
            spin.duration = 0.9
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            ring.add(spin, forKey: Self.spinKey)
        }
    }
}

/// One line of text that scrolls in a loop when it doesn't fit, fading at
/// both edges, and pauses at its start each time round. The text is drawn
/// once into layers and Core Animation runs the loop, so it costs nothing per
/// frame here. Reduce Motion truncates instead.
final class MarqueeLabel: NSView {
    var text = "" {
        didSet { if text != oldValue { render() } }
    }

    var color: NSColor = .labelColor {
        didSet { if color != oldValue { render() } }
    }

    /// How far the edges fade, and how far in the text rests: the label
    /// reaches this far before where its text starts.
    static let fade: CGFloat = 8
    /// How far the label reaches past where its text may end.
    static let overhang: CGFloat = 6
    /// Space between the end of the text and its next copy.
    private static let gap: CGFloat = 36
    /// Points per second.
    private static let speed: CGFloat = 30
    /// Seconds the text rests at its start each time round.
    private static let pause: CFTimeInterval = 1.6
    private static let scrollKey = "marquee"

    private let content = CALayer()
    private let first = CALayer()
    private let second = CALayer()
    private let truncated = makeLabel("", font: NoticeView.font)
    private let mask = CAGradientLayer()
    private var textSize = NSSize.zero
    private var distance: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(content)
        content.addSublayer(first)
        content.addSublayer(second)
        truncated.lineBreakMode = .byTruncatingTail
        truncated.translatesAutoresizingMaskIntoConstraints = true
        addSubview(truncated)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        render()
    }

    /// Draws the text once at the screen's scale for both scrolling copies.
    private func render() {
        truncated.stringValue = text
        truncated.textColor = color
        let attributed = NSAttributedString(string: text, attributes: [.font: NoticeView.font, .foregroundColor: color])
        let size = attributed.size()
        textSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        let scale = window?.backingScaleFactor ?? 2
        let image = NSImage(size: textSize, flipped: false) { _ in
            attributed.draw(at: .zero)
            return true
        }
        let contents = image.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        for copy in [first, second] {
            copy.contents = contents
            copy.contentsScale = scale
            copy.contentsGravity = .resize
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let room = bounds.width - Self.fade - Self.overhang
        let y = ((bounds.height - textSize.height) / 2).rounded()
        let overflows = textSize.width > room
        let truncates = overflows && AppTheme.shared.accessibility.reduceMotion
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        content.isHidden = truncates
        truncated.isHidden = !truncates
        if truncates {
            stopScrolling()
            layer?.mask = nil
            let height = truncated.intrinsicContentSize.height
            truncated.frame = NSRect(x: Self.fade, y: ((bounds.height - height) / 2).rounded(), width: max(room, 0), height: height)
            return
        }
        first.frame = CGRect(x: Self.fade, y: y, width: textSize.width, height: textSize.height)
        second.isHidden = !overflows
        guard overflows else {
            stopScrolling()
            layer?.mask = nil
            content.frame = bounds
            return
        }
        let step = textSize.width + Self.gap
        content.frame = CGRect(x: 0, y: 0, width: Self.fade + step * 2, height: bounds.height)
        second.frame = CGRect(x: Self.fade + step, y: y, width: textSize.width, height: textSize.height)
        mask.frame = bounds
        let edge = Double(Self.fade / bounds.width)
        mask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        layer?.mask = mask
        startScrolling(distance: step)
    }

    private func startScrolling(distance: CGFloat) {
        guard distance != self.distance || content.animation(forKey: Self.scrollKey) == nil else { return }
        self.distance = distance
        let total = Self.pause + CFTimeInterval(distance / Self.speed)
        let scroll = CAKeyframeAnimation(keyPath: "transform.translation.x")
        scroll.values = [0, 0, -distance]
        scroll.keyTimes = [0, NSNumber(value: Self.pause / total), 1]
        scroll.duration = total
        scroll.repeatCount = .infinity
        scroll.isRemovedOnCompletion = false
        content.removeAnimation(forKey: Self.scrollKey)
        content.add(scroll, forKey: Self.scrollKey)
    }

    private func stopScrolling() {
        distance = 0
        content.removeAnimation(forKey: Self.scrollKey)
    }
}

/// A notice's pill button or round close button.
final class NoticeButton: HoverView {
    enum Kind: Equatable {
        case text(String)
        case close
    }

    struct Colors: Equatable {
        var fill: NSColor
        var glyph: NSColor
    }

    var onPress: (() -> Void)?
    var kind: Kind {
        didSet {
            guard kind != oldValue else { return }
            if case .text(let title) = kind { setAccessibilityLabel(title) }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    var colors = Colors(fill: .clear, glyph: .labelColor) {
        didSet { if colors != oldValue { needsDisplay = true } }
    }

    private static let padding: CGFloat = 10
    private var pressed = false {
        didSet { needsDisplay = true }
    }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        if case .close = kind { setAccessibilityLabel("Dismiss") }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        guard case .text(let title) = kind else { return NSSize(width: 24, height: 24) }
        return NSSize(width: Self.width(title: title), height: 24)
    }

    static func width(title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: NoticeView.font]).width) + padding * 2
    }

    override func hoverDidChange() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let alpha = colors.fill.alphaComponent
        let fill = colors.fill.withAlphaComponent(alpha + (pressed ? 0.14 : isHovered ? 0.07 : 0))
        fill.setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        switch kind {
        case .text(let title):
            let attributes: [NSAttributedString.Key: Any] = [.font: NoticeView.font, .foregroundColor: colors.glyph]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: NSPoint(x: ((bounds.width - size.width) / 2).rounded(),
                                                 y: ((bounds.height - size.height) / 2).rounded()),
                                     withAttributes: attributes)
        case .close:
            guard let glyph = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
                .tinted(colors.glyph) else { return }
            let size = glyph.size
            glyph.draw(in: NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                                  width: size.width, height: size.height))
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = pressed
        pressed = false
        guard wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
