import AppKit

/// A native segmented control such as "Close sessions | Detach" that reports
/// the chosen segment through `onChange`.
public final class SegmentedPill: NSSegmentedControl {
    public private(set) var titles: [String]
    public var onChange: ((Int) -> Void)?

    public init(_ titles: [String], selected: Int, onChange: ((Int) -> Void)? = nil) {
        self.titles = titles
        self.onChange = onChange
        super.init(frame: .zero)
        segmentCount = titles.count
        for (index, title) in titles.enumerated() { setLabel(title, forSegment: index) }
        trackingMode = .selectOne
        segmentStyle = .automatic
        selectedSegment = selected
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(changed)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var selectedIndex: Int {
        get { selectedSegment }
        set { selectedSegment = newValue }
    }

    @objc private func changed() {
        onChange?(selectedSegment)
    }

    /// Chooses a segment as a click would.
    public func select(_ index: Int) {
        guard titles.indices.contains(index), index != selectedSegment else { return }
        selectedSegment = index
        onChange?(index)
    }
}

/// A native on/off switch that reports changes through `onChange`.
public final class Switch: NSSwitch {
    public var onChange: ((Bool) -> Void)?

    public init(isOn: Bool, label: String, onChange: ((Bool) -> Void)? = nil) {
        self.onChange = onChange
        super.init(frame: .zero)
        state = isOn ? .on : .off
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(label)
        target = self
        action = #selector(changed)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var isOn: Bool {
        get { state == .on }
        set { state = newValue ? .on : .off }
    }

    @objc private func changed() {
        onChange?(isOn)
    }

    /// Flips the switch as a click would.
    public func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }
}

/// A native pop-up button of items with ids. Choosing an item calls
/// `onChange` with its id.
public final class PopUp: NSPopUpButton {
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
    public var placeholder = "" { didSet { rebuild() } }

    public init(items: [Item], selected: String, label accessibilityName: String, onChange: ((String) -> Void)? = nil) {
        self.items = items
        selectedId = selected
        self.onChange = onChange
        super.init(frame: .zero, pullsDown: false)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(accessibilityName)
        target = self
        action = #selector(chosen)
        rebuild()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public var selectedTitle: String {
        items.first { $0.id == selectedId }?.title ?? placeholder
    }

    public func setItems(_ items: [Item], selected: String) {
        self.items = items
        selectedId = selected
        rebuild()
    }

    public func select(_ id: String) {
        selectedId = id
        rebuild()
    }

    /// The menu the pop-up shows.
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !items.contains(where: { $0.id == selectedId }) {
            let placeholderItem = NSMenuItem(title: placeholder, action: nil, keyEquivalent: "")
            placeholderItem.isEnabled = false
            placeholderItem.isHidden = placeholder.isEmpty
            menu.addItem(placeholderItem)
        }
        for item in items {
            if item.separatorBefore { menu.addItem(.separator()) }
            let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            menuItem.representedObject = item.id
            menuItem.state = item.id == selectedId ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    private func rebuild() {
        menu = makeMenu()
        if let index = menu?.items.firstIndex(where: { ($0.representedObject as? String) == selectedId }) {
            selectItem(at: index)
        } else {
            selectItem(at: 0)
        }
        setAccessibilityValue(selectedTitle)
    }

    @objc private func chosen() {
        guard let id = selectedItem?.representedObject as? String else { return }
        choose(id)
    }

    /// Picks the item with `id` as the menu would.
    public func choose(_ id: String) {
        guard id != selectedId else { return }
        select(id)
        onChange?(id)
    }
}
