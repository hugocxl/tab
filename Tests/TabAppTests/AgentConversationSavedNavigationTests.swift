import AppKit
import TabProtocol
import XCTest
@testable import TabApp

@MainActor
final class AgentConversationSavedNavigationTests: XCTestCase {
    func testSavedLinkReadsExactlyTheRequestedSessionAndRetainsItsProvider() async throws {
        let session = SessionId(), project = ProjectId()
        let source = AgentChatSnapshot(session: session, project: project, provider: .codex, status: .closed,
                                       items: [.init(id: "answer", kind: .assistant, text: "Saved result", isComplete: true)])
        var requests: [AgentChatRequest] = []
        let result = try await AgentConversationSavedNavigation.read(session: session, project: project, request: { request in requests.append(request); return source })
        XCTAssertEqual(requests, [.read(session: session)])
        XCTAssertEqual(result, source)
    }

    func testMismatchedSessionOrProjectCannotBecomeANavigationTarget() async throws {
        let session = SessionId(), project = ProjectId()
        for result in [AgentChatSnapshot(session: SessionId(), project: project, provider: .claude),
                       AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude)] {
            do {
                _ = try await AgentConversationSavedNavigation.read(session: session, project: project, request: { _ in result })
                XCTFail("An unrelated server reply cannot authorize opening a cited pane")
            } catch {}
        }
    }

    func testExistingTargetShowsTheSnapshotBeforeRevealingTheCitation() async throws {
        _ = NSApplication.shared
        let session = SessionId(), project = ProjectId()
        let filler = (0..<30).map { AgentChatItem(id: "filler-\($0)", kind: .assistant, text: "Earlier answer \($0)\n\nwith a second paragraph.", isComplete: true) }
        let snapshot = AgentChatSnapshot(session: session, project: project, provider: .codex, status: .idle, revision: 2,
                                         items: [.init(id: "saved-answer", kind: .assistant, text: "Saved quote with more context.", isComplete: true)] + filler)
        var requests: [AgentChatRequest] = []
        let controller = AgentPaneController(session: session, project: project, provider: .codex) { request in requests.append(request); return snapshot }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = controller.surface
        controller.surface.frame = NSRect(x: 0, y: 0, width: 680, height: 500); controller.surface.layoutSubtreeIfNeeded()
        defer { controller.dispose(); window.close() }
        try await AgentConversationSavedNavigation.awaitTranscript(controller, snapshot: snapshot)
        let clip = controller.surface.transcriptScroll.contentView
        XCTAssertGreaterThan(clip.bounds.minY, 0, "The pane follows the end of a long conversation")
        let citation = AgentAssistantCitation(environmentId: project.description, threadId: session.description, messageId: "saved-answer",
                                             text: "Saved quote", start: 0, end: 11, prefix: "", suffix: " with more context.")
        XCTAssertTrue(controller.surface.revealCitation(citation))
        XCTAssertLessThan(clip.bounds.minY, 40, "The cited message is scrolled into view")
        var missing = citation
        missing.text = "Not in the message"
        XCTAssertFalse(controller.surface.revealCitation(missing))
        var foreign = citation
        foreign.threadId = SessionId().description
        XCTAssertFalse(controller.surface.revealCitation(foreign))
        XCTAssertEqual(controller.snapshot?.session, session)
        XCTAssertTrue(requests.allSatisfy { request in
            switch request { case .create(let found, let owner, _): return found == session && owner == project
            case .read(let found): return found == session
            default: return false }
        }, "Navigation must not send a prompt or allocate another session")
    }
}
