import XCTest
import TabCore
@testable import TabApp

final class SplitsGeometryTests: XCTestCase {
    /// The gutter helper from style.md conserves the extent at every scale
    /// and snaps only the shared edge, even for extents below the gutter.
    func testGutterConservesExtentAndSnapsTheSharedEdge() {
        for extent: CGFloat in [0, 5, 12, 101, 1001] {
            for scale: CGFloat in [1, 1.5, 2] {
                for ratio: CGFloat in [0.15, 0.5, 0.85] {
                    let (first, gutter, second) = SplitGeometry.gutter(extent: extent, ratio: ratio, scale: scale)
                    XCTAssertGreaterThanOrEqual(first, 0)
                    XCTAssertLessThanOrEqual(second, extent)
                    XCTAssertEqual(gutter, min(extent, SplitGeometry.gutter), accuracy: 0.0001)
                    XCTAssertEqual(first + gutter + (extent - second), extent, accuracy: 0.001)
                    if extent > SplitGeometry.gutter {
                        XCTAssertEqual(first * scale, (first * scale).rounded(), accuracy: 0.001)
                    }
                }
            }
        }
    }

    /// Dragging divides the pointer's travel by the extent less the gutter,
    /// and the ratio stays where neither side disappears.
    func testResizeRatioFollowsThePointerAndClamps() {
        XCTAssertEqual(SplitGeometry.ratio(from: 0.5, delta: 100, extent: 1008), 0.6, accuracy: 0.0001)
        XCTAssertEqual(SplitGeometry.ratio(from: 0.5, delta: 10_000, extent: 1008), Layout<PaneId>.maximumRatio)
        XCTAssertEqual(SplitGeometry.ratio(from: 0.5, delta: -10_000, extent: 1008), Layout<PaneId>.minimumRatio)
    }

    func testFramesAndDividersFollowTheTree() {
        let (a, b, c) = (PaneId(), PaneId(), PaneId())
        let layout = Layout<PaneId>.split(axis: .horizontal, ratio: 0.5, first: .leaf(a),
                                          second: .split(axis: .vertical, ratio: 0.5, first: .leaf(b), second: .leaf(c)))
        let bounds = CGRect(x: 0, y: 0, width: 1008, height: 608)
        let frames = Dictionary(uniqueKeysWithValues: SplitGeometry.frames(layout, in: bounds, scale: 2).map { ($0.0, $0.1) })
        XCTAssertEqual(frames[a], CGRect(x: 0, y: 0, width: 500, height: 608))
        XCTAssertEqual(frames[b], CGRect(x: 508, y: 0, width: 500, height: 300))
        XCTAssertEqual(frames[c], CGRect(x: 508, y: 308, width: 500, height: 300))
        let dividers = SplitGeometry.dividers(layout, in: bounds, scale: 2)
        XCTAssertEqual(dividers.map(\.path), [[], [.second]])
        XCTAssertEqual(dividers[0].grip.width, SplitGeometry.grip)
        XCTAssertEqual(dividers[0].grip.midX, 504, accuracy: 0.001)
    }

    /// The middle of a pane swaps; near an edge it docks there; a drop that
    /// changes nothing is no target.
    func testDropTargetsSwapInTheMiddleAndDockAtEdges() {
        let (a, b) = (PaneId(), PaneId())
        let layout = Layout<PaneId>.split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b))
        let bounds = CGRect(x: 0, y: 0, width: 1008, height: 600)
        XCTAssertEqual(DropTargets.target(layout, bounds: bounds, scale: 2, point: CGPoint(x: 758, y: 300)), .swap(b))
        let bottom = DropTargets.target(layout, bounds: bounds, scale: 2, point: CGPoint(x: 758, y: 590))
        guard case .dock(let pane, let edge, _)? = bottom else { return XCTFail("expected a dock, got \(String(describing: bottom))") }
        XCTAssertEqual(edge, .down)
        let moved = DropTargets.apply(bottom!, to: layout, moving: a)
        XCTAssertNotNil(moved)
        XCTAssertEqual(Set(moved?.leaves ?? []), [a, b])
        _ = pane
        XCTAssertNil(DropTargets.target(layout, bounds: bounds, scale: 2, point: CGPoint(x: 2000, y: 300)), "outside the layout")
        XCTAssertNil(DropTargets.apply(.swap(a), to: layout, moving: a), "a pane dropped on itself changes nothing")
    }

    func testSplitTitlesShowTheirPathMuted() {
        XCTAssertEqual(PaneCardView.splitTitle("zsh ~/repos/tab").0, "zsh")
        XCTAssertEqual(PaneCardView.splitTitle("zsh ~/repos/tab").1, "~/repos/tab")
        XCTAssertEqual(PaneCardView.splitTitle("Tab macOS Swift port").1, "")
    }
}
