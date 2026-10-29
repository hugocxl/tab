import XCTest
@testable import TabCore

private typealias PaneLayout = Layout<PaneId>
private let third = 1.0 / 3.0

private func split(_ axis: Axis, _ ratio: Double, _ first: PaneLayout, _ second: PaneLayout) -> PaneLayout {
    .split(axis: axis, ratio: ratio, first: first, second: second)
}

private func assertRects(_ layout: PaneLayout, _ expected: [(PaneId, [Double])], file: StaticString = #filePath, line: UInt = #line) {
    let actual = layout.rects
    XCTAssertEqual(actual.count, expected.count, file: file, line: line)
    for (pane, rect) in expected {
        guard let found = actual.first(where: { $0.0 == pane })?.1 else {
            XCTFail("missing \(pane)", file: file, line: line)
            continue
        }
        for (a, b) in zip([found.x, found.y, found.width, found.height], rect) {
            XCTAssertEqual(a, b, accuracy: 1e-4, "\(pane): \(found) != \(rect)", file: file, line: line)
        }
    }
}

private func assertRow(_ layout: PaneLayout, _ order: [PaneId], _ edge: Direction, _ share: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(layout.leaves, order, file: file, line: line)
    var position = 0.0
    for (_, rect) in layout.rects {
        let (origin, size) = rect[edge.axis]
        XCTAssertEqual(size, share, accuracy: 1e-5, "\(rect)", file: file, line: line)
        XCTAssertEqual(origin, position, accuracy: 1e-5, "\(rect)", file: file, line: line)
        position += share
    }
    XCTAssertNoThrow(try layout.validate(), file: file, line: line)
}

private func grid() -> (PaneLayout, [PaneId]) {
    let ids = (0..<4).map { _ in PaneId() }
    let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
    return (split(.horizontal, 0.5, split(.vertical, 0.5, .leaf(a), .leaf(c)), split(.vertical, 0.5, .leaf(b), .leaf(d))), ids)
}

final class LayoutTests: XCTestCase {
    func testLayoutsRoundTripAndRejectBadRatios() throws {
        let (layout, _) = grid()
        XCTAssertEqual(try roundTrip(layout), layout)
        var bad = layout
        try bad.setRatio(at: [], to: 2)
        if case let .split(_, ratio, _, _) = bad { XCTAssertEqual(ratio, 0.85) }
        XCTAssertThrowsError(try bad.setRatio(at: [.first, .first], to: 0.5))
        XCTAssertThrowsError(try bad.setRatio(at: [], to: .nan))
        let invalid = split(.horizontal, 0.95, .leaf(PaneId()), .leaf(PaneId()))
        XCTAssertThrowsError(try invalid.validate())
    }

    func testNeighborsFollowGeometry() {
        let (layout, ids) = grid()
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        XCTAssertEqual(layout.neighbor(of: a, .right), b)
        XCTAssertEqual(layout.neighbor(of: a, .down), c)
        XCTAssertEqual(layout.neighbor(of: d, .left), c)
        XCTAssertEqual(layout.neighbor(of: d, .up), b)
        XCTAssertNil(layout.neighbor(of: a, .left))
        XCTAssertNil(layout.neighbor(of: d, .down))
    }

    func testJoiningAnotherColumnTakesAnEqualShareAndTheOldColumnClosesUp() throws {
        let (layout, ids) = grid()
        let (a, b, c, d) = (ids[0], ids[1], ids[2], ids[3])
        for (anchor, edge) in [(b, Direction.down), (d, .up)] {
            let result = try XCTUnwrap(layout.moved(a, onto: anchor, edge: edge))
            try result.validate()
            assertRects(result, [
                (c, [0, 0, 0.5, 1]),
                (b, [0.5, 0, 0.5, third]),
                (a, [0.5, third, 0.5, third]),
                (d, [0.5, 2 * third, 0.5, third]),
            ])
        }
        let beside = try XCTUnwrap(layout.moved(a, onto: b, edge: .left))
        assertRects(beside, [
            (c, [0, 0, 0.5, 1]),
            (a, [0.5, 0, 0.25, 0.5]),
            (b, [0.75, 0, 0.25, 0.5]),
            (d, [0.5, 0.5, 0.5, 0.5]),
        ])
        let swapped = try XCTUnwrap(layout.moved(a, onto: d, edge: nil))
        XCTAssertEqual(swapped.leaves, [d, c, b, a])
        XCTAssertNil(layout.moved(a, onto: a, edge: nil))
        XCTAssertNil(layout.moved(a, onto: PaneId(), edge: .left))
    }

    func testDockingBesideARowPreservesTheOtherRowAndItsResizedSplits() throws {
        let ids = (0..<5).map { _ in PaneId() }
        let (source, topLeft, topRight, bottomLeft, bottomRight) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let top = split(.horizontal, 0.61, .leaf(topLeft), .leaf(topRight))
        let bottom = split(.horizontal, 0.37, .leaf(bottomLeft), .leaf(bottomRight))
        let grid = split(.vertical, 0.7, top, bottom)
        let layout = split(.horizontal, 0.3, .leaf(source), grid)
        let besideRow = try XCTUnwrap(layout.docked(source, beside: topLeft, edge: .left, level: 0))
        guard case let .split(.vertical, ratio, _, second) = besideRow else { return XCTFail("\(besideRow)") }
        XCTAssertEqual(ratio, 0.7, accuracy: 1e-9)
        XCTAssertEqual(second, bottom)
        assertRects(besideRow, [
            (source, [0, 0, third, 0.7]),
            (topLeft, [third, 0, 0.61 * 2 * third, 0.7]),
            (topRight, [third + 0.61 * 2 * third, 0, 0.39 * 2 * third, 0.7]),
            (bottomLeft, [0, 0.7, 0.37, 0.3]),
            (bottomRight, [0.37, 0.7, 0.63, 0.3]),
        ])
        XCTAssertEqual(layout.dockDepths(topLeft, edge: .up), [3, 2, 0])
        let aboveGrid = try XCTUnwrap(layout.docked(source, beside: topLeft, edge: .up, level: 2))
        guard case let .split(.vertical, aboveRatio, first, rest) = aboveGrid else { return XCTFail("\(aboveGrid)") }
        XCTAssertEqual(aboveRatio, third, accuracy: 1e-6)
        XCTAssertEqual(first, .leaf(source))
        XCTAssertEqual(rest, grid)
    }

    func testEveryDropKeepsEachPaneOnceInAValidLayoutAndNeverTargetsItself() throws {
        let panes = (0..<5).map { _ in PaneId() }
        let (source, topLeft, topRight, bottomLeft, bottomRight) = (panes[0], panes[1], panes[2], panes[3], panes[4])
        var layout = PaneLayout.leaf(source)
        layout.split(source, new: topLeft, edge: .right)
        layout.split(topLeft, new: topRight, edge: .down)
        layout.split(topRight, new: bottomLeft, edge: .right)
        layout.split(source, new: bottomRight, edge: .up)
        try layout.setRatio(at: [], to: 0.61)
        let original = layout.leaves.sorted()
        for pane in panes {
            for anchor in panes {
                for edge in Direction.allCases {
                    let levels = layout.dockDepths(anchor, edge: edge).count
                    XCTAssertGreaterThanOrEqual(levels, 1)
                    for level in 0..<levels {
                        let result = layout.docked(pane, beside: anchor, edge: edge, level: level)
                        if pane == anchor && level == 0 {
                            XCTAssertNil(result)
                            continue
                        }
                        let docked = try XCTUnwrap(result, "\(pane) \(anchor) \(edge) \(level)")
                        try docked.validate()
                        XCTAssertEqual(docked.leaves.sorted(), original, "\(edge) \(level)")
                    }
                    XCTAssertNil(layout.docked(pane, beside: anchor, edge: edge, level: levels))
                }
            }
        }
        XCTAssertNil(layout.docked(PaneId(), beside: source, edge: .left, level: 0))
        XCTAssertNil(PaneLayout.leaf(source).docked(source, beside: source, edge: .left, level: 0))
    }

    func testEqualizingGivesEveryMemberOfEachRowAndColumnAnEqualShare() throws {
        let ids = (0..<5).map { _ in PaneId() }
        let (left, top, middle, bottom, right) = (ids[0], ids[1], ids[2], ids[3], ids[4])
        let column = split(.vertical, 0.7, .leaf(top), split(.vertical, 0.3, .leaf(middle), .leaf(bottom)))
        let row = split(.horizontal, 0.2, .leaf(left), split(.horizontal, 0.8, column, .leaf(right)))
        let result = try XCTUnwrap(row.equalized())
        try result.validate()
        XCTAssertEqual(result.leaves, [left, top, middle, bottom, right])
        assertRects(result, [
            (left, [0, 0, third, 1]),
            (top, [third, 0, third, third]),
            (middle, [third, third, third, third]),
            (bottom, [third, 2 * third, third, third]),
            (right, [2 * third, 0, third, 1]),
        ])
        XCTAssertEqual(PaneLayout.leaf(left).equalized(), .leaf(left))
    }

    // MARK: Equalizing through the app state

    func testInsertionsAndClosesEqualizeBothAxesAndDirections() throws {
        for edge in Direction.allCases {
            var state = try AppState.bootstrap()
            let tab = try state.openTerminalTab(state.home.id)
            let first = state.home.tabs[0].panes[0].id
            var order = [first]
            var anchor = first
            for share in [0.5, third, 0.25] {
                if order.count > 1 { try state.setRatio(tab, path: [], ratio: 0.7) }
                let new = try state.splitPane(anchor, edge: edge)
                if edge == .left || edge == .up { order.insert(new, at: 0) } else { order.append(new) }
                anchor = new
                assertRow(state.home.tabs[0].layout, order, edge, share)
            }
            try state.setRatio(tab, path: [], ratio: 0.65)
            try state.closePane(order.remove(at: 1))
            assertRow(state.home.tabs[0].layout, order, edge, third)
            try state.setRatio(tab, path: [], ratio: 0.3)
            try state.closePane(order.remove(at: 0))
            assertRow(state.home.tabs[0].layout, order, edge, 0.5)
            XCTAssertEqual(try roundTrip(state), state)
        }
    }

    func testMixedAxisMembersKeepInternalRatiosAndUnrelatedContainers() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let a = state.home.tabs[0].panes[0].id
        let b = try state.splitPane(a, edge: .right)
        let c = try state.splitPane(b, edge: .down)
        try state.setRatio(tab, path: [.second], ratio: 0.3)
        let stack = state.home.tabs[0].layout.node(at: [.second])
        let d = try state.splitPane(a, edge: .right)
        for (_, rect) in state.home.tabs[0].layout.rects { assertClose(rect.width, third) }
        XCTAssertEqual(state.home.tabs[0].layout.leaves, [a, d, b, c])
        try state.closePane(d)
        XCTAssertEqual(state.home.tabs[0].layout.node(at: [.second]), stack)
        try state.setRatio(tab, path: [], ratio: 0.65)
        let e = try state.splitPane(b, edge: .down)
        assertClose(state.home.tabs[0].layout.rects[0].1.width, 0.65)
        try state.closePane(e)
        assertClose(state.home.tabs[0].layout.rects[0].1.width, 0.65)
    }

    func testCollapseMergesExposedSameAxisNeighbours() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let a = state.home.tabs[0].panes[0].id
        let b = try state.splitPane(a, edge: .right)
        let c = try state.splitPane(b, edge: .down)
        let d = try state.splitPane(c, edge: .right)
        let e = try state.splitPane(d, edge: .right)
        try state.setRatio(tab, path: [], ratio: 0.7)
        try state.setRatio(tab, path: [.second, .second], ratio: 0.6)
        try state.closePane(b)
        assertRow(state.home.tabs[0].layout, [a, c, d, e], .right, 0.25)
    }

    func testDissolvingRootKeepsSurvivingOppositeAxisLayout() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let a = state.home.tabs[0].panes[0].id
        let b = try state.splitPane(a, edge: .right)
        let c = try state.splitPane(b, edge: .down)
        try state.setRatio(tab, path: [.second], ratio: 0.3)
        try state.closePane(a)
        XCTAssertEqual(state.home.tabs[0].layout.leaves, [b, c])
        assertClose(state.home.tabs[0].layout.rects[0].1.height, 0.3)
    }

    func testEditingOneStackPreservesItsResizedSibling() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let a = state.home.tabs[0].panes[0].id
        let b = try state.splitPane(a, edge: .right)
        try state.splitPane(a, edge: .down)
        try state.splitPane(b, edge: .down)
        try state.setRatio(tab, path: [], ratio: 0.6)
        try state.setRatio(tab, path: [.second], ratio: 0.35)
        let before = state.home.tabs[0].layout.rects
        let new = try state.splitPane(a, edge: .down)
        for (id, rect) in before[2...] {
            XCTAssertEqual(state.home.tabs[0].layout.rects.first { $0.0 == id }?.1, rect)
        }
        try state.closePane(new)
        for (id, rect) in before[2...] {
            XCTAssertEqual(state.home.tabs[0].layout.rects.first { $0.0 == id }?.1, rect)
        }
    }

    func testLongRunsRemainEqualAndValidOnBothAxes() throws {
        for edge in [Direction.right, .down] {
            var state = try AppState.bootstrap()
            try state.openTerminalTab(state.home.id)
            var anchor = state.home.tabs[0].panes[0].id
            var order = [anchor]
            for _ in 0..<23 {
                anchor = try state.splitPane(anchor, edge: edge)
                order.append(anchor)
            }
            assertRow(state.home.tabs[0].layout, order, edge, 1.0 / 24)
        }
    }

    func testBrowserInsertionsEqualizeLongRowsWithoutChangingFocus() throws {
        var state = try AppState.bootstrap()
        let tab = try state.openTerminalTab(state.home.id)
        let first = state.home.tabs[0].panes[0].id
        var order = [first, try state.splitPane(first, edge: .right)]
        try state.focusPane(first)
        for _ in 0..<10 {
            try state.setRatio(tab, path: [], ratio: 0.75)
            order.append(try state.splitBrowser(try XCTUnwrap(order.last), BrowserPane(), focus: false))
            assertRow(state.home.tabs[0].layout, order, .right, 1 / Double(order.count))
            XCTAssertEqual(state.activePane, first)
        }
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testEqualizingSplitsEvensALongRowAndKeepsTheZoom() throws {
        var state = try AppState.bootstrap()
        try state.openTerminalTab(state.home.id)
        let first = state.home.tabs[0].panes[0].id
        var last = first
        for _ in 0..<9 { last = try state.splitPane(last, edge: .right) }
        let panes = state.home.tabs[0].layout.leaves
        try state.setRatio(state.home.tabs[0].id, path: [], ratio: 0.7)
        try state.toggleZoom(last)
        try state.equalizeSplits(first)
        let tab = state.home.tabs[0]
        XCTAssertEqual(tab.zoomed, last)
        XCTAssertEqual(tab.layout.leaves, panes)
        var left = 0.0
        for (_, rect) in tab.layout.rects {
            assertClose(rect.x, left, accuracy: 1e-4)
            assertClose(rect.width, 0.1, accuracy: 1e-4)
            left += 0.1
        }
        let before = state
        XCTAssertThrowsError(try state.equalizeSplits(PaneId()))
        XCTAssertEqual(state, before)
    }
}
