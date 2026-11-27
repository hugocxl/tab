import Foundation

/// One line of a row's graph. Lanes are columns, counted from the left.
public struct GraphEdge: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// A lane passing the row from top to bottom.
        case through
        /// From lane `from` at the row's top into the commit's node.
        case incoming
        /// From the commit's node down to lane `to` at the row's bottom.
        case outgoing
    }

    public var kind: Kind
    public var from: UInt16
    public var to: UInt16
    /// The lane's color, an index into the graph palette.
    public var color: UInt16

    public init(_ kind: Kind, from: UInt16, to: UInt16, color: UInt16) {
        self.kind = kind
        self.from = from
        self.to = to
        self.color = color
    }
}

/// A commit's place in the graph: its node's lane and color, and its
/// edges as a range of `GitGraphLayout.edges`.
public struct GraphRow: Equatable, Sendable {
    public var lane: UInt16
    public var color: UInt16
    public var edgeStart: UInt32
    public var edgeCount: UInt16
    /// One past the rightmost lane the row draws.
    public var width: UInt16
}

/// Assigns commits to lanes one at a time, in the order Git lists them
/// with children before their parents, so pages of history append without
/// laying out what came before again. Every row's edges share one flat
/// array, keeping memory small for long histories.
public struct GitGraphLayout: Sendable {
    public private(set) var rows: [GraphRow] = []
    public private(set) var edges: ContiguousArray<GraphEdge> = []
    /// The widest row so far, in lanes.
    public private(set) var maxWidth = 0
    /// How many rows are each width, by width in lanes.
    private var widthCounts: [Int] = []
    /// The commit each lane waits for, `nil` for a free lane.
    private var lanes: [String?] = []
    private var laneColors: [UInt16] = []
    private var nextColor: UInt16 = 0

    public init() {}

    public var count: Int { rows.count }

    /// The edges of row `index`.
    public func edges(of index: Int) -> ArraySlice<GraphEdge> {
        let row = rows[index]
        let start = Int(row.edgeStart)
        return edges[start..<(start + Int(row.edgeCount))]
    }

    /// Lays out the next commit, given its hash and parents.
    public mutating func append(hash: String, parents: [String]) {
        let start = edges.count
        var expecting: [Int] = []
        for (index, waiting) in lanes.enumerated() where waiting == hash {
            expecting.append(index)
        }
        let lane: Int
        if let first = expecting.first {
            lane = first
        } else {
            lane = freeLane()
            laneColors[lane] = takeColor()
        }
        let color = laneColors[lane]
        var width = lane + 1

        for (index, waiting) in lanes.enumerated() where waiting != nil && waiting != hash {
            edges.append(GraphEdge(.through, from: UInt16(index), to: UInt16(index), color: laneColors[index]))
            width = max(width, index + 1)
        }
        for index in expecting {
            edges.append(GraphEdge(.incoming, from: UInt16(index), to: UInt16(lane), color: laneColors[index]))
            width = max(width, index + 1)
            lanes[index] = nil
        }

        if let first = parents.first {
            lanes[lane] = first
            laneColors[lane] = color
            edges.append(GraphEdge(.outgoing, from: UInt16(lane), to: UInt16(lane), color: color))
        }
        for parent in parents.dropFirst() {
            let target: Int
            if let existing = lanes.firstIndex(where: { $0 == parent }) {
                target = existing
            } else {
                target = freeLane()
                lanes[target] = parent
                laneColors[target] = takeColor()
            }
            edges.append(GraphEdge(.outgoing, from: UInt16(lane), to: UInt16(target), color: laneColors[target]))
            width = max(width, target + 1)
        }
        while let last = lanes.last, last == nil {
            lanes.removeLast()
            laneColors.removeLast()
        }

        rows.append(GraphRow(lane: UInt16(lane), color: color, edgeStart: UInt32(start),
                             edgeCount: UInt16(min(edges.count - start, Int(UInt16.max))), width: UInt16(width)))
        maxWidth = max(maxWidth, width)
        if widthCounts.count <= width { widthCounts += Array(repeating: 0, count: width + 1 - widthCounts.count) }
        widthCounts[width] += 1
    }

    /// The fewest lanes that fit `share` of the rows, so a short stretch of
    /// many parallel branches doesn't widen the graph for the whole history.
    public func width(covering share: Double) -> Int {
        let needed = Int((Double(rows.count) * share).rounded(.up))
        var covered = 0
        for (width, count) in widthCounts.enumerated() {
            covered += count
            if covered >= needed { return width }
        }
        return maxWidth
    }

    /// The leftmost free lane, opening a new one when all are taken.
    private mutating func freeLane() -> Int {
        if let free = lanes.firstIndex(where: { $0 == nil }) { return free }
        lanes.append(nil)
        laneColors.append(0)
        return lanes.count - 1
    }

    private mutating func takeColor() -> UInt16 {
        defer { nextColor &+= 1 }
        return nextColor
    }
}
