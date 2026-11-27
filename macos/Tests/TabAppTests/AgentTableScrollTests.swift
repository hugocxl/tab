import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentTableScrollTests: XCTestCase {
    func testOverflowFadesFollowBrowserDistancesAndKeyboardFocus() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = AgentTableScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 568, height: 100))
        scroll.documentView = document
        window.contentView = scroll
        for (offset, leading, trailing) in [(0.0, 0.0, 24.0), (6, 6, 24), (40, 24, 24), (308, 24, 0)] {
            scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
            scroll.updateOverflowFade()
            XCTAssertEqual(scroll.leadingFade, leading)
            XCTAssertEqual(scroll.trailingFade, trailing)
            XCTAssertNotNil(scroll.contentView.layer?.mask)
            XCTAssertEqual(scroll.contentView.layer?.mask?.frame, scroll.contentView.layer?.bounds,
                           "The fade must cover the visible backing layer after scrolling")
        }
        XCTAssertTrue(window.makeFirstResponder(scroll))
        XCTAssertNil(scroll.contentView.layer?.mask)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNotNil(scroll.contentView.layer?.mask)
        document.setFrameSize(NSSize(width: 260, height: 100))
        scroll.contentView.scroll(to: .zero)
        scroll.updateOverflowFade()
        XCTAssertNil(scroll.contentView.layer?.mask)
        XCTAssertFalse(scroll.acceptsFirstResponder)
    }
}
