import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationTemplateActionTests: XCTestCase {
    func testTemplatePromptAppendsAtEndPreservingExistingDraftAndCitationMetadata() throws {
        let surface = AgentPaneView()
        surface.citationEnvironmentId = "project"; surface.citationThreadId = "thread"
        surface.composer.string = "User typed 🐈 "
        surface.composer.setSelectedRange(NSRange(location: (surface.composer.string as NSString).length, length: 0))
        XCTAssertTrue(surface.insertCitation(.init(environmentId: "project", threadId: "thread", messageId: "answer", text: "Quoted source", start: 0, end: 13, prefix: "", suffix: "")))
        let original = surface.composer.attributedString().copy() as? NSAttributedString
        let source = try XCTUnwrap(original)
        let current = try surface.actions.composerPrompt()
        surface.composer.setSelectedRange(NSRange(location: 0, length: 4))
        let appended = " Create a presentation using the $artifact-template-slides template about…"
        try surface.actions.useArtifactTemplate(appended, expectedPrompt: current)
        XCTAssertEqual(surface.composer.attributedString().attributedSubstring(from: NSRange(location: 0, length: source.length)), source)
        XCTAssertEqual(AgentComposerCitation.prompt(from: surface.composer.attributedString()), current + appended)
        XCTAssertNil(surface.composer.attributedString().attribute(.agentAssistantCitation, at: source.length, effectiveRange: nil))
        XCTAssertEqual(surface.composer.selectedRange(), NSRange(location: source.length + (appended as NSString).length, length: 0))
    }

    func testChangedDraftBusyComposerAndDedupDoNotEraseUserTextOrSelection() throws {
        let surface = AgentPaneView()
        surface.composer.string = "Draft typed while the template action was pending"
        let selection = NSRange(location: 2, length: 5)
        surface.composer.setSelectedRange(selection)
        XCTAssertThrowsError(try surface.actions.useArtifactTemplate(" must not appear", expectedPrompt: "stale"))
        let current = surface.composer.string
        XCTAssertEqual(surface.composer.selectedRange(), selection)
        try surface.actions.useArtifactTemplate("", expectedPrompt: current)
        XCTAssertEqual(surface.composer.string, current)
        XCTAssertEqual(surface.composer.selectedRange(), selection)
        surface.composer.isEditable = false
        XCTAssertThrowsError(try surface.actions.useArtifactTemplate(" unavailable", expectedPrompt: current))
        XCTAssertEqual(surface.composer.string, current)
    }
}
