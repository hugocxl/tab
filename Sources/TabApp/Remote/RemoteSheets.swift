import AppKit

/// Builds menus of `ClosureMenuItem`s with separators between sections.
struct MenuBuilder {
    let menu = NSMenu()
    private var separate = false

    init() { menu.autoenablesItems = false }

    mutating func section() {
        separate = !menu.items.isEmpty
    }

    mutating func add(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        addItem(ClosureMenuItem(title, checked: checked, enabled: enabled, handler: handler))
    }

    mutating func submenu(_ title: String, _ items: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = items
        addItem(item)
    }

    private mutating func addItem(_ item: NSMenuItem) {
        if separate {
            menu.addItem(.separator())
            separate = false
        }
        menu.addItem(item)
    }
}

/// A themed sheet window for the remote server dialogs: on the host window
/// when there is one, else a standalone modal panel.
@MainActor
class SheetWindow: NSPanel {
    private weak var hostWindow: NSWindow?
    /// Return outside a text view performs this.
    var onDefault: (() -> Void)?
    var onCancel: (() -> Void)?

    init(content: NSView, width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                   styleMask: [.titled, .docModalWindow], backing: .buffered, defer: true)
        appearance = AppTheme.shared.nsAppearance
        let background = ThemedBackground { $0.raised }
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: background.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -16),
            background.widthAnchor.constraint(equalToConstant: width),
        ])
        contentView = background
        isReleasedWhenClosed = false
    }

    /// Shows the sheet on `window`, or alone when there is none.
    func present(on window: NSWindow?) {
        layoutIfNeeded()
        setContentSize(contentView?.fittingSize ?? frame.size)
        hostWindow = window
        if let window {
            window.beginSheet(self)
        } else {
            center()
            makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Grows or shrinks to fit content that changed.
    func fitContent() {
        guard let size = contentView?.fittingSize, size != frame.size else { return }
        setContentSize(size)
    }

    func dismiss() {
        if let hostWindow {
            hostWindow.endSheet(self)
        } else {
            orderOut(nil)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { dismiss() }
    }

    override var canBecomeKey: Bool { true }
}

/// Builders shared by the dialogs.
@MainActor
enum DialogParts {
    static func title(_ text: String) -> NSTextField {
        let label = makeLabel(text, font: AppFont.title)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    static func note(_ text: String, color: NSColor? = nil) -> NSTextField {
        let label = makeLabel(text, font: AppFont.footnote, color: color ?? AppTheme.shared.fgMuted)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A small label above a control.
    static func field(_ label: String, _ control: NSView) -> NSStackView {
        let caption = makeLabel(label, font: AppFont.footnoteMedium, color: AppTheme.shared.fgMuted)
        let stack = NSStackView(views: [caption, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = Metrics.controlGap) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    /// Buttons right-aligned, with `leading` on the left.
    static func buttons(leading: [NSView] = [], trailing: [NSView]) -> NSStackView {
        row(leading + [spacer()] + trailing)
    }
}

/// A secure field styled like `InsetTextField`.
@MainActor
final class InsetSecureField: ThemedView, NSTextFieldDelegate {
    let field = NSSecureTextField()
    var onCommit: (() -> Void)?
    var onChange: (() -> Void)?

    init(placeholder: String, label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.placeholderString = placeholder
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityLabel(label)
        field.target = self
        field.delegate = self
        field.action = #selector(commit)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    @objc private func commit() { onCommit?() }

    func controlTextDidChange(_ notification: Notification) { onChange?() }

    override func themeDidChange() {
        field.textColor = theme.fg
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        theme.surface.setFill()
        path.fill()
        theme.border.setStroke()
        path.lineWidth = Metrics.border
        path.stroke()
    }
}
