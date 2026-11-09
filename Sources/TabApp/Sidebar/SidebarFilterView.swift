import AppKit

/// The sidebar footer's filter: the filter glyph alone at rest, a pill with
/// a Filter field while the glyph is hovered, the field is focused or it
/// holds text. The glyph opens the host menu; the field filters by name.
final class SidebarFilterView: ThemedView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    /// The menu the glyph opens: which hosts the sidebar lists.
    var hostMenu: (() -> NSMenu?)?
    /// The glyph's right-click menu.
    var contextMenu: (() -> NSMenu?)?

    private let glyph = ChromeButton(SystemSymbol.filterCircleFill, label: "Filter by Host")
    private let field = FilterTextField()
    private let clear = ChromeButton(SystemSymbol.clearField, label: "Clear Filter", side: 20, glyph: 15)
    private var trackingArea: NSTrackingArea?
    private var hovering = false { didSet { if hovering != oldValue { update() } } }
    private var editing = false { didSet { if editing != oldValue { update() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        glyph.showsFill = false
        glyph.onPress = { [weak self] _ in self?.showHostMenu() }
        glyph.menuProvider = { [weak self] in self?.contextMenu?() }
        clear.showsFill = false
        clear.onPress = { [weak self] _ in self?.setText("") }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.body
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("Filter")
        field.onFocus = { [weak self] in self?.editing = true }
        for view in [glyph, field, clear] as [NSView] { addSubview(view) }
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var mouseDownCanMoveWindow: Bool { false }

    var text: String {
        get { field.stringValue }
        set {
            field.stringValue = newValue
            update()
        }
    }

    var isExpanded: Bool { hovering || editing || !field.stringValue.isEmpty }

    /// Expands the pill and puts the cursor in the field.
    func focus() {
        editing = true
        if window?.makeFirstResponder(field) != true { editing = false }
    }

    private func setText(_ text: String) {
        self.text = text
        onChange?(text)
    }

    private func update() {
        let expanded = isExpanded
        field.isHidden = !expanded
        clear.isHidden = !expanded || field.stringValue.isEmpty
        layer?.backgroundColor = expanded ? theme.hover.cgColor : nil
        needsLayout = true
    }

    override func themeDidChange() {
        field.textColor = theme.fg
        field.placeholderAttributedString = NSAttributedString(string: "Filter", attributes: [
            .foregroundColor: theme.fgMuted, .font: AppFont.body,
        ])
        update()
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        layer?.cornerRadius = height / 2
        glyph.frame = CGRect(x: 0, y: 0, width: height, height: height)
        let clearSide = clear.side
        clear.frame = CGRect(x: bounds.width - clearSide - 5, y: ((height - clearSide) / 2).rounded(), width: clearSide, height: clearSide)
        let fieldX = height - 2
        let fieldEnd = clear.isHidden ? bounds.width - 10 : clear.frame.minX - 4
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = CGRect(x: fieldX, y: ((height - fieldHeight) / 2).rounded(), width: max(fieldEnd - fieldX, 0), height: fieldHeight)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(event) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(event) }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// At rest only the glyph expands the pill; once open, the whole pill
    /// keeps it open.
    private func pointerMoved(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isExpanded ? bounds.contains(point) : glyph.frame.contains(point) { hovering = true }
    }

    private func syncHover() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if !bounds.contains(point) { hovering = false }
    }

    // MARK: Host menu

    /// Opens the host menu above the pill, aligned with its left edge.
    private func showHostMenu() {
        guard let menu = hostMenu?() else { return }
        hovering = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -menu.size.height - 6), in: self)
        syncHover()
    }

    // MARK: Field

    func controlTextDidChange(_ notification: Notification) {
        update()
        onChange?(field.stringValue)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        syncHover()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if field.stringValue.isEmpty {
                window?.makeFirstResponder(nil)
            } else {
                setText("")
            }
            return true
        default:
            return false
        }
    }
}

/// The filter's text field, reporting when it takes focus: the field editor
/// takes over right after, so the field sees no later focus change.
private final class FilterTextField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }
}
