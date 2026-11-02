import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentCommandPresentationTests: XCTestCase {
    func testCommandSourceDecodesProviderArgumentsAndKeepsShellWhitespace() {
        XCTAssertEqual(AgentCommandPresentation.command(.init(input: #"{"command":"  printf 'hello  world'\n\necho done\n","timeout_ms":1000}"#)), "printf 'hello  world'\n\necho done")
        XCTAssertEqual(AgentCommandPresentation.command(.init(input: #"{"cmd":"pwd"}"#)), "pwd")
        XCTAssertEqual(AgentCommandPresentation.command(.init(input: "echo hello\n")), "echo hello")
    }

    func testLongOutputScrollsIndependentlyFromSourceAndExitAndKeepsSelection() throws {
        _ = NSApplication.shared
        let row = AgentToolDisclosure(frame: .zero)
        let output = (0..<100).map { "output line \($0)" }.joined(separator: "\n")
        var item = AgentChatItem(id: "command", kind: .tool, text: "Read", tool: .init(category: .read, input: "printf 'hello'", output: output, status: .completed, exitCode: 2, presentation: .command))
        row.update(item, expanded: true, theme: AppTheme(systemIsDark: false))
        row.frame.size = NSSize(width: 420, height: row.height(for: 420))
        row.layoutSubtreeIfNeeded()
        let source = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "> printf 'hello'" })
        let exit = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextView }.first { $0.string == "exit 2" })
        let scroll = try XCTUnwrap(row.subviews.compactMap { $0 as? NSScrollView }.first)
        let body = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(scroll.frame.height, 320)
        XCTAssertEqual(scroll.frame.minY - source.frame.maxY, 6)
        XCTAssertEqual(exit.frame.minY - scroll.frame.maxY, 6)
        XCTAssertEqual(source.frame.minX, 12)
        XCTAssertFalse(body.string.contains("Output\n"))
        XCTAssertEqual(body.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, AppFont.mono(13))
        body.setSelectedRange(NSRange(location: 0, length: 6))
        item.tool?.output = output + "\nlast line"
        item.tool?.exitCode = 0
        row.update(item, expanded: true, theme: AppTheme(systemIsDark: false))
        XCTAssertEqual(body.selectedRange(), NSRange(location: 0, length: 6))
        XCTAssertTrue(exit.isHidden)
        XCTAssertEqual(source.string, "> printf 'hello'")

        if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            item.tool?.exitCode = 2
            for dark in [false, true] {
                let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: dark)
                row.update(item, expanded: true, theme: theme)
                row.wantsLayer = true
                row.layer?.backgroundColor = theme.bg.cgColor
                row.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                row.frame.size.height = row.height(for: 420)
                row.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
                row.cacheDisplay(in: row.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/command-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testEmptyOutputOnlyShowsPlaceholderOnceCommandFinishes() {
        let theme = AppTheme(systemIsDark: false)
        XCTAssertEqual(AgentCommandPresentation.output(.init(status: .running), theme: theme).string, "")
        XCTAssertEqual(AgentCommandPresentation.output(.init(status: .completed), theme: theme).string, "No output.")
    }
}
