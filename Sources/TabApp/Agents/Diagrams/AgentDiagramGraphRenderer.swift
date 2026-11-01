import AppKit

/// Draws a laid-out `AgentGraphScene` into a flipped Core Graphics context using only the
/// diagram style's colors, so it reads in light and dark themes.
struct AgentGraphSceneRenderer {
    let scene: AgentGraphScene
    let geometry: AgentGraphScene.Geometry
    let style: AgentDiagramStyle

    private var edgeColor: NSColor { style.muted }

    func draw(in context: CGContext) {
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineJoin(.round)
        context.setLineCap(.round)

        drawClusters(context)
        for index in scene.edges.indices { drawEdge(index, context) }
        for index in scene.nodes.indices { drawNode(index, context) }
        for index in scene.edges.indices { drawEdgeLabel(index, context) }
    }

    // MARK: Clusters

    private func clusterDepth(_ index: Int) -> Int {
        var depth = 0
        var current = scene.clusters[index].parent
        while let parent = current, parent >= 0, parent < scene.clusters.count, depth <= scene.clusters.count {
            depth += 1
            current = scene.clusters[parent].parent
        }
        return depth
    }

    private func drawClusters(_ context: CGContext) {
        let order = scene.clusters.indices.sorted { (clusterDepth($0), $0) < (clusterDepth($1), $1) }
        for index in order where index < geometry.clusterFrames.count {
            let cluster = scene.clusters[index]
            let frame = geometry.clusterFrames[index]
            let path = CGPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil)
            context.saveGState()
            if cluster.isRegion {
                context.setStrokeColor(style.border.cgColor)
                context.setLineWidth(1)
                context.setLineDash(phase: 0, lengths: [4, 3])
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
                continue
            }
            let fill = cluster.style.fill.map(nsColor) ?? style.foreground.withAlphaComponent(0.035)
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
            let stroke = cluster.style.stroke.map(nsColor) ?? style.border
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(cluster.style.strokeWidth ?? 1)
            if cluster.style.dashed { context.setLineDash(phase: 0, lengths: [5, 4]) }
            context.addPath(path)
            context.strokePath()
            context.restoreGState()

            let lines = geometry.clusterTitleLines[index]
            guard !lines.isEmpty else { continue }
            let color = cluster.style.text.map(nsColor) ?? style.muted
            drawLines(lines, font: AgentGraphScene.boldFont(style.font), color: color,
                      centerX: frame.midX, top: frame.minY + 8)
        }
    }

    // MARK: Nodes

    private func drawNode(_ index: Int, _ context: CGContext) {
        guard index < geometry.nodeFrames.count else { return }
        let node = scene.nodes[index]
        let frame = geometry.nodeFrames[index]
        let custom = node.style
        context.saveGState()
        defer { context.restoreGState() }

        switch node.shape {
        case .start:
            context.setFillColor(style.foreground.cgColor)
            context.fillEllipse(in: frame.insetBy(dx: 1, dy: 1))
            return
        case .end:
            context.setStrokeColor(style.foreground.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: frame.insetBy(dx: 1, dy: 1))
            context.setFillColor(style.foreground.cgColor)
            context.fillEllipse(in: frame.insetBy(dx: 4.5, dy: 4.5))
            return
        case .forkBar:
            context.setFillColor((custom.fill.map(nsColor) ?? style.foreground).cgColor)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: 2, cornerHeight: 2, transform: nil))
            context.fillPath()
            return
        default:
            break
        }

        let isNote = node.shape == .note
        let baseFill = isNote ? style.warning.withAlphaComponent(0.14) : style.accentSoft
        let baseStroke = isNote ? style.warning.withAlphaComponent(0.7) : style.accent.withAlphaComponent(0.75)
        let path = Self.shapePath(node.shape, in: frame.insetBy(dx: 0.5, dy: 0.5))

        context.addPath(path)
        context.setFillColor(style.surface.cgColor)
        context.fillPath()
        context.addPath(path)
        context.setFillColor((custom.fill.map(nsColor) ?? baseFill).cgColor)
        context.fillPath()

        context.setStrokeColor((custom.stroke.map(nsColor) ?? baseStroke).cgColor)
        context.setLineWidth(custom.strokeWidth ?? 1.2)
        if custom.dashed { context.setLineDash(phase: 0, lengths: [5, 4]) }
        context.addPath(path)
        context.strokePath()
        if let detail = Self.detailPath(node.shape, in: frame.insetBy(dx: 0.5, dy: 0.5)) {
            context.addPath(detail)
            context.strokePath()
        }

        let lines = geometry.nodeLines[index]
        guard !lines.isEmpty else { return }
        let textColor: NSColor
        if let text = custom.text {
            textColor = nsColor(text)
        } else if let fill = custom.fill, fill.alpha > 0.5 {
            textColor = fill.luminance > 0.55 ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.97, alpha: 1)
        } else {
            textColor = style.foreground
        }
        let font = custom.bold ? AgentGraphScene.boldFont(style.font) : style.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = lineHeight * CGFloat(lines.count)
        var centerX = frame.midX
        if node.shape == .asymmetric { centerX += frame.height / 6 }
        var centerY = frame.midY
        if node.shape == .cylinder { centerY += min(frame.width * 0.08, 8) / 2 }
        if isNote { centerX -= 3 }
        drawLines(lines, font: font, color: textColor, centerX: centerX, top: centerY - textHeight / 2)
    }

    /// The outline of a shape filling `rect`.
    static func shapePath(_ shape: AgentGraphScene.Shape, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        func polygon(_ points: [CGPoint]) {
            path.addLines(between: points)
            path.closeSubpath()
        }
        let slant = rect.height * 0.4
        switch shape {
        case .rectangle, .subroutine:
            path.addRoundedRect(in: rect, cornerWidth: 3, cornerHeight: 3)
        case .rounded:
            let radius = min(10, rect.height / 2, rect.width / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .state:
            let radius = min(8, rect.height / 2, rect.width / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .stadium:
            let radius = min(rect.height / 2, rect.width / 2)
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        case .cylinder:
            let ry = min(rect.width * 0.08, 8) + 2
            let kappa: CGFloat = 0.5523
            let rx = rect.width / 2
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + ry))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - ry))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control1: CGPoint(x: rect.minX, y: rect.maxY - ry + ry * kappa),
                          control2: CGPoint(x: rect.midX - rx * kappa, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - ry),
                          control1: CGPoint(x: rect.midX + rx * kappa, y: rect.maxY),
                          control2: CGPoint(x: rect.maxX, y: rect.maxY - ry + ry * kappa))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + ry))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control1: CGPoint(x: rect.maxX, y: rect.minY + ry - ry * kappa),
                          control2: CGPoint(x: rect.midX + rx * kappa, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.minX, y: rect.minY + ry),
                          control1: CGPoint(x: rect.midX - rx * kappa, y: rect.minY),
                          control2: CGPoint(x: rect.minX, y: rect.minY + ry - ry * kappa))
            path.closeSubpath()
        case .circle, .doubleCircle, .start, .end:
            path.addEllipse(in: rect)
        case .asymmetric:
            polygon([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
                     CGPoint(x: rect.minX + rect.height / 3, y: rect.midY)])
        case .diamond, .choice:
            polygon([CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
                     CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)])
        case .hexagon:
            let inset = rect.height * 0.3
            polygon([CGPoint(x: rect.minX + inset, y: rect.minY), CGPoint(x: rect.maxX - inset, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX - inset, y: rect.maxY),
                     CGPoint(x: rect.minX + inset, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)])
        case .parallelogram:
            polygon([CGPoint(x: rect.minX + slant, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                     CGPoint(x: rect.maxX - slant, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        case .parallelogramAlt:
            polygon([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - slant, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX + slant, y: rect.maxY)])
        case .trapezoid:
            polygon([CGPoint(x: rect.minX + slant, y: rect.minY), CGPoint(x: rect.maxX - slant, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        case .trapezoidAlt:
            polygon([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                     CGPoint(x: rect.maxX - slant, y: rect.maxY), CGPoint(x: rect.minX + slant, y: rect.maxY)])
        case .forkBar:
            path.addRect(rect)
        case .note:
            let fold = min(8, rect.height / 3)
            polygon([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX - fold, y: rect.minY),
                     CGPoint(x: rect.maxX, y: rect.minY + fold), CGPoint(x: rect.maxX, y: rect.maxY),
                     CGPoint(x: rect.minX, y: rect.maxY)])
        }
        return path
    }

    /// Inner strokes some shapes add to their outline.
    static func detailPath(_ shape: AgentGraphScene.Shape, in rect: CGRect) -> CGPath? {
        let path = CGMutablePath()
        switch shape {
        case .subroutine:
            path.move(to: CGPoint(x: rect.minX + 8, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + 8, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX - 8, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - 8, y: rect.maxY))
        case .cylinder:
            let ry = min(rect.width * 0.08, 8) + 2
            let kappa: CGFloat = 0.5523
            let rx = rect.width / 2
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + ry))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY + ry * 2),
                          control1: CGPoint(x: rect.minX, y: rect.minY + ry + ry * kappa),
                          control2: CGPoint(x: rect.midX - rx * kappa, y: rect.minY + ry * 2))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + ry),
                          control1: CGPoint(x: rect.midX + rx * kappa, y: rect.minY + ry * 2),
                          control2: CGPoint(x: rect.maxX, y: rect.minY + ry + ry * kappa))
        case .doubleCircle:
            path.addEllipse(in: rect.insetBy(dx: 4, dy: 4))
        case .note:
            let fold = min(8, rect.height / 3)
            path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
        default:
            return nil
        }
        return path
    }

    // MARK: Edges

    private func drawEdge(_ index: Int, _ context: CGContext) {
        let edge = scene.edges[index]
        guard edge.stroke != .invisible, index < geometry.routes.count else { return }
        var points = geometry.routes[index].points
        guard points.count >= 2 else { return }
        let width: CGFloat = edge.stroke == .thick ? 2.6 : 1.3
        let headLength: CGFloat = edge.stroke == .thick ? 10 : 8
        let endInset = Self.headInset(edge.endHead, length: headLength)
        let startInset = Self.headInset(edge.startHead, length: headLength)
        let endTip = points[points.count - 1]
        let endFrom = points[points.count - 2]
        let startTip = points[0]
        let startFrom = points[1]
        points[points.count - 1] = Self.pull(endTip, toward: endFrom, by: endInset)
        points[0] = Self.pull(startTip, toward: startFrom, by: startInset)

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(edgeColor.cgColor)
        context.setFillColor(edgeColor.cgColor)
        context.setLineWidth(width)
        if edge.stroke == .dotted { context.setLineDash(phase: 0, lengths: [3, 4]) }
        context.addPath(Self.roundedPolyline(points, radius: 6))
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        drawHead(edge.endHead, tip: endTip, from: endFrom, length: headLength, width: width, context)
        drawHead(edge.startHead, tip: startTip, from: startFrom, length: headLength, width: width, context)
    }

    private static func headInset(_ head: AgentGraphScene.Head, length: CGFloat) -> CGFloat {
        switch head {
        case .none: return 0
        case .arrow: return length - 1
        case .circle: return 8
        case .cross: return 2
        }
    }

    private static func pull(_ point: CGPoint, toward other: CGPoint, by distance: CGFloat) -> CGPoint {
        let dx = other.x - point.x
        let dy = other.y - point.y
        let length = hypot(dx, dy)
        guard length > 0.001, distance > 0 else { return point }
        let step = min(distance, length * 0.9)
        return CGPoint(x: point.x + dx / length * step, y: point.y + dy / length * step)
    }

    /// A polyline whose corners are rounded with up to `radius`.
    static func roundedPolyline(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let corner = points[index]
            let next = points[index + 1]
            let before = hypot(corner.x - previous.x, corner.y - previous.y)
            let after = hypot(next.x - corner.x, next.y - corner.y)
            let r = min(radius, before / 2, after / 2)
            if r < 0.5 {
                path.addLine(to: corner)
            } else {
                path.addArc(tangent1End: corner, tangent2End: next, radius: r)
            }
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    private func drawHead(_ head: AgentGraphScene.Head, tip: CGPoint, from: CGPoint, length: CGFloat, width: CGFloat, _ context: CGContext) {
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return }
        let ux = dx / distance
        let uy = dy / distance
        switch head {
        case .none:
            return
        case .arrow:
            let half = length * 0.45
            let base = CGPoint(x: tip.x - ux * length, y: tip.y - uy * length)
            context.move(to: tip)
            context.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
            context.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
            context.closePath()
            context.fillPath()
        case .circle:
            let radius: CGFloat = 4
            let center = CGPoint(x: tip.x - ux * radius, y: tip.y - uy * radius)
            let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.setFillColor(style.surface.cgColor)
            context.fillEllipse(in: rect)
            context.setLineWidth(max(1.2, width * 0.8))
            context.strokeEllipse(in: rect)
            context.setFillColor(edgeColor.cgColor)
        case .cross:
            let size: CGFloat = 4.5
            let center = CGPoint(x: tip.x - ux * 5, y: tip.y - uy * 5)
            context.setLineWidth(max(1.4, width))
            context.move(to: CGPoint(x: center.x - size, y: center.y - size))
            context.addLine(to: CGPoint(x: center.x + size, y: center.y + size))
            context.move(to: CGPoint(x: center.x - size, y: center.y + size))
            context.addLine(to: CGPoint(x: center.x + size, y: center.y - size))
            context.strokePath()
        }
    }

    private func drawEdgeLabel(_ index: Int, _ context: CGContext) {
        guard index < geometry.routes.count, scene.edges[index].stroke != .invisible,
              let center = geometry.routes[index].labelCenter else { return }
        let lines = geometry.edgeLabelLines[index]
        guard !lines.isEmpty else { return }
        let size = geometry.edgeLabelSizes[index]
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.setFillColor(style.surface.cgColor)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.fillPath()
        context.restoreGState()
        drawLines(lines, font: AgentGraphScene.smallFont(style.font), color: style.foreground, centerX: center.x, top: rect.minY + 2)
    }

    // MARK: Text

    private func drawLines(_ lines: [String], font: NSFont, color: NSColor, centerX: CGFloat, top: CGFloat) {
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: attributes)
            let width = text.size().width
            text.draw(at: CGPoint(x: centerX - width / 2, y: top + CGFloat(index) * lineHeight))
        }
    }

    private func nsColor(_ color: AgentDiagramColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}
