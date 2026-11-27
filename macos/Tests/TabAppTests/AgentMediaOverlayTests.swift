import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentMediaOverlayTests: XCTestCase {
    func testDesktopAndNarrowLayoutMatchesBrowserCapture() throws {
        for width: CGFloat in [880, 500] {
            let view = AgentMediaPreviewView(frame: NSRect(x: 0, y: 0, width: width, height: 640))
            view.theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false); view.themeDidChange()
            view.image.image = NSImage(size: NSSize(width: 1200, height: 600), flipped: false) { rect in
                NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1).setFill(); rect.fill(); return true
            }
            view.caption.stringValue = "Fixture.png (1/2)"
            view.setLoaded(true); view.layoutSubtreeIfNeeded()
            let narrow = width == 500
            XCTAssertEqual(view.scroll.frame.minX, narrow ? 20 : 83.2, accuracy: 0.02)
            XCTAssertEqual(view.scroll.frame.minY, narrow ? 193 : 129.6, accuracy: 0.02)
            XCTAssertEqual(view.caption.frame.minY, narrow ? 431 : 494.4, accuracy: 0.02)
            XCTAssertEqual(view.previous.frame.minX, narrow ? 21 : 36.2, accuracy: 0.02)
            XCTAssertEqual(view.previous.frame.minY, narrow ? 577.4 : 304, accuracy: 0.02)
            XCTAssertEqual(view.closeButton.frame.minX, narrow ? 447 : 815.8, accuracy: 0.02)
            XCTAssertEqual(view.closeButton.frame.minY, 26.6, accuracy: 0.02)
            XCTAssertEqual(view.closeButton.frame.width, narrow ? 32 : 28)
            XCTAssertEqual(view.caption.font?.pointSize, 12)
            XCTAssertEqual(view.layer?.backgroundColor?.alpha, 0.75)
            if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                let root = NSView(frame: view.frame); root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
                root.addSubview(view); root.layoutSubtreeIfNeeded()
                let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = root
                defer { window.close() }
                window.makeFirstResponder(view.closeButton)
                let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: 640, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                let bitmap = raw.retagging(with: .sRGB) ?? raw
                bitmap.size = root.bounds.size
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("media-overlay-\(Int(width)).png"))
            }
        }
    }

    func testOverlayAttachesToParentAndRestoresFocusOnClose() throws {
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 880, height: 640), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let opener = AgentMediaTile(name: "Fixture")
        parent.contentView = opener
        parent.makeFirstResponder(opener)
        let descriptor = AgentChatAttachment(name: "Fixture.png", mimeType: "image/png", data: Data()).descriptor
        let preview = AgentMediaPreviewWindow(item: "message", attachments: [descriptor], index: 0, fetch: { _, _ in throw ModelError("Unavailable") }, theme: AppTheme(systemIsDark: false))
        defer { preview.close(); parent.close() }
        preview.present(in: parent)
        let overlay = try XCTUnwrap(preview.window)
        XCTAssertTrue(overlay.parent === parent)
        XCTAssertEqual(overlay.frame, parent.convertToScreen(parent.contentLayoutRect))
        XCTAssertTrue(overlay.firstResponder === preview.content.closeButton)
        XCTAssertTrue(preview.content.previous.isHidden)
        parent.setContentSize(NSSize(width: 700, height: 500))
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: parent)
        XCTAssertEqual(overlay.frame, parent.convertToScreen(parent.contentLayoutRect))
        preview.close()
        XCTAssertNil(overlay.parent)
        XCTAssertTrue(parent.firstResponder === opener)
    }

    func testFailureFrameAndBackdropDismissal() throws {
        let view = AgentMediaPreviewView(frame: NSRect(x: 0, y: 0, width: 880, height: 640))
        view.showFailure(); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scroll.frame.size, NSSize(width: 512, height: 192))
        XCTAssertEqual(view.status.stringValue, "Image unavailable. The file may have been moved or deleted.")
        var closes = 0; view.onClose = { closes += 1 }
        func click(_ point: NSPoint) throws {
            let location = view.convert(point, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            view.mouseDown(with: event)
        }
        try click(NSPoint(x: view.scroll.frame.midX, y: view.scroll.frame.midY))
        XCTAssertEqual(closes, 0)
        try click(NSPoint(x: 3, y: 3))
        XCTAssertEqual(closes, 1)
        view.closeButton.perform()
        XCTAssertEqual(closes, 2)
    }
}
