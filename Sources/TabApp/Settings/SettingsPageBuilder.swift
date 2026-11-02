import AppKit
import TabCore

/// One setting on a page: its label, description, control and refusal.
struct SettingRow: Identifiable {
    let id: String
    let label: String
    let description: String?
    let control: SettingControl?
    /// The control goes under the label, full width, such as a list.
    let stacked: Bool
    let error: String?
}

/// Collects a page's rows in order, keeping only those the current page or
/// search shows, grouped into the sections the form shows. Pages call `row`
/// for every setting they offer; rows with an id missing from the catalog are
/// recorded in `unknownIds` (a bug the tests catch).
@MainActor
final class SettingsPageBuilder {
    enum Block {
        case row(SettingRow)
        /// Shown under the section's rows, such as a note.
        case below(SettingControl)
    }

    struct Group: Identifiable {
        let category: SettingsCategory
        let section: String
        var blocks: [Block]

        var id: String { "\(category.rawValue)/\(section)" }
    }

    let store: SettingsStore
    let query: String
    let category: SettingsCategory
    let subpage: SettingsSubpage?
    private let items: [String: SettingItem]
    private(set) var groups: [Group] = []
    private(set) var fields: [String: TextSpec] = [:]
    private(set) var rowIds: [String] = []
    private(set) var unknownIds: [String] = []

    init(store: SettingsStore, query: String, category: SettingsCategory, subpage: SettingsSubpage? = nil) {
        self.store = store
        self.query = query.trimmingCharacters(in: .whitespaces).lowercased()
        self.category = category
        self.subpage = subpage
        let index = SettingsCatalog.searchIndex()
        items = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var isSearching: Bool { !query.isEmpty }

    func item(_ id: String) -> SettingItem? { items[id] }

    /// Whether the row `id` is on screen: on the open page, or matching the
    /// search. Rows without a label, such as previews, never match a search.
    func shows(_ id: String) -> Bool {
        guard let item = items[id] else {
            unknownIds.append(id)
            return false
        }
        if isSearching { return !item.label.isEmpty && item.matches(query) }
        return item.category == category && item.subpage == subpage
    }

    /// Adds a row for `id` with its catalog label; `label` replaces it, such
    /// as for a custom command's name.
    @discardableResult
    func row(_ id: String, _ makeControl: @autoclosure () -> SettingControl?, stacked: Bool = false, label: String? = nil, description: String? = nil) -> SettingRow? {
        guard shows(id), let item = items[id] else { return nil }
        let row = SettingRow(
            id: id,
            label: label ?? item.label,
            description: description ?? (item.description.isEmpty ? nil : item.description),
            control: makeControl(),
            stacked: stacked,
            error: store.errors[id]
        )
        append(.row(row), item)
        rowIds.append(id)
        return row
    }

    /// Adds a control under the rows of `id`'s section, such as a note.
    func below(_ id: String, _ control: SettingControl) {
        guard shows(id), let item = items[id] else { return }
        append(.below(control), item)
    }

    func note(_ id: String, _ text: String, error: Bool = false) {
        below(id, .label(text, error ? .error : .note))
    }

    private func append(_ block: Block, _ item: SettingItem) {
        if let index = groups.firstIndex(where: { $0.category == item.category && $0.section == item.section }) {
            groups[index].blocks.append(block)
        } else {
            groups.append(Group(category: item.category, section: item.section, blocks: [block]))
        }
    }

    /// The rows on the page, in order.
    var rows: [SettingRow] {
        groups.flatMap(\.blocks).compactMap { block in
            if case .row(let row) = block { return row }
            return nil
        }
    }

    /// A section's title: its name, or "Page › Section" in search results.
    /// A subpage's own section has no title; the toolbar names it.
    func title(_ group: Group) -> String? {
        if isSearching { return "\(group.category.title) › \(group.section)" }
        if group.section == subpage?.title { return nil }
        return group.section
    }

    // MARK: Controls

    /// A text field saved on Return or leaving it.
    func field(
        _ id: String,
        _ value: String,
        placeholder: String = "",
        width: CGFloat? = Metrics.controlWidth,
        multiline: Bool = false,
        label: String? = nil,
        monospaced: Bool = false,
        enabled: Bool = true,
        change: ((String) -> Void)? = nil,
        commit: @escaping (String) -> Void
    ) -> SettingControl {
        let spec = TextSpec(
            id: id, value: value, placeholder: placeholder, label: label ?? items[id]?.label ?? id,
            width: width, multiline: multiline, monospaced: monospaced, enabled: enabled, change: change, commit: commit
        )
        fields[id] = spec
        return .text(spec)
    }

    func toggle(_ id: String, _ value: Bool, enabled: Bool = true, _ change: @escaping (Bool) -> Void) -> SettingControl {
        .toggle(ToggleSpec(isOn: value, label: items[id]?.label ?? id, enabled: enabled, change: change))
    }

    func popUp(_ id: String, _ choices: [Choice], selected: String, placeholder: String? = nil, label: String? = nil, _ change: @escaping (String) -> Void) -> SettingControl {
        .choice(ChoiceSpec(items: choices, selected: selected, label: label ?? items[id]?.label ?? id, placeholder: placeholder, change: change))
    }

    /// A button titled `title` that offers `choices` in a menu.
    func menu(_ id: String, _ title: String, _ choices: [Choice], _ choose: @escaping (String) -> Void) -> SettingControl {
        .choice(ChoiceSpec(items: choices, selected: "", label: items[id]?.label ?? id, placeholder: title, isMenu: true,
                           change: choose))
    }

    func stepper(_ id: String, _ value: Double, range: ClosedRange<Double>, step: Double = 1, unit: String? = nil,
                 _ commit: @escaping (Double) -> Void) -> SettingControl {
        .stepper(StepperSpec(value: value, range: range, step: step, unit: unit, label: items[id]?.label ?? id, commit: commit))
    }

    func segmented(_ id: String, _ titles: [String], selected: Int, _ change: @escaping (Int) -> Void) -> SettingControl {
        .segmented(SegmentedSpec(titles: titles, selected: selected, label: items[id]?.label ?? id, change: change))
    }

    func button(_ title: String, style: ButtonSpec.Style = .normal, enabled: Bool = true, symbol: String? = nil, help: String? = nil, _ action: @escaping () -> Void) -> SettingControl {
        .button(ButtonSpec(title: title, style: style, enabled: enabled, symbol: symbol, help: help, action: action))
    }
}
