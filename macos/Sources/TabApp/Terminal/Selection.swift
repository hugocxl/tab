import TabClient
import TabProtocol

/// A cell position. `row` counts from the top of the screen; history rows
/// above it are negative, so positions survive fetching older history.
public struct TerminalPoint: Hashable, Comparable, Sendable {
    public var row: Int
    public var column: UInt16

    public init(row: Int, column: UInt16) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: TerminalPoint, rhs: TerminalPoint) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// The cells of a row: each ASCII character of a run is one cell, any other
/// run is one cluster covering `width` cells (the server sends one run per
/// wide or combined cell).
enum TerminalCells {
    struct Cell {
        var columns: Range<UInt16>
        var text: Substring
    }

    static func cells(_ runs: [Run]) -> [Cell] {
        var result: [Cell] = []
        var column: UInt16 = 0
        for run in runs {
            if isSimple(run) {
                var index = run.text.startIndex
                while index < run.text.endIndex {
                    let next = run.text.utf8.index(after: index)
                    result.append(Cell(columns: column..<column &+ 1, text: run.text[index..<next]))
                    column &+= 1
                    index = next
                }
            } else {
                let end = column &+ run.width
                result.append(Cell(columns: column..<end, text: run.text[...]))
                column = end
            }
        }
        return result
    }

    /// One cell per byte: ASCII text as wide as its length.
    static func isSimple(_ run: Run) -> Bool {
        run.text.utf8.count == Int(run.width) && run.text.utf8.allSatisfy { $0 < 0x80 }
    }
}

/// A selection between two cells: a stream of text from `anchor` to `head`,
/// or a rectangle of columns when made with Option held.
public struct TerminalSelection: Hashable, Sendable {
    public var anchor: TerminalPoint
    public var head: TerminalPoint
    public var rectangular: Bool

    public init(anchor: TerminalPoint, head: TerminalPoint, rectangular: Bool = false) {
        self.anchor = anchor
        self.head = head
        self.rectangular = rectangular
    }

    public var start: TerminalPoint { min(anchor, head) }
    public var end: TerminalPoint { max(anchor, head) }

    public var isEmpty: Bool {
        rectangular ? anchor.column == head.column : anchor == head
    }

    /// The selected columns of a row (end exclusive), widened to whole wide
    /// cells, or an empty range.
    public func columns(row: Int, in grid: RunGrid) -> Range<UInt16> {
        guard !isEmpty else { return 0..<0 }
        let start = self.start
        let end = self.end
        guard row >= start.row, row <= end.row else { return 0..<0 }
        let cols = grid.size.cols
        var first: UInt16
        var last: UInt16
        if rectangular {
            first = min(anchor.column, head.column)
            last = max(anchor.column, head.column)
        } else {
            first = row == start.row ? start.column : 0
            last = row == end.row ? end.column : cols
        }
        guard first < last else { return 0..<0 }
        for cell in TerminalCells.cells(Self.runs(row, grid)) where cell.columns.lowerBound < last
            && cell.columns.upperBound > first {
            first = min(first, cell.columns.lowerBound)
            last = max(last, cell.columns.upperBound)
        }
        return min(first, cols)..<min(last, cols)
    }

    /// The selected text, rows joined by newlines, trailing blanks trimmed.
    public func text(in grid: RunGrid) -> String {
        guard !isEmpty else { return "" }
        let start = self.start
        let end = self.end
        var lines: [String] = []
        for row in start.row...end.row {
            if !rectangular, row == end.row, end.column == 0, row != start.row { continue }
            let columns = columns(row: row, in: grid)
            var line = ""
            for cell in TerminalCells.cells(Self.runs(row, grid))
            where cell.columns.lowerBound < columns.upperBound && cell.columns.upperBound > columns.lowerBound {
                line += cell.text
            }
            while line.last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// The selected cells' text per row, to notice when output under the
    /// selection changed.
    public func fingerprint(in grid: RunGrid) -> [String] {
        guard !isEmpty else { return [] }
        return (start.row...end.row).map { row in
            let columns = columns(row: row, in: grid)
            return TerminalCells.cells(Self.runs(row, grid))
                .filter { $0.columns.lowerBound < columns.upperBound && $0.columns.upperBound > columns.lowerBound }
                .map { String($0.text) }.joined()
        }
    }

    /// The word, run of spaces, or single punctuation cell at `point`.
    public static func word(at point: TerminalPoint, in grid: RunGrid) -> TerminalSelection {
        let cells = TerminalCells.cells(runs(point.row, grid))
        guard let index = cells.firstIndex(where: { $0.columns.contains(point.column) }) else {
            let next = min(point.column &+ 1, grid.size.cols)
            return TerminalSelection(anchor: point, head: TerminalPoint(row: point.row, column: next))
        }
        let kind = wordClass(cells[index].text)
        var first = index
        var last = index + 1
        if kind != .punctuation {
            while first > 0, wordClass(cells[first - 1].text) == kind { first -= 1 }
            while last < cells.count, wordClass(cells[last].text) == kind { last += 1 }
        }
        return TerminalSelection(anchor: TerminalPoint(row: point.row, column: cells[first].columns.lowerBound),
                                 head: TerminalPoint(row: point.row, column: cells[last - 1].columns.upperBound))
    }

    /// The whole row at `point`.
    public static func line(at point: TerminalPoint, in grid: RunGrid) -> TerminalSelection {
        TerminalSelection(anchor: TerminalPoint(row: point.row, column: 0),
                          head: TerminalPoint(row: point.row, column: grid.size.cols))
    }

    /// Everything fetched: history and screen.
    public static func all(in grid: RunGrid) -> TerminalSelection {
        let last = max(0, grid.rows.count - 1)
        return TerminalSelection(anchor: TerminalPoint(row: -grid.history.count, column: 0),
                                 head: TerminalPoint(row: last, column: grid.size.cols))
    }

    static func runs(_ row: Int, _ grid: RunGrid) -> [Run] {
        grid.contentRow(grid.history.count + row) ?? []
    }

    private enum WordClass { case space, word, punctuation }

    private static func wordClass(_ text: Substring) -> WordClass {
        guard let first = text.unicodeScalars.first else { return .space }
        if first.properties.isWhitespace { return .space }
        if first.properties.isAlphabetic || first.properties.numericType != nil { return .word }
        return .punctuation
    }
}
