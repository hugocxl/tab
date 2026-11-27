import XCTest
@testable import TabCore

final class PanePositionTests: XCTestCase {
    func testEveryEdgeAndSharePreservesNestedRemainderAndIsIdempotent() throws {
        let layout: Layout<Int> = .split(axis: .horizontal, ratio: 0.4,
            first: .split(axis: .vertical, ratio: 0.3, first: .leaf(1), second: .leaf(2)),
            second: .split(axis: .horizontal, ratio: 0.6, first: .leaf(3), second: .leaf(4)))
        for pane in layout.leaves {
            var remainder = layout
            remainder.remove(pane)
            for edge in Direction.allCases {
                for share in [1.0 / 3, 0.5, 2.0 / 3] {
                    let result = try XCTUnwrap(layout.positioned(pane, edge: edge, share: share))
                    try result.validate()
                    XCTAssertEqual(Set(result.leaves), Set(layout.leaves))
                    XCTAssertEqual(result.leaves.count, layout.leaves.count)
                    let rect = try XCTUnwrap(result.rects.first { $0.0 == pane }?.1)
                    XCTAssertEqual(rect[edge.axis].size, share, accuracy: 0.000001)
                    XCTAssertEqual(rect[edge.axis].origin,
                                   edge == .left || edge == .up ? 0 : 1 - share, accuracy: 0.000001)
                    XCTAssertEqual(edge.axis == .horizontal ? rect.height : rect.width, 1)
                    if case let .split(_, _, first, second) = result {
                        XCTAssertEqual(edge == .left || edge == .up ? second : first, remainder)
                    }
                    XCTAssertEqual(result.positioned(pane, edge: edge, share: share), result)
                }
            }
        }
    }

    func testInvalidTargetsAndSharesCannotChangeLayout() {
        let layout: Layout<Int> = .split(axis: .horizontal, ratio: 0.5, first: .leaf(1), second: .leaf(2))
        XCTAssertNil(layout.positioned(9, edge: .left, share: 0.5))
        XCTAssertNil(Layout<Int>.leaf(1).positioned(1, edge: .left, share: 0.5))
        for share in [Double.nan, .infinity, -.infinity, 0, 1, -1, 0.14, 0.86] {
            XCTAssertNil(layout.positioned(1, edge: .left, share: share))
        }
    }

    func testStatePresetRevealsZoomAndPreservesPaneRecords() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let pane = try XCTUnwrap(state.activePane)
        _ = try state.splitPane(pane, edge: .right)
        try state.toggleZoom(pane)
        let records = state.home.tabs[0].panes
        try state.positionPane(pane, edge: .down, share: 2.0 / 3)
        XCTAssertNil(state.home.tabs[0].zoomed)
        XCTAssertNil(state.window.zoomed[state.home.tabs[0].id])
        XCTAssertEqual(state.activePane, pane)
        XCTAssertEqual(state.home.tabs[0].panes, records)
        let before = state
        XCTAssertThrowsError(try state.positionPane(PaneId(), edge: .left, share: 0.5))
        XCTAssertThrowsError(try state.positionPane(pane, edge: .left, share: .nan))
        XCTAssertEqual(state, before)
    }

    func testReducerUsesCurrentLayoutAndRejectsStaleTargetAtomically() throws {
        let home = ProjectId()
        let a = Pane(content: .terminal(session: nil))
        let b = Pane(content: .terminal(session: nil))
        let c = Pane(content: .terminal(session: nil))
        var board = TabBoard(home: home)
        func apply(_ mutation: TabMutation) throws {
            _ = try TabReducer.apply(mutation, to: &board) { $0 == home }
        }
        let tab = Tab(pane: a)
        try apply(.createTab(project: home, tab: tab, after: nil))
        try apply(.insertPane(b, anchor: a.id, edge: .right))
        try apply(.insertPane(c, anchor: b.id, edge: .down))
        try apply(.positionPane(a.id, edge: .left, share: 2.0 / 3))
        XCTAssertEqual(Set(board.tab(tab.id)?.layout.leaves ?? []), Set([a.id, b.id, c.id]))
        try apply(.removePane(a.id, keepSession: false))
        let before = board
        XCTAssertThrowsError(try apply(.positionPane(a.id, edge: .right, share: 0.5)))
        XCTAssertEqual(board, before)
        for share in [Double.nan, .infinity, 0, 1] {
            XCTAssertThrowsError(try TabMutation.positionPane(b.id, edge: .left, share: share).validate())
        }
    }
}
