import Foundation
import TabProtocol

/// A place for a pane along a whole edge of its tab, as the desktop's command
/// palette offers them: the left, right, top or bottom third, half or two
/// thirds, with the other panes kept together beside it.
public struct PanePosition: Hashable, Sendable {
    public enum Size: CaseIterable, Sendable {
        case third, half, twoThirds

        public var share: Double {
            switch self {
            case .third: 1.0 / 3
            case .half: 0.5
            case .twoThirds: 2.0 / 3
            }
        }

        var name: String {
            switch self {
            case .third: "Third"
            case .half: "Half"
            case .twoThirds: "Two Thirds"
            }
        }
    }

    public var edge: Direction
    public var size: Size

    /// The edge as the desktop names it: Left, Right, Top or Bottom.
    public var edgeName: String { Self.name(edge) }

    /// "Left Third", as the desktop's "Pane Left Third" without "Pane".
    public var title: String { "\(edgeName) \(size.name)" }

    public static func name(_ edge: Direction) -> String {
        switch edge {
        case .left: "Left"
        case .right: "Right"
        case .up: "Top"
        case .down: "Bottom"
        }
    }

    /// Every choice, edge by edge in the desktop's order.
    public static let all: [PanePosition] = [Direction.left, .right, .up, .down].flatMap { edge in
        Size.allCases.map { PanePosition(edge: edge, size: $0) }
    }
}

extension ServerModel {
    /// Whether the server places panes at a tab's edges; older ones don't.
    public var positionsPanes: Bool { status == .connected && client?.supports(.panePositioning) == true }

    /// The places `tab`'s panes can move to: none from a server that can't
    /// place them, or in a tab with one pane.
    public func panePositions(in tab: Tab) -> [PanePosition] {
        Self.panePositions(supported: positionsPanes, panes: tab.layout.leaves.count)
    }

    static func panePositions(supported: Bool, panes: Int) -> [PanePosition] {
        supported && panes > 1 ? PanePosition.all : []
    }

    /// Places `pane` at `position`, shown at once and confirmed by the server.
    public func positionPane(_ pane: PaneId, at position: PanePosition) throws {
        try perform(.positionPane(pane, edge: position.edge, share: position.size.share))
    }
}
