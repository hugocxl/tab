import AppKit

/// A Mermaid `xychart-beta` chart: a categorical or numeric x axis, a y axis with an optional
/// range, and `bar` and `line` series. `horizontal` charts are drawn vertically.
struct AgentXYChartDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["xychart-beta", "xychart"]
    static let maxSeries = 24
    static let maxPoints = 500

    enum SeriesKind: Equatable {
        case bar
        case line
    }

    struct Series: Equatable {
        var kind: SeriesKind
        var name: String?
        var values: [Double]
    }

    var title: String?
    var horizontal = false
    var xTitle: String?
    var xCategories: [String]?
    var xRange: (min: Double, max: Double)?
    var yTitle: String?
    var yRange: (min: Double, max: Double)?
    var series: [Series] = []

    init(source: String) throws {
        let split = try AgentDiagramTextSource.split(source)
        guard let keyword = AgentDiagramSource.keyword(of: split.header.text), Self.keywords.contains(keyword) else {
            throw AgentDiagramError(message: "Expected an xychart-beta header.", line: split.header.number)
        }
        horizontal = split.header.text.lowercased().hasSuffix("horizontal")
        title = split.frontMatterTitle
        for line in split.body {
            try parse(line)
        }
        guard !series.isEmpty else {
            throw AgentDiagramError(message: "The chart has no `bar` or `line` data.", line: nil)
        }
    }

    private mutating func parse(_ line: AgentDiagramTextSourceLine) throws {
        let text = line.text
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "title") {
            title = AgentDiagramText.unquoted(rest)
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "x-axis") {
            let axis = try Self.parseAxis(rest, allowCategories: true, line: line)
            xTitle = axis.title
            xCategories = axis.categories
            xRange = axis.range
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "y-axis") {
            let axis = try Self.parseAxis(rest, allowCategories: false, line: line)
            yTitle = axis.title
            yRange = axis.range
            return
        }
        for (keyword, kind) in [("bar", SeriesKind.bar), ("line", .line)] {
            guard let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: keyword) else { continue }
            guard let open = rest.firstIndex(of: "["), let close = rest.lastIndex(of: "]"), open < close else {
                throw AgentDiagramError(message: "`\(keyword)` needs values in brackets, like `[1, 2, 3]`.", line: line.number)
            }
            let name = AgentDiagramText.unquoted(String(rest[..<open]))
            var values: [Double] = []
            for item in Self.splitList(String(rest[rest.index(after: open)..<close])) {
                guard let value = AgentDiagramTextNumber.parse(item) else {
                    throw AgentDiagramError(message: "`\(item.prefix(20))` is not a number.", line: line.number)
                }
                values.append(value)
            }
            guard !values.isEmpty, values.count <= Self.maxPoints else {
                throw AgentDiagramError(message: "`\(keyword)` needs between 1 and \(Self.maxPoints) values.", line: line.number)
            }
            guard series.count < Self.maxSeries else {
                throw AgentDiagramError(message: "The chart has too many series to draw.", line: line.number)
            }
            series.append(Series(kind: kind, name: name.isEmpty ? nil : name, values: values))
            return
        }
        if AgentDiagramTextSource.remainder(of: text, afterKeyword: "accTitle") != nil
            || AgentDiagramTextSource.remainder(of: text, afterKeyword: "accDescr") != nil {
            return
        }
        throw AgentDiagramError(message: "Unrecognized chart statement: \(text.prefix(60))", line: line.number)
    }

    private static func parseAxis(_ rest: String, allowCategories: Bool, line: AgentDiagramTextSourceLine) throws -> (title: String?, categories: [String]?, range: (min: Double, max: Double)?) {
        if let open = rest.firstIndex(of: "[") {
            guard allowCategories else {
                throw AgentDiagramError(message: "The y axis takes `min --> max`, not categories.", line: line.number)
            }
            guard let close = rest.lastIndex(of: "]"), open < close else {
                throw AgentDiagramError(message: "Unclosed `[` in the axis categories.", line: line.number)
            }
            let categories = splitList(String(rest[rest.index(after: open)..<close])).map { AgentDiagramText.unquoted($0) }
            guard categories.count <= maxPoints else {
                throw AgentDiagramError(message: "The axis has too many categories.", line: line.number)
            }
            let title = AgentDiagramText.unquoted(String(rest[..<open]))
            return (title.isEmpty ? nil : title, categories, nil)
        }
        if let arrow = rest.range(of: "-->") {
            let left = rest[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let lowText = left.split(separator: " ").last.map(String.init) ?? ""
            let titleText = String(left.dropLast(lowText.count))
            guard let low = AgentDiagramTextNumber.parse(lowText),
                  let high = AgentDiagramTextNumber.parse(String(rest[arrow.upperBound...])), high > low else {
                throw AgentDiagramError(message: "An axis range needs two numbers, like `0 --> 100`.", line: line.number)
            }
            let title = AgentDiagramText.unquoted(titleText)
            return (title.isEmpty ? nil : title, nil, (low, high))
        }
        let title = AgentDiagramText.unquoted(rest)
        return (title.isEmpty ? nil : title, nil, nil)
    }

    /// Splits a comma separated list, keeping commas inside double quotes.
    static func splitList(_ text: String) -> [String] {
        var items: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == ",", !quoted {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !items.isEmpty { items.append(last) }
        return items
    }

    /// The number of x positions: the categories, or the longest series.
    var pointCount: Int {
        max(xCategories?.count ?? 0, series.map(\.values.count).max() ?? 0, 1)
    }

    var xLabels: [String] {
        let count = pointCount
        if let categories = xCategories, !categories.isEmpty {
            return (0..<count).map { $0 < categories.count ? categories[$0] : "" }
        }
        if let range = xRange {
            guard count > 1 else { return [AgentDiagramTextNumber.format(range.min)] }
            return (0..<count).map { AgentDiagramTextNumber.format(range.min + (range.max - range.min) * Double($0) / Double(count - 1)) }
        }
        return (0..<count).map { String($0 + 1) }
    }

    /// The y range drawn: the declared one, or the data's, including zero.
    var valueRange: (min: Double, max: Double) {
        if let yRange { return yRange }
        let values = series.flatMap(\.values)
        var low = min(values.min() ?? 0, 0)
        var high = max(values.max() ?? 1, 0)
        if high <= low {
            high = low + 1
        }
        let ticks = AgentDiagramTextNumber.ticks(low: low, high: high, count: 5)
        if let first = ticks.first, first < low { low = first }
        if let last = ticks.last, last < high, ticks.count > 1 {
            high = last + (ticks[1] - ticks[0])
        }
        return (low, high)
    }
}

// MARK: - Layout

extension AgentXYChartDiagram {
    struct Geometry {
        var size: CGSize = .zero
        var titleRect: CGRect?
        var plot: CGRect = .zero
        /// Bar rects per bar series, in series order.
        var bars: [[CGRect]] = []
        /// Points per line series, in series order.
        var lines: [[CGPoint]] = []
        var yTicks: [(y: CGFloat, label: String)] = []
        var xTicks: [(x: CGFloat, label: String)] = []
        var rotateXLabels = false
        var xTitleCenter: CGPoint?
        var yTitleCenter: CGPoint?
    }

    static let margin: CGFloat = 12
    static let plotHeight: CGFloat = 240

    static func smallFont(_ style: AgentDiagramStyle) -> NSFont {
        NSFont.systemFont(ofSize: max(style.font.pointSize - 1, 9))
    }

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    func geometry(maxWidth: CGFloat, style: AgentDiagramStyle) -> Geometry {
        var geometry = Geometry()
        let small = Self.smallFont(style)
        let lineHeight = AgentDiagramText.lineHeight(small)
        var y = Self.margin
        if let title, !title.isEmpty {
            let size = AgentDiagramText.size(title, font: Self.boldFont(style.font))
            geometry.titleRect = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + 12
        }
        let range = valueRange
        let tickValues = AgentDiagramTextNumber.ticks(low: range.min, high: range.max, count: 5)
        let tickLabels = tickValues.map(AgentDiagramTextNumber.format)
        let tickWidth = tickLabels.map { AgentDiagramText.width($0, font: small) }.max() ?? 0
        let yTitleWidth: CGFloat = yTitle == nil ? 0 : lineHeight + 8
        let plotLeft = Self.margin + yTitleWidth + tickWidth + 8
        let available = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 640
        let count = pointCount
        let labels = xLabels
        let labelWidths = labels.map { AgentDiagramText.width($0, font: small) }
        let minimumWidth = max(320, CGFloat(count) * 14)
        let plotWidth = min(max(available - plotLeft - Self.margin, minimumWidth), max(1_200, minimumWidth))
        let plot = CGRect(x: plotLeft, y: y + lineHeight / 2, width: plotWidth, height: Self.plotHeight)
        geometry.plot = plot

        let span = range.max - range.min
        func yPosition(_ value: Double) -> CGFloat {
            let clamped = min(max(value, range.min), range.max)
            return plot.maxY - CGFloat((clamped - range.min) / span) * plot.height
        }
        geometry.yTicks = zip(tickValues, tickLabels).map { (yPosition($0.0), $0.1) }

        let slot = plot.width / CGFloat(count)
        geometry.xTicks = labels.enumerated().map { (plot.minX + slot * (CGFloat($0.offset) + 0.5), $0.element) }
        let widest = labelWidths.max() ?? 0
        geometry.rotateXLabels = widest > slot - 6
        let xLabelHeight = geometry.rotateXLabels ? widest * 0.72 + lineHeight : lineHeight

        let barSeries = series.filter { $0.kind == .bar }
        let groupWidth = slot * 0.72
        let barWidth = barSeries.isEmpty ? 0 : groupWidth / CGFloat(barSeries.count)
        let baseline = yPosition(min(max(0, range.min), range.max))
        for (seriesIndex, bar) in barSeries.enumerated() {
            geometry.bars.append(bar.values.prefix(count).enumerated().map { pointIndex, value in
                let left = plot.minX + slot * CGFloat(pointIndex) + (slot - groupWidth) / 2 + barWidth * CGFloat(seriesIndex)
                let top = yPosition(value)
                return CGRect(x: left, y: min(top, baseline), width: max(barWidth - 1, 1), height: abs(baseline - top))
            })
        }
        for line in series where line.kind == .line {
            geometry.lines.append(line.values.prefix(count).enumerated().map { pointIndex, value in
                CGPoint(x: plot.minX + slot * (CGFloat(pointIndex) + 0.5), y: yPosition(value))
            })
        }

        var bottom = plot.maxY + 6 + xLabelHeight
        if xTitle != nil {
            geometry.xTitleCenter = CGPoint(x: plot.midX, y: bottom + 4 + lineHeight / 2)
            bottom += lineHeight + 8
        }
        if yTitle != nil {
            geometry.yTitleCenter = CGPoint(x: Self.margin + lineHeight / 2, y: plot.midY)
        }
        var width = plot.maxX + Self.margin
        if let rect = geometry.titleRect {
            width = max(width, rect.width + Self.margin * 2)
            geometry.titleRect = CGRect(x: (width - rect.width) / 2, y: rect.minY, width: rect.width, height: rect.height)
        }
        geometry.size = CGSize(width: ceil(width), height: ceil(bottom + Self.margin))
        return geometry
    }

    func layout(maxWidth: CGFloat, style: AgentDiagramStyle) -> AgentDiagramLayout {
        let geometry = geometry(maxWidth: maxWidth, style: style)
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
        let small = Self.smallFont(style)
        let plot = geometry.plot
        for tick in geometry.yTicks {
            AgentDiagramTextStroke.line(context, from: CGPoint(x: plot.minX, y: tick.y), to: CGPoint(x: plot.maxX, y: tick.y), color: AgentDiagramText.faded(style.border, 0.8))
            let size = AgentDiagramText.size(tick.label, font: small)
            AgentDiagramText.draw(tick.label, in: CGRect(x: plot.minX - 8 - size.width, y: tick.y - size.height / 2, width: size.width, height: size.height), font: small, color: style.muted, alignment: .right)
        }
        AgentDiagramTextStroke.line(context, from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.minX, y: plot.maxY), color: style.border)
        AgentDiagramTextStroke.line(context, from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), color: style.border)
        for tick in geometry.xTicks {
            AgentDiagramTextStroke.line(context, from: CGPoint(x: tick.x, y: plot.maxY), to: CGPoint(x: tick.x, y: plot.maxY + 4), color: style.border)
            let size = AgentDiagramText.size(tick.label, font: small)
            if geometry.rotateXLabels {
                context.saveGState()
                context.translateBy(x: tick.x, y: plot.maxY + 8)
                context.rotate(by: -.pi / 4)
                AgentDiagramText.draw(tick.label, in: CGRect(x: -size.width, y: -size.height / 2, width: size.width, height: size.height), font: small, color: style.muted, alignment: .right)
                context.restoreGState()
            } else {
                AgentDiagramText.draw(tick.label, in: CGRect(x: tick.x - size.width / 2, y: plot.maxY + 6, width: size.width, height: size.height), font: small, color: style.muted, alignment: .center)
            }
        }
        var colorIndex = 0
        var barIndex = 0
        var lineIndex = 0
        for item in series {
            let color = color(colorIndex, style: style)
            colorIndex += 1
            switch item.kind {
            case .bar:
                guard barIndex < geometry.bars.count else { continue }
                for rect in geometry.bars[barIndex] {
                    AgentDiagramTextStroke.rect(context, rect, radius: min(2, rect.width / 2), fill: color)
                }
                barIndex += 1
            case .line:
                guard lineIndex < geometry.lines.count else { continue }
                let points = geometry.lines[lineIndex]
                AgentDiagramTextStroke.polyline(context, points, color: color, width: 2)
                context.saveGState()
                context.setFillColor(color.cgColor)
                for point in points {
                    context.fillEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                }
                context.restoreGState()
                lineIndex += 1
            }
        }
        if let xTitle, let center = geometry.xTitleCenter {
            AgentDiagramText.draw(xTitle, centeredAt: center, font: small, color: style.foreground)
        }
        if let yTitle, let center = geometry.yTitleCenter {
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: -.pi / 2)
            AgentDiagramText.draw(yTitle, centeredAt: .zero, font: small, color: style.foreground)
            context.restoreGState()
        }
        if let title, let rect = geometry.titleRect {
            AgentDiagramText.draw(title, in: rect, font: Self.boldFont(style.font), color: style.foreground, alignment: .center)
        }
    }
}
