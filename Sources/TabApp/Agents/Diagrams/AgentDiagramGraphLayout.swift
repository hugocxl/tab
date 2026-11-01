import CoreGraphics

/// The direction a layered graph flows in, as Mermaid's `TB`, `BT`, `LR` and `RL`.
enum AgentGraphDirection: Equatable {
    case topToBottom, bottomToTop, leftToRight, rightToLeft

    /// Whether ranks advance along the x axis.
    var isHorizontal: Bool { self == .leftToRight || self == .rightToLeft }

    /// Parses Mermaid's direction words and arrows: `TB`, `TD`, `BT`, `LR`, `RL`, `v`, `^`, `>`, `<`.
    init?(mermaid word: String) {
        switch word.uppercased() {
        case "TB", "TD", "V": self = .topToBottom
        case "BT", "^": self = .bottomToTop
        case "LR", ">": self = .leftToRight
        case "RL", "<": self = .rightToLeft
        default: return nil
        }
    }
}

/// What the layered layout places: sized nodes, directed edges between nodes or clusters, and
/// nested clusters laid out as compound nodes. Indices refer to the arrays in this value.
struct AgentGraphLayoutInput {
    /// One end of an edge: a node, or a whole cluster.
    enum Endpoint: Equatable {
        case node(Int)
        case cluster(Int)
    }

    /// A node of a fixed size, optionally inside a cluster, optionally pinned beside another item
    /// in the same rank (diagram notes).
    struct Node {
        var size: CGSize
        var cluster: Int?
        var anchor: Anchor?

        init(size: CGSize, cluster: Int? = nil, anchor: Anchor? = nil) {
            self.size = size
            self.cluster = cluster
            self.anchor = anchor
        }
    }

    /// Places a node next to `target` in the same rank, after it (right in top-down graphs) or before it.
    struct Anchor {
        var target: Endpoint
        var after: Bool
    }

    struct Edge {
        var from: Endpoint
        var to: Endpoint
        /// The label's size, which the layout reserves room for halfway along the edge.
        var labelSize: CGSize?
        /// The minimum number of ranks the edge spans, at least 1.
        var minLength: Int

        init(from: Endpoint, to: Endpoint, labelSize: CGSize? = nil, minLength: Int = 1) {
            self.from = from
            self.to = to
            self.labelSize = labelSize
            self.minLength = minLength
        }
    }

    /// A group of nodes and clusters drawn as one box with a title on top.
    struct Cluster {
        var parent: Int?
        var titleSize: CGSize
        /// The direction inside the cluster; the parent's when nil.
        var direction: AgentGraphDirection?

        init(parent: Int? = nil, titleSize: CGSize = .zero, direction: AgentGraphDirection? = nil) {
            self.parent = parent
            self.titleSize = titleSize
            self.direction = direction
        }
    }

    var direction: AgentGraphDirection = .topToBottom
    var nodes: [Node] = []
    var edges: [Edge] = []
    var clusters: [Cluster] = []
    /// Space between neighboring nodes in a rank.
    var nodeSpacing: CGFloat = 36
    /// Space between consecutive ranks.
    var rankSpacing: CGFloat = 44
    /// Space between edges routed side by side.
    var edgeSpacing: CGFloat = 14
    /// Padding between a cluster's border and its content.
    var clusterPadding: CGFloat = 14
}

/// Where the layered layout put everything. The origin is the top-left corner, y grows downward.
struct AgentGraphLayoutResult {
    /// An edge's polyline from its source's border to its target's border, and its label's center.
    struct Route {
        var points: [CGPoint]
        var labelCenter: CGPoint?
    }

    var size: CGSize
    var nodeFrames: [CGRect]
    var clusterFrames: [CGRect]
    /// One route per input edge, in order. Empty when an edge joins a cluster to its own content.
    var routes: [Route]
}

/// A layered (Sugiyama-style) graph layout: cycle breaking, ranking, long-edge dummies, barycentric
/// crossing reduction, rank-constrained coordinate assignment and orthogonal edge routing. Clusters
/// are laid out recursively and placed as compound nodes in their parent. Pure and deterministic.
enum AgentGraphLayout {
    static func layout(_ input: AgentGraphLayoutInput) -> AgentGraphLayoutResult {
        var layout = CompoundLayout(input: input)
        return layout.run()
    }
}

// MARK: - Compound (cluster) layout

private struct CompoundLayout {
    let input: AgentGraphLayoutInput
    let root: Int
    var clusterParent: [Int]
    var clusterDepth: [Int]
    var nodeScope: [Int]

    var nodeRelative: [CGRect]
    var clusterRelative: [CGRect]
    var clusterContentOffset: [CGPoint]
    var scopeDirection: [AgentGraphDirection]
    var scopeRoutes: [[(edge: Int, route: AgentGraphLayoutResult.Route, fixed: Bool)]]
    var scopeSize: [CGSize]

    init(input: AgentGraphLayoutInput) {
        self.input = input
        let clusterCount = input.clusters.count
        root = clusterCount
        clusterParent = input.clusters.map { cluster in
            guard let parent = cluster.parent, parent >= 0, parent < clusterCount else { return clusterCount }
            return parent
        }
        // Break parent cycles and compute depths.
        clusterDepth = Array(repeating: 0, count: clusterCount)
        for index in 0..<clusterCount {
            var depth = 0
            var current = index
            var steps = 0
            while clusterParent[current] != clusterCount, steps <= clusterCount {
                current = clusterParent[current]
                depth += 1
                steps += 1
            }
            if steps > clusterCount { clusterParent[index] = clusterCount }
            _ = depth
        }
        for index in 0..<clusterCount {
            var depth = 0
            var current = index
            var steps = 0
            while clusterParent[current] != clusterCount, steps <= clusterCount {
                current = clusterParent[current]
                depth += 1
                steps += 1
            }
            clusterDepth[index] = depth
        }
        nodeScope = input.nodes.map { node in
            guard let cluster = node.cluster, cluster >= 0, cluster < clusterCount else { return clusterCount }
            return cluster
        }
        nodeRelative = Array(repeating: .zero, count: input.nodes.count)
        clusterRelative = Array(repeating: .zero, count: clusterCount)
        clusterContentOffset = Array(repeating: .zero, count: clusterCount)
        scopeDirection = Array(repeating: input.direction, count: clusterCount + 1)
        scopeRoutes = Array(repeating: [], count: clusterCount + 1)
        scopeSize = Array(repeating: .zero, count: clusterCount + 1)
    }

    private func itemScope(_ endpoint: AgentGraphLayoutInput.Endpoint) -> Int? {
        switch endpoint {
        case .node(let index):
            return index >= 0 && index < nodeScope.count ? nodeScope[index] : nil
        case .cluster(let index):
            return index >= 0 && index < clusterParent.count ? clusterParent[index] : nil
        }
    }

    /// Scopes from the one holding `endpoint` up to the root, plus the cluster itself first when the endpoint is a cluster.
    private func chain(_ endpoint: AgentGraphLayoutInput.Endpoint) -> [Int] {
        guard var scope = itemScope(endpoint) else { return [] }
        var scopes: [Int] = []
        if case .cluster(let index) = endpoint { scopes.append(index) }
        scopes.append(scope)
        var steps = 0
        while scope != root, steps <= root {
            scope = clusterParent[scope]
            scopes.append(scope)
            steps += 1
        }
        return scopes
    }

    /// The item inside `scope` that contains `endpoint`, or nil when `endpoint` is `scope` itself.
    private func representative(of endpoint: AgentGraphLayoutInput.Endpoint, in scope: Int, chain: [Int]) -> AgentGraphLayoutInput.Endpoint? {
        if case .cluster(let index) = endpoint, index == scope { return nil }
        if itemScope(endpoint) == scope { return endpoint }
        guard let position = chain.firstIndex(of: scope), position > 0 else { return nil }
        return .cluster(chain[position - 1])
    }

    mutating func run() -> AgentGraphLayoutResult {
        let clusterCount = input.clusters.count
        // Resolve directions top-down.
        let topDown = (0..<clusterCount).sorted { (clusterDepth[$0], $0) < (clusterDepth[$1], $1) }
        for cluster in topDown {
            scopeDirection[cluster] = input.clusters[cluster].direction ?? scopeDirection[clusterParent[cluster]]
        }

        // Items per scope.
        var scopeItems: [[AgentGraphLayoutInput.Endpoint]] = Array(repeating: [], count: clusterCount + 1)
        var localIndexOfNode = Array(repeating: 0, count: input.nodes.count)
        var localIndexOfCluster = Array(repeating: 0, count: clusterCount)
        for index in input.nodes.indices {
            localIndexOfNode[index] = scopeItems[nodeScope[index]].count
            scopeItems[nodeScope[index]].append(.node(index))
        }
        for index in 0..<clusterCount {
            localIndexOfCluster[index] = scopeItems[clusterParent[index]].count
            scopeItems[clusterParent[index]].append(.cluster(index))
        }
        func local(_ endpoint: AgentGraphLayoutInput.Endpoint) -> Int {
            switch endpoint {
            case .node(let index): return localIndexOfNode[index]
            case .cluster(let index): return localIndexOfCluster[index]
            }
        }

        // Assign every edge to the scope of its endpoints' lowest common ancestor.
        var scopeEdges: [[LevelEdge]] = Array(repeating: [], count: clusterCount + 1)
        for (index, edge) in input.edges.enumerated() {
            let fromChain = chain(edge.from)
            let toChain = chain(edge.to)
            guard !fromChain.isEmpty, !toChain.isEmpty,
                  let common = fromChain.first(where: { toChain.contains($0) }) else { continue }
            guard let from = representative(of: edge.from, in: common, chain: fromChain),
                  let to = representative(of: edge.to, in: common, chain: toChain) else { continue }
            scopeEdges[common].append(LevelEdge(
                from: local(from), to: local(to), minLength: max(1, min(edge.minLength, 16)),
                labelSize: edge.labelSize, id: index
            ))
        }

        // Lay out scopes deepest first so clusters know their size before their parent places them.
        let bottomUp = (0..<clusterCount).sorted { (clusterDepth[$0], $0) > (clusterDepth[$1], $1) } + [root]
        let padding = input.clusterPadding
        for scope in bottomUp {
            let items = scopeItems[scope]
            var sizes: [CGSize] = []
            sizes.reserveCapacity(items.count)
            var anchors: [Int: LevelAnchor] = [:]
            for (position, item) in items.enumerated() {
                switch item {
                case .node(let index):
                    let size = input.nodes[index].size
                    sizes.append(CGSize(width: max(0, size.width), height: max(0, size.height)))
                    if let anchor = input.nodes[index].anchor, itemScope(anchor.target) == scope {
                        let target = local(anchor.target)
                        if target != position { anchors[position] = LevelAnchor(target: target, after: anchor.after) }
                    }
                case .cluster(let index):
                    sizes.append(clusterRelative[index].size)
                }
            }
            var layered = LayeredLayout(
                sizes: sizes, edges: scopeEdges[scope], anchors: anchors,
                direction: scopeDirection[scope], input: input
            )
            let level = layered.run()
            scopeSize[scope] = level.size
            for (position, item) in items.enumerated() {
                switch item {
                case .node(let index): nodeRelative[index] = level.frames[position]
                case .cluster(let index): clusterRelative[index].origin = level.frames[position].origin
                }
            }
            scopeRoutes[scope] = level.routes

            guard scope != root else { continue }
            let title = input.clusters[scope].titleSize
            let titleBand = title.height > 0 ? title.height + 6 : 0
            let width = max(level.size.width + padding * 2, title.width + padding * 2, 48)
            let height = max(level.size.height + padding * 2 + titleBand, 32)
            clusterRelative[scope].size = CGSize(width: width, height: height)
            clusterContentOffset[scope] = CGPoint(x: (width - level.size.width) / 2, y: padding + titleBand)
        }

        // Absolute positions, top-down.
        var scopeOrigin = Array(repeating: CGPoint.zero, count: clusterCount + 1)
        var clusterFrames = Array(repeating: CGRect.zero, count: clusterCount)
        for cluster in topDown {
            let parentOrigin = scopeOrigin[clusterParent[cluster]]
            let frame = clusterRelative[cluster].offsetBy(dx: parentOrigin.x, dy: parentOrigin.y)
            clusterFrames[cluster] = frame
            scopeOrigin[cluster] = CGPoint(x: frame.minX + clusterContentOffset[cluster].x, y: frame.minY + clusterContentOffset[cluster].y)
        }
        let nodeFrames = input.nodes.indices.map { index -> CGRect in
            let origin = scopeOrigin[nodeScope[index]]
            return nodeRelative[index].offsetBy(dx: origin.x, dy: origin.y)
        }
        func frame(of endpoint: AgentGraphLayoutInput.Endpoint) -> CGRect {
            switch endpoint {
            case .node(let index): return nodeFrames[index]
            case .cluster(let index): return clusterFrames[index]
            }
        }

        var routes = Array(repeating: AgentGraphLayoutResult.Route(points: [], labelCenter: nil), count: input.edges.count)
        for scope in 0...clusterCount {
            let origin = scopeOrigin[scope]
            let vertical = !scopeDirection[scope].isHorizontal
            for (edgeIndex, relative, fixed) in scopeRoutes[scope] {
                var points = relative.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                let edge = input.edges[edgeIndex]
                if !fixed, points.count >= 2 {
                    points = Self.retarget(points, to: frame(of: edge.from), vertical: vertical)
                    points.reverse()
                    points = Self.retarget(points, to: frame(of: edge.to), vertical: vertical)
                    points.reverse()
                    points = Self.orthogonalize(points, vertical: vertical)
                }
                let label = relative.labelCenter.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
                routes[edgeIndex] = .init(points: points, labelCenter: label)
            }
        }

        // Normalize so everything starts at the origin.
        var bounds = CGRect.null
        for frame in nodeFrames { bounds = bounds.union(frame) }
        for frame in clusterFrames { bounds = bounds.union(frame) }
        for (index, route) in routes.enumerated() {
            for point in route.points { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
            if let center = route.labelCenter, let size = input.edges[index].labelSize {
                bounds = bounds.union(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
            }
        }
        if bounds.isNull { bounds = .zero }
        let dx = -bounds.minX
        let dy = -bounds.minY
        return AgentGraphLayoutResult(
            size: CGSize(width: ceil(bounds.width), height: ceil(bounds.height)),
            nodeFrames: nodeFrames.map { $0.offsetBy(dx: dx, dy: dy) },
            clusterFrames: clusterFrames.map { $0.offsetBy(dx: dx, dy: dy) },
            routes: routes.map { route in
                .init(points: route.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) },
                      labelCenter: route.labelCenter.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            }
        )
    }

    /// Moves a route's first point onto `frame`'s matching side when the route was laid out
    /// against an enclosing cluster, keeping the first stub straight.
    static func retarget(_ points: [CGPoint], to frame: CGRect, vertical: Bool) -> [CGPoint] {
        guard let first = points.first else { return points }
        var result = points
        if vertical {
            let onBottom = abs(first.y - frame.maxY) <= abs(first.y - frame.minY)
            let y = onBottom ? frame.maxY : frame.minY
            if abs(first.y - y) < 0.5, first.x >= frame.minX - 0.5, first.x <= frame.maxX + 0.5 { return points }
            let x = frame.midX
            if result.count > 2, abs(result[1].x - first.x) < 0.5 { result[1].x = x }
            result[0] = CGPoint(x: x, y: y)
        } else {
            let onRight = abs(first.x - frame.maxX) <= abs(first.x - frame.minX)
            let x = onRight ? frame.maxX : frame.minX
            if abs(first.x - x) < 0.5, first.y >= frame.minY - 0.5, first.y <= frame.maxY + 0.5 { return points }
            let y = frame.midY
            if result.count > 2, abs(result[1].y - first.y) < 0.5 { result[1].y = y }
            result[0] = CGPoint(x: x, y: y)
        }
        return result
    }

    /// Inserts bends so every segment is horizontal or vertical, then drops redundant points.
    static func orthogonalize(_ points: [CGPoint], vertical: Bool) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        var result: [CGPoint] = [points[0]]
        for point in points.dropFirst() {
            guard let last = result.last else { continue }
            if abs(last.x - point.x) > 0.5, abs(last.y - point.y) > 0.5 {
                if vertical {
                    let middle = (last.y + point.y) / 2
                    result.append(CGPoint(x: last.x, y: middle))
                    result.append(CGPoint(x: point.x, y: middle))
                } else {
                    let middle = (last.x + point.x) / 2
                    result.append(CGPoint(x: middle, y: last.y))
                    result.append(CGPoint(x: middle, y: point.y))
                }
            }
            result.append(point)
        }
        return simplify(result)
    }

    /// Removes repeated points and middle points of straight runs.
    static func simplify(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last, abs(last.x - point.x) < 0.01, abs(last.y - point.y) < 0.01 { continue }
            if result.count >= 2 {
                let a = result[result.count - 2]
                let b = result[result.count - 1]
                let sameX = abs(a.x - b.x) < 0.01 && abs(b.x - point.x) < 0.01
                let sameY = abs(a.y - b.y) < 0.01 && abs(b.y - point.y) < 0.01
                let forwardX = (b.y - a.y) * (point.y - b.y) >= 0
                let forwardY = (b.x - a.x) * (point.x - b.x) >= 0
                if (sameX && forwardX) || (sameY && forwardY) {
                    result[result.count - 1] = point
                    continue
                }
            }
            result.append(point)
        }
        return result
    }
}

// MARK: - One level

private struct LevelEdge {
    var from: Int
    var to: Int
    var minLength: Int
    var labelSize: CGSize?
    var id: Int
}

private struct LevelAnchor {
    var target: Int
    var after: Bool
}

private struct LevelResult {
    var size: CGSize
    var frames: [CGRect]
    var routes: [(edge: Int, route: AgentGraphLayoutResult.Route, fixed: Bool)]
}

/// Lays out one flat graph of sized items top-down, then maps the result to its direction.
private struct LayeredLayout {
    private enum Kind { case real, dummy, label }

    let itemSizes: [CGSize]
    let edges: [LevelEdge]
    let anchors: [Int: LevelAnchor]
    let direction: AgentGraphDirection
    let nodeSpacing: CGFloat
    let rankSpacing: CGFloat
    let edgeSpacing: CGFloat

    // Segmented graph: items first, then dummies.
    private var width: [CGFloat] = []
    private var height: [CGFloat] = []
    private var kind: [Kind] = []
    private var rank: [Int] = []
    private var preds: [[Int]] = []
    private var succs: [[Int]] = []
    private var layers: [[Int]] = []
    private var x: [CGFloat] = []

    init(sizes: [CGSize], edges: [LevelEdge], anchors: [Int: LevelAnchor], direction: AgentGraphDirection, input: AgentGraphLayoutInput) {
        self.itemSizes = sizes
        self.edges = edges
        self.anchors = anchors
        self.direction = direction
        nodeSpacing = input.nodeSpacing
        rankSpacing = input.rankSpacing
        edgeSpacing = input.edgeSpacing
    }

    private func internalSize(_ size: CGSize) -> CGSize {
        direction.isHorizontal ? CGSize(width: size.height, height: size.width) : size
    }

    mutating func run() -> LevelResult {
        let count = itemSizes.count
        guard count > 0 else { return LevelResult(size: .zero, frames: [], routes: []) }

        // Anchors may not chain or point at anchored items.
        var anchorOf = Array<LevelAnchor?>(repeating: nil, count: count)
        for item in 0..<count {
            guard let anchor = anchors[item], anchor.target >= 0, anchor.target < count, anchors[anchor.target] == nil else { continue }
            anchorOf[item] = anchor
        }

        for size in itemSizes {
            let inner = internalSize(size)
            width.append(inner.width)
            height.append(inner.height)
            kind.append(.real)
        }

        // Edges between distinct, unanchored items take part in ranking.
        var flowEdges: [LevelEdge] = []
        var loops: [LevelEdge] = []
        for edge in edges {
            guard edge.from >= 0, edge.from < count, edge.to >= 0, edge.to < count else { continue }
            if edge.from == edge.to { loops.append(edge); continue }
            if anchorOf[edge.from] != nil || anchorOf[edge.to] != nil { loops.append(edge); continue }
            flowEdges.append(edge)
        }
        let hasLabels = flowEdges.contains { $0.labelSize != nil }
        let lengthScale = hasLabels ? 2 : 1

        let reversed = breakCycles(count: count, edges: flowEdges, anchored: anchorOf)
        var oriented: [(source: Int, target: Int, length: Int)] = []
        oriented.reserveCapacity(flowEdges.count)
        for (index, edge) in flowEdges.enumerated() {
            let length = edge.minLength * lengthScale
            oriented.append(reversed[index] ? (edge.to, edge.from, length) : (edge.from, edge.to, length))
        }
        rank = assignRanks(count: count, edges: oriented, anchored: anchorOf)
        for item in 0..<count {
            if let anchor = anchorOf[item] { rank[item] = rank[anchor.target] }
        }

        // Split long edges into chains of unit-length segments.
        preds = Array(repeating: [], count: count)
        succs = Array(repeating: [], count: count)
        var chains: [[Int]] = []
        var labelNodes: [Int?] = []
        chains.reserveCapacity(oriented.count)
        for (index, edge) in oriented.enumerated() {
            let span = max(1, rank[edge.target] - rank[edge.source])
            var chain = [edge.source]
            var labelNode: Int?
            let labelRank = rank[edge.source] + span / 2
            if span > 1 {
                for step in 1..<span {
                    let node = width.count
                    let r = rank[edge.source] + step
                    if let label = flowEdges[index].labelSize, r == labelRank, labelNode == nil {
                        let inner = internalSize(label)
                        width.append(inner.width)
                        height.append(inner.height)
                        kind.append(.label)
                        labelNode = node
                    } else {
                        width.append(0)
                        height.append(0)
                        kind.append(.dummy)
                    }
                    rank.append(r)
                    preds.append([])
                    succs.append([])
                    chain.append(node)
                }
            }
            chain.append(edge.target)
            for step in 0..<(chain.count - 1) {
                succs[chain[step]].append(chain[step + 1])
                preds[chain[step + 1]].append(chain[step])
            }
            chains.append(chain)
            labelNodes.append(labelNode)
        }

        orderLayers(itemCount: count, anchored: anchorOf)
        insertAnchored(anchored: anchorOf)
        assignCoordinates(anchored: anchorOf)
        var (exitOffset, entryOffset) = ports(chains, itemCount: count)
        straighten(chains, exitOffset: exitOffset, entryOffset: entryOffset)
        removeSmallJogs(chains, exitOffset: &exitOffset, entryOffset: &entryOffset)

        // Rank bands.
        let rankCount = layers.count
        var bandHeight = Array(repeating: CGFloat(0), count: rankCount)
        for node in rank.indices where rank[node] < rankCount {
            bandHeight[rank[node]] = max(bandHeight[rank[node]], height[node])
        }
        let gap = hasLabels ? rankSpacing / 2 : rankSpacing
        var bandTop = Array(repeating: CGFloat(0), count: rankCount)
        var cursor: CGFloat = 0
        for r in 0..<rankCount {
            bandTop[r] = cursor
            cursor += bandHeight[r] + (r == rankCount - 1 ? 0 : gap)
        }
        let innerHeight = cursor
        var innerWidth: CGFloat = 0
        for node in x.indices { innerWidth = max(innerWidth, x[node] + width[node] / 2) }
        func centerY(_ node: Int) -> CGFloat { bandTop[rank[node]] + bandHeight[rank[node]] / 2 }

        let map: (CGPoint) -> CGPoint = { [direction] point in
            switch direction {
            case .topToBottom: return point
            case .bottomToTop: return CGPoint(x: point.x, y: innerHeight - point.y)
            case .leftToRight: return CGPoint(x: point.y, y: point.x)
            case .rightToLeft: return CGPoint(x: innerHeight - point.y, y: point.x)
            }
        }
        let size = direction.isHorizontal ? CGSize(width: innerHeight, height: innerWidth) : CGSize(width: innerWidth, height: innerHeight)

        var frames: [CGRect] = []
        frames.reserveCapacity(count)
        for item in 0..<count {
            let center = map(CGPoint(x: x[item], y: centerY(item)))
            let real = itemSizes[item]
            frames.append(CGRect(x: center.x - real.width / 2, y: center.y - real.height / 2, width: real.width, height: real.height))
        }

        var routes: [(edge: Int, route: AgentGraphLayoutResult.Route, fixed: Bool)] = []
        routes.reserveCapacity(edges.count)
        for (index, chain) in chains.enumerated() {
            guard let source = chain.first, let target = chain.last else { continue }
            let last = chain.count - 1
            func position(_ step: Int) -> CGFloat {
                if step == 0 { return x[chain[0]] + exitOffset[index] }
                if step == last { return x[chain[last]] + entryOffset[index] }
                return x[chain[step]]
            }
            var points = [CGPoint(x: position(0), y: centerY(source) + height[source] / 2)]
            for step in 0..<last {
                let a = chain[step]
                let b = chain[step + 1]
                let gapMiddle = (bandTop[rank[a]] + bandHeight[rank[a]] + bandTop[rank[b]]) / 2
                let fromX = position(step)
                let toX = position(step + 1)
                if abs(fromX - toX) > 0.5 {
                    points.append(CGPoint(x: fromX, y: gapMiddle))
                    points.append(CGPoint(x: toX, y: gapMiddle))
                }
                if b == target {
                    points.append(CGPoint(x: toX, y: centerY(b) - height[b] / 2))
                } else {
                    points.append(CGPoint(x: x[b], y: bandTop[rank[b]]))
                    points.append(CGPoint(x: x[b], y: bandTop[rank[b]] + bandHeight[rank[b]]))
                }
            }
            if reversed[index] { points.reverse() }
            let label = labelNodes[index].map { map(CGPoint(x: x[$0], y: centerY($0))) }
            routes.append((flowEdges[index].id, .init(points: CompoundLayout.simplify(points.map(map)), labelCenter: label), false))
        }
        for edge in loops {
            routes.append((edge.id, loopRoute(edge, frames: frames), true))
        }
        return LevelResult(size: size, frames: frames, routes: routes)
    }

    /// Self loops and links to anchored items: a small loop on the side, or a straight connector.
    private func loopRoute(_ edge: LevelEdge, frames: [CGRect]) -> AgentGraphLayoutResult.Route {
        let from = frames[edge.from]
        if edge.from != edge.to {
            let to = frames[edge.to]
            let start: CGPoint
            let end: CGPoint
            if direction.isHorizontal {
                let down = to.midY > from.midY
                start = CGPoint(x: from.midX, y: down ? from.maxY : from.minY)
                end = CGPoint(x: to.midX, y: down ? to.minY : to.maxY)
            } else {
                let right = to.midX > from.midX
                start = CGPoint(x: right ? from.maxX : from.minX, y: from.midY)
                end = CGPoint(x: right ? to.minX : to.maxX, y: to.midY)
            }
            let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            return .init(points: [start, end], labelCenter: edge.labelSize == nil ? nil : middle)
        }
        let reach: CGFloat = 18
        if direction.isHorizontal {
            let quarter = min(from.width / 4, 12)
            let points = [
                CGPoint(x: from.midX + quarter, y: from.maxY),
                CGPoint(x: from.midX + quarter, y: from.maxY + reach),
                CGPoint(x: from.midX - quarter, y: from.maxY + reach),
                CGPoint(x: from.midX - quarter, y: from.maxY),
            ]
            let label = edge.labelSize.map { CGPoint(x: from.midX, y: from.maxY + reach + $0.height / 2 + 2) }
            return .init(points: points, labelCenter: label)
        }
        let quarter = min(from.height / 4, 12)
        let points = [
            CGPoint(x: from.maxX, y: from.midY - quarter),
            CGPoint(x: from.maxX + reach, y: from.midY - quarter),
            CGPoint(x: from.maxX + reach, y: from.midY + quarter),
            CGPoint(x: from.maxX, y: from.midY + quarter),
        ]
        let label = edge.labelSize.map { CGPoint(x: from.maxX + reach + $0.width / 2 + 4, y: from.midY) }
        return .init(points: points, labelCenter: label)
    }

    // MARK: Edge straightening and ports

    /// Lines up each long edge's dummies on one x when that fits between their layer neighbors,
    /// so long edges run straight instead of stepping at every rank.
    private mutating func straighten(_ chains: [[Int]], exitOffset: [CGFloat], entryOffset: [CGFloat]) {
        var layerIndex = Array(repeating: 0, count: rank.count)
        for layer in layers { for (index, node) in layer.enumerated() { layerIndex[node] = index } }
        func fits(_ node: Int, _ candidate: CGFloat) -> Bool {
            let layer = layers[rank[node]]
            let index = layerIndex[node]
            if index > 0, x[layer[index - 1]] + separation(layer[index - 1], node) > candidate + 0.01 { return false }
            if index + 1 < layer.count, candidate + separation(node, layer[index + 1]) > x[layer[index + 1]] + 0.01 { return false }
            return true
        }
        let order = chains.indices.sorted { (chains[$0].count, $1) > (chains[$1].count, $0) }
        for chainIndex in order {
            let chain = chains[chainIndex]
            guard chain.count > 2, let source = chain.first, let target = chain.last else { continue }
            let inner = Array(chain[1..<(chain.count - 1)])
            let sourceX = x[source] + exitOffset[chainIndex]
            let targetX = x[target] + entryOffset[chainIndex]
            let sorted = inner.map { x[$0] }.sorted()
            var aligned = false
            for candidate in [targetX, sourceX, sorted[sorted.count / 2]] where inner.allSatisfy({ fits($0, candidate) }) {
                for node in inner { x[node] = candidate }
                aligned = true
                break
            }
            guard !aligned else { continue }
            // Otherwise line up as many consecutive pieces as fit, from each end.
            var previous = sourceX
            for node in inner {
                if fits(node, previous) { x[node] = previous }
                previous = x[node]
            }
            var next = targetX
            for node in inner.reversed() {
                if fits(node, next) { x[node] = next }
                next = x[node]
            }
        }
    }

    /// Moves an edge's port to line up with its first or last bend when they are only a few points
    /// apart, so the edge leaves or enters straight instead of with a tiny step.
    private func removeSmallJogs(_ chains: [[Int]], exitOffset: inout [CGFloat], entryOffset: inout [CGFloat]) {
        for (index, chain) in chains.enumerated() where chain.count >= 2 {
            let source = chain[0]
            let target = chain[chain.count - 1]
            let afterSource = chain.count > 2 ? x[chain[1]] : x[target] + entryOffset[index]
            let jogOut = afterSource - (x[source] + exitOffset[index])
            if abs(jogOut) > 0.5, abs(jogOut) < 10, abs(afterSource - x[source]) <= width[source] * 0.4 {
                exitOffset[index] = afterSource - x[source]
            }
            let beforeTarget = chain.count > 2 ? x[chain[chain.count - 2]] : x[source] + exitOffset[index]
            let jogIn = beforeTarget - (x[target] + entryOffset[index])
            if abs(jogIn) > 0.5, abs(jogIn) < 10, abs(beforeTarget - x[target]) <= width[target] * 0.4 {
                entryOffset[index] = beforeTarget - x[target]
            }
        }
    }

    /// Spreads the ends of several edges meeting one side of an item, ordered by where they go,
    /// so they do not overlap. Returns cross-axis offsets for each chain's first and last point.
    private func ports(_ chains: [[Int]], itemCount: Int) -> ([CGFloat], [CGFloat]) {
        var exits = Array(repeating: [(key: CGFloat, chain: Int)](), count: itemCount)
        var entries = Array(repeating: [(key: CGFloat, chain: Int)](), count: itemCount)
        for (index, chain) in chains.enumerated() {
            guard chain.count >= 2, let first = chain.first, let last = chain.last else { continue }
            exits[first].append((x[chain[1]], index))
            entries[last].append((x[chain[chain.count - 2]], index))
        }
        var exitOffset = Array(repeating: CGFloat(0), count: chains.count)
        var entryOffset = Array(repeating: CGFloat(0), count: chains.count)
        func spread(_ list: [(key: CGFloat, chain: Int)], item: Int, into offsets: inout [CGFloat]) {
            guard list.count > 1 else { return }
            let sorted = list.sorted { $0.key != $1.key ? $0.key < $1.key : $0.chain < $1.chain }
            let spacing = min(12, width[item] * 0.6 / CGFloat(sorted.count - 1))
            for (position, entry) in sorted.enumerated() {
                offsets[entry.chain] = (CGFloat(position) - CGFloat(sorted.count - 1) / 2) * spacing
            }
        }
        for item in 0..<itemCount {
            spread(exits[item], item: item, into: &exitOffset)
            spread(entries[item], item: item, into: &entryOffset)
        }
        return (exitOffset, entryOffset)
    }

    // MARK: Cycle breaking

    /// Depth-first search in item order; edges back to an item on the stack are reversed.
    private func breakCycles(count: Int, edges: [LevelEdge], anchored: [LevelAnchor?]) -> [Bool] {
        var outgoing = Array(repeating: [Int](), count: count)
        for (index, edge) in edges.enumerated() { outgoing[edge.from].append(index) }
        var state = Array(repeating: 0, count: count)
        var reversed = Array(repeating: false, count: edges.count)
        var stack: [(node: Int, next: Int)] = []
        for start in 0..<count where state[start] == 0 && anchored[start] == nil {
            state[start] = 1
            stack.append((start, 0))
            while let top = stack.last {
                if top.next >= outgoing[top.node].count {
                    state[top.node] = 2
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let edgeIndex = outgoing[top.node][top.next]
                let target = edges[edgeIndex].to
                switch state[target] {
                case 0:
                    state[target] = 1
                    stack.append((target, 0))
                case 1:
                    reversed[edgeIndex] = true
                default:
                    break
                }
            }
        }
        return reversed
    }

    // MARK: Ranking

    /// Longest-path ranking, then a few passes that move each item within its feasible range
    /// toward the side with more edges (a cheap approximation of network simplex).
    private func assignRanks(count: Int, edges: [(source: Int, target: Int, length: Int)], anchored: [LevelAnchor?]) -> [Int] {
        var incoming = Array(repeating: [Int](), count: count)
        var outgoing = Array(repeating: [Int](), count: count)
        var inDegree = Array(repeating: 0, count: count)
        for (index, edge) in edges.enumerated() {
            outgoing[edge.source].append(index)
            incoming[edge.target].append(index)
            inDegree[edge.target] += 1
        }
        var order: [Int] = []
        order.reserveCapacity(count)
        var queue: [Int] = (0..<count).filter { inDegree[$0] == 0 && anchored[$0] == nil }
        var head = 0
        while head < queue.count {
            let node = queue[head]
            head += 1
            order.append(node)
            for edgeIndex in outgoing[node] {
                let target = edges[edgeIndex].target
                inDegree[target] -= 1
                if inDegree[target] == 0 { queue.append(target) }
            }
        }
        var ranks = Array(repeating: 0, count: count)
        for node in order {
            for edgeIndex in outgoing[node] {
                let edge = edges[edgeIndex]
                ranks[edge.target] = max(ranks[edge.target], ranks[node] + edge.length)
            }
        }
        for pass in 0..<4 {
            let sequence = pass % 2 == 0 ? Array(order.reversed()) : order
            for node in sequence {
                var low: Int?
                var high: Int?
                for edgeIndex in incoming[node] {
                    let edge = edges[edgeIndex]
                    low = max(low ?? Int.min, ranks[edge.source] + edge.length)
                }
                for edgeIndex in outgoing[node] {
                    let edge = edges[edgeIndex]
                    high = min(high ?? Int.max, ranks[edge.target] - edge.length)
                }
                switch (low, high) {
                case (nil, nil):
                    continue
                case (nil, let high?):
                    ranks[node] = high
                case (let low?, nil):
                    ranks[node] = low
                case (let low?, let high?):
                    guard low <= high else { continue }
                    if incoming[node].count > outgoing[node].count {
                        ranks[node] = low
                    } else if outgoing[node].count > incoming[node].count {
                        ranks[node] = high
                    } else {
                        ranks[node] = min(max(ranks[node], low), high)
                    }
                }
            }
        }
        let minimum = order.map { ranks[$0] }.min() ?? 0
        for node in 0..<count { ranks[node] -= minimum }
        return ranks
    }

    // MARK: Ordering

    private mutating func orderLayers(itemCount: Int, anchored: [LevelAnchor?]) {
        let rankCount = (rank.max() ?? 0) + 1
        layers = Array(repeating: [], count: rankCount)
        var visited = Array(repeating: false, count: rank.count)
        // Depth-first initial order keeps subtrees together.
        for start in 0..<itemCount where !visited[start] && anchored[start] == nil {
            var stack = [start]
            while let node = stack.popLast() {
                if visited[node] { continue }
                visited[node] = true
                layers[rank[node]].append(node)
                for next in succs[node].reversed() where !visited[next] { stack.append(next) }
            }
        }
        for node in itemCount..<rank.count where !visited[node] {
            visited[node] = true
            layers[rank[node]].append(node)
        }

        var position = Array(repeating: 0, count: rank.count)
        func refreshPositions() {
            for layer in layers { for (index, node) in layer.enumerated() { position[node] = index } }
        }
        refreshPositions()
        var best = layers
        var bestCrossings = countCrossings(position: position)
        guard bestCrossings > 0, rankCount > 1 else { return }

        let iterations = rank.count > 3000 ? 4 : 10
        for iteration in 0..<iterations {
            let down = iteration % 2 == 0
            let sequence = down ? Array(1..<rankCount) : Array((0..<(rankCount - 1)).reversed())
            for r in sequence {
                reorder(layer: r, usingPredecessors: down, position: &position)
            }
            let crossings = countCrossings(position: position)
            if crossings < bestCrossings {
                bestCrossings = crossings
                best = layers
                if crossings == 0 { break }
            }
        }
        layers = best
    }

    private mutating func reorder(layer r: Int, usingPredecessors: Bool, position: inout [Int]) {
        let layer = layers[r]
        guard layer.count > 1 else { return }
        var weighted: [(node: Int, value: Double, current: Int)] = []
        var fixed = Array(repeating: false, count: layer.count)
        for (index, node) in layer.enumerated() {
            let neighbors = usingPredecessors ? preds[node] : succs[node]
            guard !neighbors.isEmpty else { fixed[index] = true; continue }
            var sum = 0
            for neighbor in neighbors { sum += position[neighbor] }
            weighted.append((node, Double(sum) / Double(neighbors.count), index))
        }
        weighted.sort { $0.value != $1.value ? $0.value < $1.value : $0.current < $1.current }
        var result: [Int] = []
        result.reserveCapacity(layer.count)
        var next = 0
        for (index, node) in layer.enumerated() {
            if fixed[index] {
                result.append(node)
            } else {
                result.append(weighted[next].node)
                next += 1
            }
        }
        layers[r] = result
        for (index, node) in result.enumerated() { position[node] = index }
    }

    /// Counts edge crossings between consecutive layers with a Fenwick tree.
    private func countCrossings(position: [Int]) -> Int {
        guard layers.count > 1 else { return 0 }
        var total = 0
        var tree: [Int] = []
        var targets: [Int] = []
        for r in 0..<(layers.count - 1) {
            let size = layers[r + 1].count
            tree = Array(repeating: 0, count: size + 1)
            var seen = 0
            for node in layers[r] {
                targets.removeAll(keepingCapacity: true)
                for next in succs[node] { targets.append(position[next]) }
                targets.sort()
                for target in targets {
                    // Count earlier edges whose target lies strictly to the right.
                    var lessOrEqual = 0
                    var i = target + 1
                    while i > 0 { lessOrEqual += tree[i]; i -= i & -i }
                    total += seen - lessOrEqual
                    var j = target + 1
                    while j <= size { tree[j] += 1; j += j & -j }
                    seen += 1
                }
            }
        }
        return total
    }

    private mutating func insertAnchored(anchored: [LevelAnchor?]) {
        for item in anchored.indices {
            guard let anchor = anchored[item] else { continue }
            let r = rank[anchor.target]
            guard r < layers.count, let targetIndex = layers[r].firstIndex(of: anchor.target) else {
                layers[min(r, layers.count - 1)].append(item)
                continue
            }
            var index = targetIndex
            if anchor.after {
                index += 1
                while index < layers[r].count, let other = anchored[layers[r][index]], other.target == anchor.target, other.after { index += 1 }
            } else {
                while index > 0, let other = anchored[layers[r][index - 1]], other.target == anchor.target, !other.after { index -= 1 }
            }
            layers[r].insert(item, at: index)
        }
    }

    // MARK: Coordinates

    private func separation(_ a: Int, _ b: Int) -> CGFloat {
        let gap: CGFloat
        switch (kind[a], kind[b]) {
        case (.dummy, .dummy): gap = edgeSpacing
        case (.dummy, _), (_, .dummy): gap = (edgeSpacing + nodeSpacing) / 2
        default: gap = nodeSpacing
        }
        return (width[a] + width[b]) / 2 + gap
    }

    private func edgeWeight(_ a: Int, _ b: Int) -> Double {
        switch (kind[a] == .real, kind[b] == .real) {
        case (true, true): return 1
        case (false, false): return 8
        default: return 2
        }
    }

    /// Places each layer as close as possible to its neighbors' positions while keeping the
    /// order and spacing, solving each layer exactly with weighted isotonic regression.
    private mutating func assignCoordinates(anchored: [LevelAnchor?]) {
        x = Array(repeating: 0, count: rank.count)
        for layer in layers {
            var cursor: CGFloat = 0
            for (index, node) in layer.enumerated() {
                if index > 0 { cursor += separation(layer[index - 1], node) }
                x[node] = cursor
            }
        }
        guard layers.count > 0 else { return }
        let passes = rank.count > 3000 ? 4 : 8
        for pass in 0..<passes {
            if pass % 2 == 0 {
                for r in 0..<layers.count { place(layer: r, usePreds: true, useSuccs: pass == passes - 2, anchored: anchored) }
            } else {
                for r in (0..<layers.count).reversed() { place(layer: r, usePreds: pass == passes - 1, useSuccs: true, anchored: anchored) }
            }
        }
        var minimum = CGFloat.greatestFiniteMagnitude
        for node in x.indices { minimum = min(minimum, x[node] - width[node] / 2) }
        if minimum == .greatestFiniteMagnitude { minimum = 0 }
        for node in x.indices { x[node] -= minimum }
    }

    private mutating func place(layer r: Int, usePreds: Bool, useSuccs: Bool, anchored: [LevelAnchor?]) {
        let layer = layers[r]
        guard !layer.isEmpty else { return }
        var desired: [Double] = []
        var weights: [Double] = []
        var offsets: [Double] = []
        desired.reserveCapacity(layer.count)
        var offset: Double = 0
        for (index, node) in layer.enumerated() {
            if index > 0 { offset += Double(separation(layer[index - 1], node)) }
            offsets.append(offset)
            var sum: Double = 0
            var weight: Double = 0
            if usePreds {
                for neighbor in preds[node] {
                    let w = edgeWeight(node, neighbor)
                    sum += w * Double(x[neighbor])
                    weight += w
                }
            }
            if useSuccs {
                for neighbor in succs[node] {
                    let w = edgeWeight(node, neighbor)
                    sum += w * Double(x[neighbor])
                    weight += w
                }
            }
            if node < anchored.count, let anchor = anchored[node] {
                let target = anchor.target
                let distance = Double(separation(node, target))
                sum += 4 * (Double(x[target]) + (anchor.after ? distance : -distance))
                weight += 4
            }
            if weight == 0 {
                desired.append(Double(x[node]) - offset)
                weights.append(0.05)
            } else {
                desired.append(sum / weight - offset)
                weights.append(weight)
            }
        }
        // Pool adjacent violators: non-decreasing fit of `desired`.
        var blockValue: [Double] = []
        var blockWeight: [Double] = []
        var blockCount: [Int] = []
        for index in 0..<layer.count {
            blockValue.append(desired[index])
            blockWeight.append(weights[index])
            blockCount.append(1)
            while blockValue.count > 1, blockValue[blockValue.count - 2] > blockValue[blockValue.count - 1] {
                let last = blockValue.count - 1
                let w = blockWeight[last - 1] + blockWeight[last]
                blockValue[last - 1] = (blockValue[last - 1] * blockWeight[last - 1] + blockValue[last] * blockWeight[last]) / w
                blockWeight[last - 1] = w
                blockCount[last - 1] += blockCount[last]
                blockValue.removeLast()
                blockWeight.removeLast()
                blockCount.removeLast()
            }
        }
        var index = 0
        for (block, value) in blockValue.enumerated() {
            for _ in 0..<blockCount[block] {
                x[layer[index]] = CGFloat(value + offsets[index])
                index += 1
            }
        }
    }
}
