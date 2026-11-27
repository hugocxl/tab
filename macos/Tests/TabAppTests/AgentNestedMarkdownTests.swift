import AppKit
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentNestedMarkdownTests: XCTestCase {
    func testUserMessageUsesInteractiveMarkdownAcrossCollapseAndRecreation() throws {
        _ = NSApplication.shared
        let source = """
        Please review:

        ```swift
        let value = 42
        ```

        | Item | Value |
        | --- | --- |
        | example | 42 |

        > A quoted explanation.

        More context below the fold.
        """
        let row = AgentMessageRow(frame: .zero)
        row.update([AgentChatItem(id: "user", kind: .user, text: source)])
        func place(_ row: AgentMessageRow) -> CGFloat {
            let height = row.preferredHeight(for: 600)
            row.frame = NSRect(x: 0, y: 0, width: 600, height: height)
            row.layoutRow(width: 600)
            return height
        }
        let collapsed = place(row)
        let response = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentResponseView }.first)
        XCTAssertEqual(response.frame.height, 176)
        XCTAssertNotNil(response.layer?.mask)
        let code = try XCTUnwrap(descendants(response).compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertEqual(code.code, "let value = 42\n")
        XCTAssertEqual(descendants(response).compactMap { $0 as? AgentResponseTable }.count, 1)
        code.wrap.perform()
        let expand = try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.title == "Show full message" })
        expand.perform()
        XCTAssertGreaterThan(place(row), collapsed)
        XCTAssertNil(response.layer?.mask)
        let recreated = AgentMessageRow(frame: .zero)
        recreated.update([AgentChatItem(id: "user", kind: .user, text: source)])
        recreated.restoreState(row.captureState())
        XCTAssertEqual(place(recreated), row.frame.height)
        XCTAssertFalse(try XCTUnwrap(descendants(recreated).compactMap { $0 as? AgentResponseCode }.first).wrapped)
    }

    func testUserRawHTMLPolicyPropagatesInsideQuotes() {
        let response = AgentResponseView(frame: .zero)
        response.parseRawHTML = false
        response.setContent("> <details open>\n> <summary>Raw HTML</summary>\n> body\n> </details>", theme: AppTheme(systemIsDark: false))
        let containers = descendants(response).compactMap { $0 as? AgentResponseContainer }
        XCTAssertEqual(containers.count, 1, "The quote must not create an HTML details widget for user text")
    }

    func testQuoteAndListKeepInteractiveCodeAndTableChildren() throws {
        _ = NSApplication.shared
        let source = """
        > Quoted code:
        >
        > ```swift
        > let quoted = true
        > ```

        - A nested table:

          | Name | Value |
          | --- | --- |
          | test | 42 |

          ```swift
          let nested = true
          ```
        """
        let response = AgentResponseView(frame: .zero)
        response.setContent(source, theme: AppTheme(systemIsDark: false))
        _ = response.height(for: 600)
        let children = descendants(response)
        let code = children.compactMap { $0 as? AgentResponseCode }
        XCTAssertEqual(code.map(\.code), ["let quoted = true\n", "let nested = true\n"])
        XCTAssertEqual(children.compactMap { $0 as? AgentResponseTable }.count, 1)
        XCTAssertGreaterThan(code[0].convert(.zero, to: response).x, 0)
        XCTAssertGreaterThan(code[1].convert(.zero, to: response).x, 0)
    }

    func testNestedDetailsAndWrapStateSurviveRecreationAndStreaming() throws {
        _ = NSApplication.shared
        let source = """
        <details>
        <summary>Implementation</summary>

        ```swift
        let text = "a long line of code that can be wrapped or scrolled without losing the user's selection"
        ```

        <details open>
        <summary>Nested details</summary>

        More information.
        </details>
        </details>
        """
        let theme = AppTheme(systemIsDark: true)
        let original = AgentResponseView(frame: .zero)
        original.setContent(source, theme: theme)
        let collapsed = original.height(for: 280)
        let details = try XCTUnwrap(original.subviews.compactMap { $0 as? AgentResponseContainer }.first)
        details.disclosure.perform()
        let expanded = original.height(for: 280)
        XCTAssertGreaterThan(expanded, collapsed)
        let code = try XCTUnwrap(descendants(original).compactMap { $0 as? AgentResponseCode }.first)
        code.wrap.perform()
        XCTAssertFalse(code.wrapped)
        let state = original.captureState()
        original.setContent(source + "\n\nStreaming tail", theme: theme)
        XCTAssertFalse(code.wrapped)
        XCTAssertTrue(details.captureState().expanded == true)
        let recreated = AgentResponseView(frame: .zero)
        recreated.setContent(source, theme: theme)
        recreated.restoreState(state)
        XCTAssertGreaterThan(recreated.height(for: 280), collapsed)
        XCTAssertFalse(try XCTUnwrap(descendants(recreated).compactMap { $0 as? AgentResponseCode }.first).wrapped)
        XCTAssertEqual(descendants(recreated).compactMap { $0 as? AgentResponseContainer }.count, 2)
    }

    func testUnclosedDetailsAndFenceRemainVisibleWhileStreaming() {
        let blocks = AgentMarkdown.blocks("<details open>\n<summary>Live</summary>\n\n```swift\nlet value =")
        guard case .details(let summary, let source, let open) = blocks.first else { return XCTFail("Expected details") }
        XCTAssertEqual(summary, "Live")
        XCTAssertTrue(open)
        XCTAssertEqual(AgentMarkdown.blocks(source), [.code("swift", "let value =\n", closed: false)])
    }
    func testAlertMarkersBecomeContainersAndCodeCannotCloseDetails() {
        let parts = AgentResponsePart.partition(AgentMarkdown.blocks("> [!WARNING]\n> Keep the original data."))
        XCTAssertEqual(parts, [.container(.alert("Warning"), "Keep the original data.")])
        let source = "<details open>\n<summary>HTML example</summary>\n\n```html\n</details>\n```\n\nStill inside.\n</details>"
        guard case .details(_, let nested, _) = AgentMarkdown.blocks(source).first else { return XCTFail("Missing details") }
        XCTAssertTrue(nested.contains("Still inside."))
        XCTAssertTrue(AgentMarkdown.blocks(nested).contains(.code("html", "</details>\n")))
    }

    func testRenderNestedMarkdownReference() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let source = """
        > [!NOTE]
        > Nested blocks keep their controls and formatting.
        >
        > ```swift
        > let answer = 42
        > ```

        - Inspect the result:

          | Name | Value |
          | --- | ---: |
          | Answer | 42 |

        <details open>
        <summary>Implementation details</summary>

        ```swift
        let result = calculateAnswer()
        ```

        <details>
        <summary>Additional notes</summary>

        This section starts collapsed.
        </details>
        </details>
        """
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let response = AgentResponseView(frame: .zero)
            response.setContent(source, theme: theme)
            let height = response.height(for: 576)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            background.frame = NSRect(x: 0, y: 0, width: 600, height: height + 24)
            background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            response.frame = NSRect(x: 12, y: 12, width: 576, height: height)
            background.addSubview(response)
            background.themeDidChange()
            background.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/nested-markdown-\(dark ? "dark" : "light").png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
