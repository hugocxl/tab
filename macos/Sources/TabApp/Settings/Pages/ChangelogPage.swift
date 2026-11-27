import SwiftUI
import TabCore

/// The Changelog page: a section per version, newest first, with this
/// build's version marked.
struct ChangelogPage: View {
    let changelog: Changelog?
    let installed: String
    @Environment(\.settingsTheme) private var theme

    var body: some View {
        Form {
            if let changelog, !changelog.releases.isEmpty {
                ForEach(changelog.releases) { release in
                    Section {
                        ForEach(release.sections) { section in
                            ChangelogSection(section: section)
                                .listRowBackground(theme?.card)
                        }
                    } header: {
                        header(release)
                    }
                }
            } else {
                Section {
                    Text("This build doesn’t include the changelog.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background { theme?.background.ignoresSafeArea() }
    }

    private func header(_ release: Changelog.Release) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(release.version)
            if release.version == Changelog.releaseVersion(of: installed) {
                Text("Installed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme?.accent ?? .accentColor)
            }
            Spacer()
            if let date = release.date {
                Text(date).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// One kind of change, such as "Fixed", and its entries as a bulleted list.
private struct ChangelogSection: View {
    let section: Changelog.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !section.title.isEmpty {
                Text(section.title).font(.headline)
            }
            ForEach(section.entries.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(Self.inline(section.entries[index]))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// An entry's inline Markdown, such as `code` and **bold**.
    private static func inline(_ entry: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: entry, options: options)) ?? AttributedString(entry)
    }
}
