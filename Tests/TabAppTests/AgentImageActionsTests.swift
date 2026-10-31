import AppKit
import ImageIO
import XCTest
@testable import TabApp

@MainActor
final class AgentImageActionsTests: XCTestCase {
    func testMenuMatchesSourceAndDisablesUnavailablePayload() {
        let actions = AgentImageActions(name: "Tool output image")
        XCTAssertEqual(actions.menu().items.map(\.title), ["Save image", "Copy image"])
        XCTAssertTrue(actions.menu().items.allSatisfy { !$0.isEnabled })
        actions.fetch = { Data() }
        XCTAssertTrue(actions.menu().items.allSatisfy(\.isEnabled))
    }

    func testCopyConvertsOriginalJPEGToOrientedFullResolutionPNG() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let actions = AgentImageActions(name: "photo.jpg")
        actions.mimeType = "image/jpeg"
        let bytes = jpeg as Data
        actions.fetch = { bytes }
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try await actions.copy(to: clipboard)
        let png = try XCTUnwrap(clipboard.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 12)
        XCTAssertEqual(image.height, 24)
        XCTAssertNil(clipboard.data(forType: NSPasteboard.PasteboardType("public.jpeg")))
    }

    func testPNGPreservesBytesAndFailedCopyPreservesClipboard() async throws {
        let actions = AgentImageActions(name: "image.png")
        let bytes = Data([1, 2, 3]) // PNG pass-through deliberately matches the source MIME contract.
        actions.fetch = { bytes }
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try await actions.copy(to: clipboard)
        XCTAssertEqual(clipboard.data(forType: .png), bytes)
        actions.mimeType = "image/jpeg"
        do { try await actions.copy(to: clipboard); XCTFail("Invalid JPEG must fail") } catch {}
        XCTAssertEqual(clipboard.data(forType: .png), bytes)
    }
}
