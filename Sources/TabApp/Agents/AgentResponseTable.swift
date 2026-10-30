import AppKit

/// Selectable native cells in a horizontally scrollable grid. Explicit table copy preserves cell
/// boundaries as Markdown or CSV instead of relying on cross-view text selection.
@MainActor
final class AgentResponseTable: AgentResponseSection {
    override var kind: Int { 2 }
    let scroll = NSScrollView()
    let copy = PillButton("Copy table ▾", style: .plain)
    private let grid = AgentResponseTableGrid()
    private var cells: [AgentRichTextView] = []
    private(set) var headers: [String] = []
    private(set) var rows: [[String]] = []
    private var alignments: [AgentMarkdown.TableAlignment] = []
    private var widths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private var gridWidth: CGFloat = 0
    private var gridHeight: CGFloat = 0
    private var naturalColumnWidths: [CGFloat]?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = grid
        addSubview(scroll)
        copy.translatesAutoresizingMaskIntoConstraints = true
        copy.font = AppFont.footnote
        addSubview(copy)
        copy.onPress = { [weak self] in self?.showCopyMenu() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .table(let headers, let rows, let alignments) = part else { return }
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        naturalColumnWidths = nil
        grid.theme = theme
        let values = [headers] + rows
        let count = values.count * headers.count
        while cells.count > count { cells.removeLast().removeFromSuperview() }
        while cells.count < count {
            let cell = AgentRichTextView(frame: .zero)
            cells.append(cell)
            grid.addSubview(cell)
        }
        for row in values.indices {
            for column in headers.indices {
                let index = row * headers.count + column
                let value = values[row].indices.contains(column) ? values[row][column] : ""
                let content = NSMutableAttributedString(attributedString: AgentMarkdown.inline(
                    value, theme: theme, font: AppFont.system(13, weight: row == 0 ? .semibold : .regular), fileLinks: true))
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 3
                style.lineBreakMode = .byWordWrapping
                let alignment = alignments.indices.contains(column) ? alignments[column] : .left
                switch alignment { case .left: style.alignment = .left; case .center: style.alignment = .center; case .right: style.alignment = .right }
                content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
                cells[index].setContent(content)
                cells[index].delegate = delegate
                cells[index].linkTextAttributes = [.foregroundColor: theme.accent]
                cells[index].selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
                cells[index].setAccessibilityLabel(row == 0 ? "Column: \(value)" : "\(headers[column]): \(value)")
            }
        }
        grid.needsDisplay = true
    }

    override func height(for width: CGFloat) -> CGFloat {
        guard !headers.isEmpty else { return 0 }
        if naturalColumnWidths == nil {
            naturalColumnWidths = headers.indices.map { column in
                let natural = stride(from: column, to: cells.count, by: headers.count).map { index in
                    cells[index].attributedString().boundingRect(
                        with: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]).width
                }.max() ?? 0
                return max(90, min(240, ceil(natural) + 24))
            }
        }
        widths = naturalColumnWidths ?? []
        let naturalWidth = widths.reduce(0, +)
        if naturalWidth < width {
            let spare = (width - naturalWidth) / CGFloat(headers.count)
            widths = widths.map { $0 + spare }
        }
        gridWidth = widths.reduce(0, +)
        rowHeights = (0...rows.count).map { row in
            let height = headers.indices.map { column in
                cells[row * headers.count + column].height(for: max(1, widths[column] - 24))
            }.max() ?? 0
            return max(36, height + 18)
        }
        gridHeight = rowHeights.reduce(0, +)
        return gridHeight + 34 + (gridWidth > width ? 10 : 0)
    }

    override func layoutSection(width: CGFloat) {
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(0, bounds.height - 30))
        grid.frame = NSRect(x: 0, y: 0, width: gridWidth, height: gridHeight)
        var y: CGFloat = 0
        for row in rowHeights.indices {
            var x: CGFloat = 0
            for column in widths.indices {
                let index = row * headers.count + column
                cells[index].frame = NSRect(x: x + 12, y: y + 9, width: max(1, widths[column] - 24), height: rowHeights[row] - 18)
                x += widths[column]
            }
            y += rowHeights[row]
        }
        grid.rowHeights = rowHeights
        grid.needsDisplay = true
        copy.frame = NSRect(x: max(0, width - 108), y: max(0, bounds.height - 28), width: 108, height: 26)
    }

    enum CopyFormat { case markdown, csv }

    func copyText(_ format: CopyFormat) -> String {
        let values = [headers] + rows
        switch format {
        case .csv:
            return values.enumerated().map { rowIndex, row in
                row.enumerated().map { column, source in
                    let index = rowIndex * headers.count + column
                    let displayed = cells.indices.contains(index) ? cells[index].string : source
                    return "\"" + displayed.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }.joined(separator: ",")
            }.joined(separator: "\n")
        case .markdown:
            func line(_ row: [String]) -> String {
                "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |"
            }
            let markers = headers.indices.map { index -> String in
                guard alignments.indices.contains(index) else { return "---" }
                switch alignments[index] { case .left: return "---"; case .center: return ":---:"; case .right: return "---:" }
            }
            return ([line(headers), line(markers)] + rows.map(line)).joined(separator: "\n")
        }
    }

    private func showCopyMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy as Markdown", action: #selector(copyMarkdown), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Copy as CSV", action: #selector(copyCSV), keyEquivalent: ""))
        for item in menu.items { item.target = self }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: copy.bounds.maxY), in: copy)
    }

    @objc private func copyMarkdown() { copyToPasteboard(.markdown) }
    @objc private func copyCSV() { copyToPasteboard(.csv) }
    private func copyToPasteboard(_ format: CopyFormat) {
        NSPasteboard.general.clearContents()
        copy.title = NSPasteboard.general.setString(copyText(format), forType: .string) ? "Copied ▾" : "Copy failed ▾"
    }
}

@MainActor
private final class AgentResponseTableGrid: NSView {
    var theme: AppTheme = .shared
    var rowHeights: [CGFloat] = []
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let headerHeight = rowHeights.first {
            theme.fg.withAlphaComponent(0.045).setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight).fill()
        }
        theme.border.withAlphaComponent(0.65).setStroke()
        var y: CGFloat = 0
        let path = NSBezierPath()
        for height in rowHeights {
            y += height
            path.move(to: NSPoint(x: 0, y: y - 0.5))
            path.line(to: NSPoint(x: bounds.width, y: y - 0.5))
        }
        path.lineWidth = 1
        path.stroke()
    }
}
