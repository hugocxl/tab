import CGhosttyVT
import Foundation
import TabProtocol

/// A cell in screen space: history rows first (row 0 is the oldest), then
/// the screen, so screen row `r` is `historyCount() + r`.
public struct GridPoint: Hashable, Comparable, Codable, Sendable {
    public var row: Int
    public var column: UInt16

    public init(row: Int, column: UInt16) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: GridPoint, rhs: GridPoint) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// Cells from `start` through `end`, inclusive.
public struct GridRange: Hashable, Sendable {
    public var start: GridPoint
    public var end: GridPoint

    public init(start: GridPoint, end: GridPoint) {
        self.start = start
        self.end = end
    }
}

/// Continues a search with older matches.
public struct TerminalSearchCursor: Hashable, Sendable {
    let generation: UInt64
    let query: String
    let caseSensitive: Bool
    /// The last match returned.
    let after: GridPoint
    /// The engine's selected match, the first one of the next page.
    let resume: GridPoint
}

public struct TerminalSearchPage: Hashable, Sendable {
    /// Newest first: from the bottom of the screen up through history.
    public var matches: [GridRange]
    public var next: TerminalSearchCursor?
    /// Matches the engine found, ignoring ASCII case.
    public var candidates: Int

    public init(matches: [GridRange] = [], next: TerminalSearchCursor? = nil, candidates: Int = 0) {
        self.matches = matches
        self.next = next
        self.candidates = candidates
    }
}

/// The engine search, kept between pages so paging continues from the
/// selected match instead of searching again.
final class SearchSession {
    let handle: GhosttySearch
    var needle = ""

    init(terminal: GhosttyTerminal) throws {
        var search: GhosttySearch?
        try Ghostty.check(ghostty_search_new(nil, &search, terminal), .search)
        guard let search else { throw TerminalError(.search, .engine(GHOSTTY_OUT_OF_MEMORY.rawValue)) }
        handle = search
        var scroll = GHOSTTY_SEARCH_SCROLL_NONE
        ghostty_search_set(search, GHOSTTY_SEARCH_OPT_SELECT_SCROLL, &scroll)
    }

    deinit {
        ghostty_search_free(handle)
    }

    func setNeedle(_ query: String) throws {
        var bytes = Array(query.utf8)
        try bytes.withUnsafeMutableBufferPointer { buffer in
            guard !buffer.isEmpty else {
                try Ghostty.check(ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, nil), .search)
                return
            }
            var string = GhosttyString(ptr: buffer.baseAddress, len: buffer.count)
            try Ghostty.check(ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, &string), .search)
        }
        needle = query
    }

    /// Drops results and the selection, then searches again from scratch.
    func restart(_ query: String) throws {
        try setNeedle("")
        try setNeedle(query)
        try Ghostty.check(ghostty_search_run(handle), .search)
    }

    func total() throws -> Int {
        var total = 0
        try Ghostty.check(ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total), .search)
        return total
    }

    func selectedIndex() -> Int? {
        var index = 0
        guard ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS else { return nil }
        return index
    }

    func selected() -> GhosttySelection? {
        var selection = Ghostty.selection(Ghostty.gridRef(), Ghostty.gridRef(), rectangle: false)
        guard ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &selection) == GHOSTTY_SUCCESS else {
            return nil
        }
        return selection
    }

    /// Selects the next older match (wrapping to the newest after the oldest).
    func selectNext() -> GhosttySelection? {
        guard ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_SELECT_NEXT, nil) == GHOSTTY_SUCCESS else { return nil }
        return selected()
    }
}

extension Terminal {
    /// Searches the screen and history, newest match first. Matching ignores
    /// ASCII case unless `caseSensitive`. Pass the returned cursor to get
    /// older matches; it throws `.staleCursor` once history has changed.
    public func search(
        _ query: String, caseSensitive: Bool = false, before cursor: TerminalSearchCursor? = nil, maxResults: Int = 100
    ) throws -> TerminalSearchPage {
        guard !query.isEmpty, maxResults > 0 else { return TerminalSearchPage() }
        let generation = try historyGeneration()
        if let cursor, cursor.generation != generation || cursor.query != query || cursor.caseSensitive != caseSensitive {
            throw TerminalError(.search, .staleCursor)
        }
        let session = try searchSession ?? SearchSession(terminal: handle)
        searchSession = session
        if session.needle != query {
            try session.setNeedle(query)
        }
        try Ghostty.check(ghostty_search_run(session.handle), .search)
        let total = try session.total()
        guard total > 0 else { return TerminalSearchPage() }

        var current = try firstMatch(session, query: query, cursor: cursor, total: total)
        var last = cursor?.after
        var matches: [GridRange] = []
        var scanned = 0
        while let match = current, matches.count < maxResults, scanned < total {
            scanned += 1
            if try !caseSensitive || selectionText(match) == query {
                matches.append(match)
            }
            last = match.start
            current = session.selectNext().flatMap(range).flatMap { $0.start < match.start ? $0 : nil }
        }
        var next: TerminalSearchCursor?
        if let current, let last {
            next = TerminalSearchCursor(
                generation: generation, query: query, caseSensitive: caseSensitive, after: last, resume: current.start)
        }
        return TerminalSearchPage(matches: matches, next: next, candidates: total)
    }

    private func firstMatch(
        _ session: SearchSession, query: String, cursor: TerminalSearchCursor?, total: Int
    ) throws -> GridRange? {
        guard let cursor else {
            if session.selectedIndex() == 0, let selected = session.selected().flatMap(range) {
                return selected
            }
            try session.restart(query)
            return session.selectNext().flatMap(range)
        }
        if let selected = session.selected().flatMap(range), selected.start == cursor.resume {
            return selected
        }
        try session.restart(query)
        var previous: GridPoint?
        for _ in 0..<total {
            guard let match = session.selectNext().flatMap(range) else { return nil }
            if match.start < cursor.after { return match }
            if let previous, match.start >= previous { return nil }
            previous = match.start
        }
        return nil
    }

    /// The text of cells `start` through `end` (screen space), soft wraps
    /// joined and trailing blanks trimmed.
    public func selectionText(from start: GridPoint, to end: GridPoint, rectangle: Bool = false) throws -> String {
        var selection = Ghostty.selection(
            try gridRef(start, .selection), try gridRef(end, .selection), rectangle: rectangle)
        return try format(&selection)
    }

    public func selectionText(_ range: GridRange) throws -> String {
        try selectionText(from: range.start, to: range.end)
    }

    /// The output of the command around `point`, from its semantic prompt
    /// marks (OSC 133), or nil when `point` is not command output.
    public func selectCommandOutput(at point: GridPoint) throws -> GridRange? {
        let reference = try gridRef(point, .selection)
        var selection = Ghostty.selection(Ghostty.gridRef(), Ghostty.gridRef(), rectangle: false)
        let result = ghostty_terminal_select_output(handle, reference, &selection)
        if result == GHOSTTY_NO_VALUE { return nil }
        try Ghostty.check(result, .selection)
        return range(selection)
    }

    private func format(_ selection: inout GhosttySelection) throws -> String {
        try withUnsafePointer(to: &selection) { pointer in
            let options = GhosttyTerminalSelectionFormatOptions(
                size: MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size,
                emit: GHOSTTY_FORMATTER_FORMAT_PLAIN, unwrap: true, trim: true, selection: pointer)
            var output: UnsafeMutablePointer<UInt8>?
            var length = 0
            let result = ghostty_terminal_selection_format_alloc(handle, nil, options, &output, &length)
            defer { ghostty_free(nil, output, length) }
            if result == GHOSTTY_NO_VALUE { return "" }
            try Ghostty.check(result, .selection)
            guard let output else { return "" }
            return String(decoding: UnsafeBufferPointer(start: output, count: length), as: UTF8.self)
        }
    }

    func gridRef(_ point: GridPoint, _ step: TerminalStep) throws -> GhosttyGridRef {
        guard point.row >= 0, point.row <= Int(UInt32.max) else {
            throw TerminalError(step, .invalidArgument("row out of range"))
        }
        var reference = Ghostty.gridRef()
        try Ghostty.check(
            ghostty_terminal_grid_ref(
                handle, Ghostty.point(GHOSTTY_POINT_TAG_SCREEN, x: point.column, y: UInt32(point.row)), &reference),
            step)
        return reference
    }

    func gridPoint(_ reference: GhosttyGridRef) -> GridPoint? {
        var reference = reference
        var point = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(handle, &reference, GHOSTTY_POINT_TAG_SCREEN, &point)
            == GHOSTTY_SUCCESS
        else { return nil }
        return GridPoint(row: Int(point.y), column: point.x)
    }

    func range(_ selection: GhosttySelection) -> GridRange? {
        guard let start = gridPoint(selection.start), let end = gridPoint(selection.end) else { return nil }
        return start <= end ? GridRange(start: start, end: end) : GridRange(start: end, end: start)
    }
}
