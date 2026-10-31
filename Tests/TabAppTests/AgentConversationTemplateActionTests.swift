import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationTemplateActionTests: XCTestCase {
    func testSourcePromptAppendsAtEndPreservingExistingDraftAndCitationMetadata() throws {
        let surface = AgentPaneView(); surface.disposeConversation()
        surface.citationEnvironmentId = "project"; surface.citationThreadId = "thread"
        surface.composer.string = "User typed 🐈 "
        surface.composer.setSelectedRange(NSRange(location: (surface.composer.string as NSString).length, length: 0))
        XCTAssertTrue(surface.insertCitation(.init(environmentId: "project", threadId: "thread", messageId: "answer", text: "Quoted source", start: 0, end: 13, prefix: "", suffix: "")))
        let original = surface.composer.attributedString().copy() as? NSAttributedString
        let source = try XCTUnwrap(original)
        let current = try XCTUnwrap((AgentConversationTemplateAction.perform(["phase": "read"], surface: surface) as? [String: String])?["prompt"])
        surface.composer.setSelectedRange(NSRange(location: 0, length: 4))
        let appended = " Create a presentation using the $artifact-template-slides template about…"
        _ = try AgentConversationTemplateAction.perform(["phase": "append", "expectedPrompt": current, "append": appended], surface: surface)
        XCTAssertEqual(surface.composer.attributedString().attributedSubstring(from: NSRange(location: 0, length: source.length)), source)
        XCTAssertEqual(AgentComposerCitation.prompt(from: surface.composer.attributedString()), current + appended)
        XCTAssertNil(surface.composer.attributedString().attribute(.agentAssistantCitation, at: source.length, effectiveRange: nil))
        XCTAssertEqual(surface.composer.selectedRange(), NSRange(location: source.length + (appended as NSString).length, length: 0))
    }

    func testChangedDraftBusyComposerAndDedupDoNotEraseUserTextOrSelection() throws {
        let surface = AgentPaneView(); surface.disposeConversation()
        surface.composer.string = "Draft typed while the source action was awaiting its reply"
        let selection = NSRange(location: 2, length: 5)
        surface.composer.setSelectedRange(selection)
        XCTAssertThrowsError(try AgentConversationTemplateAction.perform(["phase": "append", "expectedPrompt": "stale", "append": " must not appear"], surface: surface))
        let current = surface.composer.string
        XCTAssertEqual(surface.composer.selectedRange(), selection)
        _ = try AgentConversationTemplateAction.perform(["phase": "append", "expectedPrompt": current, "append": ""], surface: surface)
        XCTAssertEqual(surface.composer.string, current)
        XCTAssertEqual(surface.composer.selectedRange(), selection)
        surface.composer.isEditable = false
        XCTAssertThrowsError(try AgentConversationTemplateAction.perform(["phase": "append", "expectedPrompt": current, "append": " unavailable"], surface: surface))
        XCTAssertEqual(surface.composer.string, current)
    }
}
