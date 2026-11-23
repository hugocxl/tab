import AppKit
import TabClient
import TabCore
import TabProtocol
import XCTest
@testable import TabApp

/// Archived pages loaded above a conversation's retained items, as the server trims more,
/// the pane reconnects and pages arrive late.
@MainActor
final class AgentEarlierTimelineTests: XCTestCase {
    /// A server's conversation: an append-only archive of trimmed items and the retained
    /// window after it.
    private final class Server {
        let session = SessionId()
        let project = ProjectId()
        var archive: [AgentChatItem] = []
        var retained: [AgentChatItem] = []
        var revision: UInt64 = 1
        var pageLimit = 4
        var pageGate: CheckedContinuation<Void, Never>?
        var gateNextPage = false
        var pageRequests: [Int?] = []

        init(archived: Int, retained: Int) {
            archive = (0..<archived).map { AgentChatItem(id: "a\($0)", kind: .assistant, text: "Archived \($0)") }
            self.retained = (0..<retained).map { AgentChatItem(id: "r\($0)", kind: .assistant, text: "Retained \($0)") }
        }

        var snapshot: AgentChatSnapshot {
            var snapshot = AgentChatSnapshot(session: session, project: project, provider: .claude, status: .idle,
                                             revision: revision, items: retained)
            snapshot.omittedItems = archive.count
            return snapshot
        }

        /// A turn adds `added` items and trims as many from the window's start.
        func turn(adding added: Int, prefix: String) {
            retained += (0..<added).map { AgentChatItem(id: "\(prefix)\($0)", kind: .assistant, text: "New \(prefix) \($0)") }
            archive += retained.prefix(added)
            retained.removeFirst(added)
            revision += 1
        }

        func page(before: Int?) async -> AgentEarlierItems {
            pageRequests.append(before)
            if gateNextPage {
                gateNextPage = false
                await withCheckedContinuation { pageGate = $0 }
            }
            let end = min(before ?? archive.count, archive.count)
            let start = max(0, end - pageLimit)
            return AgentEarlierItems(items: Array(archive[start..<end]), start: start, total: archive.count)
        }
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition not met", file: file, line: line)
    }

    private func pane(_ server: Server) -> AgentPaneController {
        let pane = AgentPaneController(session: server.session, project: server.project, provider: .claude) { _ in server.snapshot }
        pane.conversationRequest = { request in
            switch request {
            case .earlier(_, let before, _): return .earlier(await server.page(before: before))
            default: throw ClientError.server(ErrorReply(code: .unsupported, message: ""))
            }
        }
        pane.surface.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        pane.surface.layoutSubtreeIfNeeded()
        return pane
    }

    private func shownIDs(_ pane: AgentPaneController) -> [String] { pane.surface.snapshot?.items.map(\.id) ?? [] }

    func testLoadedHistorySurvivesTrimsReconnectsAndLatePagesWithoutDuplicatesOrGaps() async throws {
        _ = NSApplication.shared
        let server = Server(archived: 10, retained: 5)
        let pane = pane(server)
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        XCTAssertNotNil(pane.surface.onLoadEarlier)

        // Load to the beginning.
        while pane.surface.onLoadEarlier != nil, server.pageRequests.count < 10 {
            let count = server.pageRequests.count
            pane.loadEarlier()
            try await wait { server.pageRequests.count > count && !self.shownIDs(pane).isEmpty && pane.earlierItems.count >= min(10, (count + 1) * 4) }
        }
        XCTAssertEqual(shownIDs(pane), (0..<10).map { "a\($0)" } + (0..<5).map { "r\($0)" })
        XCTAssertEqual(pane.surface.snapshot?.omittedItems, 0)
        XCTAssertNil(pane.surface.onLoadEarlier, "The beginning is loaded")

        // Read near the top, away from the end.
        let scroll = pane.surface.transcriptScroll
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 40))
        scroll.reflectScrolledClipView(scroll.contentView)
        pane.surface.layoutSubtreeIfNeeded()
        XCTAssertFalse(pane.surface.isAtBottom)
        let anchor = pane.surface.transcript.captureAnchor(at: scroll.contentView.bounds.minY).rowID
        XCTAssertNotNil(anchor)

        // Another turn trims two items the reader already has.
        server.turn(adding: 2, prefix: "n")
        pane.sessionChanged(session: server.session, revision: server.revision)
        try await wait { pane.snapshot?.revision == server.revision }
        let expected = (0..<10).map { "a\($0)" } + (0..<5).map { "r\($0)" } + ["n0", "n1"]
        XCTAssertEqual(shownIDs(pane), expected, "Loaded pages stay and the trimmed items stay in place")
        XCTAssertEqual(pane.surface.snapshot?.omittedItems, 0)
        XCTAssertNil(pane.surface.onLoadEarlier, "Nothing is missing")
        XCTAssertEqual(pane.surface.transcript.captureAnchor(at: scroll.contentView.bounds.minY).rowID, anchor,
                       "The reading position holds")
        XCTAssertFalse(pane.surface.isAtBottom, "No jump to the bottom")

        // Disconnected, the server runs two turns and trims items this pane never saw.
        server.turn(adding: 4, prefix: "m")
        server.turn(adding: 4, prefix: "k")
        let pagesBefore = server.pageRequests.count
        pane.connectionChanged()
        try await wait { pane.snapshot?.revision == server.revision }
        try await wait { server.pageRequests.count > pagesBefore && !pane.earlier.needsGapFill }
        let all = server.archive.map(\.id) + server.retained.map(\.id)
        try await wait { self.shownIDs(pane) == all }
        XCTAssertEqual(Set(shownIDs(pane)).count, shownIDs(pane).count, "No duplicates")
        XCTAssertEqual(server.pageRequests.suffix(from: pagesBefore).first, .some(nil), "The gap fills from the newest page")
        XCTAssertNil(pane.surface.onLoadEarlier)
        XCTAssertFalse(pane.surface.isAtBottom, "No jump to the bottom")
    }

    func testAPageThatArrivesAfterAReconnectTrimmedMoreStillAppliesAndFillsWhatItMissed() async throws {
        _ = NSApplication.shared
        let server = Server(archived: 12, retained: 4)
        let pane = pane(server)
        defer { pane.dispose() }
        pane.refresh()
        try await wait { pane.snapshot != nil }
        pane.loadEarlier()
        try await wait { pane.earlierItems.count == 4 }
        XCTAssertNotNil(pane.surface.onLoadEarlier, "Older pages remain")

        // Ask for the next older page and hold it while the conversation trims and reconnects.
        server.gateNextPage = true
        pane.loadEarlier()
        try await wait { server.pageGate != nil }
        server.turn(adding: 6, prefix: "n")
        pane.connectionChanged()
        try await wait { pane.snapshot?.revision == server.revision }
        XCTAssertNotNil(pane.surface.onLoadEarlier, "A gap keeps the loader available")
        server.pageGate?.resume()
        server.pageGate = nil
        let loaded = Array(server.archive[4...]).map(\.id) + server.retained.map(\.id)
        try await wait { self.shownIDs(pane) == loaded }
        XCTAssertEqual(pane.surface.snapshot?.omittedItems, 4, "The late page applied, and the trimmed items joined up")
        XCTAssertNotNil(pane.surface.onLoadEarlier)
        pane.loadEarlier()
        try await wait { self.shownIDs(pane).first == "a0" }
        XCTAssertEqual(shownIDs(pane), server.archive.map(\.id) + server.retained.map(\.id))
        XCTAssertNil(pane.surface.onLoadEarlier)
    }

    func testTimelineKeysPagesByResetAndIdentity() {
        var timeline = AgentEarlierTimeline()
        let window = (0..<3).map { AgentChatItem(id: "r\($0)", kind: .user, text: "\($0)") }
        let reset = SessionId()
        XCTAssertEqual(timeline.observe(window, omitted: 5, resetID: reset).omitted, 5)
        XCTAssertTrue(timeline.canLoadMore)
        let page = AgentEarlierItems(items: (2..<5).map { AgentChatItem(id: "a\($0)", kind: .user, text: "") } + [window[0]],
                                     start: 2, total: 6)
        XCTAssertTrue(timeline.accept(page, before: nil, resetID: reset))
        XCTAssertEqual(timeline.shown.items.map(\.id), ["a2", "a3", "a4", "r0", "r1", "r2"], "A retained item in a page shows once")
        XCTAssertFalse(timeline.accept(page, before: nil, resetID: SessionId()), "Another reset's page is refused")
        // Clearing the conversation in place starts over.
        XCTAssertEqual(timeline.observe([], omitted: 0, resetID: SessionId()).items, [])
        XCTAssertFalse(timeline.isLoaded)
    }

    func testTrimmedItemsKeepTheirTurnsAndTheLeadStaysUnchanged() {
        func item(_ id: String, _ kind: AgentChatItem.Kind = .assistant) -> AgentChatItem { AgentChatItem(id: id, kind: kind, text: id) }
        func turn(_ user: String) -> AgentChatTurn {
            AgentChatTurn(userItemID: user, startedAt: Date(timeIntervalSince1970: 1), completedAt: Date(timeIntervalSince1970: 2), status: .idle)
        }
        var timeline = AgentEarlierTimeline()
        _ = timeline.observe([item("u1", .user), item("a1"), item("u2", .user), item("a2")], turns: [turn("u1"), turn("u2")],
                             omitted: 2, resetID: nil)
        timeline.accept(AgentEarlierItems(items: [item("x"), item("y")], start: 0, total: 2), before: nil, resetID: nil)
        var shown = timeline.observe([item("u1", .user), item("a1"), item("u2", .user), item("a2")], turns: [turn("u1"), turn("u2")],
                                     omitted: 2, resetID: nil)
        XCTAssertEqual(shown.unchangedLead, 0, "A loaded page comes before everything shown")
        XCTAssertEqual(shown.items.items.map(\.id), ["x", "y", "u1", "a1", "u2", "a2"])
        // The server trims the first turn out of its window, and its turn with it.
        shown = timeline.observe([item("u2", .user), item("a2"), item("u3", .user)], turns: [turn("u2"), turn("u3")],
                                 omitted: 4, resetID: nil)
        XCTAssertEqual(shown.items.items.map(\.id), ["x", "y", "u1", "a1", "u2", "a2", "u3"])
        XCTAssertEqual(shown.turns.map(\.userItemID), ["u1", "u2", "u3"], "The carried turn keeps its shape")
        XCTAssertEqual(shown.unchangedLead, 2, "What was shown first is still shown first")
        shown = timeline.observe([item("u2", .user), item("a2"), item("u3", .user)], turns: [turn("u2"), turn("u3")],
                                 omitted: 4, resetID: nil)
        XCTAssertEqual(shown.unchangedLead, 4)
    }
}
