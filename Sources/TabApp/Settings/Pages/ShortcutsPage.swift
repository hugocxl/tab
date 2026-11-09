import SwiftUI
import TabCore

/// Shortcut filtering stays on this page, independent of Settings search.
struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme
    @State private var query = ""

    var body: some View {
        Form {
            Section {
                HStack(spacing: 6) {
                    Image(.search, size: 13)
                        .foregroundStyle(.secondary)
                    TextField("Filter Shortcuts", text: $query, prompt: Text("Filter Shortcuts"))
                        .textFieldStyle(.plain)
                        .labelsHidden()
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(.circleXFill, size: 13)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear shortcut filter")
                        .accessibilityLabel("Clear shortcut filter")
                    }
                }
                .listRowBackground(theme?.card)
            } footer: {
                Text("Search by command, category, or key, such as cmd+k. Click a shortcut to record a new one.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            let groups = filteredGroups
            if groups.isEmpty {
                Section {
                    Text("No shortcuts match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(theme?.card)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(rows(of: group)) { row in
                        SettingRowView(row: row, model: model)
                            .listRowBackground(theme?.card)
                    }
                } header: {
                    Text(group.section)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }

    private func rows(of group: SettingsPageBuilder.Group) -> [SettingRow] {
        group.blocks.compactMap { block in
            if case .row(let row) = block { return row }
            return nil
        }
    }

    private var filteredGroups: [SettingsPageBuilder.Group] {
        (model.lastBuild?.groups ?? []).compactMap { group in
            var filtered = group
            filtered.blocks = group.blocks.filter { block in
                guard case .row(let row) = block,
                      let shortcut = ShortcutCatalog.find(String(row.id.dropFirst("shortcut.".count))) else { return false }
                return ShortcutFilter.matches(shortcut, query: query, keymap: model.store.settings.keymap)
            }
            return filtered.blocks.isEmpty ? nil : filtered
        }
    }
}

enum ShortcutFilter {
    /// Matches effective keys, including alternate defaults in their contexts.
    static func matches(_ shortcut: ShortcutDefinition, query: String, keymap: Keymap) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        let keys = shortcut.contexts.flatMap { keymap.keys(shortcut.name, context: $0) }
        let chordQuery = query.replacingOccurrences(of: "+", with: "-")
        if let chord = try? KeyChord(chordQuery), keys.contains(chord.rawValue) { return true }
        let text = ([shortcut.label, shortcut.name, shortcut.group.title] + keys + keys.compactMap { try? KeyChord($0).display })
            .joined(separator: " ").lowercased()
        return query.split(whereSeparator: \.isWhitespace).allSatisfy { text.contains($0) }
    }
}
