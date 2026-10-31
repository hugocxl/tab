import AppKit
import XCTest
@testable import TabApp

@MainActor
final class AgentZoomableImageTests: XCTestCase {
    func testDragPansWithoutTogglingZoomAndClickReturnsToFit() throws {
        let view = AgentMediaPreviewView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        view.image.image = NSImage(size: NSSize(width: 1200, height: 600))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.scroll.changeZoom(2)
        view.scroll.scroll(to: NSPoint(x: 100, y: 50))
        let start = view.scroll.convert(NSPoint(x: 40, y: 40), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        view.image.mouseDown(with: try mouse(.leftMouseDown, start))
        let moved = NSPoint(x: start.x + 12, y: start.y - 8)
        view.image.mouseDragged(with: try mouse(.leftMouseDragged, moved))
        view.image.mouseUp(with: try mouse(.leftMouseUp, moved))
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertEqual(view.scroll.contentView.bounds.minX, 88, accuracy: 0.01)
        XCTAssertEqual(view.scroll.contentView.bounds.minY, 42, accuracy: 0.01)
        view.image.mouseDown(with: try mouse(.leftMouseDown, moved))
        view.image.mouseUp(with: try mouse(.leftMouseUp, moved))
        XCTAssertEqual(view.scroll.zoom, 1)
        view.image.mouseDown(with: try mouse(.leftMouseDown, moved, clicks: 2))
        view.image.mouseUp(with: try mouse(.leftMouseUp, moved, clicks: 2))
        XCTAssertEqual(view.scroll.zoom, 1, "The second click of a double click must not toggle again")
    }

    func testFitMatchesBrowserAtDesktopAndNarrowWidthsWithoutUpscaling() {
        let desktop = NSSize(width: 880, height: 640)
        XCTAssertEqual(AgentZoomableImage.fitSize(image: NSSize(width: 100, height: 50), viewer: desktop), NSSize(width: 100, height: 50))
        let wide = AgentZoomableImage.fitSize(image: NSSize(width: 1200, height: 600), viewer: desktop)
        XCTAssertEqual(wide.width, 713.6, accuracy: 0.01)
        XCTAssertEqual(wide.height, 356.8, accuracy: 0.01)
        let narrow = AgentZoomableImage.fitSize(image: NSSize(width: 600, height: 1200), viewer: NSSize(width: 500, height: 700))
        XCTAssertEqual(narrow, NSSize(width: 270, height: 540))
    }

    func testZoomAnchorPanPrecedenceBoundsAndResizeReset() {
        let view = AgentMediaPreviewView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        view.image.image = NSImage(size: NSSize(width: 1200, height: 600))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        let original = view.scroll.frame
        view.scroll.changeZoom(2)
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertEqual(view.image.frame.width, 1427.2, accuracy: 0.01)
        XCTAssertEqual(view.scroll.frame.width, original.width, accuracy: 0.01)
        XCTAssertEqual(view.scroll.contentView.bounds.minX, original.width / 2, accuracy: 1)
        view.scroll.scroll(to: .zero)
        XCTAssertTrue(view.scroll.pan(key: 124))
        XCTAssertEqual(view.scroll.contentView.bounds.minX, 40, accuracy: 0.01)
        view.scroll.changeZoom(100)
        XCTAssertEqual(view.scroll.zoom, 8)
        view.scroll.changeZoom(0.1)
        XCTAssertEqual(view.scroll.zoom, 1)
        XCTAssertFalse(view.scroll.pan(key: 124))
        view.scroll.changeZoom(2)
        view.frame.size.width = 500
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scroll.zoom, 1)
        view.image.image = NSImage(size: NSSize(width: 100, height: 1200))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.scroll.changeZoom(2)
        XCTAssertFalse(view.scroll.pan(key: 124), "Vertical overflow alone must not swallow gallery navigation")
        XCTAssertTrue(view.scroll.pan(key: 125))
    }

    func testKeyboardZoomStepsAndRepeatSuppression() throws {
        let view = AgentMediaPreviewView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        view.image.image = NSImage(size: NSSize(width: 100, height: 50))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        func key(_ value: String, repeated: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: value, charactersIgnoringModifiers: value, isARepeat: repeated, keyCode: 0))
        }
        XCTAssertTrue(view.scroll.handleKey(try key("\r")))
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertTrue(view.scroll.handleKey(try key("\r", repeated: true)))
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertTrue(view.scroll.handleKey(try key("+")))
        XCTAssertEqual(view.scroll.zoom, 3)
        XCTAssertEqual(view.image.frame.size, NSSize(width: 300, height: 150))
        XCTAssertTrue(view.scroll.handleKey(try key("-")))
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertFalse(view.scroll.handleKey(try key("0", modifiers: .command)))
        XCTAssertEqual(view.scroll.zoom, 2)
        XCTAssertTrue(view.scroll.handleKey(try key("0")))
        XCTAssertEqual(view.scroll.zoom, 1)
    }
}
