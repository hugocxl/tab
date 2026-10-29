import CoreGraphics
import TabCore

/// The split layout's geometry from `docs/codesh/style.md`: an 8pt gutter
/// between the two sides of each split, only the shared edge snapped to
/// device pixels, and a ratio that follows the pointer.
public enum SplitGeometry {
    public static let gutter: CGFloat = 8
    /// The grip under the pointer, centred in the gutter.
    public static let grip: CGFloat = 10

    /// For extent `E`, ratio `r` and scale `s`: the first side's extent, the
    /// gutter's, and where the second side starts.
    public static func gutter(extent: CGFloat, ratio: CGFloat, scale: CGFloat) -> (first: CGFloat, gutter: CGFloat, secondOrigin: CGFloat) {
        let extent = max(extent, 0)
        let gutter = min(extent, Self.gutter)
        let available = extent - gutter
        let scale = max(scale, 1)
        let first = min(max((available * ratio * scale).rounded() / scale, 0), available)
        return (first, gutter, first + gutter)
    }

    /// The two sides and the gutter between them of a split of `bounds`.
    public static func split(_ bounds: CGRect, axis: Axis, ratio: Double, scale: CGFloat) -> (first: CGRect, divider: CGRect, second: CGRect) {
        switch axis {
        case .horizontal:
            let (first, gutter, second) = Self.gutter(extent: bounds.width, ratio: CGFloat(ratio), scale: scale)
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: first, height: bounds.height),
                CGRect(x: bounds.minX + first, y: bounds.minY, width: gutter, height: bounds.height),
                CGRect(x: bounds.minX + second, y: bounds.minY, width: max(bounds.width - second, 0), height: bounds.height)
            )
        case .vertical:
            let (first, gutter, second) = Self.gutter(extent: bounds.height, ratio: CGFloat(ratio), scale: scale)
            return (
                CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: first),
                CGRect(x: bounds.minX, y: bounds.minY + first, width: bounds.width, height: gutter),
                CGRect(x: bounds.minX, y: bounds.minY + second, width: bounds.width, height: max(bounds.height - second, 0))
            )
        }
    }

    /// The ratio after the pointer moved `delta` along a split of `extent`.
    public static func ratio(from start: Double, delta: CGFloat, extent: CGFloat) -> Double {
        let ratio = start + Double(delta / max(extent - gutter, 1))
        return min(max(ratio, Layout<PaneId>.minimumRatio), Layout<PaneId>.maximumRatio)
    }

    /// Where each leaf goes in `bounds` (top-left origin).
    public static func frames<Leaf>(_ layout: Layout<Leaf>, in bounds: CGRect, scale: CGFloat) -> [(Leaf, CGRect)] {
        var frames: [(Leaf, CGRect)] = []
        visit(layout, bounds, scale) { leaf, rect in frames.append((leaf, rect)) }
        return frames
    }

    /// Each split's gutter with its path, for resizing.
    public static func dividers<Leaf>(_ layout: Layout<Leaf>, in bounds: CGRect, scale: CGFloat) -> [Divider] {
        var dividers: [Divider] = []
        collect(layout, bounds, scale, path: [], into: &dividers)
        return dividers
    }

    public struct Divider: Equatable {
        public var path: [Branch]
        public var axis: Axis
        public var ratio: Double
        /// The gutter.
        public var frame: CGRect
        /// The whole split, whose extent the ratio divides.
        public var bounds: CGRect

        /// The grip: 10pt across, centred in the gutter, full length.
        public var grip: CGRect {
            switch axis {
            case .horizontal: return CGRect(x: frame.midX - SplitGeometry.grip / 2, y: frame.minY, width: SplitGeometry.grip, height: frame.height)
            case .vertical: return CGRect(x: frame.minX, y: frame.midY - SplitGeometry.grip / 2, width: frame.width, height: SplitGeometry.grip)
            }
        }

        /// The 1pt line drawn on hover and drag.
        public var line: CGRect {
            switch axis {
            case .horizontal: return CGRect(x: frame.midX - 0.5, y: frame.minY, width: 1, height: frame.height)
            case .vertical: return CGRect(x: frame.minX, y: frame.midY - 0.5, width: frame.width, height: 1)
            }
        }
    }

    private static func visit<Leaf>(_ layout: Layout<Leaf>, _ bounds: CGRect, _ scale: CGFloat, _ body: (Leaf, CGRect) -> Void) {
        switch layout {
        case .leaf(let leaf):
            body(leaf, bounds)
        case let .split(axis, ratio, first, second):
            let parts = split(bounds, axis: axis, ratio: ratio, scale: scale)
            visit(first, parts.first, scale, body)
            visit(second, parts.second, scale, body)
        }
    }

    private static func collect<Leaf>(_ layout: Layout<Leaf>, _ bounds: CGRect, _ scale: CGFloat, path: [Branch], into dividers: inout [Divider]) {
        guard case let .split(axis, ratio, first, second) = layout else { return }
        let parts = split(bounds, axis: axis, ratio: ratio, scale: scale)
        dividers.append(Divider(path: path, axis: axis, ratio: ratio, frame: parts.divider, bounds: bounds))
        collect(first, parts.first, scale, path: path + [.first], into: &dividers)
        collect(second, parts.second, scale, path: path + [.second], into: &dividers)
    }
}

/// Where a pane dragged with Command lands: on another pane's edge to dock
/// beside it (or beside the row or column around it), or in its middle to
/// swap places. Ported from Codesh's drop walker.
public enum DropTargets {
    /// Share of a pane, from each edge, that docks instead of swapping.
    public static let edgeZone: CGFloat = 0.3
    /// Widest band each enclosing row or column gets, nearest the edge.
    public static let band: CGFloat = 16

    private static let edges: [Direction] = [.left, .right, .up, .down]

    /// Whether `point` is close enough to the layout to drop there.
    public static func within(_ point: CGPoint, _ bounds: CGRect) -> Bool {
        bounds.width > 0 && bounds.height > 0 && bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    /// The target under `point` in a layout drawn in `bounds` (top-left origin).
    public static func target(_ layout: Layout<PaneId>, bounds: CGRect, scale: CGFloat, point: CGPoint) -> DropTarget? {
        guard within(point, bounds) else { return nil }
        let point = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        let (pane, frame) = paneAt(layout, bounds, scale, point)
        let distance = distances(point, frame)
        let zones = [frame.width * edgeZone, frame.width * edgeZone, frame.height * edgeZone, frame.height * edgeZone]
        var best: (DropTarget, Int, CGFloat)?
        for index in 0..<4 where distance[index] < zones[index] {
            let edge = edges[index]
            let depths = layout.dockDepths(pane, edge: edge)
            let level = levelAt(depths.count, distance[index], zones[index])
            guard depths.indices.contains(level) else { continue }
            let candidate = (DropTarget.dock(pane: pane, edge: edge, level: level), depths[level], distance[index])
            if let current = best, (current.1, current.2) <= (candidate.1, candidate.2) { continue }
            best = candidate
        }
        return best?.0 ?? .swap(pane)
    }

    /// The layout after the drop, or `nil` when it changes nothing.
    public static func apply(_ target: DropTarget, to layout: Layout<PaneId>, moving pane: PaneId) -> Layout<PaneId>? {
        let result: Layout<PaneId>?
        switch target {
        case .swap(let other): result = layout.moved(pane, onto: other, edge: nil)
        case let .dock(anchor, edge, level): result = layout.docked(pane, beside: anchor, edge: edge, level: level)
        }
        guard let result, result != layout else { return nil }
        return result
    }

    static func levelAt(_ levels: Int, _ distance: CGFloat, _ zone: CGFloat) -> Int {
        guard levels > 0 else { return 0 }
        let band = min(Self.band, zone / CGFloat(min(levels, 255)))
        var level = levels - 1
        var reach = band
        while level > 0 && distance >= reach {
            level -= 1
            reach += band
        }
        return level
    }

    private static func distances(_ point: CGPoint, _ frame: CGRect) -> [CGFloat] {
        [point.x - frame.minX, frame.maxX - point.x, point.y - frame.minY, frame.maxY - point.y]
    }

    private static func outside(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        distances(point, frame).reduce(0) { $0 + max(-$1, 0) }
    }

    /// The pane under `point`; gutters belong to the nearer side.
    private static func paneAt(_ layout: Layout<PaneId>, _ bounds: CGRect, _ scale: CGFloat, _ point: CGPoint) -> (PaneId, CGRect) {
        var node = layout
        var frame = bounds
        while true {
            switch node {
            case .leaf(let pane):
                return (pane, frame)
            case let .split(axis, ratio, first, second):
                let parts = SplitGeometry.split(frame, axis: axis, ratio: ratio, scale: scale)
                if outside(point, parts.first) <= outside(point, parts.second) {
                    (node, frame) = (first, parts.first)
                } else {
                    (node, frame) = (second, parts.second)
                }
            }
        }
    }
}
