import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentComposerCitationTests: XCTestCase {
    func testCiteReplacesOnlyComposerSelectionAndPreservesCompleteSource() throws {
        _ = NSApplication.shared
        let pane = AgentPaneView(frame: .zero)
        pane.citationEnvironmentId = "project"; pane.citationThreadId = "thread"
        pane.composer.string = "before replace after"
        pane.composer.setSelectedRange(NSRange(location: 7, length: 7))
        let citation = fixture()
        XCTAssertTrue(pane.insertCitation(citation))
        XCTAssertEqual(AgentComposerCitation.prompt(from: pane.composer.attributedString()), "before " + citation.markdown + " after")
        XCTAssertTrue(pane.composer.string.hasPrefix("before ❝ "))
        XCTAssertEqual(pane.composer.selectedRange().length, 0)
        var wrong = citation; wrong.threadId = "different"
        let before = pane.composer.attributedString()
        XCTAssertFalse(pane.insertCitation(wrong))
        XCTAssertEqual(pane.composer.attributedString(), before)
    }

    func testEditingVisibleQuoteRemovesHiddenPayloadAndAdjacentQuotesRemainDistinct() throws {
        _ = NSApplication.shared
        let pane = AgentPaneView(frame: .zero)
        pane.citationEnvironmentId = "project"; pane.citationThreadId = "thread"
        let citation = fixture()
        XCTAssertTrue(pane.insertCitation(citation)); XCTAssertTrue(pane.insertCitation(citation))
        XCTAssertEqual(AgentComposerCitation.prompt(from: pane.composer.attributedString()), citation.markdown + citation.markdown)
        let edit = NSRange(location: 3, length: 1)
        XCTAssertTrue(pane.composer.shouldChangeText(in: edit, replacementString: "edited"))
        pane.composer.textStorage?.replaceCharacters(in: edit, with: "edited")
        let prompt = AgentComposerCitation.prompt(from: pane.composer.attributedString())
        XCTAssertTrue(prompt.contains("edited"))
        XCTAssertEqual(prompt.components(separatedBy: "[Assistant quote]").count - 1, 1)
        pane.composer.selectAll(nil)
        XCTAssertTrue(pane.composer.shouldChangeText(in: pane.composer.selectedRange(), replacementString: ""))
        pane.composer.textStorage?.replaceCharacters(in: pane.composer.selectedRange(), with: "")
        XCTAssertEqual(AgentComposerCitation.prompt(from: pane.composer.attributedString()), "")
    }

    func testSelectorMatchesSourceWhitespaceAndUTF16Fixtures() throws {
        let value = try XCTUnwrap(AgentConversationSelectionSelector.citation(in: "one  two\nthree", range: NSRange(location: 5, length: 8), environmentId: "project", threadId: "thread", messageId: "message"))
        XCTAssertEqual(value.text, "two\nthre"); XCTAssertEqual(value.start, 4); XCTAssertEqual(value.end, 12)
        XCTAssertEqual(value.prefix, "one "); XCTAssertEqual(value.suffix, "e")
        let emoji = try XCTUnwrap(AgentConversationSelectionSelector.citation(in: "😀 before quote after 😀", range: NSRange(location: 10, length: 5), environmentId: "project", threadId: "thread", messageId: "message"))
        XCTAssertEqual(emoji.text, "quote"); XCTAssertEqual(emoji.start, 10); XCTAssertEqual(emoji.prefix, "😀 before ")
    }

    private func fixture() -> AgentAssistantCitation {
        AgentAssistantCitation(environmentId: "project", threadId: "thread", messageId: "message", text: "Selected 😀\nsecond line", start: 4, end: 27, prefix: "one ", suffix: " after")
    }
}
