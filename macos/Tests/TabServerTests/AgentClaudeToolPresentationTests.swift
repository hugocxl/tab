import TabProtocol
import XCTest
@testable import TabServer

final class AgentClaudeToolPresentationTests: XCTestCase {
    func testKnownNativeNamesUseSourceNormalizationAndInspectorKinds() {
        let cases: [(String, AgentToolActivity.Presentation)] = [
            ("Bash", .command), (" B_A-S H ", .command),
            ("Edit", .fileChange), ("Multi_Edit", .fileChange), ("Notebook-Edit", .fileChange), ("Write", .fileChange),
            ("Web Fetch", .webSearch), ("WEB_SEARCH", .webSearch),
            ("Grep", .dynamicTool), ("Glob", .dynamicTool), ("Read", .dynamicTool), ("Agent", .dynamicTool),
            ("shell", .dynamicTool), ("exec_command", .dynamicTool), ("apply_patch", .dynamicTool),
            ("mcp__tools__Bash", .dynamicTool), ("mcp__tools__Edit", .dynamicTool),
        ]
        for (name, expected) in cases {
            let tool = agentToolActivity(name: name, input: #"{"file_path":"a.swift","old_string":"old","new_string":"new"}"#)
            XCTAssertEqual(tool.presentation, expected, name)
            if expected == .dynamicTool { XCTAssertNil(tool.fileChanges, name) }
        }
        XCTAssertEqual(agentNormalizedClaudeToolName("\u{feff}Web\u{202f}Search"), "websearch")
        XCTAssertEqual(agentNormalizedClaudeToolName("Web\u{85}Search"), "web\u{85}search")
        XCTAssertEqual(agentToolActivity(name: "Notebook-Edit", input: nil).fileChangeDetails?.fileName, "Notebook-Edit result")
    }

    func testNormalizedFetchKeepsResultAndGenericAliasesKeepInput() {
        var tool = agentToolActivity(name: "Web-Fetch", input: #"{"url":"https://example.com"}"#)
        tool.output = "Fetched text"
        agentUpdateClaudeWebSearch(&tool, result: nil)
        XCTAssertEqual(tool.webResults?.first?.snippet, "Fetched text")
        XCTAssertEqual(tool.category, .web)
        let shell = agentToolActivity(name: "exec_command", input: #"{"cmd":"pwd"}"#)
        XCTAssertEqual(shell.category, .command)
        XCTAssertFalse(shell.presentsCommand)
        XCTAssertEqual(shell.input, #"{"cmd":"pwd"}"#)
    }
}
