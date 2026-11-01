import Foundation
import TabProtocol
import XCTest
@testable import TabApp

final class AgentConversationFindModelTests: XCTestCase {
    private func plan(_ id: String, _ markdown: String) -> AgentChatItem {
        AgentChatItem(id: id, kind: .tool, text: "Proposed plan", detail: markdown,
                      workContext: .init(itemType: "proposed_plan", sourceStatus: "completed", planStatus: "active"))
    }

    private func search(_ query: String, _ items: [AgentChatItem]) -> AgentConversationFindModel {
        var model = AgentConversationFindModel()
        model.search(query, in: items)
        return model
    }

    func testMatchesFollowItemOrderThenPosition() {
        let model = search("cat", [
            .init(id: "a", kind: .user, text: "cat and another cat"),
            .init(id: "b", kind: .assistant, text: "no match here"),
            .init(id: "c", kind: .assistant, text: "concatenate"),
        ])
        XCTAssertEqual(model.matches.map(\.itemID), ["a", "a", "c"])
        XCTAssertEqual(model.matches.map(\.range.location), [0, 16, 3])
        XCTAssertEqual(model.matches.map(\.ordinal), [0, 1, 0])
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testSearchIgnoresCase() {
        let model = search("SWIFT", [.init(id: "a", kind: .assistant, text: "Swift, swift and sWiFt")])
        XCTAssertEqual(model.matches.count, 3)
    }

    func testSearchIgnoresDiacritics() {
        let model = search("cafe", [.init(id: "a", kind: .assistant, text: "Un café, un CAFÉ, un cafe")])
        XCTAssertEqual(model.matches.count, 3)
        XCTAssertEqual(search("é", [.init(id: "a", kind: .user, text: "e E é")]).matches.count, 3)
    }

    func testOccurrencesDoNotOverlap() {
        XCTAssertEqual(search("aa", [.init(id: "a", kind: .user, text: "aaaaa")]).matches.count, 2)
    }

    func testCounterDescribesQueryResults() {
        let items: [AgentChatItem] = [.init(id: "a", kind: .assistant, text: "one two one")]
        XCTAssertEqual(search("", items).counter, "")
        XCTAssertEqual(search("three", items).counter, "No results")
        XCTAssertNil(search("three", items).selected)
        var model = search("one", items)
        XCTAssertEqual(model.counter, "1 of 2")
        model.selectNext()
        XCTAssertEqual(model.counter, "2 of 2")
    }

    func testNextWrapsFromLastToFirst() {
        var model = search("x", [.init(id: "a", kind: .user, text: "x x x")])
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.selectedIndex, 2)
        model.selectNext()
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testPreviousWrapsFromFirstToLast() {
        var model = search("x", [.init(id: "a", kind: .user, text: "x x x")])
        model.selectPrevious()
        XCTAssertEqual(model.selectedIndex, 2)
        model.selectPrevious()
        XCTAssertEqual(model.selectedIndex, 1)
    }

    func testSteppingWithoutMatchesDoesNothing() {
        var model = search("x", [.init(id: "a", kind: .user, text: "nothing")])
        model.selectNext()
        model.selectPrevious()
        XCTAssertNil(model.selectedIndex)
    }

    func testProposedPlanMarkdownIsSearched() {
        let model = search("migrate", [
            .init(id: "a", kind: .user, text: "Plan it"),
            plan("plan", "## Steps\n\n1. Migrate the store\n2. Migrate the tests"),
        ])
        XCTAssertEqual(model.matches.map(\.itemID), ["plan", "plan"])
    }

    func testToolOutputNoticesAndApprovalsAreNotSearched() {
        let model = search("secret", [
            .init(id: "tool", kind: .tool, text: "Read secret", detail: "secret output",
                  tool: .init(name: "Read", input: "{\"path\":\"secret\"}", output: "secret")),
            .init(id: "notice", kind: .notice, text: "secret notice"),
            .init(id: "approval", kind: .approval, text: "Allow secret?", isComplete: false),
            .init(id: "answer", kind: .assistant, text: "No secret here… well, one."),
        ])
        XCTAssertEqual(model.matches.map(\.itemID), ["answer"])
    }

    func testStreamingKeepsSelectionOnTheSameOccurrence() {
        var items: [AgentChatItem] = [
            .init(id: "a", kind: .user, text: "find the needle"),
            .init(id: "b", kind: .assistant, text: "a needle and a needle", isComplete: false),
        ]
        var model = search("needle", items)
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.selected, .init(itemID: "b", range: NSRange(location: 15, length: 6), ordinal: 1))
        items[1].text += " and another needle"
        items.insert(.init(id: "earlier", kind: .assistant, text: "needle first"), at: 0)
        model.update(items)
        XCTAssertEqual(model.matches.count, 5)
        XCTAssertEqual(model.selected?.itemID, "b")
        XCTAssertEqual(model.selected?.range.location, 15)
        XCTAssertEqual(model.counter, "4 of 5")
    }

    func testSelectionClampsWhenItsOccurrenceDisappears() {
        var items: [AgentChatItem] = [.init(id: "a", kind: .assistant, text: "x x x x")]
        var model = search("x", items)
        model.selectPrevious()
        XCTAssertEqual(model.selectedIndex, 3)
        items[0].text = "x x"
        model.update(items)
        XCTAssertEqual(model.selectedIndex, 1)
        items[0].text = "none"
        model.update(items)
        XCTAssertNil(model.selectedIndex)
        XCTAssertEqual(model.counter, "No results")
    }

    func testRefiningTheQueryKeepsTheReaderNearTheSelection() {
        let items: [AgentChatItem] = [
            .init(id: "a", kind: .user, text: "test one"),
            .init(id: "b", kind: .assistant, text: "test two, testing"),
            .init(id: "c", kind: .assistant, text: "testing three"),
        ]
        var model = search("test", items)
        model.selectNext()
        model.selectNext()
        XCTAssertEqual(model.selected?.range.location, 10)
        model.search("testi", in: items)
        XCTAssertEqual(model.selected?.itemID, "b")
        XCTAssertEqual(model.selected?.range.location, 10)
        XCTAssertEqual(model.counter, "1 of 2")
    }

    func testUnchangedItemsReuseTheirMatchesAcrossUpdates() {
        let long = String(repeating: "word ", count: 2_000)
        var items: [AgentChatItem] = (0..<50).map { .init(id: "\($0)", kind: .assistant, text: long) }
        var model = search("word", items)
        XCTAssertEqual(model.matches.count, 100_000)
        items.append(.init(id: "new", kind: .assistant, text: "word", isComplete: false))
        model.update(items)
        XCTAssertEqual(model.matches.count, 100_001)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    // MARK: Rendered text

    /// Renders like the transcript would for these tests: link targets and emphasis
    /// markers disappear.
    private static func rendered(_ item: AgentChatItem) -> String? {
        AgentConversationFindModel.searchableText(item).map {
            $0.replacingOccurrences(of: "(https://example.com/needle)", with: "").replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "**", with: "")
        }
    }

    func testTheRenderedTextIsSearchedNotTheMarkdownSource() {
        var model = AgentConversationFindModel(text: Self.rendered)
        model.search("needle", in: [.init(id: "a", kind: .assistant, text: "A [needle](https://example.com/needle) here")])
        XCTAssertEqual(model.counter, "1 of 1", "The link's URL is not a match")
        XCTAssertEqual(model.selected?.range, NSRange(location: 2, length: 6), "Ranges address the rendered text")
        XCTAssertEqual(model.searched("a")?.text, "A needle here")
    }

    func testAPhraseAcrossFormattingIsFound() {
        var model = AgentConversationFindModel(text: Self.rendered)
        model.search("see the docs", in: [.init(id: "a", kind: .assistant, text: "Please see **the** docs.")])
        XCTAssertEqual(model.counter, "1 of 1")
    }

    func testItemsWhoseSourceLacksAWordOfTheQueryAreNotRendered() {
        var rendered: [String] = []
        var model = AgentConversationFindModel { item in rendered.append(item.id); return item.text }
        model.search("needle", in: [
            .init(id: "a", kind: .assistant, text: "Only hay"),
            .init(id: "b", kind: .assistant, text: "A needle"),
        ])
        XCTAssertEqual(rendered, ["b"])
        XCTAssertEqual(model.renderCount, 1)
        XCTAssertNil(model.searched("a")?.text)
        XCTAssertEqual(model.searched("a")?.ranges, [])
    }

    func testMayMatchNeedsEveryWordOfTheQuery() {
        XCTAssertTrue(AgentConversationFindModel.mayMatch("see the docs", renderedFrom: "see **the** docs"))
        XCTAssertTrue(AgentConversationFindModel.mayMatch("CAFE", renderedFrom: "un café"))
        XCTAssertFalse(AgentConversationFindModel.mayMatch("needle", renderedFrom: "haystack"))
        XCTAssertTrue(AgentConversationFindModel.mayMatch("<->", renderedFrom: "no punctuation words"),
                      "A query without words is always rendered and searched")
    }

    func testRenderedTextsAreKeptAcrossQueriesAndRenderedAgainWhenTheyChange() {
        var items: [AgentChatItem] = [
            .init(id: "a", kind: .user, text: "needle and thread"),
            .init(id: "b", kind: .assistant, text: "a needle", isComplete: false),
        ]
        var model = AgentConversationFindModel { $0.text }
        model.search("needle", in: items)
        XCTAssertEqual(model.renderCount, 2)
        model.search("needl", in: items)
        model.search("thread", in: items)
        XCTAssertEqual(model.renderCount, 2, "Refining the query searches the kept texts")
        items[1].text += " and thread"
        model.update(items)
        XCTAssertEqual(model.renderCount, 3, "Only the streaming item renders again")
        XCTAssertEqual(model.counter, "1 of 2")
    }
}
