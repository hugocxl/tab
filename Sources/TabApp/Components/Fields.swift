import AppKit

/// A borderless text field that reports Return, Escape and leaving it.
final class ChromeTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}

/// The dark inset text field of settings rows: surface fill, hairline border
/// and an accent ring while editing. Text is saved on Return or when the
/// field loses focus; Escape restores the last saved value.
public final class InsetTextField: ThemedView, NSTextFieldDelegate {
    public let field: NSTextField
    /// Called with the trimmed text when it is committed and differs from the
    /// saved value.
    public var onCommit: ((String) -> Void)?
    /// Called on every edit.
    public var onChange: ((String) -> Void)?
    /// Whether the field wraps lines (a prompt area) instead of one line.
    public let multiline: Bool
    private var savedValue: String
    private var editing = false

    public init(
        value: String,
        placeholder: String = "",
        label: String,
        width: CGFloat? = Metrics.controlWidth,
        height: CGFloat? = nil,
        multiline: Bool = false,
        monospaced: Bool = false
    ) {
        let textField = ChromeTextField(string: value)
        field = textField
        savedValue = value
        self.multiline = multiline
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = monospaced ? AppFont.mono(12) : AppFont.body
        textField.placeholderString = placeholder
        textField.usesSingleLineMode = !multiline
        textField.cell?.wraps = multiline
        textField.cell?.isScrollable = !multiline
        textField.lineBreakMode = multiline ? .byWordWrapping : .byClipping
        textField.maximumNumberOfLines = multiline ? 0 : 1
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setAccessibilityLabel(label)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        let fieldHeight = height ?? Metrics.controlHeight
        var constraints = [
            heightAnchor.constraint(equalToConstant: fieldHeight),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ]
        if multiline {
            constraints += [
                textField.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                textField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            ]
        } else {
            constraints.append(textField.centerYAnchor.constraint(equalTo: centerYAnchor))
        }
        if let width {
            constraints.append(widthAnchor.constraint(equalToConstant: width))
        }
        NSLayoutConstraint.activate(constraints)
        textField.delegate = self
        textField.onFocus = { [weak self] in
            self?.editing = true
            self?.needsDisplay = true
        }
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Replaces the shown and saved value unless the user is editing.
    public func setSavedValue(_ value: String) {
        savedValue = value
        if !editing { field.stringValue = value }
    }

    public var isEditing: Bool { editing }

    public override func themeDidChange() {
        field.textColor = theme.fg
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: theme.fgDim, .font: field.font ?? AppFont.body]
            )
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        theme.surface.setFill()
        path.fill()
        (editing ? theme.accent : theme.border).setStroke()
        path.lineWidth = editing ? 1.5 : Metrics.border
        path.stroke()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        needsDisplay = true
        commit()
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if multiline && !NSEvent.modifierFlags.contains(.command) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            field.stringValue = savedValue
            onChange?(savedValue)
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Saves the current text as Return would.
    public func commit() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != savedValue else { return }
        savedValue = value
        onCommit?(value)
    }
}

/// The rounded search field at the top of the Settings sidebar and lists:
/// a magnifying glass, placeholder and live filtering.
public final class SearchField: ThemedView, NSTextFieldDelegate {
    public let field: NSTextField
    private let glyph = NSImageView()
    public var onChange: ((String) -> Void)?
    /// Called on Return, such as to open the first result.
    public var onSubmit: (() -> Void)?

    public init(placeholder: String) {
        field = ChromeTextField(string: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.setAccessibilityLabel(placeholder)
        glyph.image = AppIcon.search.image(size: 14)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    public override func themeDidChange() {
        field.textColor = theme.fg
        glyph.contentTintColor = theme.fgMuted
        field.placeholderAttributedString = NSAttributedString(
            string: field.placeholderString ?? "",
            attributes: [.foregroundColor: theme.fgDim, .font: AppFont.body]
        )
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge).fill()
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    public func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            guard !field.stringValue.isEmpty else { return false }
            field.stringValue = ""
            onChange?("")
            return true
        default:
            return false
        }
    }
}

/// A horizontal slider that previews while dragging and commits on release,
/// with its value shown beside it.
public final class Slider: ThemedView {
    public var value: Double { didSet { updateText() } }
    public let minimum: Double
    public let maximum: Double
    public let step: Double
    /// Appended to the shown value, such as `%`.
    public let suffix: String
    /// Called while dragging, once per distinct value.
    public var onPreview: ((Double) -> Void)?
    /// Called once when the drag or key press ends.
    public var onCommit: ((Double) -> Void)?
    private let valueLabel: NSTextField
    private let track = SliderTrack()
    private var dragStart: Double?

    public init(value: Double, range: ClosedRange<Double>, step: Double, suffix: String = "", label: String) {
        self.value = value
        minimum = min(range.lowerBound, value)
        maximum = max(range.upperBound, value)
        self.step = step
        self.suffix = suffix
        valueLabel = makeLabel("", font: AppFont.body)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        track.slider = self
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: 20),
            track.widthAnchor.constraint(equalToConstant: Metrics.sliderWidth - 52),
            valueLabel.leadingAnchor.constraint(equalTo: track.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.widthAnchor.constraint(equalToConstant: 44),
        ])
        track.setAccessibilityElement(true)
        track.setAccessibilityRole(.slider)
        track.setAccessibilityLabel(label)
        updateText()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func themeDidChange() {
        valueLabel.textColor = theme.fg
        track.needsDisplay = true
    }

    /// The value as shown, such as `13`, `0.5` or `40%`.
    public var displayText: String { Self.format(value, step: step) + suffix }

    static func format(_ value: Double, step: Double) -> String {
        if step >= 1 { return String(Int(value.rounded())) }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private func updateText() {
        valueLabel.stringValue = displayText
        track.setAccessibilityValue(displayText)
        track.needsDisplay = true
    }

    var fraction: Double {
        guard maximum > minimum else { return 0 }
        return (value - minimum) / (maximum - minimum)
    }

    func snapped(_ raw: Double) -> Double {
        let stepped = (raw / step).rounded() * step
        return min(max(stepped, minimum), maximum)
    }

    func beginDrag() { dragStart = value }

    /// Moves the value to `fraction` of the range, previewing it.
    func drag(to fraction: Double) {
        let next = snapped(minimum + min(max(fraction, 0), 1) * (maximum - minimum))
        guard next != value else { return }
        value = next
        onPreview?(next)
    }

    func endDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        if value != start { onCommit?(value) }
    }

    /// Steps the value as an arrow key does, committing at once.
    func increment(by steps: Double) {
        let next = snapped(value + steps * step)
        guard next != value else { return }
        value = next
        onPreview?(next)
        onCommit?(next)
    }
}

final class SliderTrack: NSView {
    weak var slider: Slider?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let slider else { return }
        let theme = slider.theme
        let knob: CGFloat = 16
        let lineRect = NSRect(x: knob / 2, y: bounds.midY - 2, width: bounds.width - knob, height: 4)
        theme.control.setFill()
        NSBezierPath(roundedRect: lineRect, xRadius: 2, yRadius: 2).fill()
        let x = lineRect.minX + lineRect.width * slider.fraction
        theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: lineRect.minX, y: lineRect.minY, width: x - lineRect.minX, height: 4), xRadius: 2, yRadius: 2).fill()
        let knobRect = NSRect(x: x - knob / 2, y: bounds.midY - knob / 2, width: knob, height: knob)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 2
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
        NSGraphicsContext.restoreGraphicsState()
        if window?.firstResponder === self {
            theme.accent.setStroke()
            let ring = NSBezierPath(ovalIn: knobRect.insetBy(dx: -1, dy: -1))
            ring.lineWidth = 2
            ring.stroke()
        }
    }

    private func fraction(_ event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        return Double((point.x - 8) / max(bounds.width - 16, 1))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        slider?.beginDrag()
        slider?.drag(to: fraction(event))
    }

    override func mouseDragged(with event: NSEvent) {
        slider?.drag(to: fraction(event))
    }

    override func mouseUp(with event: NSEvent) {
        slider?.endDrag()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: slider?.increment(by: -1)
        case 124, 126: slider?.increment(by: 1)
        default: super.keyDown(with: event)
        }
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        slider?.increment(by: 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        slider?.increment(by: -1)
        return true
    }
}
