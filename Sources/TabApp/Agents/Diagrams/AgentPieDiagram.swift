import AppKit

/// A Mermaid `pie` chart: `pie [showData] [title …]` and `"Label" : value` rows.
struct AgentPieDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["pie"]
    static let maxSlices = 200

    struct Slice: Equatable {
        var label: String
        var value: Double
    }

    var title: String?
    var showData = false
    var slices: [Slice] = []

    var total: Double { slices.reduce(0) { $0 + $1.value } }

    init(source: String) throws {
        let split = try AgentDiagramTextSource.split(source)
        guard var header = AgentDiagramTextSource.remainder(of: split.header.text, afterKeyword: "pie") else {
            throw AgentDiagramError(message: "Expected a pie header.", line: split.header.number)
        }
        title = split.frontMatterTitle
        if let rest = AgentDiagramTextSource.remainder(of: header, afterKeyword: "showData") {
            showData = true
            header = rest
        }
        if let rest = AgentDiagramTextSource.remainder(of: header, afterKeyword: "title") {
            title = rest
        }
        for line in split.body {
            try parse(line)
        }
        guard !slices.isEmpty else {
            throw AgentDiagramError(message: "The pie chart has no slices.", line: nil)
        }
        guard total > 0 else {
            throw AgentDiagramError(message: "The pie chart's values add up to zero.", line: nil)
        }
    }

    private mutating func parse(_ line: AgentDiagramTextSourceLine) throws {
        let text = line.text
        if AgentDiagramTextSource.remainder(of: text, afterKeyword: "showData") != nil {
            showData = true
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "title") {
            title = rest
            return
        }
        if AgentDiagramTextSource.remainder(of: text, afterKeyword: "accTitle") != nil
            || AgentDiagramTextSource.remainder(of: text, afterKeyword: "accDescr") != nil {
            return
        }
        guard let colon = text.lastIndex(of: ":") else {
            throw AgentDiagramError(message: "Expected `\"Label\" : value`.", line: line.number)
        }
        let label = AgentDiagramText.unquoted(String(text[..<colon]))
        guard let value = AgentDiagramTextNumber.parse(String(text[text.index(after: colon)...])) else {
            throw AgentDiagramError(message: "A pie slice needs a number after the colon.", line: line.number)
        }
        guard value >= 0 else {
            throw AgentDiagramError(message: "Pie slice values cannot be negative.", line: line.number)
        }
        guard slices.count < Self.maxSlices else {
            throw AgentDiagramError(message: "The pie chart has too many slices to draw.", line: line.number)
        }
        slices.append(Slice(label: label, value: value))
    }

    /// Start and end angles of each slice in degrees, clockwise from 12 o'clock.
    var sliceAngles: [(start: Double, end: Double)] {
        let total = total
        var angle = 0.0
        return slices.map { slice in
            let sweep = total > 0 ? slice.value / total * 360 : 0
            defer { angle += sweep }
            return (angle, angle + sweep)
        }
    }

    func percentage(of slice: Slice) -> Double {
        let total = total
        return total > 0 ? slice.value / total * 100 : 0
    }

    struct Geometry {
        var size: CGSize
        var titleRect: CGRect?
        var center: CGPoint
        var radius: CGFloat
        var legendRows: [CGRect]
    }

    static let radius: CGFloat = 96
    static let margin: CGFloat = 12

    func legendText(_ slice: Slice) -> String {
        let percent = String(format: "%.1f%%", percentage(of: slice))
        if showData {
            return "\(slice.label)  \(AgentDiagramTextNumber.format(slice.value)) · \(percent)"
        }
        return "\(slice.label)  \(percent)"
    }

    func geometry(style: AgentDiagramStyle) -> Geometry {
        let font = style.font
        let titleFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        var y = Self.margin
        var titleRect: CGRect?
        if let title, !title.isEmpty {
            let size = AgentDiagramText.size(title, font: titleFont)
            titleRect = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + 12
        }
        let rowHeight = max(AgentDiagramText.lineHeight(font), 12) + 6
        let legendSizes = slices.map { AgentDiagramText.size(legendText($0), font: font) }
        let legendWidth = (legendSizes.map(\.width).max() ?? 0) + 20
        let rowHeights = legendSizes.map { max($0.height + 6, rowHeight) }
        let legendHeight = rowHeights.reduce(0, +)
        let pieTop = y
        let bodyHeight = max(Self.radius * 2, legendHeight)
        let center = CGPoint(x: Self.margin + Self.radius, y: pieTop + bodyHeight / 2)
        let legendX = Self.margin + Self.radius * 2 + 28
        var rowY = pieTop + (bodyHeight - legendHeight) / 2
        var legendRows: [CGRect] = []
        for height in rowHeights {
            legendRows.append(CGRect(x: legendX, y: rowY, width: legendWidth, height: height))
            rowY += height
        }
        var width = legendX + legendWidth + Self.margin
        if let rect = titleRect {
            width = max(width, rect.width + Self.margin * 2)
            titleRect = CGRect(x: (width - rect.width) / 2, y: rect.minY, width: rect.width, height: rect.height)
        }
        return Geometry(
            size: CGSize(width: ceil(width), height: ceil(pieTop + bodyHeight + Self.margin)),
            titleRect: titleRect, center: center, radius: Self.radius, legendRows: legendRows
        )
    }

    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        let geometry = geometry(style: style)
        let diagram = self
        return AgentDiagramLayout(size: geometry.size) { context in
            AgentDiagramText.withGraphics(context) {
                diagram.draw(geometry, style: style, in: context)
            }
        }
    }

    private func color(_ index: Int, style: AgentDiagramStyle) -> NSColor {
        style.series.isEmpty ? style.accent : style.series[index % style.series.count]
    }

    private func draw(_ geometry: Geometry, style: AgentDiagramStyle, in context: CGContext) {
        let angles = sliceAngles
        for (index, angle) in angles.enumerated() where angle.end > angle.start {
            let start = CGFloat((angle.start - 90) * .pi / 180)
            let end = CGFloat((angle.end - 90) * .pi / 180)
            context.saveGState()
            context.move(to: geometry.center)
            // The context is flipped (y down), so increasing angles run clockwise on screen.
            context.addArc(center: geometry.center, radius: geometry.radius, startAngle: start, endAngle: end, clockwise: false)
            context.closePath()
            context.setFillColor(color(index, style: style).cgColor)
            context.setStrokeColor(style.surface.cgColor)
            context.setLineWidth(slices.count > 1 ? 1.5 : 0)
            context.drawPath(using: slices.count > 1 ? .fillStroke : .fill)
            context.restoreGState()
        }
        context.saveGState()
        context.setStrokeColor(style.border.cgColor)
        context.setLineWidth(1)
        context.strokeEllipse(in: CGRect(x: geometry.center.x - geometry.radius, y: geometry.center.y - geometry.radius, width: geometry.radius * 2, height: geometry.radius * 2))
        context.restoreGState()

        for (index, slice) in slices.enumerated() where index < geometry.legendRows.count {
            let row = geometry.legendRows[index]
            let swatch = CGRect(x: row.minX, y: row.midY - 5, width: 10, height: 10)
            AgentDiagramTextStroke.rect(context, swatch, radius: 2, fill: color(index, style: style))
            let text = legendText(slice)
            let size = AgentDiagramText.size(text, font: style.font)
            AgentDiagramText.draw(text, in: CGRect(x: row.minX + 18, y: row.midY - size.height / 2, width: size.width, height: size.height), font: style.font, color: style.foreground, alignment: .left)
        }
        if let title, let rect = geometry.titleRect {
            let titleFont = NSFontManager.shared.convert(style.font, toHaveTrait: .boldFontMask)
            AgentDiagramText.draw(title, in: rect, font: titleFont, color: style.foreground, alignment: .center)
        }
    }
}
