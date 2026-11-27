import Foundation

// Pane drops see a layout as rows and columns rather than binary splits: a run
// of same-direction splits is one row or column, so a pane dropped beside
// another pane in a row joins that row.

extension Layout {
    /// The distinct drops along `edge` of `anchor`, innermost first: beside
    /// `anchor`, then beside each enclosing row or column that shares that
    /// edge. Each is given as how deeply its pane, row or column is nested,
    /// with 0 for the whole layout, so drops on different edges compare.
    public func dockDepths(_ anchor: Leaf, edge: Direction) -> [Int] {
        DockNode(self).levels(anchor, edge: edge).map(\.count)
    }

    /// Moves `leaf` to the `edge` of `anchor`, or of the enclosing row or
    /// column that `level` picks from `dockDepths`. A leaf joining a row gets
    /// an equal share of it, a leaf moved within its own row keeps its size,
    /// and the leaves it leaves grow evenly into its space.
    public func docked(_ leaf: Leaf, beside anchor: Leaf, edge: Direction, level: Int) -> Layout? {
        let root = DockNode(self)
        let levels = root.levels(anchor, edge: edge)
        guard level >= 0, level < levels.count else { return nil }
        guard let changed = root.dock(leaf, target: levels[level], edge: edge) else { return nil }
        return changed ? root.layout() : self
    }

    /// Gives every member of each row and column an equal share of it.
    public func equalized() -> Layout? {
        let root = DockNode(self)
        root.equalize()
        return root.layout()
    }

    /// Equalizes just this row or column, keeping each member's own shape.
    func equalizedContainer() -> Layout? {
        let root = DockNode(self)
        if !root.isLeaf { root.equalizeMembers() }
        return root.layout()
    }
}

private struct DockMember<Leaf: Hashable & Sendable> {
    /// Share of the group, from 0 to 1.
    var size: Double
    var node: DockNode<Leaf>
}

private indirect enum DockShape {
    case member
    case split(ratio: Double, first: DockShape, second: DockShape)
}

/// A pane, or a row or column: one run of same-direction splits.
private final class DockNode<Leaf: Hashable & Sendable> {
    var leaf: Leaf?
    var axis: Axis = .horizontal
    var members: [DockMember<Leaf>] = []
    /// The original splits, reused until the members change.
    var shape: DockShape?

    var isLeaf: Bool { leaf != nil }

    init(leaf: Leaf) {
        self.leaf = leaf
    }

    init(axis: Axis, members: [DockMember<Leaf>], shape: DockShape?) {
        self.axis = axis
        self.members = members
        self.shape = shape
    }

    convenience init(_ layout: Layout<Leaf>) {
        switch layout {
        case .leaf(let leaf):
            self.init(leaf: leaf)
        case .split(let axis, _, _, _):
            var members: [DockMember<Leaf>] = []
            let shape = DockNode.collect(layout, axis: axis, size: 1, into: &members)
            self.init(axis: axis, members: members, shape: shape)
        }
    }

    private func become(_ other: DockNode) {
        leaf = other.leaf
        axis = other.axis
        members = other.members
        shape = other.shape
    }

    func layout() -> Layout<Leaf>? {
        if let leaf { return .leaf(leaf) }
        if let shape {
            var iterator = members.makeIterator()
            return DockNode.build(shape, axis: axis, members: &iterator)
        }
        return DockNode.balanced(axis: axis, members: members)
    }

    func equalize() {
        guard !isLeaf else { return }
        equalizeMembers()
        for member in members { member.node.equalize() }
    }

    func equalizeMembers() {
        let share = 1 / Double(members.count)
        for index in members.indices { members[index].size = share }
        shape = nil
    }

    /// Index of the member that touches `edge`, which runs across the group.
    private func end(_ edge: Direction) -> Int? {
        switch edge {
        case .left, .up: return 0
        case .right, .down: return members.isEmpty ? nil : members.count - 1
        }
    }

    /// Paths of the nodes a leaf can dock against along `edge` of `anchor`,
    /// innermost first. Rows or columns that run along the edge only repeat
    /// the drop beside their end member, so they are skipped.
    func levels(_ anchor: Leaf, edge: Direction) -> [[Int]] {
        guard let path = find(anchor) else { return [] }
        var levels = [path]
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            guard let node = at(Array(path[..<depth])), !node.isLeaf else { break }
            if node.axis != edge.axis {
                levels.append(Array(path[..<depth]))
            } else if path[depth] != node.end(edge) {
                break
            }
        }
        return levels
    }

    /// Moves `leaf` beside the node at `target`, returning whether anything
    /// changed, or `nil` when the drop is impossible.
    func dock(_ leaf: Leaf, target: [Int], edge: Direction) -> Bool? {
        let axis = edge.axis
        let after = edge == .right || edge == .down ? 1 : 0
        guard let targetNode = at(target) else { return nil }
        if targetNode.isLeaf(leaf) { return nil }
        var target = target
        if !target.isEmpty, dissolvesWithout(Array(target.dropLast()), leaf: leaf, axis: axis) {
            target.removeLast()
        }
        guard let node = at(target) else { return nil }
        let container: [Int]
        let index: Int
        if !node.isLeaf && node.axis == axis {
            container = target
            index = node.members.count * after
        } else if let last = target.last, let parent = at(Array(target.dropLast())),
                  !parent.isLeaf, parent.axis == axis
        {
            container = Array(target.dropLast())
            index = last + after
        } else {
            node.wrap(axis)
            container = target
            index = after
        }
        guard var source = find(leaf), let group = at(container), !group.isLeaf else { return nil }
        let share = 1 / (group.lanes(axis, without: leaf) + 1)
        if source.count == container.count + 1, source.starts(with: container) {
            let from = source[container.count]
            let to = from < index ? index - 1 : index
            if from == to { return false }
            let member = group.members.remove(at: from)
            group.members.insert(member, at: to)
            group.shape = nil
            return true
        }
        for member in group.members.indices { group.members[member].size *= 1 - share }
        group.members.insert(DockMember(size: share, node: DockNode(leaf: leaf)), at: index)
        group.shape = nil
        if source.count > container.count, source.starts(with: container), source[container.count] >= index {
            source[container.count] += 1
        }
        return remove(source) ? true : nil
    }

    /// Whether the group at `path` runs across `axis` and holds only `leaf`
    /// and one other member, which takes the group's place once `leaf`
    /// moves. Docking beside that member then means docking beside the group.
    private func dissolvesWithout(_ path: [Int], leaf: Leaf, axis: Axis) -> Bool {
        guard let group = at(path), !group.isLeaf else { return false }
        return group.axis != axis && group.members.count == 2
            && group.members.contains { $0.node.isLeaf(leaf) }
    }

    private func isLeaf(_ id: Leaf) -> Bool { leaf == id }

    /// Removes the member at `path`; the rest of its row or column grows
    /// evenly into its space, and a group left with one member dissolves.
    private func remove(_ path: [Int]) -> Bool {
        guard let index = path.last, let node = at(Array(path.dropLast())), !node.isLeaf,
              index < node.members.count
        else { return false }
        node.members.remove(at: index)
        if node.members.count == 1 {
            node.become(node.members[0].node)
        } else {
            let total = node.members.reduce(0) { $0 + $1.size }
            for member in node.members.indices { node.members[member].size /= total }
            node.shape = nil
        }
        return true
    }

    /// Turns this node into the only member of a new group along `axis`.
    private func wrap(_ axis: Axis) {
        let old = DockNode(axis: self.axis, members: members, shape: shape)
        old.leaf = leaf
        leaf = nil
        self.axis = axis
        members = [DockMember(size: 1, node: old)]
        shape = nil
    }

    /// Leaves side by side along `axis`, as if `without` were already gone.
    private func lanes(_ axis: Axis, without: Leaf) -> Double {
        if let leaf { return leaf == without ? 0 : 1 }
        let lanes = members.map { $0.node.lanes(axis, without: without) }
        return self.axis == axis ? lanes.reduce(0, +) : lanes.max() ?? 0
    }

    private func find(_ id: Leaf) -> [Int]? {
        if let leaf { return leaf == id ? [] : nil }
        for (index, member) in members.enumerated() {
            if let path = member.node.find(id) { return [index] + path }
        }
        return nil
    }

    private func at(_ path: [Int]) -> DockNode? {
        var node = self
        for index in path {
            guard !node.isLeaf, index < node.members.count else { return nil }
            node = node.members[index].node
        }
        return node
    }

    private static func collect(
        _ layout: Layout<Leaf>,
        axis: Axis,
        size: Double,
        into members: inout [DockMember<Leaf>]
    ) -> DockShape {
        if case let .split(split, ratio, first, second) = layout, split == axis {
            return .split(
                ratio: ratio,
                first: collect(first, axis: axis, size: size * ratio, into: &members),
                second: collect(second, axis: axis, size: size * (1 - ratio), into: &members)
            )
        }
        members.append(DockMember(size: size, node: DockNode(layout)))
        return .member
    }

    private static func build(
        _ shape: DockShape,
        axis: Axis,
        members: inout IndexingIterator<[DockMember<Leaf>]>
    ) -> Layout<Leaf>? {
        switch shape {
        case .member:
            return members.next()?.node.layout()
        case let .split(ratio, first, second):
            guard let first = build(first, axis: axis, members: &members),
                  let second = build(second, axis: axis, members: &members)
            else { return nil }
            return .split(axis: axis, ratio: ratio, first: first, second: second)
        }
    }

    /// Rebuilds a changed row or column as splits that each divide it as
    /// close to the middle as its members allow.
    private static func balanced(axis: Axis, members: [DockMember<Leaf>]) -> Layout<Leaf>? {
        if members.count < 2 { return members.last?.node.layout() }
        let total = members.reduce(0) { $0 + $1.size }
        var before = 0.0
        var best: (index: Int, ratio: Double)?
        for (index, member) in members.dropLast().enumerated() {
            before += member.size
            let ratio = before / total
            if best.map({ abs(ratio - 0.5) < abs($0.ratio - 0.5) }) ?? true { best = (index, ratio) }
        }
        guard let best,
              let first = balanced(axis: axis, members: Array(members[...best.index])),
              let second = balanced(axis: axis, members: Array(members[(best.index + 1)...]))
        else { return nil }
        let ratio = min(max(best.ratio, Layout<Leaf>.minimumRatio), Layout<Leaf>.maximumRatio)
        return .split(axis: axis, ratio: ratio, first: first, second: second)
    }
}
