import AppKit

/// One TextKit table keeps selection, links and keyboard navigation continuous across cells.
@MainActor
final class AgentResponseTable: AgentResponseSection {
    override var kind: Int { 2 }
    let scroll = AgentTableScrollView()
    let copy = PillButton("", style: .plain)
    let text = AgentRichTextView(frame: .zero)
    var headingTargets: [AgentMarkdownHeadingTarget] { AgentMarkdownHeadingTarget.collect(in: text) }
    private var cellContents: [NSAttributedString] = []
    private(set) var headers: [String] = []
    private(set) var rows: [[String]] = []
    private var alignments: [AgentMarkdown.TableAlignment] = []
    private var tableTheme: AppTheme = .shared
    private var measuredWidth: CGFloat?
    private var gridWidth: CGFloat = 0
    private var gridHeight: CGFloat = 0
    private var copyReset: Task<Void, Never>?
    private var copyIcon: AppIcon = .copy

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = text
        addSubview(scroll)
        copy.translatesAutoresizingMaskIntoConstraints = true
        copy.imagePosition = .imageOnly
        addSubview(copy)
        resetCopyAction()
        copy.onPress = { [weak self] in self?.showCopyMenu() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        AgentTableCopyHitTesting.hitTest(point, in: self) ?? super.hitTest(point)
    }


    override func update(_ part: AgentResponsePart, theme: AppTheme, delegate: NSTextViewDelegate) {
        guard case .table(let headers, let rows, let alignments) = part else { return }
        self.headers = headers
        self.rows = rows
        self.alignments = alignments
        tableTheme = theme
        copy.contentTintColor = AgentMarkdownPalette(theme: theme).muted
        copy.image = copyIcon.image(size: 12, scale: AppIcon.inlineScale, color: AgentMarkdownPalette(theme: theme).muted)
        measuredWidth = nil
        cellContents = ([headers] + rows).enumerated().flatMap { row, values in
            headers.indices.map { column in
                AgentMarkdown.inline(values.indices.contains(column) ? values[column] : "", theme: theme,
                    font: AppFont.system(14, weight: row == 0 ? .semibold : .light), fileLinks: true, references: references, lineBreaks: lineBreaks, rawHTML: rawHTML)
            }
        }
        text.delegate = delegate
        text.linkTextAttributes = [:] // Inline spans already carry their own link or code color.
        text.selectedTextAttributes = [.backgroundColor: theme.accent.withAlphaComponent(0.22)]
        text.setAccessibilityLabel("Table: " + headers.joined(separator: ", "))
    }

    override func height(for width: CGFloat) -> CGFloat {
        guard !headers.isEmpty else { return 0 }
        if measuredWidth != width {
            measuredWidth = width
            rebuildTable(width: width)
            gridHeight = text.height(for: gridWidth)
            // TextKit reserves an editable paragraph after a table; this read-only section
            // ends at the table, with its copy action immediately below the last rule.
            if let manager = text.layoutManager, manager.extraLineFragmentTextContainer != nil {
                gridHeight = min(gridHeight, manager.extraLineFragmentRect.minY)
            }
        }
        return gridHeight + 26 + (gridWidth > width ? 10 : 0)
    }

    private func rebuildTable(width: CGFloat) {
        var minimum: [CGFloat] = []
        var preferred: [CGFloat] = []
        for column in headers.indices {
            let padding: CGFloat = (column == 0 ? 0 : 12) + (column == headers.count - 1 ? 0 : 12)
            let contents = stride(from: column, to: cellContents.count, by: headers.count).map { cellContents[$0] }
            let natural = contents.map { $0.size().width + AgentExternalLinkLayout.additionalWidth($0) + AgentInlineCodeLayout.additionalWidth($0) }.max() ?? 0
            let longestWord = contents.flatMap { content -> [CGFloat] in
                let source = content.string as NSString
                var sizes: [CGFloat] = []
                content.string.enumerateSubstrings(in: content.string.startIndex..., options: .byWords) { _, range, _, _ in
                    let nsRange = NSRange(range, in: content.string)
                    if nsRange.length > 0, NSMaxRange(nsRange) <= source.length {
                        let word = content.attributedSubstring(from: nsRange)
                        sizes.append(word.size().width + AgentExternalLinkLayout.additionalWidth(word) + AgentInlineCodeLayout.additionalWidth(word))
                    }
                }
                return sizes
            }.max() ?? 0
            let prefixWidth = contents.map { AgentExternalLinkLayout.minimumPrefixWidth($0) }.max() ?? 0
            minimum.append(min(384, max(1, longestWord, prefixWidth) + padding))
            preferred.append(min(384, max(1, natural) + padding))
        }
        let minTotal = minimum.reduce(0, +)
        let preferredTotal = preferred.reduce(0, +)
        gridWidth = max(width, minTotal)
        let widths: [CGFloat]
        if preferredTotal <= gridWidth {
            widths = preferred.map { $0 * gridWidth / max(1, preferredTotal) }
        } else {
            let fraction = (gridWidth - minTotal) / max(1, preferredTotal - minTotal)
            widths = zip(minimum, preferred).map { $0 + ($1 - $0) * fraction }
        }
        let table = AgentMarkdownTextTable()
        table.ruleColor = AgentMarkdownPalette(theme: tableTheme).tableRule
        table.numberOfColumns = headers.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        // Only bottom rules are present; no neighboring borders need merging.
        // TextKit collapse mode adds a half-rule inset on the horizontal axis too.
        table.collapsesBorders = false
        table.setValue(gridWidth, type: .absoluteValueType, for: .width)
        let content = NSMutableAttributedString()
        for index in cellContents.indices {
            let row = index / headers.count
            let column = index % headers.count
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.verticalAlignment = .top
            block.setValue(widths[column], type: .absoluteValueType, for: .width)
            block.setWidth(column == 0 ? 0 : 12, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(column == headers.count - 1 ? 0 : 12, type: .absoluteValueType, for: .padding, edge: .maxX)
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.minimumLineHeight = 22.75
            paragraph.maximumLineHeight = 22.75
            paragraph.lineBreakMode = .byWordWrapping
            let alignment = alignments.indices.contains(column) ? alignments[column] : .left
            switch alignment { case .left: paragraph.alignment = .left; case .center: paragraph.alignment = .center; case .right: paragraph.alignment = .right }
            let cell = NSMutableAttributedString(attributedString: cellContents[index])
            cell.append(NSAttributedString(string: "\n", attributes: [.font: AppFont.system(14, weight: .light)]))
            cell.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length))
            content.append(cell)
        }
        text.setContent(content)
    }

    override func layoutSection(width: CGFloat) {
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(0, bounds.height - 26))
        text.frame = NSRect(x: 0, y: 0, width: gridWidth, height: gridHeight)
        scroll.updateOverflowFade()
        copy.frame = NSRect(x: max(0, width - 20), y: max(0, bounds.height - 24), width: 24, height: 24)
    }

    enum CopyFormat { case markdown, csv }

    func copyText(_ format: CopyFormat) -> String {
        switch format {
        case .csv:
            return AgentTableClipboard.csv(cells: cellContents.map(\.string), columns: headers.count)
        case .markdown:
            func line(_ row: [String]) -> String {
                "| " + headers.indices.map { column in
                    AgentTableClipboard.markdownCell(row.indices.contains(column) ? row[column] : "", references: references)
                }.joined(separator: " | ") + " |"
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
    func copyToPasteboard(_ format: CopyFormat) {
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(copyText(format), forType: .string)
        copyIcon = copied ? .check : .triangleAlert
        copy.image = copyIcon.image(size: 12, scale: AppIcon.inlineScale, color: AgentMarkdownPalette(theme: tableTheme).muted)
        copy.toolTip = copied ? "Copied" : "Copy failed"
        copy.setAccessibilityLabel(copy.toolTip)
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            self?.resetCopyAction()
        }
    }

    private func resetCopyAction() {
        copyIcon = .copy
        copy.image = copyIcon.image(size: 12, scale: AppIcon.inlineScale, color: AgentMarkdownPalette(theme: tableTheme).muted)
        copy.toolTip = "Copy table"
        copy.setAccessibilityLabel("Copy table")
    }
}
