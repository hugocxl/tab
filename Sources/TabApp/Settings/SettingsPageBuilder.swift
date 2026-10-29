import AppKit
import TabCore

/// Collects a page's rows in order, keeping only those the current page,
/// section or search shows, then lays them out as section headers over
/// inset cards. Pages call `row` for every setting they offer; rows with an
/// id missing from the catalog are recorded in `unknownIds` (a bug the tests
/// catch).
@MainActor
final class SettingsPageBuilder {
    enum Block {
        case row(CardRow)
        case below(NSView)
    }

    struct Group {
        let category: SettingsCategory
        let section: String
        var blocks: [Block]
    }

    let store: SettingsStore
    let query: String
    let category: SettingsCategory
    let section: String?
    private let items: [String: SettingItem]
    private(set) var groups: [Group] = []
    private(set) var fields: [String: InsetTextField] = [:]
    private(set) var sliders: [Slider] = []
    private(set) var rowIds: [String] = []
    private(set) var unknownIds: [String] = []

    init(store: SettingsStore, query: String, category: SettingsCategory, section: String?) {
        self.store = store
        self.query = query.trimmingCharacters(in: .whitespaces).lowercased()
        self.category = category
        self.section = section
        let index = SettingsCatalog.searchIndex(commands: store.settings.commands)
        items = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isSearching: Bool { !query.isEmpty }

    func item(_ id: String) -> SettingItem? { items[id] }

    /// Whether the row `id` is on screen: on the open page (and section),
    /// or matching the search.
    func shows(_ id: String) -> Bool {
        guard let item = items[id] else {
            unknownIds.append(id)
            return false
        }
        if isSearching { return item.matches(query) }
        return item.category == category && (section == nil || item.section == section)
    }

    /// Adds a row for `id` with its catalog label; `label` replaces it, such
    /// as for a custom command's name.
    @discardableResult
    func row(_ id: String, _ makeControl: @autoclosure () -> NSView?, stacked: Bool = false, label: String? = nil, description: String? = nil) -> CardRow? {
        guard shows(id), let item = items[id] else { return nil }
        let control = makeControl()
        control?.setAccessibilityHelp(description ?? item.description)
        if control?.accessibilityLabel() == nil { control?.setAccessibilityLabel(label ?? item.label) }
        let row = CardRow(
            id: id,
            label: label ?? item.label,
            control: control,
            description: description ?? (item.description.isEmpty ? nil : item.description),
            stacked: stacked,
            error: store.errors[id]
        )
        append(.row(row), item)
        rowIds.append(id)
        return row
    }

    /// Adds a view under the card of `id`'s section, such as a note.
    func below(_ id: String, _ view: NSView) {
        guard shows(id), let item = items[id] else { return }
        append(.below(view), item)
    }

    func note(_ id: String, _ text: String, error: Bool = false) {
        below(id, NoteLabel(text, error: error))
    }

    private func append(_ block: Block, _ item: SettingItem) {
        if let index = groups.firstIndex(where: { $0.category == item.category && $0.section == item.section }) {
            groups[index].blocks.append(block)
        } else {
            groups.append(Group(category: item.category, section: item.section, blocks: [block]))
        }
    }

    // MARK: Controls

    /// A text field saved on Return or leaving it.
    func field(
        _ id: String,
        _ value: String,
        placeholder: String = "",
        width: CGFloat? = Metrics.controlWidth,
        height: CGFloat? = nil,
        multiline: Bool = false,
        label: String? = nil,
        monospaced: Bool = false,
        commit: @escaping (String) -> Void
    ) -> InsetTextField {
        let field = InsetTextField(
            value: value,
            placeholder: placeholder,
            label: label ?? items[id]?.label ?? id,
            width: width,
            height: height,
            multiline: multiline,
            monospaced: monospaced
        )
        field.onCommit = commit
        fields[id] = field
        return field
    }

    func toggle(_ id: String, _ value: Bool, _ change: @escaping (Bool) -> Void) -> Switch {
        Switch(isOn: value, label: items[id]?.label ?? id, onChange: change)
    }

    func popUp(_ id: String, _ items: [PopUp.Item], selected: String, _ change: @escaping (String) -> Void) -> PopUp {
        PopUp(items: items, selected: selected, label: self.items[id]?.label ?? id, onChange: change)
    }

    func segmented(_ titles: [String], selected: Int, _ change: @escaping (Int) -> Void) -> SegmentedPill {
        SegmentedPill(titles, selected: selected, onChange: change)
    }

    func button(_ title: String, style: PillButton.Style = .normal, enabled: Bool = true, _ action: @escaping () -> Void) -> PillButton {
        let button = PillButton(title, style: style, action: action)
        button.isEnabled = enabled
        return button
    }

    /// A slider that previews while dragging and commits on release.
    func slider(
        _ id: String,
        value: Double,
        range: ClosedRange<Double>,
        step: Double,
        suffix: String = "",
        preview: ((Double) -> Void)? = nil,
        commit: @escaping (Double) -> Void
    ) -> Slider {
        let slider = Slider(value: value, range: range, step: step, suffix: suffix, label: items[id]?.label ?? id)
        slider.onPreview = preview
        slider.onCommit = commit
        sliders.append(slider)
        return slider
    }

    // MARK: Layout

    /// The page's sections stacked: header, card, notes.
    func makeSections() -> [NSView] {
        var views: [NSView] = []
        for group in groups {
            let title = isSearching ? "\(group.category.title) › \(group.section)" : group.section
            if !(group.category == .commands && !isSearching) { views.append(SectionHeader(title)) }
            var card: Card?
            for block in group.blocks {
                switch block {
                case .row(let row):
                    if card == nil {
                        let new = Card()
                        views.append(new)
                        card = new
                    }
                    card?.addRow(row)
                case .below(let view):
                    views.append(view)
                    card = nil
                }
            }
        }
        return views
    }
}

/// Small horizontal stacks for controls with buttons beside them.
@MainActor
func hstack(_ views: [NSView], spacing: CGFloat = Metrics.controlGap) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
func vstack(_ views: [NSView], spacing: CGFloat = Metrics.controlGap, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}
