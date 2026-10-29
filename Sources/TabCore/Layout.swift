import Foundation

public enum Axis: String, Codable, Sendable {
    /// Side by side: the split runs left to right.
    case horizontal
    /// Stacked: the split runs top to bottom.
    case vertical
}

public enum Direction: String, CaseIterable, Codable, Sendable {
    case left, right, up, down

    public var axis: Axis {
        switch self {
        case .left, .right: return .horizontal
        case .up, .down: return .vertical
        }
    }
}

/// Which side of a split a path goes down.
public enum Branch: String, Codable, Sendable {
    case first, second
}

/// A leaf's share of the whole layout, from 0 to 1 on each axis.
public struct UnitRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let unit = UnitRect(x: 0, y: 0, width: 1, height: 1)

    subscript(axis: Axis) -> (origin: Double, size: Double) {
        switch axis {
        case .horizontal: return (x, width)
        case .vertical: return (y, height)
        }
    }
}

public struct LayoutError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A split tree of leaves, such as a tab's panes.
public indirect enum Layout<Leaf: Hashable & Sendable>: Hashable, Sendable {
    case leaf(Leaf)
    case split(axis: Axis, ratio: Double, first: Layout, second: Layout)

    /// The smallest share either side of a split keeps.
    public static var minimumRatio: Double { 0.15 }
    public static var maximumRatio: Double { 0.85 }

    /// Leaves in reading order: first before second at every split.
    public var leaves: [Leaf] {
        var leaves: [Leaf] = []
        visit(.unit) { leaf, _ in leaves.append(leaf) }
        return leaves
    }

    /// Each leaf with its share of the whole.
    public var rects: [(Leaf, UnitRect)] {
        var rects: [(Leaf, UnitRect)] = []
        visit(.unit) { leaf, rect in rects.append((leaf, rect)) }
        return rects
    }

    public func contains(_ leaf: Leaf) -> Bool {
        switch self {
        case .leaf(let id): return id == leaf
        case let .split(_, _, first, second): return first.contains(leaf) || second.contains(leaf)
        }
    }

    /// Splits `leaf` in two, putting `new` on its `edge` side, half and half.
    public mutating func split(_ leaf: Leaf, new: Leaf, edge: Direction) {
        switch self {
        case .leaf(let id) where id == leaf:
            let before = edge == .left || edge == .up
            self = .split(
                axis: edge.axis,
                ratio: 0.5,
                first: .leaf(before ? new : leaf),
                second: .leaf(before ? leaf : new)
            )
        case .split(let axis, let ratio, var first, var second):
            first.split(leaf, new: new, edge: edge)
            second.split(leaf, new: new, edge: edge)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        case .leaf:
            break
        }
    }

    /// Puts `new` where `leaf` is.
    public mutating func replace(_ leaf: Leaf, with new: Leaf) {
        map { $0 == leaf ? new : $0 }
    }

    /// Exchanges the places of two leaves.
    public mutating func swap(_ leaf: Leaf, _ other: Leaf) {
        map { $0 == leaf ? other : $0 == other ? leaf : $0 }
    }

    private mutating func map(_ transform: (Leaf) -> Leaf) {
        switch self {
        case .leaf(let id):
            self = .leaf(transform(id))
        case .split(let axis, let ratio, var first, var second):
            first.map(transform)
            second.map(transform)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// Removes `leaf`; its sibling takes the place of their split.
    public mutating func remove(_ leaf: Leaf) {
        guard case .split(let axis, let ratio, var first, var second) = self else { return }
        if case .leaf(let id) = first, id == leaf {
            self = second
        } else if case .leaf(let id) = second, id == leaf {
            self = first
        } else {
            first.remove(leaf)
            second.remove(leaf)
            self = .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// Sets the ratio of the split at `path`, clamped so neither side
    /// disappears.
    public mutating func setRatio(at path: [Branch], to value: Double) throws {
        guard value.isFinite else { throw LayoutError("split ratio must be finite") }
        var failure: LayoutError?
        let found = update(at: path[...]) { node in
            guard case let .split(axis, _, first, second) = node else {
                failure = LayoutError("path must name a split")
                return
            }
            node = .split(
                axis: axis,
                ratio: min(max(value, Self.minimumRatio), Self.maximumRatio),
                first: first,
                second: second
            )
        }
        if let failure { throw failure }
        if !found { throw LayoutError("unknown split path") }
    }

    /// Checks every ratio is in range.
    public func validate() throws {
        guard case let .split(_, ratio, first, second) = self else { return }
        guard ratio.isFinite, (Self.minimumRatio...Self.maximumRatio).contains(ratio) else {
            throw LayoutError("split ratio must be between 0.15 and 0.85")
        }
        try first.validate()
        try second.validate()
    }

    /// The leaf touching `leaf` on its `direction` side, the most centered
    /// one when several do.
    public func neighbor(of leaf: Leaf, _ direction: Direction) -> Leaf? {
        let rectangles = rects
        guard let source = rectangles.first(where: { $0.0 == leaf })?.1 else { return nil }
        var best: (Leaf, Double)?
        for (id, other) in rectangles where id != leaf {
            let gap: Double
            let overlap: Double
            let offset: Double
            switch direction {
            case .left, .right:
                gap = direction == .left ? source.x - other.x - other.width : other.x - source.x - source.width
                overlap = min(source.y + source.height, other.y + other.height) - max(source.y, other.y)
                offset = abs(source.y + source.height / 2 - other.y - other.height / 2)
            case .up, .down:
                gap = direction == .up ? source.y - other.y - other.height : other.y - source.y - source.height
                overlap = min(source.x + source.width, other.x + other.width) - max(source.x, other.x)
                offset = abs(source.x + source.width / 2 - other.x - other.width / 2)
            }
            guard abs(gap) < 0.000_01, overlap > 0 else { continue }
            if best.map({ offset < $0.1 }) ?? true { best = (id, offset) }
        }
        return best?.0
    }

    /// The layout after dropping `leaf` on `target`: on its `edge`, or in its
    /// place (swapping) without one. `nil` for a drop on itself or outside.
    public func moved(_ leaf: Leaf, onto target: Leaf, edge: Direction?) -> Layout? {
        guard leaf != target, contains(leaf), contains(target) else { return nil }
        if let edge { return docked(leaf, beside: target, edge: edge, level: 0) }
        var layout = self
        layout.swap(leaf, target)
        return layout
    }

    func visit(_ rect: UnitRect, _ visitor: (Leaf, UnitRect) -> Void) {
        switch self {
        case .leaf(let id):
            visitor(id, rect)
        case let .split(axis, ratio, first, second):
            var firstRect = rect
            var secondRect = rect
            switch axis {
            case .horizontal:
                firstRect.width *= ratio
                secondRect.x += firstRect.width
                secondRect.width *= 1 - ratio
            case .vertical:
                firstRect.height *= ratio
                secondRect.y += firstRect.height
                secondRect.height *= 1 - ratio
            }
            first.visit(firstRect, visitor)
            second.visit(secondRect, visitor)
        }
    }

    /// The subtree at `path`.
    public func node(at path: [Branch]) -> Layout? {
        var node = self
        for branch in path {
            guard case let .split(_, _, first, second) = node else { return nil }
            node = branch == .first ? first : second
        }
        return node
    }

    /// Runs `body` on the subtree at `path`, returning whether it exists.
    @discardableResult
    mutating func update(at path: ArraySlice<Branch>, _ body: (inout Layout) -> Void) -> Bool {
        guard let branch = path.first else {
            body(&self)
            return true
        }
        guard case .split(let axis, let ratio, var first, var second) = self else { return false }
        let found: Bool
        if branch == .first {
            found = first.update(at: path.dropFirst(), body)
        } else {
            found = second.update(at: path.dropFirst(), body)
        }
        self = .split(axis: axis, ratio: ratio, first: first, second: second)
        return found
    }
}

extension Layout: Codable where Leaf: Codable {
    private enum CodingKeys: String, CodingKey {
        case leaf, split
    }

    private enum SplitKeys: String, CodingKey {
        case axis, ratio, first, second
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let leaf = try container.decodeIfPresent(Leaf.self, forKey: .leaf) {
            self = .leaf(leaf)
            return
        }
        guard container.contains(.split) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "a layout is a leaf or a split"
            ))
        }
        let split = try container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
        self = .split(
            axis: try split.decode(Axis.self, forKey: .axis),
            ratio: try split.decode(Double.self, forKey: .ratio),
            first: try split.decode(Layout.self, forKey: .first),
            second: try split.decode(Layout.self, forKey: .second)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let leaf):
            try container.encode(leaf, forKey: .leaf)
        case let .split(axis, ratio, first, second):
            var split = container.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try split.encode(axis, forKey: .axis)
            try split.encode(ratio, forKey: .ratio)
            try split.encode(first, forKey: .first)
            try split.encode(second, forKey: .second)
        }
    }
}

// Structural edits equalize only the maximal same-axis run containing the
// leaf's parent. Its path is remembered before a removal; if the run
// dissolves, the enclosing run is used, including any same-axis neighbours
// exposed by the collapse.
extension Layout {
    /// Gives the members of the row or column holding `leaf` equal shares.
    public mutating func equalizeParent(of leaf: Leaf) {
        guard let path = path(to: leaf), !path.isEmpty else { return }
        equalizeRun(path[...])
    }

    /// Removes `leaf` and equalizes the row or column it leaves.
    public mutating func removeEqualized(_ leaf: Leaf) {
        guard let path = path(to: leaf), !path.isEmpty else { return }
        let depth = Self.runStart(path[...])
        let axis = path[depth].1
        remove(leaf)
        let branches = path[..<depth].map(\.0)
        var survives = false
        if case let .split(current, _, _, _) = node(at: branches), current == axis {
            survives = true
        }
        if survives {
            equalizeRun(path[...])
        } else if depth > 0 {
            equalizeRun(path[..<depth])
        }
    }

    private mutating func equalizeRun(_ path: ArraySlice<(Branch, Axis)>) {
        let branches = path[path.startIndex..<path.startIndex + Self.runStart(path)].map(\.0)
        update(at: branches[...]) { container in
            if let equalized = container.equalizedContainer() { container = equalized }
        }
    }

    private static func runStart(_ path: ArraySlice<(Branch, Axis)>) -> Int {
        guard let axis = path.last?.1 else { return 0 }
        return path.count - path.reversed().prefix { $0.1 == axis }.count
    }

    private func path(to leaf: Leaf) -> [(Branch, Axis)]? {
        switch self {
        case .leaf(let id):
            return id == leaf ? [] : nil
        case let .split(axis, _, first, second):
            if let path = first.path(to: leaf) { return [(.first, axis)] + path }
            if let path = second.path(to: leaf) { return [(.second, axis)] + path }
            return nil
        }
    }
}
