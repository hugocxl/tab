import Foundation

/// The versions listed in `CHANGELOG.md`, newest first. The file is a
/// Markdown list per version:
///
///     ## 1.2.0 - 2026-10-30
///
///     ### Added
///
///     - An entry, wrapped onto
///       indented lines.
///
/// Text before the first version is the file's introduction and is skipped.
struct Changelog: Equatable {
    struct Release: Equatable, Identifiable {
        let version: String
        let date: String?
        var sections: [Section]

        var id: String { version }
    }

    struct Section: Equatable, Identifiable {
        /// Such as "Added" or "Fixed"; empty for entries directly under the
        /// version.
        let title: String
        var entries: [String]

        var id: String { title }
    }

    var releases: [Release]

    init(releases: [Release]) {
        self.releases = releases
    }

    init(markdown: String) {
        var releases: [Release] = []
        var continues = false
        for line in markdown.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                releases.append(Self.release(heading: String(line.dropFirst(3))))
                continues = false
                continue
            }
            guard !releases.isEmpty else { continue }
            let last = releases.count - 1
            if line.hasPrefix("### ") {
                releases[last].sections.append(Section(title: text.dropFirst(4).trimmingCharacters(in: .whitespaces), entries: []))
                continues = false
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                if releases[last].sections.isEmpty { releases[last].sections.append(Section(title: "", entries: [])) }
                releases[last].sections[releases[last].sections.count - 1].entries.append(String(text.dropFirst(2)))
                continues = true
            } else if text.isEmpty {
                continues = false
            } else if continues, line.first?.isWhitespace == true {
                let section = releases[last].sections.count - 1
                let entry = releases[last].sections[section].entries.count - 1
                releases[last].sections[section].entries[entry] += " " + text
            }
        }
        self.releases = releases
    }

    /// "1.2.0 - 2026-10-30", or just the version.
    private static func release(heading: String) -> Release {
        let parts = heading.components(separatedBy: " - ")
        let version = parts[0].trimmingCharacters(in: .whitespaces)
        let date = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return Release(version: version, date: date, sections: [])
    }

    /// The changelog the app bundle carries, copied from the repository's
    /// `CHANGELOG.md` by `scripts/bundle.sh`; nil when this build has none,
    /// such as `swift run`.
    static func bundled(_ bundle: Bundle = .main) -> Changelog? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Changelog(markdown: text)
    }

    /// The release a build of `version` is: betas, `X.Y.Z-beta.N`, are
    /// listed under `X.Y.Z`.
    static func releaseVersion(of version: String) -> String {
        String(version.prefix { $0 != "-" })
    }
}
