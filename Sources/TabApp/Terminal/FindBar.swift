import AppKit

@MainActor public protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBar, didChangeQuery query: String)
    func findBarDidToggleCase(_ bar: FindBar)
    func findBar(_ bar: FindBar, step previous: Bool)
    func findBarDidClose(_ bar: FindBar)
}

/// The in-pane find bar above a terminal: a dark inset field, the match
/// counter, previous and next, the Aa case toggle, and close.
public final class FindBar: NSView, NSTextFieldDelegate {
    /// Colors and sizes, supplied by the host's theme.
    public struct Style: Equatable {
        public var background: NSColor
        public var border: NSColor
        public var fieldBackground: NSColor
        public var fieldBorder: NSColor
        public var text: NSColor
        public var muted: NSColor
        public var accent: NSColor
        public var fontSize: CGFloat
        public var captionSize: CGFloat

        public init(background: NSColor = NSColor(white: 0.1, alpha: 1), border: NSColor = NSColor(white: 1, alpha: 0.08),
                    fieldBackground: NSColor = NSColor(white: 0.04, alpha: 1),
                    fieldBorder: NSColor = NSColor(white: 1, alpha: 0.1), text: NSColor = NSColor(white: 0.9, alpha: 1),
                    muted: NSColor = NSColor(white: 0.55, alpha: 1),
                    accent: NSColor = NSColor(srgbRed: 0.55, green: 0.5, blue: 0.95, alpha: 1),
                    fontSize: CGFloat = 13, captionSize: CGFloat = 11) {
            self.background = background
            self.border = border
            self.fieldBackground = fieldBackground
            self.fieldBorder = fieldBorder
            self.text = text
            self.muted = muted
            self.accent = accent
            self.fontSize = fontSize
            self.captionSize = captionSize
        }
    }

    public static let height: CGFloat = 40

    public weak var delegate: FindBarDelegate?
    public var style = Style() { didSet { applyStyle() } }

    public var query: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    public var counter: String = "" {
        didSet {
            counterLabel.stringValue = counter
            needsLayout = true
        }
    }

    public var isCaseSensitive = false { didSet { applyStyle() } }

    private let fieldBox = NSView()
    private let field = NSTextField()
    private let counterLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let caseButton = NSButton()
    private let closeButton = NSButton()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        fieldBox.wantsLayer = true
        fieldBox.layer?.cornerRadius = 6
        fieldBox.layer?.borderWidth = 1
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Find in terminal…"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.setAccessibilityLabel("Find in terminal")
        counterLabel.lineBreakMode = .byTruncatingTail
        counterLabel.alignment = .right
        configure(previousButton, symbol: "chevron.left", label: "Previous match", action: #selector(previous))
        configure(nextButton, symbol: "chevron.right", label: "Next match", action: #selector(next))
        configure(closeButton, symbol: "xmark", label: "Close search", action: #selector(close))
        caseButton.isBordered = false
        caseButton.title = "Aa"
        caseButton.target = self
        caseButton.action = #selector(toggleCase)
        caseButton.setAccessibilityLabel("Match case")
        caseButton.toolTip = "Match case"
        fieldBox.addSubview(field)
        for view in [fieldBox, counterLabel, previousButton, nextButton, caseButton, closeButton] { addSubview(view) }
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// Puts the keyboard in the field with its text selected.
    public func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    public var isEditing: Bool {
        guard let editor = field.currentEditor() else { return false }
        return window?.firstResponder === editor
    }

    public override func layout() {
        super.layout()
        let padding: CGFloat = 8
        let button: CGFloat = 26
        let height = bounds.height
        var right = bounds.width - padding
        func place(_ view: NSView, width: CGFloat) {
            right -= width
            view.frame = CGRect(x: right, y: (height - button) / 2, width: width, height: button)
            right -= 2
        }
        place(closeButton, width: button)
        place(caseButton, width: 30)
        place(nextButton, width: button)
        place(previousButton, width: button)
        let counterWidth = min(140, ceil(counterLabel.intrinsicContentSize.width) + 4)
        right -= 6
        let labelHeight = counterLabel.intrinsicContentSize.height
        counterLabel.frame = CGRect(x: right - counterWidth, y: (height - labelHeight) / 2, width: counterWidth,
                                    height: labelHeight)
        right -= counterWidth + 8
        fieldBox.frame = CGRect(x: padding, y: (height - 26) / 2, width: max(40, right - padding), height: 26)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = CGRect(x: 8, y: (26 - fieldHeight) / 2, width: fieldBox.bounds.width - 16, height: fieldHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        style.background.setFill()
        bounds.fill()
        style.border.setFill()
        CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    public func controlTextDidChange(_ notification: Notification) {
        delegate?.findBar(self, didChangeQuery: field.stringValue)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            delegate?.findBar(self, step: NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    @objc private func previous() { delegate?.findBar(self, step: true) }
    @objc private func next() { delegate?.findBar(self, step: false) }
    @objc private func close() { delegate?.findBarDidClose(self) }

    @objc private func toggleCase() {
        delegate?.findBarDidToggleCase(self)
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = action
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func applyStyle() {
        fieldBox.layer?.backgroundColor = style.fieldBackground.cgColor
        fieldBox.layer?.borderColor = style.fieldBorder.cgColor
        field.font = .systemFont(ofSize: style.fontSize)
        field.textColor = style.text
        field.placeholderAttributedString = NSAttributedString(
            string: "Find in terminal…",
            attributes: [.foregroundColor: style.muted, .font: NSFont.systemFont(ofSize: style.fontSize)])
        counterLabel.font = .systemFont(ofSize: style.captionSize)
        counterLabel.textColor = style.muted
        for button in [previousButton, nextButton, closeButton] { button.contentTintColor = style.muted }
        caseButton.attributedTitle = NSAttributedString(
            string: "Aa",
            attributes: [.foregroundColor: isCaseSensitive ? style.accent : style.muted,
                         .font: NSFont.systemFont(ofSize: style.fontSize, weight: .medium)])
        caseButton.setAccessibilityValue(isCaseSensitive ? "on" : "off")
        needsDisplay = true
    }
}
