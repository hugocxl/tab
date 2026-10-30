import AppKit

/// The browser's toolbar: back, forward, reload or stop, the address bar,
/// the element picker, open elsewhere and the profile button, on the surface
/// color with a hairline below, 36pt tall.
final class BrowserToolbar: ThemedView {
    let back = IconButton(.chevronLeft, label: "Back")
    let forward = IconButton(.chevronRight, label: "Forward")
    let reload = IconButton(.refresh, label: "Reload")
    let address = BrowserAddressBar()
    let picker = IconButton(.code, label: "Select an element to copy its HTML and text")
    let external = IconButton(.externalLink, label: "Open in External Browser")
    let profile = BrowserProfileButton()
    private let progress = ThemedBackground(color: { $0.accent })
    private var progressWidth: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [back, forward, reload, address, picker, external, profile])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.setCustomSpacing(Metrics.controlGap, after: reload)
        row.setCustomSpacing(Metrics.controlGap, after: address)
        row.translatesAutoresizingMaskIntoConstraints = false
        address.setContentHuggingPriority(.defaultLow, for: .horizontal)
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(row)
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        addSubview(progress)
        let width = progress.widthAnchor.constraint(equalToConstant: 0)
        progressWidth = width
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            width,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var theme: AppTheme {
        didSet { address.theme = theme; progress.theme = theme }
    }

    /// Shows the load progress as an accent line under the toolbar.
    func setProgress(_ fraction: Double, loading: Bool) {
        let visible = loading && fraction < 1
        progress.isHidden = !visible
        progressWidth?.constant = bounds.width * CGFloat(max(fraction, 0.05))
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        bounds.fill()
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - Metrics.border, width: bounds.width, height: Metrics.border).fill()
    }
}

/// The address field: the page's icon and an editable address, with an
/// accent ring while editing.
final class BrowserAddressBar: ThemedView, NSTextFieldDelegate {
    final class Field: NSTextField {
        var onFocus: (() -> Void)?

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocus?() }
            return accepted
        }
    }

    let field = Field(string: "")
    private let icon = NSImageView()
    private(set) var editing = false
    var favicon: NSImage? { didSet { updateIcon() } }

    var onFocus: (() -> Void)?
    var onChange: ((String) -> Void)?
    /// Return: what was typed.
    var onSubmit: ((String) -> Void)?
    /// Escape; returns whether it was handled (suggestions closed).
    var onCancel: (() -> Bool)?
    /// Up or Down; returns whether suggestions moved.
    var onMove: ((_ down: Bool) -> Bool)?
    var onEndEditing: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.lineBreakMode = .byTruncatingTail
        field.placeholderString = "Search or enter address"
        field.setAccessibilityLabel("Address")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.delegate = self
        field.onFocus = { [weak self] in
            guard let self else { return }
            editing = true
            updateIcon()
            needsDisplay = true
            onFocus?()
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.controlHeight + 2),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateIcon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    private func updateIcon() {
        if let favicon, !editing {
            icon.image = favicon
            icon.contentTintColor = nil
        } else {
            icon.image = AppIcon.globe.image(size: 14)
            icon.contentTintColor = theme.fgDim
        }
    }

    override func themeDidChange() {
        field.textColor = theme.fg
        field.placeholderAttributedString = NSAttributedString(
            string: field.placeholderString ?? "",
            attributes: [.foregroundColor: theme.fgDim, .font: AppFont.body])
        updateIcon()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        theme.bg.setFill()
        path.fill()
        (editing ? theme.accent : theme.border).setStroke()
        path.lineWidth = editing ? 1.5 : Metrics.border
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(field)
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        updateIcon()
        needsDisplay = true
        onEndEditing?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return onCancel?() ?? false
        case #selector(NSResponder.moveDown(_:)):
            return onMove?(true) ?? false
        case #selector(NSResponder.moveUp(_:)):
            return onMove?(false) ?? false
        default:
            return false
        }
    }
}

/// The profile the page browses with: a native borderless button with a
/// person glyph and its name; a click opens the profile menu.
final class BrowserProfileButton: NSButton {
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = true
        image = AppIcon.circleUser.image()
        imagePosition = .imageLeading
        font = AppFont.footnote
        contentTintColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingTail
        widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        toolTip = "Browser Profile"
        target = self
        action = #selector(pressed)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var name: String {
        get { title }
        set {
            title = newValue
            setAccessibilityLabel("Browser Profile: \(newValue)")
        }
    }

    @objc private func pressed() {
        onClick?()
    }
}

/// Find on page: a field, "Not found", previous, next and close.
final class BrowserFindBar: ThemedView, NSTextFieldDelegate {
    let field = NSTextField(string: "")
    private let glyph = NSImageView()
    private let missing = makeLabel("Not found", font: AppFont.footnote)
    private let previous = IconButton(.chevronUp, label: "Previous match")
    private let next = IconButton(.chevronDown, label: "Next match")
    private let close = IconButton(.close, label: "Close search")

    var onChange: ((String) -> Void)?
    var onStep: ((_ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.placeholderString = "Find on page"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        glyph.image = AppIcon.search.image(size: 14)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        missing.isHidden = true
        previous.onPress = { [weak self] in self?.onStep?(true) }
        next.onPress = { [weak self] in self?.onStep?(false) }
        close.onPress = { [weak self] in self?.onClose?() }
        let row = NSStackView(views: [glyph, field, missing, previous, next, close])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            glyph.widthAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var notFound = false {
        didSet {
            missing.isHidden = !notFound
            themeDidChange()
        }
    }

    override func themeDidChange() {
        field.textColor = notFound ? theme.warning : theme.fg
        glyph.contentTintColor = theme.fgDim
        missing.textColor = theme.warning
        field.placeholderAttributedString = NSAttributedString(
            string: field.placeholderString ?? "",
            attributes: [.foregroundColor: theme.fgDim, .font: AppFont.body])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        bounds.fill()
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - Metrics.border, width: bounds.width, height: Metrics.border).fill()
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(NSEvent.modifierFlags.contains(.shift))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}

/// What the content area shows instead of a page: the start page, a page
/// that couldn't be opened, or the disabled browser.
final class BrowserPlaceholder: ThemedView {
    enum Kind: Equatable {
        case start(engine: String)
        case error(url: String, message: String)
        case disabled
    }

    private let stack = NSStackView()
    var kind: Kind = .disabled { didSet { rebuild() } }
    var onSearch: (() -> Void)?
    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        rebuild()
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.card.setFill()
        bounds.fill()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let glyph = NSImageView()
        glyph.translatesAutoresizingMaskIntoConstraints = false
        glyph.widthAnchor.constraint(equalToConstant: 40).isActive = true
        glyph.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.addArrangedSubview(glyph)
        switch kind {
        case .start(let engine):
            glyph.image = AppIcon.globe.image(size: 40)
            glyph.contentTintColor = theme.fgMuted
            stack.addArrangedSubview(makeLabel("New Browser", font: AppFont.title, color: theme.fg))
            stack.addArrangedSubview(makeLabel("Search with \(engine) or enter a website address.", font: AppFont.body, color: theme.fgMuted))
            let search = BrowserStartSearch(theme: theme)
            search.onClick = { [weak self] in self?.onSearch?() }
            stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 1])
            stack.addArrangedSubview(search)
        case let .error(url, message):
            glyph.image = AppIcon.triangleAlert.image(size: 40)
            glyph.contentTintColor = theme.warning
            stack.addArrangedSubview(makeLabel("This page can't be opened", font: AppFont.title, color: theme.fg))
            let detail = makeLabel(message, font: AppFont.body, color: theme.fgMuted)
            detail.alignment = .center
            detail.lineBreakMode = .byWordWrapping
            detail.maximumNumberOfLines = 4
            detail.preferredMaxLayoutWidth = 420
            stack.addArrangedSubview(detail)
            let address = makeLabel(url, font: AppFont.mono(10), color: theme.fgDim)
            address.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
            stack.addArrangedSubview(address)
            let retry = PillButton("Try Again", style: .primary) { [weak self] in self?.onRetry?() }
            stack.setCustomSpacing(16, after: address)
            stack.addArrangedSubview(retry)
        case .disabled:
            glyph.image = AppIcon.globe.image(size: 40)
            glyph.contentTintColor = theme.fgDim
            stack.addArrangedSubview(makeLabel("Built-in browser is disabled", font: AppFont.title, color: theme.fg))
            stack.addArrangedSubview(makeLabel("Turn it on in Settings → Browser.", font: AppFont.body, color: theme.fgMuted))
        }
        needsDisplay = true
    }
}

/// The start page's search pill, which focuses the address bar.
private final class BrowserStartSearch: HoverView {
    var onClick: (() -> Void)?

    init(theme: AppTheme) {
        super.init(frame: .zero)
        self.theme = theme
        translatesAutoresizingMaskIntoConstraints = false
        let label = makeLabel("Search or enter address", font: AppFont.body, color: theme.fgDim)
        let key = makeLabel("⌘L", font: AppFont.body, color: theme.fgDim)
        addSubview(label)
        addSubview(key)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Search or enter address")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        (isHovered ? theme.hover : theme.surface).setFill()
        path.fill()
        theme.border.setStroke()
        path.stroke()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The address bar's history suggestions: a borderless child window under
/// the field that never takes the keyboard, so typing continues in the field.
final class BrowserSuggestionsPanel: NSPanel {
    private final class List: ThemedView {
        var entries: [BrowserHistoryEntry] = [] { didSet { needsDisplay = true } }
        var selected: Int? { didSet { needsDisplay = true } }
        var onChoose: ((Int) -> Void)?
        static let rowHeight: CGFloat = 40

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusLarge, yRadius: Metrics.radiusLarge)
            theme.raised.setFill()
            outline.fill()
            theme.cardBorder.setStroke()
            outline.stroke()
            for (position, entry) in entries.enumerated() {
                let row = NSRect(x: 4, y: 4 + CGFloat(position) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
                if position == selected {
                    theme.selection.setFill()
                    NSBezierPath(roundedRect: row, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
                }
                let textWidth = row.width - 16
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let title = entry.title ?? entry.url
                (title as NSString).draw(
                    in: NSRect(x: row.minX + 8, y: row.minY + 4, width: textWidth, height: 17),
                    withAttributes: [.font: AppFont.body, .foregroundColor: theme.fg, .paragraphStyle: paragraph])
                (entry.url as NSString).draw(
                    in: NSRect(x: row.minX + 8, y: row.minY + 21, width: textWidth, height: 15),
                    withAttributes: [.font: AppFont.footnote, .foregroundColor: theme.fgMuted, .paragraphStyle: paragraph])
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let row = Int((point.y - 4) / Self.rowHeight)
            guard entries.indices.contains(row) else { return }
            onChoose?(row)
        }
    }

    private let list = List()

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        contentView = list
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var onChoose: ((Int) -> Void)? {
        get { list.onChoose }
        set { list.onChoose = newValue }
    }

    var entries: [BrowserHistoryEntry] { list.entries }

    var selected: Int? {
        get { list.selected }
        set { list.selected = newValue }
    }

    /// Shows `entries` under `anchor`, or hides when there are none.
    func show(_ entries: [BrowserHistoryEntry], under anchor: NSView, theme: AppTheme) {
        list.theme = theme
        list.entries = entries
        list.selected = nil
        guard !entries.isEmpty, let parent = anchor.window else {
            dismiss()
            return
        }
        let frameInWindow = anchor.convert(anchor.bounds, to: nil)
        let onScreen = parent.convertToScreen(frameInWindow)
        let height = CGFloat(entries.count) * List.rowHeight + 8
        setFrame(NSRect(x: onScreen.minX, y: onScreen.minY - 4 - height, width: max(onScreen.width, 280), height: height), display: true)
        if parent.childWindows?.contains(self) != true { parent.addChildWindow(self, ordered: .above) }
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
