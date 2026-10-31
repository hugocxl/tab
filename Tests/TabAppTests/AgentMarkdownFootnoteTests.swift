import AppKit
import XCTest
import TabCore
@testable import TabApp

@MainActor
final class AgentMarkdownFootnoteTests: XCTestCase {
    private let source = """
    ## Research notes

    The result is reproducible[^method], with one caveat[^limit]. The method is documented again[^method].

    > A reference inside a quote[^limit].

    | Check | Evidence |
    | --- | --- |
    | Repeated run | Stable[^method] |

    [^method]: Run the experiment twice using the [same configuration][config].

        ```swift
        let repeats = 2
        ```

        Both runs produced the same result.

    [^limit]: The sample is small. **Further testing** is needed.
    [config]: https://example.com/config
    [^unused]: This unreferenced note must not appear.
    """

    func testOrderRepeatedBacklinksAndRichNoteBodies() throws {
        let prepared = AgentMarkdownFootnotes.prepare(AgentMarkdown.blocks(source), parseRawHTML: true)
        guard case .footnotes(let notes) = prepared.last else { return XCTFail("Missing footnotes") }
        XCTAssertEqual(notes.map(\.id), ["fn-method", "fn-limit"])
        XCTAssertEqual(notes.map(\.number), [1, 2])
        XCTAssertTrue(notes[0].blocks.contains(.code("swift", "let repeats = 2\n")))
        guard case .paragraph(let last) = notes[0].blocks.last else { return XCTFail("Missing backrefs") }
        XCTAssertTrue(last.contains("fnref-method-3"))
        XCTAssertFalse(String(describing: prepared).contains("This unreferenced note"))
        let literal = AgentMarkdownFootnotes.rewrite("`[^method]` \\[^method] [link](path/[^method]) [^unknown]") { $0 == "method" ? "REPLACED" : nil }
        XCTAssertEqual(literal, "`[^method]` \\[^method] [link](path/[^method]) [^unknown]")
    }

    func testFootnotesAreSelectableAndNavigateBothWaysIncludingTableReferences() throws {
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let response = AgentResponseView(frame: .zero)
        response.setContent(source, theme: theme)
        let height = response.height(for: 560)
        response.frame = NSRect(x: 0, y: 0, width: 560, height: height)
        response.layoutSubtreeIfNeeded()
        XCTAssertEqual(response.subviews.compactMap { $0 as? AgentResponseFootnotes }.count, 1)
        for id in ["fn-method", "fn-limit", "fnref-method", "fnref-method-2", "fnref-method-3", "fnref-limit-2"] {
            XCTAssertTrue(response.openFragment(id), "Missing navigation target \(id)")
        }
        let note = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseFootnotes }.first)
        let texts = descendants(note).compactMap { $0 as? AgentRichTextView }
        let number = try XCTUnwrap(texts.first { $0.string == "1." })
        XCTAssertGreaterThan(try XCTUnwrap(number.textContainer).containerSize.width, 10)
        let body = try XCTUnwrap(texts.first { $0.string.contains("Run the experiment") })
        XCTAssertEqual((body.attributedString().attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 12)
        XCTAssertTrue(body.isSelectable)
        let references = descendants(response).compactMap { $0 as? AgentRichTextView }.flatMap { links($0) }
        XCTAssertTrue(references.contains { $0.absoluteString == "https://example.com/config" })
        let backlink = try XCTUnwrap(references.first { $0.scheme == "tab-agent-footnote" && $0.host == "back" })
        XCTAssertEqual(AgentResponseLink.parse(backlink.absoluteString), .fragment("fnref-method"))
    }

    func testStreamingDefinitionReplacesLiteralReferenceAndKeepsCodeState() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: false)
        let prefix = "Reference[^later].\n\n```swift\nlet value = 1\n```"
        response.setContent(prefix, theme: theme)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        code.wrap.perform()
        response.setContent(prefix + "\n\n[^later]: Added at the end.", theme: theme)
        XCTAssertTrue(response.subviews.contains { $0 === code })
        XCTAssertFalse(code.wrapped)
        XCTAssertTrue(response.openFragment("fn-later"))
        XCTAssertFalse(descendants(response).compactMap { $0 as? AgentRichTextView }.contains { $0.string.contains("Reference[^later]") })
    }

    func testFootnoteSnapshots() throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let response = AgentResponseView(frame: .zero)
            response.setContent(source, theme: theme)
            let height = response.height(for: 576)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            background.frame = NSRect(x: 0, y: 0, width: 600, height: height + 32)
            background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            response.frame = NSRect(x: 12, y: 16, width: 576, height: height)
            background.addSubview(response)
            background.themeDidChange()
            background.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/footnotes-\(dark ? "dark" : "light").png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func links(_ view: AgentRichTextView) -> [URL] {
        var result: [URL] = []
        let text = view.attributedString()
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let url = value as? URL { result.append(url) }
        }
        return result
    }
}
