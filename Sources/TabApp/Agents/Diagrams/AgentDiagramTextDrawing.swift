import AppKit

/// One meaningful line of Mermaid source: trimmed, with its 1-based line number.
struct AgentDiagramTextSourceLine: Equatable {
    var number: Int
    var text: String
}

/// Splits Mermaid source into the header line and the body statements, skipping blank lines,
/// `%%` comments and `%%{init}%%` directives, and a leading `---` front matter block.
/// Bounds the input so parsing untrusted text stays cheap.
enum AgentDiagramTextSource {
    static let maxCharacters = 200_000
    static let maxLines = 5_000

    struct Split {
        var header: AgentDiagramTextSourceLine
        var body: [AgentDiagramTextSourceLine]
        /// `title:` from front matter, if any.
        var frontMatterTitle: String?
    }

    static func split(_ source: String) throws -> Split {
        if source.utf16.count > maxCharacters {
            throw AgentDiagramError(message: "The diagram is too large to draw.", line: nil)
        }
        var lines: [AgentDiagramTextSourceLine] = []
        var number = 0
        var inFrontMatter = false
        var sawContent = false
        var frontMatterTitle: String?
        for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            number += 1
            if number > maxLines {
                throw AgentDiagramError(message: "The diagram has too many lines to draw.", line: number)
            }
            let text = rawLine.trimmingCharacters(in: .whitespaces)
            if inFrontMatter {
                if text == "---" {
                    inFrontMatter = false
                } else if text.lowercased().hasPrefix("title:") {
                    frontMatterTitle = AgentDiagramText.unquoted(String(text.dropFirst(6)))
                }
                continue
            }
            if text.isEmpty || text.hasPrefix("%%") { continue }
            if !sawContent, text == "---" {
                inFrontMatter = true
                continue
            }
            sawContent = true
            lines.append(AgentDiagramTextSourceLine(number: number, text: text))
        }
        guard let header = lines.first else {
            throw AgentDiagramError(message: "The diagram is empty.", line: nil)
        }
        return Split(header: header, body: Array(lines.dropFirst()), frontMatterTitle: frontMatterTitle)
    }

    /// The text after the leading keyword of `line`, trimmed, or `nil` when the line does not start
    /// with `keyword` (case-insensitive) followed by whitespace, a colon or the end of the line.
    static func remainder(of line: String, afterKeyword keyword: String) -> String? {
        guard line.count >= keyword.count else { return nil }
        let head = line.prefix(keyword.count)
        guard head.lowercased() == keyword.lowercased() else { return nil }
        let rest = line.dropFirst(keyword.count)
        guard let next = rest.first else { return "" }
        guard next.isWhitespace || next == ":" else { return nil }
        var trimmed = rest.drop { $0.isWhitespace }
        if trimmed.first == ":" { trimmed = trimmed.dropFirst() }
        return trimmed.trimmingCharacters(in: .whitespaces)
    }
}

/// Measures and draws diagram labels. Labels may span several lines with `<br>` or `\n`.
enum AgentDiagramText {
    static let maxLabelCharacters = 400

    /// `color` with its opacity scaled by `factor`, for tints that must stay subtle in both themes.
    static func faded(_ color: NSColor, _ factor: CGFloat) -> NSColor {
        color.withAlphaComponent(color.alphaComponent * factor)
    }

    /// Strips one pair of surrounding double quotes.
    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    /// The display lines of a Mermaid label: `<br>`, `<br/>`, a literal `\n` and real newlines
    /// break lines, a few entities are decoded, and overlong labels are truncated.
    static func lines(_ label: String) -> [String] {
        var text = label
        if text.count > maxLabelCharacters {
            text = String(text.prefix(maxLabelCharacters)) + "…"
        }
        for breakToken in ["<br/>", "<br />", "<br>", "<BR/>", "<BR>", "<BR />", "\\n"] {
            text = text.replacingOccurrences(of: breakToken, with: "\n")
        }
        for (entity, value) in [("#quot;", "\""), ("#59;", ";"), ("#35;", "#"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func width(_ line: String, font: NSFont) -> CGFloat {
        guard !line.isEmpty else { return 0 }
        return ceil(NSAttributedString(string: line, attributes: [.font: font]).size().width)
    }

    /// The size of a possibly multi-line label.
    static func size(_ label: String, font: NSFont) -> CGSize {
        size(lines: lines(label), font: font)
    }

    static func size(lines: [String], font: NSFont) -> CGSize {
        guard !lines.isEmpty, lines != [""] else { return .zero }
        let width = lines.map { width($0, font: font) }.max() ?? 0
        return CGSize(width: width, height: CGFloat(lines.count) * lineHeight(font))
    }

    /// Runs `body` with an AppKit graphics context over `context`, flipped so text draws upright
    /// in the diagram's top-left coordinate space.
    static func withGraphics(_ context: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Draws a label centered at `center`. Call inside `withGraphics`.
    static func draw(_ label: String, centeredAt center: CGPoint, font: NSFont, color: NSColor) {
        let labelLines = lines(label)
        let size = size(lines: labelLines, font: font)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        draw(lines: labelLines, in: rect, font: font, color: color, alignment: .center)
    }

    /// Draws label lines from the top of `rect` with the given horizontal alignment. Call inside `withGraphics`.
    static func draw(lines labelLines: [String], in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let height = lineHeight(font)
        for (index, line) in labelLines.enumerated() where !line.isEmpty {
            let string = NSAttributedString(string: line, attributes: attributes)
            let lineWidth = ceil(string.size().width)
            let x: CGFloat
            switch alignment {
            case .center: x = rect.midX - lineWidth / 2
            case .right: x = rect.maxX - lineWidth
            default: x = rect.minX
            }
            string.draw(at: CGPoint(x: x, y: rect.minY + CGFloat(index) * height))
        }
    }

    static func draw(_ label: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        draw(lines: lines(label), in: rect, font: font, color: color, alignment: alignment)
    }
}

/// Arrowheads and markers drawn at line ends.
enum AgentDiagramTextMarker: Equatable {
    case none
    case filledArrow
    case openArrow
    case cross
    case hollowTriangle
    case filledDiamond
    case hollowDiamond
}

/// Line, shape and marker drawing shared by the native diagrams.
enum AgentDiagramTextStroke {
    static func line(_ context: CGContext, from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat = 1, dashed: Bool = false) {
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
    }

    static func polyline(_ context: CGContext, _ points: [CGPoint], color: NSColor, width: CGFloat = 1, dashed: Bool = false) {
        guard let first = points.first, points.count > 1 else { return }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
        context.move(to: first)
        for point in points.dropFirst() { context.addLine(to: point) }
        context.strokePath()
        context.restoreGState()
    }

    static func rect(_ context: CGContext, _ rect: CGRect, radius: CGFloat = 0, fill: NSColor? = nil, stroke: NSColor? = nil, width: CGFloat = 1, dashed: Bool = false) {
        guard rect.width > 0, rect.height > 0 else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil)
        context.saveGState()
        if let fill {
            context.setFillColor(fill.cgColor)
            context.addPath(path)
            context.fillPath()
        }
        if let stroke {
            context.setStrokeColor(stroke.cgColor)
            context.setLineWidth(width)
            if dashed { context.setLineDash(phase: 0, lengths: [4, 3]) }
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// Draws `marker` with its tip at `tip`, pointing away from `from`.
    /// `fill` paints hollow markers so the line underneath does not show through.
    static func marker(_ context: CGContext, _ marker: AgentDiagramTextMarker, tip: CGPoint, from: CGPoint, color: NSColor, fill: NSColor, size: CGFloat = 9) {
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux
        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: tip.x - ux * along + px * across, y: tip.y - uy * along + py * across)
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        context.setLineWidth(1.2)
        context.setLineJoin(.miter)
        switch marker {
        case .none:
            break
        case .filledArrow:
            context.move(to: tip)
            context.addLine(to: point(size, size * 0.45))
            context.addLine(to: point(size, -size * 0.45))
            context.closePath()
            context.fillPath()
        case .openArrow:
            context.move(to: point(size, size * 0.5))
            context.addLine(to: tip)
            context.addLine(to: point(size, -size * 0.5))
            context.strokePath()
        case .cross:
            let center = point(size * 0.6, 0)
            let half = size * 0.4
            context.move(to: CGPoint(x: center.x - half, y: center.y - half))
            context.addLine(to: CGPoint(x: center.x + half, y: center.y + half))
            context.move(to: CGPoint(x: center.x - half, y: center.y + half))
            context.addLine(to: CGPoint(x: center.x + half, y: center.y - half))
            context.setLineWidth(1.6)
            context.strokePath()
        case .hollowTriangle:
            let triangle = size * 1.4
            context.move(to: tip)
            context.addLine(to: point(triangle, triangle * 0.5))
            context.addLine(to: point(triangle, -triangle * 0.5))
            context.closePath()
            context.setFillColor(fill.cgColor)
            context.drawPath(using: .fillStroke)
        case .filledDiamond, .hollowDiamond:
            let diamond = size * 1.6
            context.move(to: tip)
            context.addLine(to: point(diamond / 2, diamond * 0.3))
            context.addLine(to: point(diamond, 0))
            context.addLine(to: point(diamond / 2, -diamond * 0.3))
            context.closePath()
            if marker == .hollowDiamond { context.setFillColor(fill.cgColor) }
            context.drawPath(using: .fillStroke)
        }
        context.restoreGState()
    }

    /// How far back from the tip a marker extends, so lines can stop at its base.
    static func markerLength(_ marker: AgentDiagramTextMarker, size: CGFloat = 9) -> CGFloat {
        switch marker {
        case .none, .openArrow, .cross: return 0
        case .filledArrow: return size * 0.6
        case .hollowTriangle: return size * 1.4
        case .filledDiamond, .hollowDiamond: return size * 1.6
        }
    }
}

/// Number formatting and axis ticks shared by the charts.
enum AgentDiagramTextNumber {
    /// Integers without decimals, other values with up to two.
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Parses a finite number, tolerating surrounding whitespace.
    static func parse(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
        return value
    }

    /// "Nice" axis ticks covering `low...high` with about `count` steps.
    static func ticks(low: Double, high: Double, count: Int) -> [Double] {
        guard low.isFinite, high.isFinite, high > low, count > 0 else { return [low] }
        let rough = (high - low) / Double(count)
        let magnitude = pow(10, floor(log10(rough)))
        let residual = rough / magnitude
        let step: Double
        if residual > 5 {
            step = 10 * magnitude
        } else if residual > 2 {
            step = 5 * magnitude
        } else if residual > 1 {
            step = 2 * magnitude
        } else {
            step = magnitude
        }
        guard step > 0, step.isFinite else { return [low, high] }
        var ticks: [Double] = []
        var value = ceil(low / step - 1e-9) * step
        while value <= high + step * 1e-9, ticks.count < 50 {
            ticks.append(abs(value) < step * 1e-9 ? 0 : value)
            value += step
        }
        return ticks
    }
}
