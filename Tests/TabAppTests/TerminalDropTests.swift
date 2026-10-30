import AppKit
import XCTest
@testable import TabApp

@MainActor
final class TerminalDropTests: XCTestCase {
    func testScreenshotThumbnailFilePromisesAreAccepted() {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let registered = Set(view.registeredDraggedTypes)
        for type in NSFilePromiseReceiver.readableDraggedTypes {
            XCTAssertTrue(registered.contains(NSPasteboard.PasteboardType(type)), type)
        }
    }

    func testDroppedFilesPastePaths() {
        let (view, host) = makeView()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/Screenshot 1.png") as NSURL])
        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))
        XCTAssertEqual(host.drops, [["/tmp/Screenshot 1.png"]])
    }

    /// Ctrl+V would make the program read the clipboard, not the dragged image.
    func testDroppedImageDataBecomesAFileInsteadOfCtrlV() throws {
        let (view, host) = makeView()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
        let png = try XCTUnwrap(image?.representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(view.performDragOperation(FakeDrag(pasteboard: pasteboard)))
        XCTAssertEqual(host.droppedImages, [png])
        XCTAssertEqual(host.inputs, [])
    }

    private func makeView() -> (TerminalView, RecordingHost) {
        let view = TerminalView(settings: TerminalFixtures.settings(), palette: TerminalPalette())
        let host = RecordingHost()
        view.host = host
        return (view, host)
    }
}

private final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
