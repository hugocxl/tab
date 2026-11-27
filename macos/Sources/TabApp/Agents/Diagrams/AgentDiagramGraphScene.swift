import AppKit

/// A node-and-edge diagram ready to lay out and draw: what flowcharts and state diagrams become
/// after parsing. Sizes come from the labels; positions come from `AgentGraphLayout`.
struct AgentGraphScene {
    enum Shape: CaseIterable, Equatable {
        case rectangle, rounded, stadium, subroutine, cylinder, circle, doubleCircle, asymmetric
        case diamond, hexagon, parallelogram, parallelogramAlt, trapezoid, trapezoidAlt
        /// State diagram shapes.
        case state, start, end, forkBar, choice, note
    }

    enum Stroke: Equatable { case solid, dotted, thick, invisible }

    enum Head: Equatable { case none, arrow, circle, cross }

    struct Node {
        var label: String
        var shape: Shape
        var cluster: Int?
        var style = AgentDiagramNodeStyle()
        var anchor: AgentGraphLayoutInput.Anchor?
    }

    struct Edge {
        var from: AgentGraphLayoutInput.Endpoint
        var to: AgentGraphLayoutInput.Endpoint
        var label: String?
        var stroke: Stroke = .solid
        var startHead: Head = .none
        var endHead: Head = .arrow
        var minLength = 1
    }

    struct Cluster {
        var title: String
        var parent: Int?
        var direction: AgentGraphDirection?
        /// Concurrent regions of a state: a dashed box without title or tint.
        var isRegion = false
        var style = AgentDiagramNodeStyle()
    }

    /// Where everything landed, in diagram coordinates (top-left origin, y down).
    struct Geometry {
        var size: CGSize
        var nodeFrames: [CGRect]
        var clusterFrames: [CGRect]
        var routes: [AgentGraphLayoutResult.Route]
        var nodeLines: [[String]]
        var edgeLabelLines: [[String]]
        var edgeLabelSizes: [CGSize]
        var clusterTitleLines: [[String]]
        var nodeDirections: [AgentGraphDirection]
    }

    var direction: AgentGraphDirection = .topToBottom
    var nodes: [Node] = []
    var edges: [Edge] = []
    var clusters: [Cluster] = []

    static let margin: CGFloat = 4
    static let maximumLabelWidth: CGFloat = 220

    // MARK: Layout

    func geometry(style: AgentDiagramStyle) -> Geometry {
        let font = style.font
        let measurer = AgentDiagramTextMeasurer(font: font)
        let titleMeasurer = AgentDiagramTextMeasurer(font: Self.boldFont(font))
        let edgeMeasurer = AgentDiagramTextMeasurer(font: Self.smallFont(font))
        let nodeDirections = nodes.map { effectiveDirection(cluster: $0.cluster) }

        var input = AgentGraphLayoutInput()
        input.direction = direction
        var nodeLines: [[String]] = []
        for (index, node) in nodes.enumerated() {
            let text = measurer.measure(node.label, maxWidth: Self.maximumLabelWidth)
            nodeLines.append(text.lines)
            let size = Self.nodeSize(shape: node.shape, text: text.size, direction: nodeDirections[index])
            input.nodes.append(.init(size: size, cluster: node.cluster, anchor: node.anchor))
        }
        var clusterTitleLines: [[String]] = []
        for cluster in clusters {
            let text = cluster.isRegion || cluster.title.isEmpty
                ? AgentDiagramTextMeasurer.Block(lines: [], size: .zero)
                : titleMeasurer.measure(cluster.title, maxWidth: Self.maximumLabelWidth * 1.5)
            clusterTitleLines.append(text.lines)
            input.clusters.append(.init(parent: cluster.parent, titleSize: text.size, direction: cluster.direction))
        }
        var edgeLabelLines: [[String]] = []
        var edgeLabelSizes: [CGSize] = []
        for edge in edges {
            guard let label = edge.label, !label.isEmpty else {
                edgeLabelLines.append([])
                edgeLabelSizes.append(.zero)
                input.edges.append(.init(from: edge.from, to: edge.to, minLength: edge.minLength))
                continue
            }
            let text = edgeMeasurer.measure(label, maxWidth: Self.maximumLabelWidth * 0.8)
            let size = CGSize(width: ceil(text.size.width + 8), height: ceil(text.size.height + 4))
            edgeLabelLines.append(text.lines)
            edgeLabelSizes.append(size)
            input.edges.append(.init(from: edge.from, to: edge.to, labelSize: size, minLength: edge.minLength))
        }

        var result = AgentGraphLayout.layout(input)
        for (index, edge) in edges.enumerated() where index < result.routes.count {
            var points = result.routes[index].points
            guard points.count >= 2 else { continue }
            if case .node(let from) = edge.from, from < nodes.count {
                points[0] = Self.snap(points[0], toward: points[1], shape: nodes[from].shape, frame: result.nodeFrames[from])
            }
            if case .node(let to) = edge.to, to < nodes.count {
                let last = points.count - 1
                points[last] = Self.snap(points[last], toward: points[last - 1], shape: nodes[to].shape, frame: result.nodeFrames[to])
            }
            result.routes[index].points = points
        }
        let margin = Self.margin
        func shift(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: margin, dy: margin) }
        func shift(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + margin, y: point.y + margin) }
        return Geometry(
            size: CGSize(width: result.size.width + margin * 2, height: result.size.height + margin * 2),
            nodeFrames: result.nodeFrames.map(shift),
            clusterFrames: result.clusterFrames.map(shift),
            routes: result.routes.map { .init(points: $0.points.map(shift), labelCenter: $0.labelCenter.map(shift)) },
            nodeLines: nodeLines,
            edgeLabelLines: edgeLabelLines,
            edgeLabelSizes: edgeLabelSizes,
            clusterTitleLines: clusterTitleLines,
            nodeDirections: nodeDirections
        )
    }

    /// Lays the scene out at its natural size; wide diagrams exceed `maxWidth` and scroll.
    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        let geometry = geometry(style: style)
        let scene = self
        return AgentDiagramLayout(size: geometry.size) { context in
            AgentGraphSceneRenderer(scene: scene, geometry: geometry, style: style).draw(in: context)
        }
    }

    private static let rectangular: Set<Shape> = [.rectangle, .rounded, .subroutine, .state, .note, .forkBar]

    /// Moves an edge end that lies on the frame of a non-rectangular shape onto the shape's outline,
    /// along the axis of the edge's last segment.
    static func snap(_ point: CGPoint, toward next: CGPoint, shape: Shape, frame: CGRect) -> CGPoint {
        guard !rectangular.contains(shape) else { return point }
        let path = AgentGraphSceneRenderer.shapePath(shape, in: frame)
        let vertical = abs(next.x - point.x) < 0.5
        var inside = vertical ? CGPoint(x: point.x, y: frame.midY) : CGPoint(x: frame.midX, y: point.y)
        guard path.contains(inside) else { return point }
        var outside = point
        for _ in 0..<14 {
            let middle = CGPoint(x: (outside.x + inside.x) / 2, y: (outside.y + inside.y) / 2)
            if path.contains(middle) { inside = middle } else { outside = middle }
        }
        return outside
    }

    private func effectiveDirection(cluster: Int?) -> AgentGraphDirection {
        var current = cluster
        var steps = 0
        while let index = current, index >= 0, index < clusters.count, steps <= clusters.count {
            if let direction = clusters[index].direction { return direction }
            current = clusters[index].parent
            steps += 1
        }
        return direction
    }

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.bold), size: font.pointSize) ?? font
    }

    static func smallFont(_ font: NSFont) -> NSFont {
        font.withSize(max(9, font.pointSize - 1))
    }

    /// A shape's size around a label of `text` size.
    static func nodeSize(shape: Shape, text: CGSize, direction: AgentGraphDirection) -> CGSize {
        let paddingX: CGFloat = 14
        let paddingY: CGFloat = 9
        let w = text.width
        let h = text.height
        func round(_ size: CGSize) -> CGSize { CGSize(width: ceil(size.width), height: ceil(size.height)) }
        switch shape {
        case .rectangle, .rounded, .state:
            return round(CGSize(width: max(w + paddingX * 2, 48), height: h + paddingY * 2))
        case .stadium:
            let height = h + paddingY * 2
            return round(CGSize(width: max(w + height, 56), height: height))
        case .subroutine:
            return round(CGSize(width: max(w + paddingX * 2 + 16, 56), height: h + paddingY * 2))
        case .cylinder:
            let width = max(w + paddingX * 2, 48)
            let cap = min(width * 0.08, 8) + 2
            return round(CGSize(width: width, height: h + paddingY * 2 + cap * 2))
        case .circle:
            let diameter = max(sqrt(w * w + h * h) + 12, 40)
            return round(CGSize(width: diameter, height: diameter))
        case .doubleCircle:
            let diameter = max(sqrt(w * w + h * h) + 22, 48)
            return round(CGSize(width: diameter, height: diameter))
        case .asymmetric:
            let height = h + paddingY * 2
            return round(CGSize(width: max(w + paddingX * 2 + height / 3, 56), height: height))
        case .diamond:
            let ratio: CGFloat = 0.6
            let half = w / 2 + h / (2 * ratio) + 8
            return round(CGSize(width: max(half * 2, 48), height: max(half * 2 * ratio, 36)))
        case .hexagon:
            let height = h + paddingY * 2
            return round(CGSize(width: max(w + paddingX * 2 + height * 0.6, 60), height: height))
        case .parallelogram, .parallelogramAlt, .trapezoid, .trapezoidAlt:
            let height = h + paddingY * 2
            return round(CGSize(width: max(w + paddingX * 2 + height * 0.8, 64), height: height))
        case .start:
            return CGSize(width: 16, height: 16)
        case .end:
            return CGSize(width: 18, height: 18)
        case .forkBar:
            return direction.isHorizontal ? CGSize(width: 7, height: 72) : CGSize(width: 72, height: 7)
        case .choice:
            return CGSize(width: 26, height: 26)
        case .note:
            return round(CGSize(width: max(w + 24, 40), height: h + 14))
        }
    }
}

/// Measures label text in lines, wrapping long lines at word boundaries.
struct AgentDiagramTextMeasurer {
    struct Block {
        var lines: [String]
        var size: CGSize
    }

    let font: NSFont
    let lineHeight: CGFloat

    init(font: NSFont) {
        self.font = font
        lineHeight = ceil(font.ascender - font.descender + font.leading)
    }

    func width(of line: String) -> CGFloat {
        ceil(NSAttributedString(string: line, attributes: [.font: font]).size().width)
    }

    func measure(_ text: String, maxWidth: CGFloat) -> Block {
        guard !text.isEmpty else { return Block(lines: [], size: .zero) }
        var lines: [String] = []
        var widest: CGFloat = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(40) {
            let line = String(paragraph)
            let lineWidth = width(of: line)
            if lineWidth <= maxWidth || !line.contains(" ") {
                lines.append(line)
                widest = max(widest, lineWidth)
                continue
            }
            var current = ""
            for word in line.split(separator: " ") {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if current.isEmpty || width(of: candidate) <= maxWidth {
                    current = candidate
                } else {
                    lines.append(current)
                    widest = max(widest, width(of: current))
                    current = String(word)
                }
            }
            if !current.isEmpty {
                lines.append(current)
                widest = max(widest, width(of: current))
            }
        }
        return Block(lines: lines, size: CGSize(width: widest, height: lineHeight * CGFloat(lines.count)))
    }
}
