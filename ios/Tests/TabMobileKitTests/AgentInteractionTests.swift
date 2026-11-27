import TabProtocol
import XCTest
@testable import TabMobileKit

@MainActor
final class AgentInteractionTests: XCTestCase {
    private let session = SessionId()

    private func controller(drafts: AgentDraftStore? = nil) -> AgentChatController {
        AgentChatController(session: session, project: ProjectId(), provider: .claude, server: nil, drafts: drafts)
    }

    private func snapshot(items: [AgentChatItem] = [], queued: [AgentQueuedPrompt]? = nil,
                          status: AgentChatStatus = .idle, revision: UInt64 = 1) -> AgentChatSnapshot {
        var snapshot = AgentChatSnapshot(session: session, project: ProjectId(), provider: .claude, status: status,
                                         revision: revision, items: items)
        snapshot.queuedPrompts = queued
        return snapshot
    }

    private func question(id: String = "q", complete: Bool = false) -> AgentChatItem {
        AgentChatItem(id: id, kind: .approval, text: "AskUserQuestion", isComplete: complete,
                      questionnaire: AgentQuestionnaire(questions: [
                          .init(id: "color", title: "Which color?", options: [.init(label: "Red"), .init(label: "Blue")]),
                          .init(id: "token", title: "Your token", secret: true),
                      ]))
    }

    private func queued(_ text: String, state: AgentQueuedPrompt.State = .queued) -> AgentQueuedPrompt {
        AgentQueuedPrompt(prompt: AgentPrompt(text: text, model: nil, effort: nil, provider: .claude, planMode: false),
                          state: state)
    }

    /// A message that didn't reach the server goes again with the same id, so
    /// the server can tell a retry from a new prompt.
    func testRetryingTheSameMessageKeepsItsPromptId() throws {
        let chat = controller()
        chat.accept(snapshot())
        chat.draftChanged(text: "Fix the build")
        chat.send()
        let first = try XCTUnwrap(chat.draft.submission)
        XCTAssertEqual(chat.draft.text, "Fix the build", "a send the server never took leaves the draft")
        chat.send()
        XCTAssertEqual(chat.draft.submission?.id, first.id)
        chat.draftChanged(text: "Fix the build, then test")
        chat.send()
        XCTAssertNotEqual(chat.draft.submission?.id, first.id, "an edited message is a new prompt")
    }

    func testPrivateAnswersAreNeverKeptInTheDraft() {
        let chat = controller()
        let item = question()
        chat.accept(snapshot(items: [item], status: .waiting))
        chat.questionAnswersChanged(["color": ["Red"], "token": ["s3cret"]], for: item)
        XCTAssertEqual(chat.draft.answers, ["q": ["color": ["Red"]]])
    }

    func testAnsweredQuestionsLeaveTheDraft() {
        let chat = controller()
        let item = question()
        chat.accept(snapshot(items: [item], status: .waiting))
        chat.questionAnswersChanged(["color": ["Blue"]], for: item)
        XCTAssertEqual(chat.pendingQuestion?.id, "q")
        chat.accept(snapshot(items: [question(complete: true)], revision: 2))
        XCTAssertNil(chat.pendingQuestion)
        XCTAssertTrue(chat.draft.answers.isEmpty)
    }

    func testQuestionsAreAnsweredInTheirFormNotTheTranscript() {
        let approval = AgentChatItem(id: "a", kind: .approval, text: "Bash", isComplete: false)
        let rows = AgentTranscript.rows(snapshot(items: [question(), approval], status: .waiting), expanded: [])
        XCTAssertEqual(rows.map(\.id), ["a"])
    }

    /// Only a prompt still waiting moves, and only ahead of another waiting one.
    func testQueuedPromptsMoveAheadOfTheWaitingOneBefore() {
        let chat = controller()
        let first = queued("one"), sending = queued("two", state: .delivering), last = queued("three")
        chat.accept(snapshot(queued: [first, sending, last], status: .working))
        XCTAssertEqual(chat.earlierQueued(than: last)?.id, first.id)
        XCTAssertNil(chat.earlierQueued(than: first))
        XCTAssertNil(chat.earlierQueued(than: sending))
        XCTAssertTrue(chat.isBusy)
    }

    func testAPausedQueueLeavesNothingToStop() {
        let chat = controller()
        var paused = snapshot(queued: [queued("later")])
        paused.queuePaused = true
        chat.accept(paused)
        XCTAssertFalse(chat.hasActiveQueue)
        XCTAssertFalse(chat.isBusy)
    }

    func testPlanModeWaitsForTheAgentToFinish() {
        let chat = controller()
        chat.accept(snapshot(status: .working))
        chat.togglePlanMode()
        XCTAssertEqual(chat.error, "Stop the current response before changing plan mode.")
    }

    /// Older servers send none of the new fields, and the phone reads them as empty.
    func testSnapshotsFromOlderServersHaveNoQueueOrPlan() throws {
        let json = """
        {"session":"\(session)","project":"\(ProjectId())","provider":"claude","status":"idle","revision":3,"items":[]}
        """
        let decoded = try JSONDecoder().decode(AgentChatSnapshot.self, from: Data(json.utf8))
        let chat = controller()
        chat.accept(decoded)
        XCTAssertFalse(chat.planMode)
        XCTAssertTrue(chat.queuedPrompts.isEmpty)
        XCTAssertNil(chat.pendingQuestion)
    }
}

final class AgentDraftStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDraftsOutliveTheAppAndOlderSavesNeverWin() async throws {
        let store = AgentDraftStore(directory: directory)
        let session = SessionId()
        let photo = AgentChatAttachment(name: "a.png", mimeType: "image/png", data: Data([1, 2, 3]))
        try await store.write(AgentDraft(text: "newer", attachments: [photo]), session: session, revision: 2)
        try await store.write(AgentDraft(text: "older"), session: session, revision: 1)
        let read = await AgentDraftStore(directory: directory).read(session)
        XCTAssertEqual(read?.text, "newer")
        XCTAssertEqual(read?.attachments, [photo])
    }

    func testAnEmptyDraftRemovesItsFile() async throws {
        let store = AgentDraftStore(directory: directory)
        let session = SessionId()
        try await store.write(AgentDraft(text: "hi"), session: session, revision: 1)
        try await store.write(AgentDraft(), session: session, revision: 2)
        let read = await store.read(session)
        XCTAssertNil(read)
    }

    func testDraftsTolerateUnknownAndMissingKeys() throws {
        let draft = try JSONDecoder().decode(AgentDraft.self, from: Data(#"{"text":"hi","future":1}"#.utf8))
        XCTAssertEqual(draft, AgentDraft(text: "hi"))
    }
}
