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

/// A native bezeled text field that saves on Return or when it loses focus;
/// Escape restores the last saved value. Multiline fields wrap and take
/// Return as a newline (Command-Return saves).
public final class InsetTextField: NSView, NSTextFieldDelegate {
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
        textField.isBezeled = true
        textField.bezelStyle = multiline ? .squareBezel : .roundedBezel
        textField.font = monospaced ? AppFont.mono(12) : AppFont.body
        textField.placeholderString = placeholder
        textField.usesSingleLineMode = !multiline
        textField.cell?.wraps = multiline
        textField.cell?.isScrollable = !multiline
        textField.lineBreakMode = multiline ? .byWordWrapping : .byClipping
        textField.maximumNumberOfLines = multiline ? 0 : 1
        textField.setAccessibilityLabel(label)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        textField.pinEdges(to: self)
        if let height { heightAnchor.constraint(equalToConstant: height).isActive = true }
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
        textField.delegate = self
        textField.onFocus = { [weak self] in self?.editing = true }
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

    public func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
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

/// A native search field with live filtering: `onChange` on every edit,
/// `onSubmit` on Return. Escape clears it.
public final class SearchField: NSView, NSSearchFieldDelegate {
    public let field: NSSearchField
    public var onChange: ((String) -> Void)?
    /// Called on Return, such as to open the first result.
    public var onSubmit: (() -> Void)?

    public init(placeholder: String) {
        field = NSSearchField(string: "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.delegate = self
        field.setAccessibilityLabel(placeholder)
        addSubview(field)
        field.pinEdges(to: self)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    public func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    public func searchFieldDidEndSearching(_ sender: NSSearchField) {
        onChange?("")
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
