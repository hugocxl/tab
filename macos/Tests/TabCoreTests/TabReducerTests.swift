import XCTest
@testable import TabCore

final class TabReducerTests: XCTestCase {
    private let home = ProjectId()
    private let project = ProjectId()

    @discardableResult
    private func apply(_ mutation: TabMutation, _ board: inout TabBoard) throws -> TabChangeEffects {
        try TabReducer.apply(mutation, to: &board) { [home, project] in $0 == home || $0 == project }
    }

    private func terminal(_ session: SessionId? = nil) -> Pane { Pane(content: .terminal(session: session)) }

    /// A Home tab of `panes` side by side.
    private func board(_ panes: [Pane]) throws -> (TabBoard, TabId) {
        var board = TabBoard(home: home)
        let tab = Tab(pane: panes[0])
        try apply(.createTab(project: home, tab: tab, after: nil), &board)
        for (anchor, pane) in zip(panes, panes.dropFirst()) {
            try apply(.insertPane(pane, anchor: anchor.id, edge: .right), &board)
        }
        return (board, tab.id)
    }

    func testChangesFromTwoAppsToDifferentPanesBothApply() throws {
        let a = terminal(), b = terminal()
        let (base, tab) = try board([a, b])
        let fromFirst = TabMutation.insertPane(terminal(), anchor: a.id, edge: .down)
        let fromSecond = TabMutation.insertPane(terminal(), anchor: b.id, edge: .down)
        var oneWay = base, otherWay = base
        try apply(fromFirst, &oneWay)
        try apply(fromSecond, &oneWay)
        try apply(fromSecond, &otherWay)
        try apply(fromFirst, &otherWay)
        XCTAssertEqual(oneWay.tab(tab)?.panes.count, 4)
        XCTAssertEqual(Set(oneWay.tab(tab)?.layout.leaves ?? []), Set(otherWay.tab(tab)?.layout.leaves ?? []))
    }

    func testARefusedChangeLeavesTheTabsAsTheyWere() throws {
        let a = terminal(), b = terminal()
        var (board, tab) = try board([a, b])
        let before = board
        try apply(.removePane(b.id, keepSession: false), &board)
        var stale = board
        XCTAssertThrowsError(try apply(.insertPane(terminal(), anchor: b.id, edge: .right), &stale)) { error in
            XCTAssertEqual(error as? TabChangeError, .gone("pane"))
        }
        XCTAssertEqual(stale, board)
        board = before
        XCTAssertThrowsError(try apply(.insertPane(a, anchor: b.id, edge: .right), &board))
        XCTAssertThrowsError(try apply(.createTab(project: ProjectId(), tab: Tab(pane: terminal()), after: nil), &board))
        XCTAssertThrowsError(try apply(.updatePane(a.id, content: .browser(BrowserPane())), &board))
        XCTAssertThrowsError(try apply(.closeTab(TabId(), keepSessions: false), &board))
        XCTAssertEqual(board, before)
        XCTAssertNotNil(board.tab(tab))
    }

    func testARatioNamesItsSplitEvenAfterAnotherAppChangedTheLayout() throws {
        let a = terminal(), b = terminal()
        var (board, tab) = try board([a, b])
        let outer = try XCTUnwrap(board.tab(tab)?.layout.anchor(at: []))
        let c = terminal()
        try apply(.insertPane(c, anchor: a.id, edge: .down), &board)
        try apply(.setRatio(tab, split: outer, ratio: 0.3), &board)
        guard case let .split(_, ratio, _, _)? = board.tab(tab)?.layout else { return XCTFail("no split") }
        assertClose(ratio, 0.3)
        let inner = try XCTUnwrap(board.tab(tab)?.layout.anchor(at: [.first]))
        try apply(.removePane(c.id, keepSession: false), &board)
        let before = board
        XCTAssertThrowsError(try apply(.setRatio(tab, split: inner, ratio: 0.2), &board))
        XCTAssertEqual(board, before)
    }

    func testClosingPanesEndsOnlyTerminalsNoOtherPaneShows() throws {
        let shared = SessionId()
        let a = terminal(shared), b = terminal(shared), c = terminal(SessionId()), waiting = terminal()
        let agent = Pane(content: .agent(session: SessionId(), provider: .claude))
        var (board, tab) = try board([a, b, c, waiting, agent])
        var effects = try apply(.removePane(a.id, keepSession: false), &board)
        XCTAssertEqual(effects, TabChangeEffects())
        effects = try apply(.removePane(c.id, keepSession: true), &board)
        XCTAssertTrue(effects.endedSessions.isEmpty)
        effects = try apply(.closeTab(tab, keepSessions: false), &board)
        XCTAssertEqual(effects.endedSessions, [shared])
        XCTAssertEqual(effects.cancelledCreations, [waiting.id.creationToken])
        XCTAssertEqual(effects.closedAgents, [agent.content.agentSession])
        XCTAssertTrue(board.projects.isEmpty)
    }

    func testRestartingATerminalEndsTheOldOne() throws {
        let session = SessionId()
        let a = terminal(session), b = terminal()
        var (board, tab) = try board([a, b])
        let new = terminal()
        let effects = try apply(.replacePane(a.id, with: new), &board)
        XCTAssertEqual(effects.endedSessions, [session])
        XCTAssertEqual(board.tab(tab)?.layout.leaves, [new.id, b.id])
    }

    func testTwoAppsOpeningTheFirstTabOfAProjectBothKeepTheirPanes() throws {
        var board = TabBoard(home: home)
        let first = Tab(pane: terminal()), second = Tab(pane: terminal())
        try apply(.createTab(project: project, tab: first, after: nil), &board)
        try apply(.createTab(project: project, tab: second, after: nil), &board)
        XCTAssertEqual(board.tabs(project).count, 1)
        XCTAssertEqual(board.tabs(project).first?.id, first.id)
        XCTAssertEqual(board.tabs(project).first?.layout.leaves, first.layout.leaves + second.layout.leaves)
    }

    func testNewHomeTabsGoAfterTheirAnchorAndThePinnedTabs() throws {
        var board = TabBoard(home: home)
        var pinned = Tab(pane: terminal())
        pinned.pinned = true
        let plain = Tab(pane: terminal())
        try apply(.createTab(project: home, tab: pinned, after: nil), &board)
        try apply(.createTab(project: home, tab: plain, after: nil), &board)
        let early = Tab(pane: terminal())
        try apply(.createTab(project: home, tab: early, after: TabId()), &board)
        let next = Tab(pane: terminal())
        try apply(.createTab(project: home, tab: next, after: pinned.id), &board)
        XCTAssertEqual(board.tabs(home).map(\.id), [pinned.id, next.id, plain.id, early.id])
    }

    func testAdoptingTabsKeptBeforeLeavesOutWhatTheServerAlreadyHasAndCanRepeat() throws {
        let session = SessionId()
        let shown = terminal(session)
        var (board, _) = try board([shown])
        let duplicate = terminal(session), fresh = terminal()
        var kept = Tab(pane: duplicate)
        kept.layout.split(duplicate.id, new: fresh.id, edge: .right)
        kept.panes.append(fresh)
        let alreadyThere = try XCTUnwrap(board.tabs(home).first)
        try apply(.adoptTabs(project: home, tabs: [alreadyThere, kept]), &board)
        let once = board
        XCTAssertEqual(board.tabs(home).count, 2)
        XCTAssertEqual(board.tabs(home).last?.panes, [fresh])
        try apply(.adoptTabs(project: home, tabs: [alreadyThere, kept]), &board)
        XCTAssertEqual(board, once)
        let other = Tab(pane: terminal()), more = Tab(pane: terminal())
        try apply(.adoptTabs(project: project, tabs: [other, more]), &board)
        XCTAssertEqual(board.tabs(project).count, 1)
        XCTAssertEqual(board.tabs(project).first?.panes.count, 2)
    }

    func testOnlyAWaitingTerminalTakesASessionAndAnEndedOneClosesItsPanes() throws {
        let a = terminal(), b = terminal(), browser = Pane(content: .browser(BrowserPane()))
        var (board, tab) = try board([a, b, browser])
        let session = SessionId()
        XCTAssertTrue(TabReducer.bind(session, to: a.id, proxy: true, in: &board))
        XCTAssertFalse(TabReducer.bind(SessionId(), to: a.id, proxy: false, in: &board))
        XCTAssertFalse(TabReducer.bind(session, to: browser.id, proxy: false, in: &board))
        XCTAssertFalse(TabReducer.bind(session, to: PaneId(), proxy: false, in: &board))
        let bound = try XCTUnwrap(board.tab(tab)?.pane(a.id))
        XCTAssertEqual(bound.content, .terminal(session: session))
        XCTAssertTrue(bound.proxy)
        XCTAssertNil(bound.launch)
        XCTAssertTrue(TabReducer.removePanes(showing: session, in: &board))
        XCTAssertFalse(TabReducer.removePanes(showing: session, in: &board))
        XCTAssertEqual(board.tab(tab)?.layout.leaves, [b.id, browser.id])
    }

    func testTabsKeepTheirShapeOnTheWire() throws {
        var tab = Tab(pane: Pane(content: .terminal(session: nil), launch: TerminalLaunch(command: "ls")))
        tab.zoomed = tab.panes[0].id
        tab.panes[0].title = "Mine"
        let decoded = try roundTrip(tab)
        XCTAssertEqual(decoded, tab)
        XCTAssertNil(decoded.zoomed, "zoom is each app's own")
        XCTAssertEqual(decoded.panes[0].title, "Terminal", "titles are each app's own")
        XCTAssertEqual(decoded.panes[0].launch?.command, "ls")
    }
}
