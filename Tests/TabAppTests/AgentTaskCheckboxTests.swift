import AppKit
import TabCore
import XCTest
@testable import TabApp

@MainActor
final class AgentTaskCheckboxTests: XCTestCase {
    func testCheckboxDrawingKeepsCopyableTaskStateAndSourceSizedGutter() throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let content = AgentMarkdown.render("- [ ] Incomplete task\n- [x] Completed task\n  - [ ] Nested task", theme: theme)
            XCTAssertTrue(content.string.contains("☐\tIncomplete task"))
            XCTAssertTrue(content.string.contains("☑\tCompleted task"))
            var states: [Int] = []
            content.enumerateAttribute(.agentTaskCheckbox, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                guard let state = value as? Int else { return }
                states.append(state)
                XCTAssertEqual(range.length, 1)
                XCTAssertEqual((content.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)?.alphaComponent, 0)
                let style = content.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                XCTAssertEqual(style?.headIndent, states.count == 3 ? 40 : 20)
            }
            XCTAssertEqual(states, dark ? [2, 3, 2] : [0, 1, 0])
        }
    }

    func testNativeCheckboxSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] else { throw XCTSkip("Set TAB_SNAPSHOT_DIR") }
        _ = NSApplication.shared
        for dark in [false, true] {
            let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
            let root = CheckboxFixture(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            root.wantsLayer = true; root.layer?.backgroundColor = NSColor.white.cgColor
            let response = AgentResponseView(frame: .zero)
            response.setContent("- [ ] Incomplete task\n- [x] Completed task\n  - [ ] Nested task", theme: theme)
            response.frame = NSRect(x: 20, y: 20, width: 460, height: response.height(for: 460))
            root.addSubview(response)
            let window = NSWindow(contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = root
            defer { window.close() }
            root.layoutSubtreeIfNeeded()
            let raw = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 300,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let bitmap = raw.retagging(with: .sRGB) ?? raw
            bitmap.size = root.bounds.size
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("task-checkbox-\(dark).png"))
        }
    }
}

private final class CheckboxFixture: NSView { override var isFlipped: Bool { true } }
