import AppKit
import ImageIO
import XCTest
import TabCore
import TabProtocol
@testable import TabApp

@MainActor
final class AgentMessageMediaTests: XCTestCase {
    func testAttachmentCacheCannotCollideAcrossSlashContainingOwnerIDs() async throws {
        let cache = AgentAttachmentCache()
        var fetched: [String] = []
        cache.fetch = { item, _ in
            fetched.append(item)
            return item == "a/b" ? Data([1]) : Data([2])
        }
        let first = AgentChatAttachmentDescriptor(id: "c", name: "first", mimeType: "image/png", byteCount: 1)
        let second = AgentChatAttachmentDescriptor(id: "b/c", name: "second", mimeType: "image/png", byteCount: 1)
        let firstBytes = try await cache.data(item: "a/b", attachment: first)
        let secondBytes = try await cache.data(item: "a", attachment: second)
        XCTAssertEqual(firstBytes, Data([1]))
        XCTAssertEqual(secondBytes, Data([2]))
        XCTAssertEqual(fetched, ["a/b", "a"])
    }

    func testAnimatedGIFRetainsFramesAndPlaysInTileAndPreview() async throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for color in [NSColor.red, .blue] {
            let still = try fixture("frame", color: color, width: 16, height: 16)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(still.data as CFData, nil))
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.12]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = data as Data
        let decoded = await AgentAttachmentImporter.previewImage(data: bytes, pixels: 600)
        let image = try XCTUnwrap(decoded)
        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep)
        XCTAssertEqual((bitmap.value(forProperty: .frameCount) as? NSNumber)?.intValue, 2)
        let tile = AgentMediaTile(name: "Animated fixture")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tile
        defer { window.close() }
        tile.load({ image }, changed: {})
        try await wait { tile.image != nil }
        tile.layoutSubtreeIfNeeded()
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFront(nil)
        let player = try XCTUnwrap(tile.subviews.compactMap { $0 as? NSImageView }.first)
        XCTAssertTrue(player.animates)
        // Observe a rendered frame change, not merely the animation flag.
        var colors = Set<Int>()
        for _ in 0..<30 {
            let capture = try XCTUnwrap(player.bitmapImageRepForCachingDisplay(in: player.bounds))
            player.cacheDisplay(in: player.bounds, to: capture)
            let color = try XCTUnwrap(capture.colorAt(x: capture.pixelsWide / 2, y: capture.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            colors.insert(color.redComponent > color.blueComponent ? 0 : 1)
            if colors.count == 2 { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertEqual(colors.count, 2)
        tile.suspend()
        XCTAssertFalse(player.animates)
        XCTAssertNil(player.image)
        let attachment = AgentChatAttachment(name: "animation.gif", mimeType: "image/gif", data: bytes)
        let preview = AgentMediaPreviewWindow(item: "message", attachments: [attachment.descriptor], index: 0, fetch: { _, _ in bytes }, theme: AppTheme(systemIsDark: false))
        defer { preview.close() }
        try await wait { preview.content.image.image != nil }
        XCTAssertTrue(preview.content.image.animates)
        XCTAssertEqual((preview.content.image.image?.representations.first as? NSBitmapImageRep)?.value(forProperty: .frameCount) as? Int, 2)
        preview.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertFalse(preview.content.image.animates)
    }

    func testCacheDeduplicatesAndRejectsMismatchedPayloadsForEveryCaller() async throws {
        let cache = AgentAttachmentCache()
        let attachment = AgentChatAttachment(name: "image.png", mimeType: "image/png", data: Data([1, 2, 3]))
        var calls = 0
        cache.fetch = { _, _ in calls += 1; try await Task.sleep(for: .milliseconds(30)); return attachment.data }
        let first = Task { try await cache.data(item: "message", attachment: attachment.descriptor) }
        let second = Task { try await cache.data(item: "message", attachment: attachment.descriptor) }
        let values = try await [first.value, second.value]
        XCTAssertEqual(values, [attachment.data, attachment.data])
        XCTAssertEqual(calls, 1)
        _ = try await cache.data(item: "message", attachment: attachment.descriptor)
        XCTAssertEqual(calls, 1)
        cache.cancel()
        cache.fetch = { _, _ in try await Task.sleep(for: .milliseconds(20)); return Data() }
        let badOne = Task { try await cache.data(item: "message", attachment: attachment.descriptor) }
        let badTwo = Task { try await cache.data(item: "message", attachment: attachment.descriptor) }
        for task in [badOne, badTwo] {
            do { _ = try await task.value; XCTFail("Every coalesced caller must validate its payload") } catch {}
        }
    }

    func testImagesSitAboveTextAndImageOnlyMessageHasNoBubble() async throws {
        let image = try fixture("Wide screenshot", color: .systemBlue, width: 600, height: 300)
        let row = AgentMessageRow(frame: .zero)
        row.fetchAttachment = { _, _ in image.data }
        row.update([AgentChatItem(id: "message", kind: .user, text: "Please review this screenshot.", attachments: [image.descriptor])])
        let media = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentMessageMediaView }.first)
        try await wait { media.images.first.flatMap { $0 } != nil }
        place(row, width: 600)
        let response = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentResponseView }.first)
        XCTAssertEqual(media.frame.height, 240)
        XCTAssertEqual(media.frame.width, 480)
        XCTAssertGreaterThan(response.frame.minY, media.frame.maxY)
        row.update([AgentChatItem(id: "message", kind: .user, text: "", attachments: [image.descriptor])])
        place(row, width: 600)
        XCTAssertTrue(try XCTUnwrap(row.subviews.first { $0 is ThemedBackground }).isHidden)
        XCTAssertEqual(row.frame.height, 268)
        XCTAssertTrue(try XCTUnwrap(row.subviews.compactMap { $0 as? PillButton }.first { $0.toolTip == "Copy message" }).isHidden)
    }

    func testWholeImageStackGeometryAndRetryAfterFetchFailure() async throws {
        let files = try [fixture("One", color: .systemBlue), fixture("Two", color: .systemGreen), fixture("Three", color: .systemOrange)]
        let media = AgentMessageMediaView(frame: .zero)
        var fail = true
        media.fetch = { _, attachment in
            if fail { throw ModelError("Offline") }
            return try XCTUnwrap(files.first { $0.id == attachment.id }).data
        }
        media.update(item: "message", attachments: files.map(\.descriptor), theme: AppTheme(systemIsDark: false))
        let tiles = media.subviews.compactMap { $0 as? AgentMediaTile }
        try await wait { tiles.allSatisfy { $0.toolTip?.contains("Offline") == true } }
        fail = false
        tiles.forEach { $0.onPress?() }
        try await wait { media.images.allSatisfy { $0 != nil } }
        media.frame = NSRect(origin: .zero, size: media.measuredSize(maxWidth: 400))
        media.layoutSubtreeIfNeeded()
        XCTAssertEqual(media.frame.size, NSSize(width: 400, height: 736))
        XCTAssertEqual(tiles[0].frame.height, 240)
        XCTAssertTrue(tiles.allSatisfy(\.fitsWholeImage))
        XCTAssertEqual(tiles[1].frame.maxY + 8, tiles[2].frame.minY)
        XCTAssertEqual(tiles[0].frame.minX, tiles[1].frame.minX)
        var previewIndex: Int?
        media.onPreview = { _, _, index in previewIndex = index }
        XCTAssertTrue(tiles[2].accessibilityPerformPress())
        XCTAssertEqual(previewIndex, 2)
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        try await tiles[2].imageActions.copy(to: clipboard)
        XCTAssertEqual(clipboard.data(forType: .png), files[2].data)
    }

    func testPreviewIgnoresSlowPriorImageAndSupportsNavigationAndZoom() async throws {
        let restoreClipboard = preserveAgentTestClipboard()
        defer { restoreClipboard() }
        let first = try fixture("Slow", color: .systemRed, width: 300, height: 100)
        let second = try fixture("Current", color: .systemGreen, width: 100, height: 300)
        let preview = AgentMediaPreviewWindow(item: "message", attachments: [first.descriptor, second.descriptor], index: 0, fetch: { _, attachment in
            if attachment.id == first.id { try? await Task.sleep(for: .milliseconds(120)); return first.data }
            return second.data
        }, theme: AppTheme(systemIsDark: false))
        defer { preview.close() }
        preview.select(1)
        XCTAssertTrue(preview.imageActions.menu().items.allSatisfy(\.isEnabled), "Original media actions remain available while the preview is loading")
        try await wait { preview.content.image.image != nil }
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(preview.content.image.imageActions === preview.imageActions)
        XCTAssertEqual(preview.selectedIndex, 1)
        let size = try XCTUnwrap(preview.content.image.image?.size)
        XCTAssertGreaterThan(size.height, size.width)
        preview.imageActions.copyImage()
        try await wait { NSPasteboard.general.data(forType: .png) == second.data }
        XCTAssertEqual(NSPasteboard.general.data(forType: .png), second.data)
        XCTAssertFalse(preview.content.next.isHidden)
        preview.content.next.perform()
        XCTAssertEqual(preview.selectedIndex, 0)
        preview.content.previous.perform()
        XCTAssertEqual(preview.selectedIndex, 1)
        try await wait { preview.content.image.image != nil }
        preview.content.layoutSubtreeIfNeeded()
        preview.content.scroll.changeZoom(2)
        XCTAssertEqual(preview.content.scroll.zoom, 2)
        XCTAssertTrue(preview.content.onKey?(123) == true)
        XCTAssertEqual(preview.selectedIndex, 0)
    }

    func testMediaSnapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        let files = try [fixture("Screenshot A", color: .systemBlue, width: 600, height: 300), fixture("Screenshot B", color: .systemGreen), fixture("Screenshot C", color: .systemOrange)]
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let row = AgentMessageRow(frame: .zero)
            row.theme = theme
            row.fetchAttachment = { _, attachment in try XCTUnwrap(files.first { $0.id == attachment.id }).data }
            row.update([AgentChatItem(id: "message", kind: .user, text: "Compare these screens and tighten the spacing.", attachments: files.map(\.descriptor))])
            let media = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentMessageMediaView }.first)
            try await wait { media.images.allSatisfy { $0 != nil } }
            place(row, width: 500)
            let background = ThemedBackground(color: { $0.card })
            background.theme = theme
            background.frame = NSRect(x: 0, y: 0, width: 524, height: row.frame.height + 24)
            background.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            row.setFrameOrigin(NSPoint(x: 12, y: 12))
            background.addSubview(row)
            background.themeDidChange()
            background.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(background.bitmapImageRepForCachingDisplay(in: background.bounds))
            background.cacheDisplay(in: background.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/message-media-\(dark ? "dark" : "light").png"))
        }
    }

    private func place(_ row: AgentMessageRow, width: CGFloat) {
        row.frame = NSRect(x: 0, y: 0, width: width, height: row.preferredHeight(for: width)); row.layoutRow(width: width)
    }
    private func fixture(_ name: String, color: NSColor, width: CGFloat = 300, height: CGFloat = 300) throws -> AgentChatAttachment {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        color.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.white.withAlphaComponent(0.3).setFill(); NSBezierPath(ovalIn: NSRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2)).fill()
        (name as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.white])
        image.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        return AgentChatAttachment(name: name + ".png", mimeType: "image/png", data: try XCTUnwrap(rep.representation(using: .png, properties: [:])))
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for media state")
    }
}
