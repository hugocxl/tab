import AppKit
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentReplArgumentsTests: XCTestCase {
    func testExactToolNamesAndCodeArgumentRequired() {
        for name in ["js", "node_repl.js", "cua_repl.js"] {
            XCTAssertTrue(AgentReplArguments.accepts(.init(name: name, input: #"{"code":""}"#)))
        }
        for name in ["JS", "mcp__node_repl.js", "node_repl", "Read"] {
            XCTAssertFalse(AgentReplArguments.accepts(.init(name: name, input: #"{"code":"x"}"#)))
        }
        XCTAssertFalse(AgentReplArguments.accepts(.init(name: "js", input: #"{"title":"Run"}"#)))
        XCTAssertFalse(AgentReplArguments.accepts(.init(name: "js", input: #"{"truncated":true,"summary":"large input","code":"x"}"#)))
    }

    func testCodeHasItsOwnBoundedScrollBetweenOrdinaryArguments() throws {
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let row = AgentToolDisclosure(frame: .zero)
        for count in [2, 100] {
            let code = (0..<count).map { "const value\($0) = \($0);" }.joined(separator: "\n")
            let input = AgentToolJSON.object([("title", .string("Inspect data")), ("code", .string(code)), ("timeout_ms", .literal("1000"))]).encoded()
            let activity = AgentToolActivity(name: "node_repl.js", category: .other, input: input, output: "Done", status: .completed, presentation: .dynamicTool)
            row.update(.init(id: "repl", kind: .tool, text: "REPL", tool: activity), expanded: true, theme: theme)
            row.frame.size = NSSize(width: 420, height: row.height(for: 420)); row.layoutSubtreeIfNeeded()
            let panel = try XCTUnwrap(row.subviews.compactMap { $0 as? AgentReplArguments }.first)
            XCTAssertFalse(panel.isHidden)
            XCTAssertEqual(panel.frame.minY, 48)
            let texts = panel.subviews.compactMap { $0 as? NSTextView }
            XCTAssertEqual(texts.map(\.string), ["title Inspect data", "code ", "timeout_ms 1000"])
            let scroll = try XCTUnwrap(panel.subviews.compactMap { $0 as? NSScrollView }.first)
            XCTAssertEqual((scroll.documentView as? NSTextView)?.string, code)
            XCTAssertEqual(scroll.frame.minY, 42.25)
            XCTAssertEqual(scroll.frame.height, count == 2 ? 42.25 : 320)
            XCTAssertEqual(texts.last?.frame.minY, scroll.frame.maxY)
            XCTAssertEqual(row.frame.height, count == 2 ? 198.75 : 476.5)
            if count == 100 {
                row.restoreArgumentScrollPosition(NSPoint(x: 0, y: 150))
                panel.needsLayout = true; panel.layoutSubtreeIfNeeded()
                XCTAssertEqual(row.argumentScrollPosition.y, 150)
                XCTAssertEqual(row.outputScrollPosition.y, 0)
            }
        }
    }
}
