import XCTest
import TabCore
@testable import TabApp

@MainActor
final class PaletteTests: XCTestCase {
    private func item(_ id: String, disabled: Bool = false) -> PaletteItem {
        var item = PaletteItem(id: id, title: id, target: .apply {})
        item.disabled = disabled
        return item
    }

    func testSelectionSkipsDisabledRowsWrapsAndSurvivesReorders() {
        var page = PageState(spec: PageSpec(.root, placeholder: ""), content: PageContent(sections: [
            PaletteSection("Local", [item("main", disabled: true), item("feature")]),
            PaletteSection("Remote", [item("origin")]),
            PaletteSection("Empty", []),
        ]))
        XCTAssertEqual(page.selected, "feature")
        XCTAssertEqual(page.counts.sections, 2)
        XCTAssertEqual(page.counts.items, 3)
        XCTAssertTrue(page.moveSelection(1))
        XCTAssertEqual(page.selected, "origin")
        XCTAssertTrue(page.moveSelection(1))
        XCTAssertEqual(page.selected, "feature", "wraps around")
        page.select("origin")
        page.setContent(.items([item("origin"), item("feature")]))
        XCTAssertEqual(page.selected, "origin", "the selection follows its item")
        XCTAssertEqual(page.selectedRow, 0)
        page.setContent(.loading("Loading…"))
        XCTAssertNil(page.selected, "no selection while a status shows")
    }

    /// Folder matches arrive after the query changed; Return must open the
    /// match, not the "Choose in Finder…" row that was first a moment before.
    func testLateResultsTakeTheSelectionUntilTheUserPicks() {
        var page = PageState(spec: PageSpec(.root, placeholder: ""), content: .items([item("finder")]))
        page.queryChanged("/tmp/proj")
        page.setContent(.items([item("folder"), item("finder")]))
        XCTAssertEqual(page.selected, "folder")
        page.moveSelection(1)
        page.setContent(.items([item("folder2"), item("folder"), item("finder")]))
        XCTAssertEqual(page.selected, "finder", "a picked row stays picked")
    }

    /// Heights come from row counts: header, sections, rows, list insets and
    /// footer, capped at 480pt plus the border.
    func testHeightsComeFromRowCounts() {
        XCTAssertEqual(PaletteLayout.height(sections: 1, items: 2, list: true), 56 + 28 + 80 + 12 + 40 + 2)
        XCTAssertEqual(PaletteLayout.height(sections: 0, items: 0, list: false), 56 + 96 + 40 + 2)
        XCTAssertEqual(PaletteLayout.height(sections: 3, items: 40, list: true), 480 + 2)
    }

    /// Titles outrank keywords; ties go to the earlier category, then the
    /// shorter title; recent commands lead the empty page.
    func testRootRankingAndRecentCommands() {
        let commands = [
            RootCommand(id: "a", title: "Toggle Files", keywords: "explorer", category: .files, target: .apply {}),
            RootCommand(id: "b", title: "Find in Files…", keywords: "search grep", category: .files, target: .apply {}),
            RootCommand(id: "c", title: "New Terminal", category: .terminal, target: .apply {}),
            RootCommand(id: "d", title: "Split Right", category: .panes, disabled: true, target: .apply {}),
        ]
        XCTAssertEqual(RootRanking.ranked(commands, query: "files").map(\.id).first, "a")
        XCTAssertEqual(RootRanking.ranked(commands, query: "grep").map(\.id), ["b"], "keywords find commands too")
        XCTAssertTrue(RootRanking.ranked(commands, query: "grep")[0].highlights.isEmpty, "keyword hits draw no highlight")
        let sections = RootRanking.sections(commands, recent: ["c", "d", "missing"])
        XCTAssertEqual(sections.first?.title, "Suggestions")
        XCTAssertEqual(sections.first?.items.map(\.id), ["c"], "disabled and unknown recents are skipped")
        XCTAssertEqual(sections.map(\.title), ["Suggestions", "Panes", "Files"])
    }

    /// Pushing a page keeps the root under it; Escape goes back, then closes.
    func testPageStackNavigation() throws {
        let dirs = try ModelFixtures.profile()
        let model = AppModel(dirs: dirs, theme: AppTheme(systemIsDark: true)) { _, _ in nil }
        let source = PaletteSource(model: model)
        let palette = PaletteController(parent: nil)
        palette.source = source
        source.palette = palette
        palette.open(.themes)
        XCTAssertEqual(palette.depth, 2)
        XCTAssertEqual(palette.page, .themes)
        XCTAssertEqual(palette.current?.spec.breadcrumb, "Change Theme")
        XCTAssertTrue(palette.pop())
        XCTAssertEqual(palette.page, .root)
        XCTAssertFalse(palette.pop(), "the root page has nothing under it")
        palette.push(.files, query: "read")
        XCTAssertEqual(palette.page, .files)
        XCTAssertEqual(palette.query, "read")
        let root = source.content(for: .root, query: "")
        XCTAssertTrue(root.sections.contains { $0.title == "Terminal" })
        let newTerminal = root.sections.flatMap(\.items).first { $0.id == ShortcutId.newTab.rawValue }
        XCTAssertEqual(newTerminal?.shortcut, try KeyChord("cmd-t"), "rows show the keymap's keys")
        XCTAssertEqual(newTerminal?.kind, "Command")
    }

    func testTypedPathsBrowseAndComplete() throws {
        let root = try ModelFixtures.folder("browse")
        for name in ["alpha-one", "alpha-two", "beta"] {
            try FileManager.default.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        }
        XCTAssertEqual(FolderBrowse.matches(root + "/al").map { ($0 as NSString).lastPathComponent }, ["alpha-one", "alpha-two"])
        XCTAssertEqual(FolderBrowse.complete(root + "/al"), root + "/alpha-")
        XCTAssertEqual(FolderBrowse.complete(root + "/be"), root + "/beta/")
        XCTAssertEqual(FolderBrowse.items(root + "/").first, root)
    }
}
