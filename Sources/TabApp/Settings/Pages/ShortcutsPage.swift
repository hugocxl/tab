import SwiftUI
import TabCore

/// Shortcut filtering stays on this page, independent of Settings search.
struct ShortcutsPage: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.settingsTheme) private var theme
    @State private var query = ""

    var body: some View {
        SwiftUI.ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter Shortcuts…", text: $query)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Filter Shortcuts")
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Clear shortcut filter")
                            .accessibilityLabel("Clear shortcut filter")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .overlay(Capsule().strokeBorder((theme?.secondaryText ?? .secondary).opacity(0.35)))

                    Text("Search by command, category, or key, such as cmd+k. Click a shortcut to record a new one.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }

                let groups = filteredGroups
                if groups.isEmpty {
                    Text("No shortcuts match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.section)
                            .font(.headline)
                            .padding(.horizontal, 12)
                        VStack(spacing: 0) {
                            let rows = group.blocks.compactMap { block -> SettingRow? in
                                if case .row(let row) = block { return row }
                                return nil
                            }
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { SwiftUI.Divider().padding(.horizontal, 12) }
                                SettingRowView(row: row, model: model)
                                    .labeledContentStyle(ShortcutRowStyle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                            }
                        }
                        .background(theme?.card ?? .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(20)
        }
        .background { theme?.background.ignoresSafeArea() }
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

private struct ShortcutRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 16)
            configuration.content
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
