import AppKit

/// A Mermaid `gantt` chart: sections and tasks with dates, durations and `after` dependencies.
/// Dates are `YYYY-MM-DD`, optionally with a `HH:mm[:ss]` time, read in UTC.
struct AgentGanttDiagram: AgentDiagramDocument {
    static let keywords: Set<String> = ["gantt"]
    static let maxTasks = 400

    struct Task: Equatable {
        var name: String
        var section: Int?
        var id: String?
        /// Seconds since 1970 in UTC.
        var start: Double
        var end: Double
        var done = false
        var active = false
        var critical = false
        var milestone = false
    }

    var title: String?
    var dateFormat = "YYYY-MM-DD"
    var axisFormat: String?
    var sections: [String] = []
    var tasks: [Task] = []

    init(source: String) throws {
        let split = try AgentDiagramTextSource.split(source)
        guard AgentDiagramTextSource.remainder(of: split.header.text, afterKeyword: "gantt") != nil else {
            throw AgentDiagramError(message: "Expected a gantt header.", line: split.header.number)
        }
        title = split.frontMatterTitle
        var ids: [String: Int] = [:]
        for line in split.body {
            try parse(line, ids: &ids)
        }
        guard !tasks.isEmpty else {
            throw AgentDiagramError(message: "The gantt chart has no tasks.", line: nil)
        }
    }

    private static let ignoredKeywords = [
        "excludes", "includes", "todayMarker", "tickInterval", "weekday", "weekend", "inclusiveEndDates",
        "topAxis", "displayMode", "accTitle", "accDescr", "click",
    ]

    private mutating func parse(_ line: AgentDiagramTextSourceLine, ids: inout [String: Int]) throws {
        let text = line.text
        for keyword in Self.ignoredKeywords where AgentDiagramTextSource.remainder(of: text, afterKeyword: keyword) != nil {
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "title") {
            title = rest
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "dateFormat") {
            dateFormat = rest
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "axisFormat") {
            axisFormat = rest
            return
        }
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "section") {
            sections.append(rest)
            return
        }
        guard let colon = text.firstIndex(of: ":") else {
            throw AgentDiagramError(message: "Expected `Task name : start, duration`.", line: line.number)
        }
        guard tasks.count < Self.maxTasks else {
            throw AgentDiagramError(message: "The gantt chart has too many tasks to draw.", line: line.number)
        }
        let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        var items = text[text.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        items.removeAll { $0.isEmpty }
        var task = Task(name: name, section: sections.isEmpty ? nil : sections.count - 1, start: 0, end: 0)
        while let first = items.first?.lowercased(), ["crit", "done", "active", "milestone"].contains(first) {
            switch first {
            case "crit": task.critical = true
            case "done": task.done = true
            case "active": task.active = true
            default: task.milestone = true
            }
            items.removeFirst()
        }
        let startText: String?
        let endText: String
        switch items.count {
        case 1:
            startText = nil
            endText = items[0]
        case 2:
            startText = items[0]
            endText = items[1]
        case 3:
            task.id = items[0]
            startText = items[1]
            endText = items[2]
        default:
            throw AgentDiagramError(message: "A task needs `[id,] start, end or duration`.", line: line.number)
        }
        if let startText {
            task.start = try resolveStart(startText, ids: ids, line: line)
        } else if let previous = tasks.last {
            task.start = previous.end
        } else {
            throw AgentDiagramError(message: "The first task needs a start date.", line: line.number)
        }
        task.end = try resolveEnd(endText, start: task.start, ids: ids, line: line)
        if task.end < task.start {
            throw AgentDiagramError(message: "A task ends before it starts.", line: line.number)
        }
        if let id = task.id { ids[id] = tasks.count }
        tasks.append(task)
    }

    private func resolveStart(_ text: String, ids: [String: Int], line: AgentDiagramTextSourceLine) throws -> Double {
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "after") {
            let references = rest.split(separator: " ").map(String.init)
            guard !references.isEmpty else {
                throw AgentDiagramError(message: "`after` needs a task id.", line: line.number)
            }
            var latest = -Double.infinity
            for reference in references {
                guard let index = ids[reference] else {
                    throw AgentDiagramError(message: "Unknown task id `\(reference)`.", line: line.number)
                }
                latest = max(latest, tasks[index].end)
            }
            return latest
        }
        guard let date = Self.parseDate(text) else {
            throw AgentDiagramError(message: "Unsupported date `\(text.prefix(30))`; use YYYY-MM-DD.", line: line.number)
        }
        return date
    }

    private func resolveEnd(_ text: String, start: Double, ids: [String: Int], line: AgentDiagramTextSourceLine) throws -> Double {
        if let rest = AgentDiagramTextSource.remainder(of: text, afterKeyword: "until") {
            guard let index = ids[rest] else {
                throw AgentDiagramError(message: "Unknown task id `\(rest)`.", line: line.number)
            }
            return tasks[index].start
        }
        if let duration = Self.parseDuration(text) {
            return start + duration
        }
        if let date = Self.parseDate(text) {
            return date
        }
        throw AgentDiagramError(message: "Expected an end date or a duration like `3d`, not `\(text.prefix(30))`.", line: line.number)
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }

    /// Parses `YYYY-MM-DD`, optionally followed by ` HH:mm[:ss]` or `THH:mm[:ss]`, in UTC.
    static func parseDate(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "T" }).map(String.init)
        guard let datePart = parts.first, parts.count <= 2 else { return nil }
        let day = datePart.split(separator: "-").map { Int($0) }
        guard day.count == 3, let year = day[0], let month = day[1], let dayOfMonth = day[2],
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(dayOfMonth) else { return nil }
        var components = DateComponents(year: year, month: month, day: dayOfMonth, hour: 0, minute: 0, second: 0)
        if parts.count == 2 {
            let time = parts[1].split(separator: ":").map { Int($0) }
            guard (2...3).contains(time.count), let hour = time[0], let minute = time[1],
                  (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            components.hour = hour
            components.minute = minute
            if time.count == 3 {
                guard let second = time[2], (0...59).contains(second) else { return nil }
                components.second = second
            }
        }
        return calendar.date(from: components)?.timeIntervalSince1970
    }

    /// Parses a duration like `3d`, `2w`, `12h`, `30m`, `10s` or `1.5d`, in seconds.
    static func parseDuration(_ text: String) -> Double? {
        let units: [(suffix: String, seconds: Double)] = [
            ("ms", 0.001), ("s", 1), ("m", 60), ("h", 3_600), ("d", 86_400), ("w", 604_800), ("M", 2_592_000), ("y", 31_536_000),
        ]
        for unit in units where text.hasSuffix(unit.suffix) {
            let number = String(text.dropLast(unit.suffix.count))
            guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
                  let value = Double(number), value.isFinite, value >= 0, value < 100_000 else { continue }
            return value * unit.seconds
        }
        return nil
    }

    /// Formats `time` with a strftime subset: `%Y %y %m %d %e %b %B %a %A %H %I %p %M %S %j %%`.
    static func format(_ time: Double, _ format: String) -> String {
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: Date(timeIntervalSince1970: time))
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let fullMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let fullDays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let year = components.year ?? 1970
        let month = min(max(components.month ?? 1, 1), 12)
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let weekday = min(max((components.weekday ?? 1) - 1, 0), 6)
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        var output = ""
        var iterator = format.makeIterator()
        while let character = iterator.next() {
            guard character == "%" else {
                output.append(character)
                continue
            }
            guard let code = iterator.next() else { break }
            switch code {
            case "Y": output += String(year)
            case "y": output += two(year % 100)
            case "m": output += two(month)
            case "d": output += two(day)
            case "e": output += String(day)
            case "b": output += months[month - 1]
            case "B": output += fullMonths[month - 1]
            case "a": output += days[weekday]
            case "A": output += fullDays[weekday]
            case "H": output += two(hour)
            case "I": output += two(hour % 12 == 0 ? 12 : hour % 12)
            case "p": output += hour < 12 ? "AM" : "PM"
            case "M": output += two(components.minute ?? 0)
            case "S": output += two(components.second ?? 0)
            case "j": output += String(calendar.ordinality(of: .day, in: .year, for: Date(timeIntervalSince1970: time)) ?? 1)
            case "%": output += "%"
            default: output += "%\(code)"
            }
        }
        return output
    }
}

// MARK: - Layout

extension AgentGanttDiagram {
    struct Geometry {
        var size: CGSize = .zero
        var titleRect: CGRect?
        var chartRect: CGRect = .zero
        /// One rect per task, in source order.
        var bars: [CGRect] = []
        var sectionRects: [CGRect] = []
        var ticks: [(x: CGFloat, label: String)] = []
    }

    static let margin: CGFloat = 12
    static let rowHeight: CGFloat = 26
    static let barHeight: CGFloat = 18

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    static func smallFont(_ style: AgentDiagramStyle) -> NSFont {
        NSFont.systemFont(ofSize: max(style.font.pointSize - 1, 9))
    }

    var timeRange: (low: Double, high: Double) {
        let low = tasks.map(\.start).min() ?? 0
        var high = tasks.map(\.end).max() ?? 0
        if high <= low { high = low + 86_400 }
        return (low, high)
    }

    func geometry(maxWidth: CGFloat, style: AgentDiagramStyle) -> Geometry {
        var geometry = Geometry()
        let font = style.font
        let small = Self.smallFont(style)
        var y = Self.margin
        if let title, !title.isEmpty {
            let size = AgentDiagramText.size(title, font: Self.boldFont(font))
            geometry.titleRect = CGRect(x: 0, y: y, width: size.width, height: size.height)
            y += size.height + 10
        }
        let sectionWidth = sections.map { AgentDiagramText.size($0, font: Self.boldFont(small)).width }.max().map { $0 + 20 } ?? 0
        let available = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 720
        // Tick labels are centered on their ticks, so the chart keeps half a label clear on each side.
        let edge = ceil(AgentDiagramText.width(Self.format(timeRange.low, axisFormat ?? "%Y-%m-%d"), font: small) / 2)
        let chartLeft = Self.margin + max(sectionWidth, edge)
        let chartWidth = min(max(available - chartLeft - edge - Self.margin, 360), 1_600)
        let chartTop = y
        let chartHeight = CGFloat(tasks.count) * Self.rowHeight
        geometry.chartRect = CGRect(x: chartLeft, y: chartTop, width: chartWidth, height: chartHeight)

        let range = timeRange
        let scale = Double(chartWidth) / (range.high - range.low)
        func x(_ time: Double) -> CGFloat { chartLeft + CGFloat((time - range.low) * scale) }
        for (index, task) in tasks.enumerated() {
            let top = chartTop + CGFloat(index) * Self.rowHeight + (Self.rowHeight - Self.barHeight) / 2
            let left = x(task.start)
            let width = task.milestone ? Self.barHeight : max(x(task.end) - left, 3)
            let originX = task.milestone ? left - Self.barHeight / 2 : left
            geometry.bars.append(CGRect(x: originX, y: top, width: width, height: Self.barHeight))
        }
        for sectionIndex in sections.indices {
            let rows = tasks.indices.filter { tasks[$0].section == sectionIndex }
            guard let first = rows.first, let last = rows.last else { continue }
            geometry.sectionRects.append(CGRect(
                x: Self.margin, y: chartTop + CGFloat(first) * Self.rowHeight,
                width: chartLeft + chartWidth - Self.margin, height: CGFloat(last - first + 1) * Self.rowHeight
            ))
        }

        // Ticks: the smallest interval whose labels do not collide.
        let span = range.high - range.low
        let intervals: [Double] = [60, 300, 900, 3_600, 3 * 3_600, 6 * 3_600, 12 * 3_600, 86_400, 2 * 86_400, 7 * 86_400, 14 * 86_400, 30 * 86_400, 91 * 86_400, 365 * 86_400, 3_650 * 86_400]
        var interval = intervals.last ?? 86_400
        var labelFormat = axisFormat ?? "%Y-%m-%d"
        for candidate in intervals {
            let format = axisFormat ?? (candidate < 86_400 ? "%H:%M" : "%Y-%m-%d")
            let labelWidth = AgentDiagramText.width(Self.format(range.low, format), font: small) + 16
            if Double(chartWidth) / (span / candidate) >= Double(labelWidth) {
                interval = candidate
                labelFormat = format
                break
            }
        }
        let alignment = interval >= 86_400 ? 86_400.0 : interval
        var tick = (range.low / alignment).rounded(.down) * alignment
        if tick < range.low { tick += alignment }
        while tick <= range.high, geometry.ticks.count < 200 {
            geometry.ticks.append((x(tick), Self.format(tick, labelFormat)))
            tick += interval
        }

        let axisHeight = AgentDiagramText.lineHeight(small) + 10
        var width = chartLeft + chartWidth + edge + Self.margin
        // Labels that do not fit inside their bars are drawn to the right and may widen the chart.
        for (index, task) in tasks.enumerated() {
            let textWidth = AgentDiagramText.width(task.name, font: small)
            let bar = geometry.bars[index]
            if textWidth + 12 > bar.width, bar.maxX + textWidth + 8 > chartLeft + chartWidth, bar.minX - textWidth - 8 < chartLeft {
                width = max(width, bar.maxX + textWidth + 8 + Self.margin)
            }
        }
        if let rect = geometry.titleRect {
            width = max(width, rect.width + Self.margin * 2)
            geometry.titleRect = CGRect(x: (width - rect.width) / 2, y: rect.minY, width: rect.width, height: rect.height)
        }
        geometry.size = CGSize(width: ceil(width), height: ceil(chartTop + chartHeight + axisHeight + Self.margin))
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

    private func draw(_ geometry: Geometry, style: AgentDiagramStyle, in context: CGContext) {
        let small = Self.smallFont(style)
        let chart = geometry.chartRect
        var drawnSections = 0
        for sectionIndex in sections.indices where tasks.contains(where: { $0.section == sectionIndex }) {
            guard drawnSections < geometry.sectionRects.count else { break }
            let rect = geometry.sectionRects[drawnSections]
            if drawnSections % 2 == 0 {
                AgentDiagramTextStroke.rect(context, rect, fill: AgentDiagramText.faded(style.accentSoft, 0.6))
            }
            let size = AgentDiagramText.size(sections[sectionIndex], font: Self.boldFont(small))
            AgentDiagramText.draw(sections[sectionIndex], in: CGRect(x: rect.minX + 6, y: rect.midY - size.height / 2, width: chart.minX - rect.minX - 12, height: size.height), font: Self.boldFont(small), color: style.muted, alignment: .left)
            drawnSections += 1
        }
        for tick in geometry.ticks {
            AgentDiagramTextStroke.line(context, from: CGPoint(x: tick.x, y: chart.minY), to: CGPoint(x: tick.x, y: chart.maxY + 4), color: AgentDiagramText.faded(style.border, 0.8))
            let size = AgentDiagramText.size(tick.label, font: small)
            AgentDiagramText.draw(tick.label, in: CGRect(x: tick.x - size.width / 2, y: chart.maxY + 6, width: size.width, height: size.height), font: small, color: style.muted, alignment: .center)
        }
        AgentDiagramTextStroke.line(context, from: CGPoint(x: chart.minX, y: chart.maxY), to: CGPoint(x: chart.maxX, y: chart.maxY), color: style.border)

        for (index, task) in tasks.enumerated() where index < geometry.bars.count {
            let bar = geometry.bars[index]
            var fill = style.accentSoft
            var stroke = style.accent
            var textColor = style.foreground
            if task.done {
                fill = style.muted.withAlphaComponent(0.3)
                stroke = style.muted
            } else if task.active {
                fill = style.accent
                stroke = style.accent
                textColor = style.surface
            } else if task.critical {
                fill = style.danger.withAlphaComponent(0.18)
            }
            if task.critical { stroke = style.danger }
            if task.milestone {
                context.saveGState()
                context.move(to: CGPoint(x: bar.midX, y: bar.minY))
                context.addLine(to: CGPoint(x: bar.maxX, y: bar.midY))
                context.addLine(to: CGPoint(x: bar.midX, y: bar.maxY))
                context.addLine(to: CGPoint(x: bar.minX, y: bar.midY))
                context.closePath()
                context.setFillColor((task.critical ? style.danger : style.accent).cgColor)
                context.fillPath()
                context.restoreGState()
            } else {
                AgentDiagramTextStroke.rect(context, bar, radius: 3, fill: fill, stroke: stroke, width: task.critical ? 2 : 1)
            }
            let size = AgentDiagramText.size(task.name, font: small)
            let labelRect: CGRect
            if !task.milestone, size.width + 12 <= bar.width {
                labelRect = CGRect(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2, width: size.width, height: size.height)
            } else if bar.maxX + size.width + 8 <= chart.maxX || bar.minX - size.width - 8 < chart.minX {
                labelRect = CGRect(x: bar.maxX + 6, y: bar.midY - size.height / 2, width: size.width, height: size.height)
                textColor = style.foreground
            } else {
                labelRect = CGRect(x: bar.minX - size.width - 6, y: bar.midY - size.height / 2, width: size.width, height: size.height)
                textColor = style.foreground
            }
            AgentDiagramText.draw(task.name, in: labelRect, font: small, color: textColor, alignment: .left)
        }
        if let title, let rect = geometry.titleRect {
            AgentDiagramText.draw(title, in: rect, font: Self.boldFont(style.font), color: style.foreground, alignment: .center)
        }
    }
}
