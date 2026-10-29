import Foundation
import TabProtocol

/// A file's diff laid out for drawing: rows in unified or split order, the
/// width of the line number columns, and the widest line, in character cells.
public struct DiffDocument: Equatable, Sendable {
    /// A split-view row: a deleted or context line on the left, an added or
    /// context line on the right, by index into `rows`.
    public struct SplitRow: Equatable, Sendable {
        public var left: Int?
        public var right: Int?
    }

    /// Text drawn at a column: a line number (dim), the `+`/`-` marker or source.
    public struct Segment: Equatable, Sendable {
        public var column: Int
        public var text: String
        public var dim: Bool
    }

    public private(set) var diff: GitDiff
    public var rows: [GitDiffRow] { diff.rows }
    public private(set) var split: [SplitRow]
    /// Cells for one line number column, including a space.
    public private(set) var numberColumns: Int
    /// Cells of the widest line's source.
    public private(set) var maxColumns: Int

    public init(_ diff: GitDiff) {
        var diff = diff
        Self.hideSingleHunk(&diff.rows)
        self.diff = diff
        split = Self.splitRows(diff.rows)
        let largest = diff.rows.flatMap { [$0.oldLineNumber, $0.newLineNumber] }.compactMap { $0 }.max() ?? 1
        numberColumns = String(largest).count + 1
        maxColumns = diff.rows.map { max(Self.columns(Self.content($0, old: true)), Self.columns(Self.content($0, old: false))) }.max() ?? 0
    }

    /// One hunk needs no header: its lines say where they are.
    static func hideSingleHunk(_ rows: inout [GitDiffRow]) {
        if rows.filter({ $0.kind == .hunk }).count == 1 {
            rows.removeAll { $0.kind == .hunk }
        }
    }

    /// Pairs each run of deletions and additions side by side.
    static func splitRows(_ rows: [GitDiffRow]) -> [SplitRow] {
        var layout: [SplitRow] = []
        layout.reserveCapacity(rows.count)
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .addition || rows[index].kind == .deletion else {
                layout.append(SplitRow(left: index, right: index))
                index += 1
                continue
            }
            let start = index
            while index < rows.count && (rows[index].kind == .addition || rows[index].kind == .deletion) { index += 1 }
            let deleted = (start..<index).filter { rows[$0].kind == .deletion }
            let added = (start..<index).filter { rows[$0].kind == .addition }
            for pair in 0..<max(deleted.count, added.count) {
                layout.append(SplitRow(left: deleted.indices.contains(pair) ? deleted[pair] : nil,
                                       right: added.indices.contains(pair) ? added[pair] : nil))
            }
        }
        return layout
    }

    /// The source text of a row's old or new side, without the diff marker.
    public static func content(_ row: GitDiffRow, old: Bool) -> String {
        if let text = old ? row.oldText : row.newText { return text }
        if row.kind == .hunk || row.text.isEmpty { return row.text }
        return String(row.text.dropFirst())
    }

    /// Character cells `text` takes: tabs are four, wide characters two.
    public static func columns(_ text: String) -> Int {
        text.reduce(0) { total, character in
            total + (character == "\t" ? 4 : (character.isASCII ? 1 : 2))
        }
    }

    public func rowCount(split isSplit: Bool) -> Int { isSplit ? split.count : rows.count }

    /// The segments drawn for `row`: its line numbers (both in unified
    /// view, one side in split view), the marker and the source.
    public static func segments(_ row: GitDiffRow, old: Bool, unified: Bool, numberColumns: Int) -> [Segment] {
        var segments: [Segment] = []
        var column = 0
        var numbers: [UInt64?] = []
        if unified || old { numbers.append(row.oldLineNumber) }
        if unified || !old { numbers.append(row.newLineNumber) }
        for number in numbers {
            let text = number.map(String.init) ?? ""
            segments.append(Segment(column: column + max(numberColumns - (text.count + 1), 0), text: text, dim: true))
            column += numberColumns
        }
        let marker: String
        switch row.kind {
        case .addition: marker = "+"
        case .deletion: marker = "-"
        default: marker = " "
        }
        segments.append(Segment(column: column, text: marker, dim: false))
        segments.append(Segment(column: column + 2, text: content(row, old: old).replacingOccurrences(of: "\t", with: "    "), dim: false))
        return segments
    }

    /// The part of `segment` between columns `first` and `last`, with the
    /// column it starts at, so very long lines draw only what shows.
    public static func visible(_ segment: Segment, first: Int, last: Int) -> (column: Int, text: String)? {
        let skip = max(first - segment.column, 0)
        let start = max(segment.column, first)
        let take = max(last - start, 0)
        let text = String(segment.text.dropFirst(skip).prefix(take))
        return text.isEmpty ? nil : (start, text)
    }

    /// Cells across the whole document, for the horizontal scroll width.
    public func totalColumns(split isSplit: Bool) -> Int {
        maxColumns + numberColumns * (isSplit ? 1 : 2) + 2
    }
}
