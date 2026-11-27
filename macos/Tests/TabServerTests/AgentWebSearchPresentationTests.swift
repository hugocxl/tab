import Foundation
import TabProtocol
import XCTest
@testable import TabServer

final class AgentWebSearchPresentationTests: XCTestCase {
    func testCodexPatternsMatchActionOrderAndKeepDuplicates() {
        XCTAssertEqual(agentCodexWebSearchPatterns(["query": " main ", "action": ["type": "search", "queries": ["one", " ", "one"], "query": "two"]]), ["one", "one", "two", "main"])
        XCTAssertEqual(agentCodexWebSearchPatterns(["query": "query", "action": ["type": "findInPage", "pattern": "match", "url": "https://example.com"]]), ["match", "https://example.com", "query"])
        XCTAssertEqual(agentCodexWebSearchPatterns(["action": ["type": "openPage", "url": "https://example.com"]]), ["https://example.com"])
    }

    func testClaudeTypedSearchMetadataAndFetchSnippetSurvivePersistence() throws {
        var activity = agentToolActivity(name: "WebSearch", input: #"{"query":"  Swift docs  "}"#)
        agentUpdateClaudeWebSearch(&activity, result: ["query": "fallback", "durationSeconds": 1.2, "results": [
            "ignored text", ["content": [["title": "Guide", "url": "https://example.com"]]],
        ]])
        XCTAssertEqual(activity.presentation, .webSearch)
        XCTAssertEqual(activity.searchPatterns, ["Swift docs"])
        XCTAssertEqual(activity.webResults, [.init(title: "Guide", url: "https://example.com")])
        let restored = try JSONDecoder().decode(AgentToolActivity.self, from: JSONEncoder().encode(activity))
        XCTAssertEqual(restored, activity)
        var fetch = agentToolActivity(name: "WebFetch", input: #"{"url":" https://example.com "}"#)
        fetch.output = String(repeating: "a", count: 9000)
        agentUpdateClaudeWebSearch(&fetch, result: nil)
        XCTAssertEqual(fetch.webResults?.first?.url, "https://example.com")
        XCTAssertEqual(fetch.webResults?.first?.snippet?.count, 8000)
    }
}
