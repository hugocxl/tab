import AppKit
@testable import TabCore
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentToolPresentationTests: XCTestCase {
    func testStructuredScalarsAndObjectOrderReachVisibleOutput() {
        let theme = AppTheme(systemIsDark: false)
        for value in ["42", "false", "0"] {
            XCTAssertEqual(AgentToolPresentation.output(value, isJSON: true, theme: theme).string, value)
        }
        XCTAssertEqual(AgentToolPresentation.output(#"{"z":1,"a":2}"#, isJSON: true, theme: theme).string,
                       "{\n  \"z\": 1,\n  \"a\": 2\n}")
    }

    func testArgumentsKeepKeysValuesAndJavaScriptEnumerationOrder() {
        let theme = AppTheme(systemIsDark: false)
        let source = #"{"file_path":"Sources/main.swift","empty":"","reset":null,"flags":{"quiet":true,"levels":[1,2]},"2":"two","1":"one"}"#
        let result = AgentToolPresentation.arguments(source, theme: theme)
        XCTAssertEqual(result.string, "1 one\n2 two\nfile_path Sources/main.swift\nempty \"\"\nreset null\nflags {\"quiet\":true,\"levels\":[1,2]}")
        let key = (result.string as NSString).range(of: "file_path")
        XCTAssertEqual(result.attribute(.foregroundColor, at: key.location, effectiveRange: nil) as? NSColor, theme.fgMuted)
        let path = (result.string as NSString).range(of: "Sources/main.swift")
        XCTAssertEqual(result.attribute(.foregroundColor, at: path.location, effectiveRange: nil) as? NSColor, theme.fg.withAlphaComponent(0.85))
        XCTAssertEqual(AgentToolJSON.parse(#"{"a":1,"b":2,"a":3}"#)?.encoded(), #"{"a":3,"b":2}"#)
        XCTAssertEqual(AgentToolJSON.parse(#"[1e2,-0,1e20,1e-6,1e-7]"#)?.encoded(), "[100,0,100000000000000000000,0.000001,1e-7]")
    }

    func testStructuredOutputUnwrapsTextAndResourceBlocksAndPrettyPrintsJSONLines() {
        let theme = AppTheme(systemIsDark: false)
        let source = #"{"content":[{"type":"text","text":"Read complete"},{"type":"resource_link","uri":"file:///tmp/readme"}],"isError":false}"#
        XCTAssertEqual(AgentToolPresentation.output(source, isJSON: true, theme: theme).string, "Read complete\nfile:///tmp/readme")
        XCTAssertEqual(AgentToolPresentation.prettyJSON("{\"a\":1}\n{\"b\":[2,3]}"), "{\n  \"a\": 1\n}\n\n{\n  \"b\": [\n    2,\n    3\n  ]\n}")
        XCTAssertEqual(AgentToolPresentation.output("{}", isJSON: true, theme: theme).string, "")
        XCTAssertEqual(AgentToolPresentation.output("[]", isJSON: true, theme: theme).string, "")
        XCTAssertEqual(AgentToolPresentation.output("null", theme: theme).string, "null")
        XCTAssertEqual(AgentToolPresentation.output("{}", theme: theme).string, "{}")
        XCTAssertEqual(AgentToolPresentation.output("ordinary output\n", theme: theme).string, "ordinary output\n")
        XCTAssertEqual(AgentToolPresentation.arguments(#"{"truncated":true,"summary":"long input"}"#, theme: theme).string, "{\n  \"truncated\": true,\n  \"summary\": \"long input\"\n}")
    }

    func testJSONInspectorSyntaxUsesExistingCustomThemeColors() throws {
        let source = #"{"key":"value\n\u00e9","number":-1.5e2,"yes":true,"no":false,"nil":null,"array":[1,2]}"#
        for dark in [false, true] {
            let scheme = ColorScheme(background: RGBColor(dark ? 0x102030 : 0xF0E0D0), foreground: RGBColor(dark ? 0xE0D0C0 : 0x203040), palette: [1: RGBColor(0xA01122), 2: RGBColor(0x22A033), 3: RGBColor(0xA08822), 5: RGBColor(0xAA22CC), 6: RGBColor(0x22AABB)])
            let theme = AppTheme(catalog: ThemeCatalog(entries: [ThemeEntry(name: "Custom", scheme: scheme)]), darkTheme: "Custom", lightTheme: "Custom", systemIsDark: dark)
            let text = AgentJSONSyntax.highlight(source, theme: theme)
            XCTAssertEqual(text.string, source)
            let syntax = theme.syntaxColors
            let expected = [syntax.color(.punctuation), syntax.color(.attribute), syntax.color(.string), syntax.color(.type), syntax.color(.number), syntax.color(.number), syntax.color(.keyword)]
            for (index, offset) in [0, 1, 7, 13, 32, 45, 67].enumerated() {
                XCTAssertEqual(text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor, expected[index])
            }
            let escapedKey = AgentJSONSyntax.highlight(#"{"ke\"y":"a\\b"}"#, theme: theme)
            XCTAssertEqual(escapedKey.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor, expected[3])
            let summary = AgentToolPresentation.arguments(#"{"truncated":true,"summary":"long input"}"#, theme: theme)
            let keyOffset = (summary.string as NSString).range(of: "\"summary\"").location
            XCTAssertEqual(summary.attribute(.foregroundColor, at: keyOffset, effectiveRange: nil) as? NSColor, expected[1])
            let ordinary = AgentToolPresentation.arguments(#"{"argument":"true"}"#, theme: theme)
            XCTAssertEqual(ordinary.attribute(.foregroundColor, at: ordinary.length - 1, effectiveRange: nil) as? NSColor, theme.fg.withAlphaComponent(0.85))
            let output = AgentToolPresentation.output(source, theme: theme)
            XCTAssertEqual(output.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, theme.fgMuted)
        }
    }

    func testStructuredArgumentsHaveIndependentBoundedScrollAndEmptyOutput() throws {
        _ = NSApplication.shared
        let theme = AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false)
        let input = "[" + (0..<100).map(String.init).joined(separator: ",") + "]"
        var activity = AgentToolActivity(name: "Tool", category: .other, input: input, status: .completed, presentation: .dynamicTool)
        let row = AgentToolDisclosure(frame: .zero)
        row.update(.init(id: "tool", kind: .tool, text: "Tool", tool: activity), expanded: true, theme: theme)
        row.frame.size = NSSize(width: 420, height: row.height(for: 420)); row.layoutSubtreeIfNeeded()
        let scrolls = row.subviews.compactMap { $0 as? NSScrollView }.filter { !$0.isHidden }
        XCTAssertEqual(scrolls.count, 2)
        let arguments = try XCTUnwrap(scrolls.first { ($0.documentView as? NSTextView)?.string.hasPrefix("[") == true })
        let output = try XCTUnwrap(scrolls.first { ($0.documentView as? NSTextView)?.string == "No output." })
        XCTAssertEqual(arguments.frame.height, 320)
        XCTAssertEqual(output.frame.minY - arguments.frame.maxY, 6)
        XCTAssertEqual(row.frame.height, 413.125)
        row.restoreArgumentScrollPosition(NSPoint(x: 0, y: 200))
        row.needsLayout = true; row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.argumentScrollPosition.y, 200)
        XCTAssertEqual(row.outputScrollPosition.y, 0)
        activity.status = .running
        XCTAssertEqual(AgentToolPresentation.completedOutput(activity, theme: theme).string, "")
        activity.status = .completed
        activity.output = "{}"; activity.outputIsJSON = false
        XCTAssertEqual(AgentToolPresentation.completedOutput(activity, theme: theme).string, "{}")
        activity.outputIsJSON = true
        XCTAssertEqual(AgentToolPresentation.completedOutput(activity, theme: theme).string, "No output.")
        XCTAssertFalse(AgentToolPresentation.argumentsNeedScroll(#"{"code":"long normal argument"}"#))
        XCTAssertTrue(AgentToolPresentation.argumentsNeedScroll(#"{"truncated":true,"summary":"long input"}"#))
    }

    func testArgumentPanelKeepsInputVisibleWhileOutputScrolls() throws {
        _ = NSApplication.shared
        let row = AgentToolDisclosure(frame: .zero)
        let tool = AgentToolActivity(name: "Read", category: .read, input: #"{"file_path":"README.md","offset":10}"#, output: String(repeating: "line\n", count: 100), presentation: .dynamicTool)
        row.update(.init(id: "read", kind: .tool, text: "Read", tool: tool), expanded: true,
                   theme: AppTheme(catalog: ThemeCatalog.load(customDirectory: nil), systemIsDark: false))
        row.frame.size = NSSize(width: 420, height: row.height(for: 420))
        row.layoutSubtreeIfNeeded()
        let input = try XCTUnwrap(row.subviews.compactMap { $0 as? NSTextView }.first { $0.string.hasPrefix("file_path") })
        let scroll = try XCTUnwrap(row.subviews.compactMap { $0 as? NSScrollView }.first)
        let output = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertEqual(input.string, "file_path README.md\noffset 10")
        XCTAssertEqual(input.frame.minX, 12, "Arguments sit inside the padded result box")
        XCTAssertEqual(input.frame.height, 42.25, accuracy: 0.01)
        XCTAssertEqual(scroll.frame.minY - input.frame.maxY, 6)
        XCTAssertEqual(scroll.frame.height, 320)
        XCTAssertEqual(output.string, tool.output)
        if let directory = ProcessInfo.processInfo.environment["TAB_SNAPSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            row.wantsLayer = true
            row.appearance = NSAppearance(named: .aqua)
            row.layer?.backgroundColor = NSColor.white.cgColor
            let bitmap = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
            row.cacheDisplay(in: row.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory + "/generic-tool.png"))
            let measured = input.textContainer.flatMap { input.layoutManager?.usedRect(for: $0) } ?? .zero
            try "input=\(input.frame) used=\(measured) output=\(scroll.frame)".write(toFile: directory + "/generic-tool-geometry.txt", atomically: true, encoding: .utf8)
        }
    }
}
