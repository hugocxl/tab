import Foundation
import XCTest
@testable import TabApp

final class ChangelogTests: XCTestCase {
    func testParsesVersionsSectionsAndWrappedEntries() {
        let changelog = Changelog(markdown: """
        # Changelog

        An introduction that is not a release.

        - Not an entry either.

        ## 1.1.0 - 2026-11-02

        ### Added

        - A `tab` command that wraps
          onto a second line.
        - Another entry.

        ### Fixed

        * A fix.

        ## 1.0.0

        - An entry directly under the version.
        """)
        XCTAssertEqual(changelog.releases, [
            Changelog.Release(version: "1.1.0", date: "2026-11-02", sections: [
                Changelog.Section(title: "Added", entries: ["A `tab` command that wraps onto a second line.", "Another entry."]),
                Changelog.Section(title: "Fixed", entries: ["A fix."]),
            ]),
            Changelog.Release(version: "1.0.0", date: nil, sections: [
                Changelog.Section(title: "", entries: ["An entry directly under the version."]),
            ]),
        ])
    }

    func testBetasAreListedUnderTheirRelease() {
        XCTAssertEqual(Changelog.releaseVersion(of: "1.2.0-beta.340"), "1.2.0")
        XCTAssertEqual(Changelog.releaseVersion(of: "1.2.0"), "1.2.0")
    }

    /// The repository's changelog is what the app shows and what
    /// `scripts/tag-release.sh` checks, so it must stay in this format.
    func testRepositoryChangelogListsEveryVersionNewestFirst() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("CHANGELOG.md")
        let changelog = Changelog(markdown: try String(contentsOf: file, encoding: .utf8))
        XCTAssertFalse(changelog.releases.isEmpty)
        var previous: [Int]?
        for release in changelog.releases {
            let parts = release.version.split(separator: ".").compactMap { Int($0) }
            XCTAssertEqual(parts.count, 3, "\(release.version) is not X.Y.Z")
            XCTAssertNotNil(release.date?.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression), "\(release.version) has no YYYY-MM-DD date")
            XCTAssertFalse(release.sections.flatMap(\.entries).isEmpty, "\(release.version) lists no changes")
            if let previous {
                XCTAssertTrue(parts.lexicographicallyPrecedes(previous), "\(release.version) is listed above an older version")
            }
            previous = parts
        }
    }
}
