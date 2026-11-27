import AppKit
import TabCore
import XCTest
@testable import TabApp

/// Wrapped code keeps its shape: a long indented line continues under its indentation,
/// and the indentation never wraps onto a line of its own.
@MainActor
final class AgentCodeWrapIndentTests: XCTestCase {
    func testWrappedIndentedLineHangsUnderItsIndentation() throws {
        _ = NSApplication.shared
        let line = "    entry.inbox.releaseReservation(markingUncertain: true)"
        let response = AgentResponseView(frame: .zero)
        response.setContent("```swift\nfunc release() {\n" + line + "\n}\n```", theme: AppTheme(systemIsDark: false))
        for width: CGFloat in [260, 340] {
            response.frame = NSRect(x: 0, y: 0, width: width, height: response.height(for: width))
            response.layoutSubtreeIfNeeded()
            let code = try XCTUnwrap(response.subviews.first { $0 is AgentResponseCode } as? AgentResponseCode)
            let manager = try XCTUnwrap(code.text.layoutManager)
            let storage = try XCTUnwrap(code.text.textStorage)
            let start = (storage.string as NSString).range(of: line).location
            XCTAssertNotEqual(start, NSNotFound)
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: start, length: (line as NSString).length), actualCharacterRange: nil)
            var fragments: [(rect: NSRect, characters: NSRange)] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, range, _ in
                fragments.append((used, manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)))
            }
            XCTAssertGreaterThan(fragments.count, 1, "The line wraps at \(width)")
            let first = (storage.string as NSString).substring(with: fragments[0].characters)
            XCTAssertFalse(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "The indentation stays with the code it indents at \(width)")
            let space = (" " as NSString).size(withAttributes: [.font: AppFont.mono(13)]).width
            for fragment in fragments.dropFirst() {
                XCTAssertEqual(fragment.rect.minX, 4 * space, accuracy: 0.5, "Continuations hang under the indentation at \(width)")
            }
            XCTAssertTrue(code.code.hasPrefix("func release() {\n" + line + "\n}"), "Copying keeps the source as written")
        }
    }

    func testNarrowLanesGiveAnswersTheWholeWidthWithoutJumps() {
        XCTAssertEqual(AgentMessageRow.responseWidth(480), 480)
        XCTAssertEqual(AgentMessageRow.responseWidth(680), 680)
        XCTAssertEqual(AgentMessageRow.responseWidth(760), 680)
        XCTAssertEqual(AgentMessageRow.responseWidth(896), floor(896 * 0.8))
        var previous = AgentMessageRow.responseWidth(199)
        for lane in stride(from: CGFloat(200), through: 1000, by: 1) {
            let width = AgentMessageRow.responseWidth(lane)
            XCTAssertGreaterThanOrEqual(width, previous, "Widening a split never narrows the answer (\(lane))")
            XCTAssertLessThanOrEqual(width - previous, 1.01, "No jump at \(lane)")
            previous = width
        }
    }
}

/// Scrolling over a code block or tool output reaches the conversation when the block
/// can't use it, instead of trapping the pointer.
@MainActor
final class AgentPassThroughScrollTests: XCTestCase {
    private func event(dx: Int32 = 0, dy: Int32 = 0) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testVerticalScrollPassesAtTheEdgesAndSidewaysPassesWhenItFits() throws {
        let scroll = AgentPassThroughScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.hasVerticalScroller = true
        let document = AgentRichTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.documentView = document
        XCTAssertTrue(AgentPassThroughScrollView.passes(try event(dy: 10), scroll: scroll), "At the top, scrolling up goes on")
        XCTAssertFalse(AgentPassThroughScrollView.passes(try event(dy: -10), scroll: scroll), "Scrolling down stays in the output")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        XCTAssertTrue(AgentPassThroughScrollView.passes(try event(dy: -10), scroll: scroll), "At the bottom, scrolling down goes on")
        XCTAssertTrue(AgentPassThroughScrollView.passes(try event(dx: 10), scroll: scroll), "Nothing to scroll sideways")

        let code = AgentPassThroughScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        code.hasHorizontalScroller = true
        code.documentView = AgentRichTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 100))
        XCTAssertTrue(AgentPassThroughScrollView.passes(try event(dy: -10), scroll: code), "A sideways-only block passes vertical scrolling")
        XCTAssertFalse(AgentPassThroughScrollView.passes(try event(dx: -10), scroll: code))
    }
}
