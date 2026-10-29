import Foundation
import TabClient
import TabProtocol

/// Find in a terminal's whole history: the query, the matches found so far
/// (newest first, as the server returns them), the current match, and the
/// paging state of the search.
public struct TerminalFind: Equatable, Sendable {
    public struct Request: Equatable, Sendable {
        public var token: UInt64
        public var query: String
        public var ignoreCase: Bool
        public var before: HistoryCursor?
    }

    public var query = ""
    public var ignoreCase = true
    public private(set) var matches: [SearchMatch] = []
    public private(set) var totalRows: UInt64 = 0
    public var current: Int?
    public var loadingHistory = false
    public private(set) var error: String?
    private(set) var pending: Request?
    private var restarted = false
    private var nextToken: UInt64 = 1

    public init() {}

    /// Starts over with the current query; returns the first page to fetch.
    public mutating func restart() -> Request? {
        clear()
        restarted = false
        if query.isEmpty { return nil }
        if query.utf8.count > Limits.maxSearchQuery {
            error = "Query is too long"
            return nil
        }
        return request(before: nil)
    }

    /// Takes a page; returns the next page to fetch, if any.
    public mutating func receive(_ request: Request, _ result: Result<SearchPage, Error>) -> Request? {
        guard pending == request else { return nil }
        pending = nil
        switch result {
        case .success(let page):
            if request.before != nil, page.totalRows != totalRows { return stale() }
            totalRows = page.totalRows
            matches += page.matches
            if current == nil, !matches.isEmpty { current = 0 }
            return page.next.map { self.request(before: $0) }
        case .failure(let error as ClientError) where error.serverCode == .staleHistoryCursor:
            return stale()
        case .failure(let error):
            clear()
            self.error = String(describing: error)
            return nil
        }
    }

    /// Moves to the next (older) or previous (newer) match, wrapping around.
    public mutating func step(previous: Bool) {
        let count = matches.count
        guard count > 0 else { return }
        switch (current, previous) {
        case (nil, _): current = 0
        case (0?, true): current = count - 1
        case (let index?, true): current = index - 1
        case (let index?, false): current = (index + 1) % count
        }
    }

    public var currentMatch: SearchMatch? {
        current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
    }

    /// `3 of 12`, `Loading…`, or the error.
    public var counter: String {
        if let error { return error }
        if loadingHistory { return "Loading…" }
        let position = current.map { $0 + 1 } ?? 0
        return pending == nil ? "\(position) of \(matches.count)" : "\(position) of \(matches.count)…"
    }

    public var isSearching: Bool { pending != nil }

    /// The matches on a content row (history-then-screen index) of `grid`,
    /// and whether each is the current one. Matches whose text no longer
    /// matches what is on screen are left out.
    public func highlights(in grid: RunGrid, contentRow index: Int) -> [(columns: Range<UInt16>, current: Bool)] {
        guard !matches.isEmpty, grid.historyTotal == totalRows,
              totalRows >= UInt64(grid.history.count), index >= 0 else { return [] }
        let row = totalRows - UInt64(grid.history.count) + UInt64(index)
        let first = matches.partitionIndex { $0.row <= row }
        guard first < matches.count, matches[first].row == row else { return [] }
        let cells = TerminalCells.cells(grid.contentRow(index) ?? [])
        var result: [(Range<UInt16>, Bool)] = []
        var position = first
        while position < matches.count, matches[position].row == row {
            let found = matches[position]
            if matchesText(cells, found) {
                result.append((found.start..<found.end, current == position))
            }
            position += 1
        }
        return result
    }

    private func matchesText(_ cells: [TerminalCells.Cell], _ found: SearchMatch) -> Bool {
        let text = cells.filter { $0.columns.upperBound > found.start && $0.columns.lowerBound < found.end }
            .map { String($0.text) }.joined()
        return ignoreCase ? text.lowercased().contains(query.lowercased()) : text.contains(query)
    }

    private mutating func clear() {
        matches = []
        current = nil
        pending = nil
        loadingHistory = false
        error = nil
    }

    private mutating func stale() -> Request? {
        clear()
        if restarted {
            error = "Output changed; search again"
            return nil
        }
        restarted = true
        return request(before: nil)
    }

    private mutating func request(before: HistoryCursor?) -> Request {
        let request = Request(token: nextToken, query: query, ignoreCase: ignoreCase, before: before)
        nextToken &+= 1
        pending = request
        return request
    }

    public static func == (lhs: TerminalFind, rhs: TerminalFind) -> Bool {
        lhs.query == rhs.query && lhs.ignoreCase == rhs.ignoreCase && lhs.matches == rhs.matches
            && lhs.totalRows == rhs.totalRows && lhs.current == rhs.current && lhs.pending == rhs.pending
            && lhs.error == rhs.error && lhs.loadingHistory == rhs.loadingHistory
    }
}

private extension Array {
    /// The first index whose element satisfies `predicate`, for a predicate
    /// that is false then true along the array.
    func partitionIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
