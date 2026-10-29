import AppKit

/// A borderless glyph button that shows a pill under the pointer, as in pane
/// headers and the sidebar: a 16pt glyph in a 24pt square by default.
public final class IconButton: HoverView {
    public var icon: AppIcon { didSet { updateImage() } }
    public var action: (() -> Void)?
    /// Tints the glyph with the accent, for toggles that are on.
    public var isActive = false { didSet { needsDisplay = true } }
    public var isEnabled = true { didSet { needsDisplay = true } }
    public let side: CGFloat
    private var image: NSImage?
    private var pressed = false

    public init(_ icon: AppIcon, label: String, side: CGFloat = 24, action: (() -> Void)? = nil) {
        self.icon = icon
        self.side = side
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        updateImage()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private func updateImage() {
        image = icon.image(size: Metrics.glyph)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHovered || pressed) {
            (pressed ? theme.selection : theme.hover).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
        }
        guard let image else { return }
        let color = !isEnabled ? theme.fgDim : (isActive ? theme.accent : (isHovered ? theme.fg : theme.fgMuted))
        let size = image.size
        let rect = NSRect(
            x: ((bounds.width - size.width) / 2).rounded(),
            y: ((bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        image.tinted(color).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        action?()
        return true
    }
}

/// A text button: a soft pill with a hairline border, 24pt tall.
public final class PillButton: HoverView {
    public enum Style: Sendable {
        /// The neutral fill most settings buttons use.
        case normal
        /// Accent fill, for the window's one main action.
        case primary
        /// Danger text, for actions that remove something.
        case destructive
        /// No fill until hovered, such as Reset beside a shortcut.
        case plain
    }

    public var title: String {
        didSet {
            label.stringValue = title
            setAccessibilityLabel(title)
            invalidateIntrinsicContentSize()
        }
    }
    public var style: Style { didSet { themeDidChange() } }
    public var isEnabled = true { didSet { themeDidChange() } }
    public var action: (() -> Void)?
    private let label: NSTextField
    private var pressed = false

    public init(_ title: String, style: Style = .normal, action: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.action = action
        label = makeLabel(title, font: AppFont.body)
        label.alignment = .center
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        themeDidChange()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Like `NSButton`, it takes the keyboard only with Full Keyboard Access,
    /// so the window never gives a button the focus a pane should have.
    public override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder }

    public override func themeDidChange() {
        switch style {
        case .primary: label.textColor = isEnabled ? theme.accentForeground : theme.fgDim
        case .destructive: label.textColor = isEnabled ? theme.danger : theme.fgDim
        case .normal, .plain: label.textColor = isEnabled ? theme.fg : theme.fgDim
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        let active = isEnabled && (isHovered || pressed)
        switch style {
        case .primary:
            (isEnabled ? theme.accent : theme.button).withAlphaComponent(pressed ? 0.8 : 1).setFill()
            path.fill()
        case .plain:
            guard active else { break }
            theme.hover.setFill()
            path.fill()
        case .normal, .destructive:
            theme.button.setFill()
            path.fill()
            if active {
                theme.hover.setFill()
                path.fill()
            }
            theme.border.setStroke()
            path.lineWidth = Metrics.border
            path.stroke()
        }
        if window?.firstResponder === self {
            theme.accent.setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            perform()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { perform() }
    }

    /// Runs the action as a click would.
    public func perform() {
        guard isEnabled else { return }
        action?()
    }

    public override func accessibilityPerformPress() -> Bool {
        perform()
        return isEnabled
    }
}

/// A text link such as "Edit in settings.json": muted 11pt text that gets a
/// hover pill.
public final class LinkButton: HoverView {
    private let label: NSTextField
    public var action: (() -> Void)?

    public init(_ title: String, action: (() -> Void)? = nil) {
        label = makeLabel(title, font: AppFont.footnote)
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.gutter),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(title)
        themeDidChange()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var title: String { label.stringValue }

    public override func themeDidChange() {
        label.textColor = isHovered ? theme.fg : theme.fgMuted
        needsDisplay = true
    }

    public override func hoverDidChange() { themeDidChange() }

    public override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    public override func accessibilityPerformPress() -> Bool {
        action?()
        return true
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
