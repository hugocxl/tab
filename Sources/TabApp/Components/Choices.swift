import AppKit

/// A segmented pill such as "Close sessions | Detach": a surface track with
/// the chosen segment raised.
public final class SegmentedPill: HoverView {
    public private(set) var titles: [String]
    public var selectedIndex: Int { didSet { needsDisplay = true } }
    public var onChange: ((Int) -> Void)?
    private var hoveredIndex: Int?
    private let font = AppFont.body
    private let padding: CGFloat = 10

    public init(_ titles: [String], selected: Int, onChange: ((Int) -> Void)? = nil) {
        self.titles = titles
        selectedIndex = selected
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var segmentWidths: [CGFloat] {
        titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + padding * 2 }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidths.reduce(0, +) + 4, height: Metrics.controlHeight + 2)
    }

    private func segmentRects() -> [NSRect] {
        var x: CGFloat = 2
        return segmentWidths.map { width in
            defer { x += width }
            return NSRect(x: x, y: 2, width: width, height: bounds.height - 4)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        theme.surface.setFill()
        track.fill()
        for (index, rect) in segmentRects().enumerated() {
            let selected = index == selectedIndex
            if selected || index == hoveredIndex {
                (selected ? theme.control : theme.hover).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: selected ? theme.fg : theme.fgMuted,
            ]
            let title = titles[index] as NSString
            let size = title.size(withAttributes: attributes)
            title.draw(
                at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return segmentRects().firstIndex { $0.contains(point) }
    }

    public override func mouseMoved(with event: NSEvent) {
        let index = index(at: event)
        if index != hoveredIndex {
            hoveredIndex = index
            needsDisplay = true
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    public override func hoverDidChange() {
        if !isHovered { hoveredIndex = nil }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard let index = index(at: event) else { return }
        select(index)
    }

    /// Chooses a segment as a click would.
    public func select(_ index: Int) {
        guard titles.indices.contains(index), index != selectedIndex else { return }
        selectedIndex = index
        onChange?(index)
    }

    public override func accessibilityValue() -> Any? { titles.indices.contains(selectedIndex) ? titles[selectedIndex] : nil }
}

/// An on/off switch: accent track when on, 36×20 with an 18pt knob.
public final class Switch: ThemedView {
    public var isOn: Bool { didSet { needsDisplay = true } }
    public var isEnabled = true { didSet { needsDisplay = true } }
    public var onChange: ((Bool) -> Void)?

    public init(isOn: Bool, label: String, onChange: ((Bool) -> Void)? = nil) {
        self.isOn = isOn
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(label)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 20) }
    public override var acceptsFirstResponder: Bool { isEnabled }

    public override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? theme.accent : theme.control).withAlphaComponent(isEnabled ? 1 : 0.4).setFill()
        track.fill()
        if window?.firstResponder === self {
            theme.accent.withAlphaComponent(0.5).setStroke()
            track.lineWidth = 2
            track.stroke()
        }
        let diameter: CGFloat = 16
        let x = isOn ? bounds.width - diameter - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - diameter) / 2, width: diameter, height: diameter))
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7).setFill()
        knob.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    public override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { toggle() }
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggle() } else { super.keyDown(with: event) }
    }

    /// Flips the switch as a click would.
    public func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    public override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    public override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    public override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
}

/// A pop-up menu shown as the chosen title and an up-down chevron box, like
/// "Codesh editor ⌃⌄" in Settings. Choosing an item calls `onChange` with its
/// id.
public final class PopUp: HoverView, NSMenuDelegate {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var title: String
        /// A separator before the item.
        public var separatorBefore: Bool

        public init(id: String, title: String, separatorBefore: Bool = false) {
            self.id = id
            self.title = title
            self.separatorBefore = separatorBefore
        }
    }

    public private(set) var items: [Item]
    public private(set) var selectedId: String
    public var onChange: ((String) -> Void)?
    /// Shown when no item has the selected id.
    public var placeholder = ""
    private let label: NSTextField
    private let chevron: NSImageView
    private var menuOpen = false

    public init(items: [Item], selected: String, label accessibilityName: String, onChange: ((String) -> Void)? = nil) {
        self.items = items
        selectedId = selected
        self.onChange = onChange
        label = makeLabel("", font: AppFont.body)
        label.alignment = .right
        chevron = NSImageView()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = AppIcon.chevronsUpDown.image(size: 12)
        chevron.wantsLayer = true
        chevron.layer?.cornerRadius = 5
        addSubview(label)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.controlHeight),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 20),
            chevron.heightAnchor.constraint(equalToConstant: 20),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityName)
        updateTitle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public var selectedTitle: String {
        items.first { $0.id == selectedId }?.title ?? placeholder
    }

    public func setItems(_ items: [Item], selected: String) {
        self.items = items
        selectedId = selected
        updateTitle()
    }

    public func select(_ id: String) {
        selectedId = id
        updateTitle()
    }

    private func updateTitle() {
        label.stringValue = selectedTitle
        setAccessibilityValue(selectedTitle)
        invalidateIntrinsicContentSize()
    }

    public override func themeDidChange() {
        label.textColor = theme.fg
        chevron.contentTintColor = theme.fg
        chevron.layer?.backgroundColor = theme.surface.cgColor
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard isHovered || menuOpen else { return }
        theme.hover.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium).fill()
    }

    public override func mouseDown(with event: NSEvent) {
        showMenu()
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 125 {
            showMenu()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        showMenu()
        return true
    }

    /// The menu the pop-up shows, built when it opens.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.appearance = theme.nsAppearance
        for item in items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.title, action: #selector(chooseMenuItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.id
            menuItem.state = item.id == selectedId ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    private func showMenu() {
        let menu = makeMenu()
        let selected = menu.items.first { $0.state == .on }
        menuOpen = true
        needsDisplay = true
        menu.popUp(positioning: selected, at: NSPoint(x: 0, y: bounds.height - 2), in: self)
    }

    public func menuDidClose(_ menu: NSMenu) {
        menuOpen = false
        needsDisplay = true
    }

    @objc private func chooseMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        choose(id)
    }

    /// Picks the item with `id` as the menu would.
    public func choose(_ id: String) {
        guard id != selectedId else { return }
        select(id)
        onChange?(id)
    }
}
