import TabProtocol
import XCTest
@testable import TabMobileKit

final class AgentConversationNavigationTests: XCTestCase {
    func testPromptNavigationStopsAtTheEnds() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ids, current: "b", previous: true), "a")
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ids, current: "b", previous: false), "c")
        XCTAssertNil(AgentPromptNavigation.destination(ids: ids, current: "a", previous: true))
        XCTAssertNil(AgentPromptNavigation.destination(ids: ids, current: "c", previous: false))
        XCTAssertEqual(AgentPromptNavigation.destination(ids: ids, current: "gone", previous: true), "c")
        XCTAssertNil(AgentPromptNavigation.destination(ids: [], current: nil, previous: false))
    }

    func testOutlineListsPromptsIncludingAttachmentOnlyOnes() {
        var image = AgentChatItem(id: "u2", kind: .user, text: " ")
        image.attachments = [AgentChatAttachmentDescriptor(id: "i", name: "a.png", mimeType: "image/png", byteCount: 3)]
        let items = [AgentChatItem(id: "u1", kind: .user, text: "fix\nit"), AgentChatItem(id: "a", kind: .assistant, text: "ok"), image]
        let entries = AgentPromptNavigation.entries(items)
        XCTAssertEqual(entries.map(\.id), ["u1", "u2"])
        XCTAssertEqual(entries[0].title, "fix it")
        XCTAssertEqual(entries[1].title, "Attachments")
        XCTAssertEqual(entries[1].detail, "Prompt 2 · 1 attachment")
        XCTAssertTrue(entries[0].matches("FIX"))
        XCTAssertFalse(entries[0].matches("tests"))
    }

    private func todo(_ id: String, _ steps: [(String, String)]) -> AgentChatItem {
        let json = try? JSONSerialization.data(withJSONObject: ["steps": steps.enumerated().map { index, step in
            ["id": "\(index)", "text": step.0, "status": step.1]
        }])
        var item = AgentChatItem(id: id, kind: .tool, text: "Tasks", detail: json.flatMap { String(data: $0, encoding: .utf8) })
        item.workContext = AgentChatWorkContext(itemType: "todo_list")
        return item
    }

    private func snapshot(_ items: [AgentChatItem], status: AgentChatStatus) -> AgentChatSnapshot {
        AgentChatSnapshot(session: SessionId(), project: ProjectId(), provider: .claude, status: status, revision: 1, items: items)
    }

    func testTaskProgressFollowsTheLatestUnfinishedList() {
        var progress = AgentTaskProgress()
        progress.update(snapshot([todo("t1", [("Read", "completed"), ("Test", "running"), ("Ship", "pending")])], status: .working))
        XCTAssertEqual(progress.title, "1 of 3 done · Test")
        XCTAssertEqual(progress.target, "t1")
        progress.update(snapshot([todo("t1", [("Read", "completed"), ("Test", "running"), ("Ship", "pending")])], status: .idle))
        XCTAssertEqual(progress.title, "Paused · 1 of 3 done · Test")
        progress.update(snapshot([todo("t2", [("Read", "completed")])], status: .idle))
        XCTAssertNil(progress.target)
        progress.update(nil)
        XCTAssertNil(progress.target)
    }

    func testReviewSelectionUsesOneSideAndNeverCrossesAHunk() {
        let rows = [
            GitDiffRow(kind: .hunk, text: "@@ -1,2 +1,2 @@"),
            GitDiffRow(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: " keep"),
            GitDiffRow(kind: .deletion, oldLineNumber: 2, text: "-old"),
            GitDiffRow(kind: .addition, newLineNumber: 2, text: "+new"),
        ]
        let new = AgentReviewComment.selection(rows[1...3], old: false)
        XCTAssertEqual(new?.first, 1)
        XCTAssertEqual(new?.last, 2)
        XCTAssertEqual(new?.source, "keep\nnew")
        XCTAssertEqual(AgentReviewComment.selection(rows[1...2], old: true)?.source, "keep\nold")
        XCTAssertNil(AgentReviewComment.selection(rows[0...1], old: false))
        XCTAssertNil(AgentReviewComment.selection(rows[2...2], old: false))
    }

    func testReviewPromptCarriesFileSideLinesAndSource() {
        let comment = AgentReviewComment(checkpoint: "c", path: "a.swift", old: false, firstLine: 4, lastLine: 5,
                                         source: "let a\nlet b", text: "Rename these")
        let prompt = AgentReviewComment.prompt([comment])
        XCTAssertTrue(prompt.contains("File: a.swift\nCheckpoint: c\nSide: new\nLines: 4–5"))
        XCTAssertTrue(prompt.contains("> let a\n> let b"))
        XCTAssertTrue(prompt.hasSuffix("Comment:\nRename these"))
    }

    /// Drafts saved before review comments existed still read, and new ones keep them.
    func testDraftKeepsReviewCommentsAndReadsOlderFiles() throws {
        let older = try JSONDecoder().decode(AgentDraft.self, from: Data(#"{"text":"hi","attachments":[],"answers":{}}"#.utf8))
        XCTAssertEqual(older.text, "hi")
        XCTAssertTrue(older.reviewComments.isEmpty)
        let comment = AgentReviewComment(checkpoint: "c", path: "a", old: true, firstLine: 1, lastLine: 1, source: "x", text: "y")
        let draft = AgentDraft(reviewComments: [comment])
        XCTAssertFalse(draft.isEmpty)
        let decoded = try JSONDecoder().decode(AgentDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(decoded.reviewComments, [comment])
    }
}
