import AppKit

/// A category's colored icon tile: a 20pt rounded square with a 14pt glyph.
final class CategoryTile: NSView {
    private let category: SettingsCategory
    private var image: NSImage?

    init(_ category: SettingsCategory, side: CGFloat = 20) {
        self.category = category
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
        image = category.tile.icon.image(size: side * 0.7)?.tinted(NSColor(hex: category.tile.glyph))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hex: category.tile.fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.width / 4, yRadius: bounds.height / 4).fill()
        guard let image else { return }
        let size = image.size
        image.draw(
            in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }
}

/// A row of the Settings sidebar: a category with its tile, or one of its
/// sections, indented.
final class SidebarItem: HoverView {
    let category: SettingsCategory
    let section: String?
    var isSelected = false { didSet { themeDidChange() } }
    var onClick: (() -> Void)?
    private let label: NSTextField

    init(category: SettingsCategory, section: String?) {
        self.category = category
        self.section = section
        label = makeLabel(section ?? category.title, font: AppFont.body)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        var constraints = [
            heightAnchor.constraint(equalToConstant: section == nil ? 28 : 30),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.gutter),
        ]
        if section == nil {
            let tile = CategoryTile(category)
            addSubview(tile)
            constraints += [
                tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
                tile.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 12),
            ]
        } else {
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34))
        }
        NSLayoutConstraint.activate(constraints)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section ?? category.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func themeDidChange() {
        if section == nil {
            label.textColor = theme.fg
        } else {
            label.textColor = isSelected ? theme.accent : theme.fgMuted
        }
        setAccessibilitySelected(isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isHovered else { return }
        (isSelected ? theme.selection : theme.hover).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The server tile under the search field: an accent avatar, "Server" and
/// its state. Clicking it opens the Server page.
final class ServerTile: HoverView {
    private let stateLabel = makeLabel("", font: AppFont.footnote)
    private let nameLabel = makeLabel("Server", font: AppFont.body)
    private let avatar = ThemedBackground(color: { $0.accent })
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        avatar.cornerRadius = 16
        avatar.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: AppIcon.terminal.image(size: 20) ?? NSImage())
        glyph.contentTintColor = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(glyph)
        let text = NSStackView(views: [nameLabel, stateLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)
        addSubview(text)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.gutter),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),
            glyph.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: Metrics.gutter),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var state: ServerConnectionState = .stopped {
        didSet {
            stateLabel.stringValue = state.title
            setAccessibilityLabel("Server, \(state.title)")
        }
    }

    var stateText: String { stateLabel.stringValue }

    override func themeDidChange() {
        nameLabel.textColor = theme.fg
        stateLabel.textColor = theme.fgMuted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The Settings sidebar: search, the server tile and the categories, the
/// selected one expandable into its sections.
final class SettingsSidebar: ThemedView {
    let search = SearchField(placeholder: "Search Settings")
    let serverTile = ServerTile()
    private let list = NSStackView()
    private let scroll = ScrollView()
    var onSelect: ((SettingsCategory, String?) -> Void)?
    private(set) var items: [SidebarItem] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.content.addSubview(list)
        list.pinEdges(to: scroll.content, insets: NSEdgeInsets(top: 0, left: 0, bottom: Metrics.gutter, right: 0))
        for view in [search, serverTile, scroll] as [NSView] { addSubview(view) }
        let gutter = Metrics.gutter
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            serverTile.topAnchor.constraint(equalTo: search.bottomAnchor, constant: gutter),
            serverTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            serverTile.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            scroll.topAnchor.constraint(equalTo: serverTile.bottomAnchor, constant: gutter),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: gutter),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Settings categories")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = theme.raised.cgColor
    }

    override func themeDidChange() { needsDisplay = true }

    /// Shows the categories with `selected` highlighted (none while
    /// searching) and the sections of `expanded`.
    func reload(selected: SettingsCategory?, section: String?, expanded: SettingsCategory?, hiddenSections: Set<String>) {
        search.theme = theme
        serverTile.theme = theme
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        items = []
        for category in SettingsCategory.allCases {
            if category.startsGroup {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                spacer.heightAnchor.constraint(equalToConstant: Metrics.gutter - 2).isActive = true
                list.addArrangedSubview(spacer)
            }
            let item = SidebarItem(category: category, section: nil)
            item.theme = theme
            item.isSelected = category == selected && section == nil
            item.onClick = { [weak self] in self?.onSelect?(category, nil) }
            list.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            items.append(item)
            guard category == expanded else { continue }
            for name in category.sections where !hiddenSections.contains(name) {
                let sub = SidebarItem(category: category, section: name)
                sub.theme = theme
                sub.isSelected = category == selected && section == name
                sub.onClick = { [weak self] in self?.onSelect?(category, name) }
                list.addArrangedSubview(sub)
                sub.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                items.append(sub)
            }
        }
    }
}
