import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentResponsePerformanceTests: XCTestCase {
    private let source = """
    A completed paragraph with **formatting**.

    ```swift
    let complete = true
    let longLine = "A deliberately long line that should wrap in a narrow response column and retain its own native text selection."
    ```

    | Name | State |
    | --- | --- |
    | Completed table | Ready |

    The streaming tail
    """

    func testTrailingStreamUpdatesOnlyOneSectionAndReusesCompletedMeasurements() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let theme = AppTheme(systemIsDark: true)
        response.setContent(source, theme: theme)
        let height = response.height(for: 640)
        response.frame = NSRect(x: 0, y: 0, width: 640, height: height)
        response.layoutSubtreeIfNeeded()
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        code.text.setSelectedRange(NSRange(location: 0, length: 3))
        let initialUpdates = response.sectionUpdateCount
        let initialMeasurements = response.sectionMeasurementCount
        let initialLineScans = code.longestLineScanCount
        XCTAssertEqual(initialUpdates, 4, "The fixture has prose, code, table, and trailing prose")

        for _ in 0..<50 { _ = response.height(for: 640) }
        XCTAssertEqual(response.sectionMeasurementCount, initialMeasurements)
        for token in 1...25 {
            response.setContent(source + String(repeating: " token", count: token), theme: theme)
            _ = response.height(for: 640)
        }
        XCTAssertEqual(response.sectionUpdateCount - initialUpdates, 25,
                       "Completed prose, code and table must not rebuild attributed text")
        XCTAssertEqual(response.sectionMeasurementCount - initialMeasurements, 25,
                       "Only the growing tail should run TextKit measurement")
        XCTAssertEqual(code.longestLineScanCount, initialLineScans)
        XCTAssertEqual(code.text.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertTrue(code === response.subviews.compactMap { $0 as? AgentResponseCode }.first)

        let beforeResize = response.sectionMeasurementCount
        _ = response.height(for: 360)
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
        XCTAssertEqual(code.longestLineScanCount, initialLineScans,
                       "A width change must not rescan unchanged source lines")
        for _ in 0..<50 { _ = response.height(for: 360) }
        XCTAssertEqual(response.sectionMeasurementCount - beforeResize, 4)
    }

    func testWrapStateSurvivesEvictionAndRestoresSilently() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let original = AgentResponseView(frame: .zero)
        original.setContent(source, theme: theme)
        let code = try XCTUnwrap(original.subviews.compactMap { $0 as? AgentResponseCode }.first)
        XCTAssertTrue(code.wrapped, "Conversation defaults code blocks to wrapped text")
        code.setWrapped(false)
        let unwrappedHeight = original.height(for: 280)
        var userChanges = 0
        original.onHeightChanged = { userChanges += 1 }
        code.wrap.perform()
        XCTAssertEqual(userChanges, 1)
        XCTAssertTrue(code.wrapped)
        let metadata = original.wrappedCodeSections
        XCTAssertEqual(metadata, [1], "Indices address all response sections, not just code sections")

        let recreated = AgentResponseView(frame: .zero)
        recreated.setContent(source, theme: theme)
        var restoreCallbacks = 0
        recreated.onHeightChanged = { restoreCallbacks += 1 }
        recreated.wrappedCodeSections = metadata
        let wrappedHeight = recreated.height(for: 280)
        XCTAssertEqual(restoreCallbacks, 0, "Restoration must not recursively reflow the virtualizer")
        XCTAssertEqual(recreated.wrappedCodeSections, metadata)
        XCTAssertGreaterThan(wrappedHeight, unwrappedHeight)

        let measured = recreated.sectionMeasurementCount
        recreated.wrappedCodeSections = metadata
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured, "Idempotent restore must not invalidate caches")
        recreated.wrappedCodeSections = []
        _ = recreated.height(for: 280)
        XCTAssertEqual(recreated.sectionMeasurementCount, measured + 1, "Only the changed code section is remeasured")
        XCTAssertEqual(restoreCallbacks, 0)
    }

    func testThemeInvalidatesSectionCachesButDoesNotRescanCodeWidth() throws {
        _ = NSApplication.shared
        let response = AgentResponseView(frame: .zero)
        let catalog = ThemeCatalog.load(customDirectory: nil)
        let dark = AppTheme(catalog: catalog, systemIsDark: true)
        let light = AppTheme(catalog: catalog, systemIsDark: false)
        XCTAssertNotEqual(dark.palette, light.palette)
        response.setContent(source, theme: dark)
        _ = response.height(for: 640)
        let code = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseCode }.first)
        let updates = response.sectionUpdateCount
        let measurements = response.sectionMeasurementCount
        let lineScans = code.longestLineScanCount
        response.setContent(source, theme: light)
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionUpdateCount, updates + 4)
        XCTAssertEqual(response.sectionMeasurementCount, measurements + 4)
        XCTAssertEqual(code.longestLineScanCount, lineScans)
        let afterTheme = response.sectionMeasurementCount
        _ = response.height(for: 640)
        XCTAssertEqual(response.sectionMeasurementCount, afterTheme)
    }

    /// A long answer of plain paragraphs is one prose section; streaming its last
    /// paragraph must render that paragraph alone and leave the earlier text in place.
    func testLongProseStreamingRendersOnlyTheTail() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let paragraphs = (1...200).map { "Paragraph \($0) with **bold** text and a `code` span that wraps across a line or two." }
        let response = AgentResponseView(frame: .zero)
        response.isStreaming = true
        response.setContent(paragraphs.joined(separator: "\n\n"), theme: theme)
        _ = response.height(for: 640)
        let prose = try XCTUnwrap(response.subviews.compactMap { $0 as? AgentResponseProse }.first)
        XCTAssertEqual(response.subviews.compactMap { $0 as? AgentResponseProse }.count, 1)
        let before = prose.renderCache.renderedBlocks
        let start = Date()
        for token in 1...25 {
            response.setContent(paragraphs.joined(separator: "\n\n") + String(repeating: " more", count: token), theme: theme)
            _ = response.height(for: 640)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(prose.renderCache.renderedBlocks - before, 25, "Each update renders only the growing paragraph")
        // About 0.3 s on an M1 in a debug build; a full re-render of every paragraph took 2 s.
        XCTAssertLessThan(elapsed, 1, "25 updates of a 200-paragraph answer took \(elapsed) s")
        let streamed = prose.text.attributedString()
        let fresh = AgentResponseView(frame: .zero)
        fresh.isStreaming = true
        fresh.setContent(paragraphs.joined(separator: "\n\n") + String(repeating: " more", count: 25), theme: theme)
        let reference = try XCTUnwrap(fresh.subviews.compactMap { $0 as? AgentResponseProse }.first).text.attributedString()
        XCTAssertTrue(streamed.isEqual(to: reference), "Reused blocks must render exactly as a fresh render")
    }

    func testOnlyTheChangedParagraphsAreReplaced() {
        let old = NSAttributedString(string: "First\nSecond\nThird")
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "First\nSecond\nThird and more")), 13)
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "First\nSecond\nThird\nFourth")), 13)
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, NSAttributedString(string: "Other")), 0)
        let restyled = NSMutableAttributedString(string: "First\nSecond\nThird more")
        restyled.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 2))
        XCTAssertEqual(AgentRichTextView.unchangedParagraphs(old, restyled), 0, "Changed attributes in the prefix replace everything")
    }

    func testTextScaleSizesConversationText() throws {
        _ = NSApplication.shared
        defer { AgentTextScale.set(1) }
        let theme = AppTheme(systemIsDark: true)
        let normal = AgentMarkdown.render(AgentMarkdown.blocks("Body"), theme: theme)
        XCTAssertTrue(AgentTextScale.step(larger: true))
        let larger = AgentMarkdown.render(AgentMarkdown.blocks("Body"), theme: theme)
        let normalSize = try XCTUnwrap(normal.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        let largerSize = try XCTUnwrap(larger.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).pointSize
        XCTAssertGreaterThan(largerSize, normalSize)
        AgentTextScale.set(AgentTextScale.steps.last ?? 1)
        XCTAssertFalse(AgentTextScale.step(larger: true), "The scale stops at its largest step")
    }

    /// A long streamed answer of mixed Markdown, the workload profiled for parse cost
    /// against layout and drawing: 24 sections, each a heading, two paragraphs with
    /// emphasis, code spans and reference links, a five-item list, a 12-line Swift fence
    /// and a 6-row table, with every reference defined at the end (about 35 KB).
    static func longStreamedWorkload() -> String {
        var parts: [String] = []
        for section in 1...24 {
            parts.append("## Section \(section): measured work")
            parts.append("This paragraph explains step \(section) with **bold**, *emphasis*, `inline code`, and a [reference link][ref\(section)] "
                + "that resolves only once its definition, at the very end, arrives. It is long enough to wrap across several lines.")
            parts.append((1...5).map { "- Item \($0) of section \(section) with `code` and a [link](https://example.com/\(section)/\($0))" }
                .joined(separator: "\n"))
            parts.append("```swift\n" + (1...12).map { "let value\($0) = compute(\(section), \($0)) // line \($0)" }.joined(separator: "\n") + "\n```")
            parts.append("| Name | Value | Notes |\n| --- | --- | --- |\n"
                + (1...6).map { "| row \($0) | \($0 * section) | note for **\($0)** |" }.joined(separator: "\n"))
            parts.append("A closing paragraph for section \(section), with a footnote-free summary and ~~struck~~ text.")
        }
        parts.append((1...24).map { "[ref\($0)]: https://example.com/reference/\($0)" }.joined(separator: "\n"))
        return parts.joined(separator: "\n\n")
    }

    /// T7: profiles the response surface on a long streamed answer, timing the parse
    /// (tail hold-back, block parse, tail repair, references and footnotes) separately
    /// from building sections, layout and drawing, for identical cumulative updates.
    ///
    /// Recorded November 2026 on an Apple silicon Mac, 34,924 bytes in 175 cumulative
    /// updates of 200 bytes (the server publishes at most one update per 50 ms), 640 pt wide:
    ///
    /// | Build   | Parse total / p95 / last | Build sections | Layout total / p95 | Draw total / p95 |
    /// | ------- | ------------------------ | -------------- | ------------------ | ---------------- |
    /// | debug   | 967 ms / 10.1 / 12.0 ms  | 1,263 ms       | 1,637 / 12.9 ms    | 1,618 / 14.1 ms  |
    /// | release | 425 ms / 4.4 / 5.6 ms    | 912 ms         | 1,530 / 12.2 ms    | 1,554 / 13.8 ms  |
    ///
    /// Parsing is about a tenth of each update in release and grows linearly with the
    /// answer; layout and drawing dominate. The one costly update is the last, where the
    /// reference definitions arrive and every paragraph citing them renders again
    /// (88 ms building, 68 ms layout in release), which is section work, not parsing. The
    /// parser doesn't stall the main thread, so it is kept as it is; this test guards that
    /// measured result and that late definitions resolve like a nonstreamed render.
    func testLongStreamedResponseParsingStaysASmallShareOfLayoutAndDrawing() throws {
        _ = NSApplication.shared
        let theme = AppTheme(systemIsDark: true)
        let source = Self.longStreamedWorkload()
        let bytes = Array(source.utf8)
        let chunk = 200
        let response = AgentResponseView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
        response.isStreaming = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(response)
        var parse: [Double] = [], apply: [Double] = [], layout: [Double] = [], draw: [Double] = []
        func time(_ work: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            work()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        var end = 0
        while end < bytes.count {
            end = min(bytes.count, end + chunk)
            let prefix = String(decoding: bytes[..<end], as: UTF8.self)
            // The parse phase exactly as `setContent` runs it.
            parse.append(time {
                let held = AgentStreamingCompletion.holdingBackAmbiguousTail(prefix)
                let blocks = AgentStreamingCompletion.completingLastBlock(AgentResponseParser.parse(held))
                _ = AgentMarkdownReferences.collect(blocks, parseRawHTML: true)
                _ = AgentMarkdownFootnotes.prepare(blocks, parseRawHTML: true)
            })
            apply.append(time { response.setContent(prefix, theme: theme) } - (parse.last ?? 0))
            layout.append(time {
                let height = response.height(for: 640)
                response.frame.size.height = height
                response.layoutSubtreeIfNeeded()
            })
            // The visible tail, as the transcript draws it while following the stream.
            let visible = NSRect(x: 0, y: max(0, response.frame.height - 600), width: 640, height: min(600, response.frame.height))
            draw.append(time {
                guard let rep = response.bitmapImageRepForCachingDisplay(in: visible) else { return }
                response.cacheDisplay(in: visible, to: rep)
            })
        }
        func summary(_ values: [Double]) -> String {
            let sorted = values.sorted()
            return String(format: "total %.0f ms, last %.2f ms, p95 %.2f ms, max %.2f ms", values.reduce(0, +), values.last ?? 0,
                          sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last ?? 0)
        }
        let report = """
        T7 workload: \(bytes.count) bytes in \(parse.count) updates of \(chunk) bytes, 640 pt wide
          parse:  \(summary(parse))
          build:  \(summary(apply))
          layout: \(summary(layout))
          draw:   \(summary(draw))
        """
        print(report)
        XCTContext.runActivity(named: report) { _ in }
        // The finished answer resolves the late references like a nonstreamed render.
        response.isStreaming = false
        response.setContent(source, theme: theme)
        _ = response.height(for: 640)
        let fresh = AgentResponseView(frame: .zero)
        fresh.setContent(source, theme: theme)
        _ = fresh.height(for: 640)
        XCTAssertEqual(response.textViews.map(\.string), fresh.textViews.map(\.string))
        func links(_ view: AgentResponseView) -> [String] {
            view.textViews.flatMap { text -> [String] in
                guard let storage = text.textStorage else { return [] }
                var found: [String] = []
                storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let value { found.append("\(value)") }
                }
                return found
            }
        }
        XCTAssertEqual(links(response), links(fresh), "Late reference definitions resolve in blocks that streamed before them")
        XCTAssertTrue(links(response).contains("https://example.com/reference/1"))
        // Parsing the whole answer stays well inside the 50 ms between published updates at
        // the end of the stream, and a minority of the work the updates do.
        let lastParse = parse.suffix(10).reduce(0, +) / 10
        XCTAssertLessThan(lastParse, 50, report)
        XCTAssertLessThan(parse.reduce(0, +), (apply.reduce(0, +) + layout.reduce(0, +) + draw.reduce(0, +)) / 2, report)
    }
}
