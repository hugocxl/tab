import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentToolVirtualizationTests: XCTestCase {
    func testFiveHundredToolsMountOnlyViewportAndBoundDetachedCache() {
        let view = AgentToolDetailView(items: tools(), theme: AppTheme(systemIsDark: true))
        XCTAssertEqual(view.mountedRowCount, 0, "Snapshots alone must not construct tool rows")
        XCTAssertEqual(view.height(for: 560), 360)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.mountedRowCount, 0)
        XCTAssertLessThanOrEqual(view.mountedRowCount, 20)
        XCTAssertLessThanOrEqual(view.measurementCount, 20)

        for index in stride(from: 0, through: 450, by: 30) {
            view.scrollOffset = NSPoint(x: 0, y: CGFloat(index * 32))
            view.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(view.mountedRowCount, 22)
            XCTAssertLessThanOrEqual(view.retainedRowCount, view.mountedRowCount + 24)
        }
        let measured = view.measurementCount
        for _ in 0..<10 {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(view.measurementCount, measured, "Stationary scrolling/layout must reuse measured rows")
    }

    func testDisclosureAndOuterScrollSurviveEvictionWithoutEagerExpansion() {
        let theme = AppTheme(systemIsDark: true)
        let items = tools()
        let view = AgentToolDetailView(items: items, theme: theme)
        view.expandedIDs = ["tool-0", "tool-400"]
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        view.layoutSubtreeIfNeeded()
        view.scrollOffset = NSPoint(x: 0, y: 6_400)
        view.layoutSubtreeIfNeeded()
        let state = (view.expandedIDs, view.scrollOffset)
        view.update(items: [], theme: theme)
        XCTAssertEqual(view.mountedRowCount, 0)
        XCTAssertEqual(view.retainedRowCount, 0)

        let restored = AgentToolDetailView(frame: .zero)
        var callbacks = 0
        restored.onDisclosure = { callbacks += 1 }
        restored.expandedIDs = state.0
        restored.scrollOffset = state.1
        XCTAssertEqual(restored.expandedIDs, state.0)
        restored.update(items: items, theme: theme)
        XCTAssertEqual(callbacks, 0, "Programmatic state restoration is not user disclosure")
        XCTAssertEqual(restored.mountedRowCount, 0)
        restored.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        restored.layoutSubtreeIfNeeded()
        XCTAssertEqual(restored.expandedIDs, state.0)
        XCTAssertEqual(restored.scrollOffset.y, state.1.y, accuracy: 0.1)
        XCTAssertLessThanOrEqual(restored.retainedRowCount, 22)
    }

    func testOffscreenOutputChangeDoesNotMeasureOrMoveViewport() {
        let theme = AppTheme(systemIsDark: true)
        var items = tools()
        let view = AgentToolDetailView(items: items, theme: theme)
        view.expandedIDs = ["tool-0"]
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 360)
        view.layoutSubtreeIfNeeded()
        view.scrollOffset = NSPoint(x: 0, y: 6_400)
        view.layoutSubtreeIfNeeded()
        let offset = view.scrollOffset
        let count = view.measurementCount
        items[0].detail = String(repeating: "Additional output\n", count: 1_000)
        view.update(items: items, theme: theme)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.measurementCount, count)
        XCTAssertEqual(view.scrollOffset.y, offset.y, accuracy: 0.1)
    }

    func testFocusedTextSelectionPinsAtMostOneOffscreenTool() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = AgentToolDetailView(items: tools(), theme: AppTheme(systemIsDark: true))
        view.expandedIDs = ["tool-0"]
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func textView(in parent: NSView) -> NSTextView? {
            if let text = parent as? NSTextView { return text }
            return parent.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: view))
        text.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertTrue(window.makeFirstResponder(text))
        for index in stride(from: 30, through: 450, by: 30) {
            view.scrollOffset = NSPoint(x: 0, y: CGFloat(index * 32))
            view.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.firstResponder === text)
            XCTAssertTrue(text.isDescendant(of: view))
            XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 4))
            XCTAssertLessThanOrEqual(view.mountedRowCount, 23)
            XCTAssertLessThanOrEqual(view.retainedRowCount, view.mountedRowCount + 24)
        }
        window.makeFirstResponder(nil)
    }

    private func tools() -> [AgentChatItem] {
        (0..<500).map { .init(id: "tool-\($0)", kind: .tool, text: "Read", detail: "File \($0) contents") }
    }
}
