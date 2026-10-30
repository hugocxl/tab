import AppKit
import TabCore

/// The palette card: the 56pt header with the search field, the rows or a
/// status message, and the footer capsule floating over the last 52pt, where
/// the rows fade out beneath it.
final class PalettePanelView: ThemedView {
    let header = PaletteHeaderView()
    let list = PaletteListView()
    let footer = PaletteFooterView()
    private let fade = PaletteFadeView()
    private let messageLabel = makeLabel("", font: AppFont.system(12))
    /// A tight shadow at the card's edge, under the wide one on `self`.
    private let edge = ThemedBackground(color: { $0.floating })
    private let card = ThemedBackground(color: { $0.floating })

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
        shadow = Self.shadow(alpha: 0.26, blur: 36, y: 14)
        edge.cornerRadius = PaletteLayout.radius
        edge.layer?.cornerCurve = .continuous
        edge.shadow = Self.shadow(alpha: 0.14, blur: 4, y: 1)
        addSubview(edge)
        card.cornerRadius = PaletteLayout.radius
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.cornerCurve = .continuous
        addSubview(card)
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = true
        messageLabel.isHidden = true
        for view in [header, list, messageLabel, fade, footer] as [NSView] { card.addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A black shadow `y` points below the view: AppKit applies the offset
    /// in flipped coordinates here.
    static func shadow(alpha: CGFloat, blur: CGFloat, y: CGFloat) -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(alpha)
        shadow.shadowBlurRadius = blur
        shadow.shadowOffset = NSSize(width: 0, height: y)
        return shadow
    }

    override func themeDidChange() {
        card.layer?.borderColor = theme.fg(alpha: 0.10).cgColor
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        edge.frame = bounds
        card.frame = bounds
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: PaletteLayout.header)
        footer.frame = NSRect(x: 0, y: bounds.height - PaletteLayout.footer, width: width, height: PaletteLayout.footer)
        let body = NSRect(x: 0, y: header.frame.maxY, width: width, height: max(footer.frame.minY - header.frame.maxY, 0))
        list.frame = NSRect(x: 0, y: header.frame.maxY, width: width, height: max(bounds.height - header.frame.maxY, 0))
        fade.frame = NSRect(x: 0, y: footer.frame.minY - 12, width: width, height: footer.frame.height + 12)
        let height = messageLabel.intrinsicContentSize.height
        messageLabel.frame = NSRect(x: 32, y: body.midY - height / 2, width: width - 64, height: height)
        if let actionsPanel {
            let size = NSSize(width: PaletteLayout.actionsWidth, height: actionsPanel.preferredHeight)
            let capsule = footer.convert(footer.capsule.frame, to: self)
            actionsPanel.frame = NSRect(x: capsule.maxX - size.width, y: capsule.minY - size.height - 6, width: size.width, height: size.height)
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

/// The footer: a glass capsule at the bottom right with the primary action
/// and ↩, then Actions and ⌘K. Clicks beside the capsule reach the rows.
final class PaletteFooterView: ThemedView {
    let capsule = GlassCapsuleView()
    let primary = FooterButton()
    let actions = FooterButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        primary.caps.symbols = ["↩"]
        actions.label.stringValue = "Actions"
        actions.caps.symbols = ["⌘", "K"]
        actions.muted = true
        for view in [primary, actions] as [NSView] { capsule.content.addSubview(view) }
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(primary title: String?, actionsEnabled: Bool) {
        primary.isHidden = title == nil
        primary.label.stringValue = title ?? ""
        primary.invalidateIntrinsicContentSize()
        actions.isEnabled = actionsEnabled
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let inset = (PaletteLayout.capsule - 28) / 2
        var x = inset
        if !primary.isHidden {
            let size = primary.intrinsicContentSize
            primary.frame = NSRect(x: x, y: inset, width: size.width, height: 28)
            x += size.width + 2
        }
        let size = actions.intrinsicContentSize
        actions.frame = NSRect(x: x, y: inset, width: size.width, height: 28)
        let width = x + size.width + inset
        let margin = (bounds.height - PaletteLayout.capsule) / 2
        capsule.frame = NSRect(x: bounds.width - margin - width, y: margin, width: width, height: PaletteLayout.capsule)
    }
}

/// The rows fading into the card behind the footer capsule.
final class PaletteFadeView: ThemedView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func themeDidChange() {
        let color = theme.floating
        gradient.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.55).cgColor]
        gradient.locations = [0, 1]
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}

/// A floating capsule of Liquid Glass on macOS 26 and later, the rows
/// beneath refracting through a whitened clear glass inside a hairline edge;
/// before, frosted glass with a shadow.
final class GlassCapsuleView: ThemedView {
    let content = ThemedView()
    private let glass: NSView

    override init(frame frameRect: NSRect) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.contentView = content
            self.glass = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .withinWindow
            material.state = .active
            material.wantsLayer = true
            material.layer?.masksToBounds = true
            material.layer?.cornerCurve = .continuous
            material.addSubview(content)
            self.glass = material
        }
        super.init(frame: frameRect)
        if glass is NSVisualEffectView { shadow = PalettePanelView.shadow(alpha: 0.10, blur: 12, y: 3) }
        addSubview(glass)
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        glass.appearance = NSAppearance(named: theme.isLight ? .aqua : .darkAqua)
        layer?.borderColor = theme.fg(alpha: 0.10).cgColor
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.tintColor = theme.isLight ? NSColor.white.withAlphaComponent(0.25) : theme.floating.withAlphaComponent(0.35)
        }
    }

    override func layout() {
        super.layout()
        let radius = bounds.height / 2
        glass.frame = bounds
        content.frame = bounds
        layer?.cornerRadius = radius
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            glass.layer?.cornerRadius = radius
        }
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
        contentInsets = NSEdgeInsets(top: PaletteLayout.listInset, left: 0, bottom: PaletteLayout.listInset + PaletteLayout.footer, right: 0)
        scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: PaletteLayout.footer, right: 0)
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
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        shadow = PalettePanelView.shadow(alpha: 0.16, blur: 20, y: 6)
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
        layer?.backgroundColor = theme.floating.cgColor
        layer?.borderColor = theme.fg(alpha: 0.10).cgColor
        for (index, label) in labels.enumerated() {
            label.textColor = state.actions[index].destructive ? theme.danger : theme.fg
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.backgroundColor = theme.floating.cgColor
        layer?.borderColor = theme.fg(alpha: 0.10).cgColor
        let row = rowFrame(state.selected)
        theme.fg(alpha: 0.08).setFill()
        NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
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
