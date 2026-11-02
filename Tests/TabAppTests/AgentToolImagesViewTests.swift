import AppKit
import TabProtocol
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentToolImagesViewTests: XCTestCase {
    func testImageSizingMatchesSourceCapsAndDoesNotUpscale() {
        XCTAssertEqual(AgentToolImagesView.imageSize(NSSize(width: 1200, height: 600), width: 600), NSSize(width: 480, height: 240))
        XCTAssertEqual(AgentToolImagesView.imageSize(NSSize(width: 600, height: 1200), width: 600), NSSize(width: 128, height: 256))
        XCTAssertEqual(AgentToolImagesView.imageSize(NSSize(width: 1200, height: 600), width: 240), NSSize(width: 240, height: 120))
        XCTAssertEqual(AgentToolImagesView.imageSize(NSSize(width: 24, height: 16), width: 600), NSSize(width: 24, height: 16))
    }
    func testToolPlaceholdersMatchBlankLoadingAndCenteredFailure() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            for width: CGFloat in [416, 236] {
                for failed in [false, true] {
                    let tile = AgentMediaTile(name: "Tool output image")
                    tile.isToolResult = true
                    tile.apply(theme)
                    tile.wantsLayer = true; tile.layer?.cornerRadius = 8; tile.layer?.masksToBounds = true
                    tile.layer?.borderWidth = 1; tile.layer?.borderColor = theme.border.withAlphaComponent(theme.border.alphaComponent * 0.4).cgColor
                    tile.frame.size = AgentToolImagesView.imageSize(nil, width: width)
                    tile.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    if failed { tile.fail("Internal transport error") }
                    tile.layoutSubtreeIfNeeded()
                    XCTAssertTrue(tile.subviews.compactMap { $0 as? NSTextField }.allSatisfy(\.isHidden))
                    XCTAssertEqual(tile.accessibilityLabel(), failed ? "Image unavailable · Tool output image" : "Loading image")
                    XCTAssertTrue(tile.acceptsFirstResponder)
                    XCTAssertFalse(tile.accessibilityPerformPress())
                    XCTAssertEqual(tile.frame.height, width == 416 ? 234 : 132.75)
                    if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        let root = NSView(frame: tile.frame)
                        root.appearance = tile.appearance
                        root.wantsLayer = true; root.layer?.backgroundColor = theme.bg.cgColor
                        root.addSubview(tile)
                        root.layoutSubtreeIfNeeded()
                        root.displayIfNeeded()
                        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                        root.cacheDisplay(in: root.bounds, to: bitmap)
                        if !dark {
                            let fill = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 20)?.usingColorSpace(.sRGB))
                            XCTAssertGreaterThan(fill.redComponent, 0.8, "A muted light frame must not become an opaque dark foreground fill")
                        }
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/tool-image-\(failed ? "failure" : "loading")-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    }
                }
            }
        }
    }

    func testToolImagesLoadAndOpenPreviewWithoutEmptyOutputLabel() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        var payload = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        payload.append(Data(count: 9 * 1024 * 1024 - payload.count))
        let data = payload
        let attachment = AgentChatAttachment(name: "Tool output image", mimeType: "image/png", data: data)
        let row = AgentToolDisclosure(frame: .zero)
        row.fetchAttachment = { _, _ in data }
        var previewed: String?
        row.onPreviewAttachments = { id, attachments, index in
            previewed = id
            XCTAssertEqual(attachments, [attachment.descriptor]); XCTAssertEqual(index, 0)
        }
        var activity = AgentToolActivity(name: "render", input: "{}", output: "[]", status: .completed, presentation: .dynamicTool)
        activity.outputIsJSON = true
        row.update(.init(id: "tool/image", kind: .tool, text: "render", tool: activity, attachments: [attachment.descriptor]), expanded: true, theme: AppTheme.shared)
        let panel = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentToolImagesView }.first)
        let tile = try XCTUnwrap(panel.subviews.compactMap { $0 as? AgentMediaTile }.first)
        for _ in 0..<100 where tile.image == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(tile.image)
        row.frame.size = NSSize(width: 420, height: row.height(for: 420)); row.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.minY, 48)
        XCTAssertTrue(tile.accessibilityPerformPress())
        XCTAssertEqual(previewed, "tool/image")
        let output = row.subviews.compactMap { $0 as? NSScrollView }.compactMap { $0.documentView as? NSTextView }
        XCTAssertFalse(output.contains { $0.string == "No output." })
    }
}
