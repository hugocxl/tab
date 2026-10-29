import AppKit
import TabCore

/// The palette card: the 56pt header with the search field, the rows or a
/// status message, and the 40pt footer.
final class PalettePanelView: ThemedView {
    let header = PaletteHeaderView()
    let list = PaletteListView()
    let footer = PaletteFooterView()
    private let messageLabel = makeLabel("", font: AppFont.system(12))
    private let card = ThemedBackground(color: { $0.raised })

    var message: (String, isError: Bool)? {
        didSet {
            messageLabel.stringValue = message?.0 ?? ""
            messageLabel.textColor = message?.isError == true ? theme.danger : theme.fgMuted
            messageLabel.isHidden = message == nil
            list.isHidden = message != nil
        }
    }

    var actionsPanel: ActionsPanelView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let actionsPanel { addSubview(actionsPanel) }
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = PaletteLayout.radius
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 24
        layer?.shadowOffset = CGSize(width: 0, height: -12)
        card.wantsLayer = true
        card.cornerRadius = PaletteLayout.radius
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.cornerCurve = .continuous
        addSubview(card)
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = true
        messageLabel.isHidden = true
        for view in [header, list, messageLabel, footer] as [NSView] { card.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        card.layer?.borderColor = theme.border.cgColor
        card.needsDisplay = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        card.layer?.borderColor = theme.border.cgColor
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: PaletteLayout.header)
        footer.frame = NSRect(x: 0, y: bounds.height - PaletteLayout.footer, width: width, height: PaletteLayout.footer)
        let body = NSRect(x: 0, y: header.frame.maxY, width: width, height: max(footer.frame.minY - header.frame.maxY, 0))
        list.frame = body
        let height = messageLabel.intrinsicContentSize.height
        messageLabel.frame = NSRect(x: 32, y: body.midY - height / 2, width: width - 64, height: height)
        if let actionsPanel {
            let size = NSSize(width: PaletteLayout.actionsWidth, height: actionsPanel.preferredHeight)
            actionsPanel.frame = NSRect(x: width - size.width - 8, y: footer.frame.minY - size.height - 4, width: size.width, height: size.height)
        }
    }
}

/// The search row: a magnifier or the back chip, the field, accessories.
final class PaletteHeaderView: ThemedView {
    let field = PaletteSearchField()
    let back = BackChip()
    private let glyph = NSImageView()
    private var accessories: [NSView] = []
    private var pushed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        glyph.image = AppIcon.search.image(size: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = AppFont.system(PaletteLayout.searchFont)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        for view in [glyph, back, field] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(spec: PageSpec, query: String, pushed: Bool, controller: PaletteController) {
        self.pushed = pushed
        glyph.isHidden = pushed
        back.isHidden = !pushed
        back.title = spec.breadcrumb ?? ""
        if field.stringValue != query { field.stringValue = query }
        field.placeholderAttributedString = NSAttributedString(string: spec.placeholder, attributes: [
            .font: AppFont.system(PaletteLayout.searchFont), .foregroundColor: theme.fgDim,
        ])
        accessories.forEach { $0.removeFromSuperview() }
        accessories = spec.accessories.map { accessory -> NSView in
            switch accessory {
            case let .toggle(id, label, active):
                let pill = AccessoryPill(id: id, title: label, active: active)
                pill.action = { [weak controller] in controller?.toggleAccessory(id) }
                return pill
            case let .hint(label, key):
                let stack = NSStackView()
                stack.spacing = 6
                let text = makeLabel(label, font: AppFont.system(12), color: theme.fgMuted)
                stack.addArrangedSubview(text)
                if let key {
                    let caps = KeycapsView()
                    caps.symbols = KeycapsView.symbols(key)
                    stack.addArrangedSubview(caps)
                }
                return stack
            }
        }
        for view in accessories { addSubview(view) }
        needsLayout = true
    }

    override func themeDidChange() {
        glyph.contentTintColor = theme.fgMuted
        field.textColor = theme.fg
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.border.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        var x: CGFloat = 16
        if pushed {
            let size = back.intrinsicContentSize
            back.frame = NSRect(x: x, y: middle - size.height / 2, width: size.width, height: size.height)
            x += size.width + 10
        } else {
            glyph.frame = NSRect(x: x, y: middle - 9, width: 18, height: 18)
            x += 18 + 10
        }
        var right = bounds.width - 16
        for view in accessories.reversed() {
            let size = view.fittingSize.width > 0 ? view.fittingSize : view.intrinsicContentSize
            right -= size.width
            view.frame = NSRect(x: right, y: middle - size.height / 2, width: size.width, height: size.height)
            right -= 8
        }
        let height = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: x, y: (middle - height / 2).rounded(), width: max(right - x, 0), height: height)
    }
}

/// The search field; its caret uses the accent.
final class PaletteSearchField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = AppTheme.shared.accent
        }
        return accepted
    }
}

/// The footer: the primary action with ↩ and Actions with its keycaps.
final class PaletteFooterView: ThemedView {
    let primary = FooterButton()
    let actions = FooterButton()
    private let separator = ThemedBackground(color: { $0.border })

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primary.caps.symbols = ["↩"]
        actions.label.stringValue = "Actions"
        actions.caps.symbols = ["⌘", "K"]
        for view in [primary, separator, actions] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(primary title: String?, actionsEnabled: Bool) {
        primary.isHidden = title == nil
        separator.isHidden = title == nil
        primary.label.stringValue = title ?? ""
        actions.isEnabled = actionsEnabled
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        var right = bounds.width - 8
        let actionsSize = actions.intrinsicContentSize
        right -= actionsSize.width
        actions.frame = NSRect(x: right, y: middle - 14, width: actionsSize.width, height: 28)
        guard !primary.isHidden else { return }
        right -= 9
        separator.frame = NSRect(x: right, y: middle - 8, width: 1, height: 16)
        right -= 8
        let primarySize = primary.intrinsicContentSize
        right -= primarySize.width
        primary.frame = NSRect(x: right, y: middle - 14, width: primarySize.width, height: 28)
    }
}

/// The rows, virtualized in a table.
final class PaletteListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    var state = PageState(spec: PageSpec(.root, placeholder: ""))
    var onClick: ((Int) -> Void)?
    private let table = HoverTable()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        hasVerticalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        borderType = .noBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        documentView = table
        contentInsets = NSEdgeInsets(top: PaletteLayout.listInset, left: 0, bottom: PaletteLayout.listInset, right: 0)
        automaticallyAdjustsContentInsets = false
        table.onHover = { [weak self] row in self?.hover(row) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var hovered: Int?

    func reloadRows() {
        table.reloadData()
    }

    func reveal(_ row: Int, top: Bool) {
        guard row < table.numberOfRows else { return }
        if top, row <= 1 {
            contentView.scroll(to: NSPoint(x: 0, y: -PaletteLayout.listInset))
            reflectScrolledClipView(contentView)
            return
        }
        table.scrollRowToVisible(row)
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        onClick?(row)
    }

    private func hover(_ row: Int?) {
        guard row != hovered else { return }
        if let hovered, hovered < table.numberOfRows, let view = table.view(atColumn: 0, row: hovered, makeIfNecessary: false) as? PaletteItemView {
            view.hovered = false
        }
        hovered = row
        if let row, row < table.numberOfRows, let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? PaletteItemView {
            view.hovered = true
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { state.rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .section = state.rows[row] { return PaletteLayout.section }
        return PaletteLayout.row
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = state.rows[row]
        if let title = state.sectionTitle(entry) {
            let identifier = NSUserInterfaceItemIdentifier("section")
            let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteSectionView ?? {
                let view = PaletteSectionView()
                view.identifier = identifier
                return view
            }()
            view.configure(title)
            return view
        }
        guard let item = state.rowItem(entry) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("item")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? PaletteItemView ?? {
            let view = PaletteItemView()
            view.identifier = identifier
            return view
        }()
        view.configure(item)
        view.selected = state.selected == item.id
        view.hovered = hovered == row
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

/// A table that reports the row under the pointer.
final class HoverTable: NSTableView {
    var onHover: ((Int?) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        onHover?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}

/// The ⌘K panel: the selected row's actions.
final class ActionsPanelView: ThemedView {
    private let state: ActionsState
    private var labels: [NSTextField] = []
    weak var controller: PaletteController?

    init(state: ActionsState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        for (index, action) in state.actions.enumerated() {
            let title = state.armed && index == state.selected ? "Press Return to \(action.title.lowercased())" : action.title
            let label = makeLabel(title, font: AppFont.system(13))
            label.translatesAutoresizingMaskIntoConstraints = true
            labels.append(label)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredHeight: CGFloat { PaletteLayout.actionsHeight(rows: state.actions.count) - PaletteLayout.listInset }

    override var wantsUpdateLayer: Bool { false }

    override func themeDidChange() {
        layer?.backgroundColor = theme.raised.cgColor
        layer?.borderColor = theme.border.cgColor
        for (index, label) in labels.enumerated() {
            label.textColor = state.actions[index].destructive ? theme.danger : theme.fg
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = theme.raised.cgColor
        layer?.borderColor = theme.border.cgColor
        let row = rowFrame(state.selected)
        theme.fg(alpha: 0.08).setFill()
        NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
    }

    private func rowFrame(_ index: Int) -> NSRect {
        NSRect(x: 6, y: PaletteLayout.listInset + CGFloat(index) * PaletteLayout.actionsRow, width: bounds.width - 12, height: PaletteLayout.actionsRow)
    }

    override func layout() {
        super.layout()
        for (index, label) in labels.enumerated() {
            let row = rowFrame(index)
            let height = label.intrinsicContentSize.height
            label.frame = NSRect(x: row.minX + 10, y: row.midY - height / 2, width: row.width - 20, height: height)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for index in state.actions.indices where rowFrame(index).contains(point) {
            controller?.clickAction(index)
            return
        }
    }
}
