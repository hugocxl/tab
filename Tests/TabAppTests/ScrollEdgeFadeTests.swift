import AppKit
import XCTest
@testable import TabApp

@MainActor
final class ScrollEdgeFadeTests: XCTestCase {
    func testEdgesFadeOnlyWhereContentContinues() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scroll.documentView = document
        window.contentView = scroll
        let fade = ScrollEdgeFade(scroll)
        for (offset, top, bottom) in [(0.0, 0.0, 24.0), (10, 10, 24), (150, 24, 24), (290, 24, 10), (300, 24, 0)] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            XCTAssertEqual(fade.topFade, top, "offset \(offset)")
            XCTAssertEqual(fade.bottomFade, bottom, "offset \(offset)")
            XCTAssertEqual(scroll.contentView.layer?.mask?.frame, scroll.contentView.layer?.bounds,
                           "The fade must cover the visible backing layer after scrolling")
        }
        document.setFrameSize(NSSize(width: 200, height: 80))
        XCTAssertEqual(fade.topFade, 0)
        XCTAssertEqual(fade.bottomFade, 0)
        XCTAssertNil(scroll.contentView.layer?.mask)
    }
}
