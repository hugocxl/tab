import AppKit

/// An inset grouped card, as in Settings: rows on a soft fill with a 10pt
/// radius, a faint edge and separators inset from both sides.
public final class Card: ThemedView {
    private let stack = NSStackView()

    public init(rows: [NSView] = []) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        addSubview(stack)
        stack.pinEdges(to: self)
        rows.forEach(addRow)
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var rows: [NSView] { stack.arrangedSubviews }

    public func addRow(_ row: NSView) {
        (stack.arrangedSubviews.last as? CardRow)?.showsSeparator = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cardRadius, yRadius: Metrics.cardRadius)
        theme.rowFill.setFill()
        path.fill()
        theme.rowBorder.setStroke()
        path.lineWidth = Metrics.border
        path.stroke()
    }
}

/// One row of a `Card`: the label on the left and its control on the right,
/// or the control under the label when `stacked`. The description shows as
/// the row's tooltip, and an error under the label.
public final class CardRow: ThemedView {
    public let id: String
    public let label: NSTextField
    public let control: NSView?
    private let errorLabel: NSTextField

    public init(id: String, label text: String, control: NSView?, description: String? = nil, stacked: Bool = false, error: String? = nil) {
        self.id = id
        label = makeLabel(text, font: AppFont.body)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        self.control = control
        errorLabel = makeLabel(error ?? "", font: AppFont.footnote)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 0
        errorLabel.isHidden = error == nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = description
        let text = NSStackView(views: [label, errorLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inset = Metrics.gutter * 1.5
        var constraints = [
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            if stacked {
                constraints += [
                    text.topAnchor.constraint(equalTo: topAnchor, constant: 11),
                    text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
                    control.topAnchor.constraint(equalTo: text.bottomAnchor, constant: Metrics.controlGap),
                    control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
                    control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
                    control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                ]
            } else {
                constraints += [
                    text.centerYAnchor.constraint(equalTo: centerYAnchor),
                    text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
                    control.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 16),
                    control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset + 2),
                    control.centerYAnchor.constraint(equalTo: centerYAnchor),
                    control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
                ]
                control.setContentCompressionResistancePriority(.required, for: .horizontal)
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
        } else {
            constraints += [
                text.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
                text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(false)
        setAccessibilityLabel(text.accessibilityLabel())
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the line between this row and the next.
    public var showsSeparator = false { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator else { return }
        theme.separator.setFill()
        let inset = Metrics.gutter * 1.5
        NSRect(x: inset, y: bounds.height - 1, width: bounds.width - inset * 2, height: 1).fill()
    }

    public var error: String? {
        get { errorLabel.isHidden ? nil : errorLabel.stringValue }
        set {
            errorLabel.stringValue = newValue ?? ""
            errorLabel.isHidden = newValue == nil
        }
    }

    public override func themeDidChange() {
        label.textColor = theme.fg
        errorLabel.textColor = theme.danger
    }
}

/// A section title above a card: 13pt semibold.
public final class SectionHeader: ThemedView {
    public let label: NSTextField

    public init(_ title: String) {
        label = makeLabel(title, font: AppFont.header)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var title: String { label.stringValue }

    public override func themeDidChange() {
        label.textColor = theme.fg
    }
}

/// Muted or error text under a card or inside a row.
public final class NoteLabel: ThemedView {
    public let label: NSTextField
    public let isError: Bool

    public init(_ text: String, error: Bool = false) {
        label = makeLabel(text, font: AppFont.small)
        label.alignment = .left
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        isError = error
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pinEdges(to: self, insets: NSEdgeInsets(top: 6, left: Metrics.gutter * 1.5, bottom: 6, right: Metrics.gutter * 1.5))
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func themeDidChange() {
        label.textColor = isError ? theme.danger : theme.fgMuted
    }
}

/// A small uppercase tag such as PRIMARY: 8pt bold on a surface pill.
public final class Badge: ThemedView {
    private let label: NSTextField

    public init(_ text: String) {
        label = makeLabel(text.uppercased(), font: AppFont.micro)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.pinEdges(to: self, insets: NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var text: String { label.stringValue }

    public override func themeDidChange() {
        label.textColor = theme.fgMuted
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
    }
}
