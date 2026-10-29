import Foundation
import TabProtocol

/// History cursors: a tag from the session and the history's generation in
/// the high bits, a row in the low ones, so a cursor from before the history
/// changed is refused instead of returning other rows.
enum HistoryWindow {
    private static let rowBits: UInt64 = 32
    private static let rowMask: UInt64 = (1 << rowBits) - 1

    static func tag(session: SessionId, generation: UInt64) -> UInt64 {
        var hash = StableHash()
        hash.combine(session.uuid)
        hash.combine(generation)
        // Never zero, so no cursor is 0.
        return (hash.value | (1 << 63)) & ~rowMask
    }

    /// Rows `range` for a page of up to `maxRows` before `cursor` (the newest
    /// rows when `nil`), and the cursor of the next older page.
    static func range(session: SessionId, generation: UInt64, before cursor: HistoryCursor?, maxRows: UInt16,
                      total: Int) throws -> (Range<Int>, HistoryCursor?) {
        guard (1...Limits.maxHistoryPage).contains(Int(maxRows)) else {
            throw ServiceError(.badRequest, "History pages hold 1 through \(Limits.maxHistoryPage) rows")
        }
        guard total <= Int(rowMask) else { throw ServiceError(.historyUnavailable, "History exceeds the cursor range") }
        let tag = tag(session: session, generation: generation)
        var end = total
        if let cursor {
            let row = Int(cursor.rawValue & rowMask)
            guard cursor.rawValue & ~rowMask == tag, row > 0, row <= total else {
                throw ServiceError(.staleHistoryCursor, "History changed; start from a fresh window")
            }
            end = row
        }
        let start = max(0, end - Int(maxRows))
        return (start..<end, start > 0 ? HistoryCursor(tag | UInt64(start)) : nil)
    }
}

/// Plain-text search through rows, newest match first, a bounded number of
/// rows per page. Matching ignores case unless asked not to.
struct HistorySearch {
    static let scanLimit = Int(Limits.maxSearchScannedRows)
    /// A position is a row and a column, so a single row can span pages.
    private static let positionBits: UInt64 = 44
    private static let positionMask: UInt64 = (1 << positionBits) - 1

    var session: SessionId
    var generation: UInt64
    var query: String
    var ignoreCase: Bool
    var before: HistoryCursor?
    var maxResults: UInt16
    var historyRows: Int
    var screenRows: Int

    private var tag: UInt64 {
        var hash = StableHash()
        hash.combine(session.uuid)
        hash.combine(generation)
        hash.combine(query)
        hash.combine(ignoreCase ? 1 : 0)
        return (hash.value | (1 << 63)) & ~Self.positionMask
    }

    private func position() throws -> UInt64 {
        do {
            try Validation.search(query: query, maxResults: maxResults)
        } catch {
            throw ServiceError(.badRequest, "Invalid search query or result limit")
        }
        let end = UInt64(historyRows + screenRows) * UInt64(Limits.maxCols)
        guard end <= Self.positionMask else { throw ServiceError(.historyUnavailable, "History exceeds the cursor range") }
        guard let before else { return end }
        let position = before.rawValue & Self.positionMask
        guard position > 0, position <= end, before.rawValue == tag | position else {
            throw ServiceError(.staleHistoryCursor, "History changed; start a fresh search")
        }
        return position
    }

    /// The rows the next page scans, in history-then-screen coordinates.
    func range() throws -> Range<Int> {
        let cols = UInt64(Limits.maxCols)
        let end = Int((try position() + cols - 1) / cols)
        return max(0, end - Self.scanLimit)..<end
    }

    /// Scans the rows of `range()` from the newest; `row` returns a row's runs.
    func scan(_ row: (Int) throws -> [Run]) throws -> SearchPage {
        var position = try position()
        let rows = try range()
        let cols = UInt64(Limits.maxCols)
        var page = SearchPage(matches: [], totalRows: UInt64(historyRows), scannedRows: 0)
        for index in rows.reversed() {
            page.scannedRows += 1
            let base = UInt64(index) * cols
            let limit = position - base
            for found in Self.matches(in: try row(index), query: query, ignoreCase: ignoreCase).reversed()
            where UInt64(found.start) < limit {
                position = base + UInt64(found.start)
                page.matches.append(SearchMatch(row: UInt64(index), start: found.start, end: found.end))
                if page.matches.count == Int(maxResults) {
                    page.next = position > 0 ? HistoryCursor(tag | position) : nil
                    return page
                }
            }
            position = base
        }
        page.next = position > 0 ? HistoryCursor(tag | position) : nil
        return page
    }

    /// Matches in one row, in cell columns. ASCII runs map one byte to one
    /// cell; other runs share their cells among their characters.
    static func matches(in runs: [Run], query: String, ignoreCase: Bool) -> [(start: UInt16, end: UInt16)] {
        let needle = Array((ignoreCase ? fold(query) : query).utf8)
        guard !needle.isEmpty else { return [] }
        var text: [UInt8] = []
        var columns: [(UInt16, UInt16)] = []
        var column: UInt16 = 0
        for run in runs {
            if run.text.utf8.count == Int(run.width), run.text.utf8.allSatisfy({ $0 < 0x80 }) {
                for byte in run.text.utf8 {
                    text.append(ignoreCase && (0x41...0x5a).contains(byte) ? byte + 0x20 : byte)
                    columns.append((column, column &+ 1))
                    column &+= 1
                }
                continue
            }
            let end = column &+ run.width
            for character in run.text {
                let value = Array((ignoreCase ? fold(String(character)) : String(character)).utf8)
                text += value
                columns += Array(repeating: (column, end), count: value.count)
            }
            column = end
        }
        var found: [(start: UInt16, end: UInt16)] = []
        guard text.count >= needle.count else { return found }
        var index = 0
        while index + needle.count <= text.count {
            if text[index] == needle[0], text[index..<index + needle.count].elementsEqual(needle) {
                let start = columns[index].0
                let end = columns[index + needle.count - 1].1
                if start < end, found.last?.start != start {
                    found.append((start, end))
                }
            }
            index += 1
        }
        return found
    }

    private static func fold(_ text: String) -> String {
        text.lowercased()
    }
}
