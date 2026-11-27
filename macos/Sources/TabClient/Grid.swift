import Foundation
import TabProtocol

/// What changed in a grid since the renderer last looked.
public struct GridChanges: Hashable, Sendable {
    /// Everything must be drawn again: size, history or scroll position changed.
    public var full: Bool
    /// Screen rows replaced, by index.
    public var rows: IndexSet
    /// The cursor, modes or graphics changed.
    public var cursor: Bool

    public init(full: Bool = false, rows: IndexSet = [], cursor: Bool = false) {
        self.full = full
        self.rows = rows
        self.cursor = cursor
    }

    public var isEmpty: Bool { !full && rows.isEmpty && !cursor }

    mutating func merge(_ other: GridChanges) {
        full = full || other.full
        rows.formUnion(other.rows)
        cursor = cursor || other.cursor
    }
}

/// One attached session's screen as a client sees it: the screen rows as
/// style runs, the cursor and modes, kitty graphics, the history pages
/// fetched above the screen, and the user's scroll position. Frames carry only
/// changed rows; `apply` merges them.
public struct RunGrid: Hashable, Sendable {
    public var size: Size
    /// Screen rows, top first.
    public var rows: [[Run]]
    public var cursor: Cursor
    public var modes: Modes
    public var graphics: Graphics?
    /// Rows where prompts start, in history-then-screen coordinates.
    public var prompts: Set<Int>
    public var promptState = ScreenPrompts()
    public var links = ScreenLinks()
    /// History rows fetched so far, oldest first, directly above the screen.
    public var history: [Row]
    /// Where to continue paging older history; `nil` when all of it is here.
    public var historyCursor: HistoryCursor?
    /// Rows of history the server keeps above the screen.
    public var historyTotal: UInt64
    /// Whether `history` ends right where the screen starts.
    public var historyFresh: Bool
    /// How many rows the view is scrolled up from live output; 0 follows it.
    public private(set) var scrollOffset = 0
    /// Bumped on every change, so views can skip redundant work.
    public private(set) var revision: UInt64 = 0
    private var pending = GridChanges(full: true)

    public init(snapshot: AttachSnapshot) {
        size = snapshot.size
        rows = Self.blank(snapshot.size.rows)
        cursor = snapshot.cursor
        modes = snapshot.modes
        graphics = snapshot.graphics
        prompts = Set(snapshot.prompts.map(Int.init))
        history = snapshot.history
        historyCursor = snapshot.historyCursor
        historyTotal = snapshot.historyTotal
        historyFresh = true
        replaceRows(snapshot.rows)
    }

    /// A session's last screen, read after it ended or while offline.
    public init(saved screen: SavedScreen) {
        size = screen.size
        rows = screen.rows.map(\.runs)
        cursor = screen.cursor
        cursor.visible = false
        modes = Modes()
        graphics = screen.graphics
        prompts = []
        history = []
        historyCursor = nil
        historyTotal = 0
        historyFresh = false
    }

    /// Merges a frame. A `reset` frame replaces the whole screen and drops the
    /// fetched history, which no longer lines up with it.
    @discardableResult
    public mutating func apply(_ frame: ScreenFrame) -> GridChanges {
        var changes = GridChanges(cursor: true)
        if let graphics = frame.graphics {
            self.graphics = graphics
        }
        links.frameSeq = frame.seq
        promptState.frameSeq = frame.seq
        if frame.reset || promptState.seq > frame.seq {
            prompts = prompts.filter { $0 < history.count }
        }
        if promptState.pending && promptState.seq <= frame.seq {
            applyScreenPrompts()
        }
        historyFresh = false
        if frame.reset {
            clearHistory()
            size = frame.size
            let height = max(Int(frame.size.rows), (frame.rows.map { Int($0.index) + 1 }.max() ?? 0))
            rows = Array(repeating: [], count: height)
            changes.full = true
        }
        if historyTotal != frame.historyRows {
            if scrollOffset > 0, frame.historyRows > historyTotal {
                scrollOffset += Int(frame.historyRows - historyTotal)
            }
            historyTotal = frame.historyRows
            changes.full = changes.full || scrollOffset > 0
        }
        changes.rows = replaceRows(frame.rows)
        cursor = frame.cursor
        modes = frame.modes
        clampScroll()
        record(changes)
        return changes
    }

    /// Starts over at a new size, before the server's full frame arrives.
    public mutating func resize(_ size: Size) {
        graphics = nil
        links.rows = []
        prompts = []
        promptState.pending = false
        promptState.rows = []
        self.size = size
        rows = Self.blank(size.rows)
        history = []
        historyCursor = nil
        historyFresh = false
        scrollOffset = 0
        record(GridChanges(full: true))
    }

    /// Replaces the history with the newest page, and with a saved session's
    /// screen when the page carries one.
    public mutating func replaceHistory(_ page: HistoryPage) {
        prompts = Set(page.prompts.map(Int.init))
        promptState.pending = false
        if let screen = page.screen {
            links.rows = []
            graphics = screen.graphics
            size = screen.size
            rows = screen.rows.map(\.runs)
            cursor = screen.cursor
        }
        history = page.rows
        historyCursor = page.next
        historyTotal = page.totalRows
        historyFresh = true
        clampScroll()
        record(GridChanges(full: true))
    }

    /// Puts an older page above the fetched history.
    public mutating func fetchOlder(_ page: HistoryPage) {
        prompts = Set(prompts.map { $0 + page.rows.count }).union(page.prompts.map(Int.init))
        history.insert(contentsOf: page.rows, at: 0)
        historyCursor = page.next
        record(GridChanges(full: true))
    }

    public mutating func clearHistory() {
        let count = history.count
        prompts = Set(prompts.compactMap { $0 >= count ? $0 - count : nil })
        history = []
        historyCursor = nil
        historyFresh = false
        scrollOffset = 0
    }

    /// Prompt rows on the screen of frame `seq`, applied once that frame is here.
    public mutating func screenPrompts(seq: UInt64, rows: [UInt16]) {
        guard seq >= promptState.seq else { return }
        promptState.seq = seq
        promptState.rows = rows
        promptState.pending = true
        if seq <= promptState.frameSeq {
            applyScreenPrompts()
        }
    }

    private mutating func applyScreenPrompts() {
        prompts = prompts.filter { $0 < history.count }
        for row in promptState.rows where row < size.rows {
            prompts.insert(history.count + Int(row))
        }
        promptState.pending = false
    }

    // MARK: Scrolling

    /// Scrolls up (positive) or down (negative) by rows, within the fetched
    /// history. Returns whether the position moved.
    @discardableResult
    public mutating func scroll(by rows: Int) -> Bool {
        let previous = scrollOffset
        scrollOffset = max(0, scrollOffset + rows)
        clampScroll()
        guard scrollOffset != previous else { return false }
        record(GridChanges(full: true))
        return true
    }

    /// Back to live output.
    public mutating func scrollToBottom() {
        scroll(by: -scrollOffset)
    }

    /// Whether the view is close enough to the top of the fetched history to
    /// fetch an older page, and one exists.
    public func needsOlderHistory(margin: Int) -> Bool {
        historyCursor != nil && scrollOffset + margin >= history.count
    }

    private mutating func clampScroll() {
        scrollOffset = min(scrollOffset, history.count)
    }

    /// The runs of the `index`-th visible row, with history above the screen
    /// when scrolled up.
    public func visibleRow(_ index: Int) -> [Run] {
        contentRow(history.count - scrollOffset + index) ?? []
    }

    // MARK: Reading

    /// A row in history-then-screen coordinates.
    public func contentRow(_ index: Int) -> [Run]? {
        guard index >= 0 else { return nil }
        if index < history.count { return history[index].runs }
        let screen = index - history.count
        return screen < rows.count ? rows[screen] : nil
    }

    /// Where a search match's row, counted over the server's whole history,
    /// is in the fetched content; `nil` when it isn't fetched or the totals
    /// differ.
    public func searchContentRow(_ row: UInt64, totalRows: UInt64) -> Int? {
        guard historyTotal == totalRows, totalRows >= UInt64(history.count) else { return nil }
        let first = totalRows - UInt64(history.count)
        guard row >= first else { return nil }
        let index = Int(row - first)
        return contentRow(index) == nil ? nil : index
    }

    /// A screen row's text.
    public func rowText(_ index: Int) -> String {
        guard index >= 0, index < rows.count else { return "" }
        return rows[index].map(\.text).joined()
    }

    /// The last `lines` screen rows as text, trailing spaces trimmed.
    public func screenText(lines: Int) -> String {
        rows.suffix(max(0, lines)).map { runs in
            var text = runs.map(\.text).joined()
            while text.last == " " { text.removeLast() }
            return text
        }.joined(separator: "\n")
    }

    /// What changed since the last call, for the renderer to redraw.
    public mutating func takeChanges() -> GridChanges {
        let changes = pending
        pending = GridChanges()
        return changes
    }

    @discardableResult
    private mutating func replaceRows(_ replacements: [Row]) -> IndexSet {
        var changed = IndexSet()
        for row in replacements where Int(row.index) < rows.count {
            rows[Int(row.index)] = row.runs
            changed.insert(Int(row.index))
        }
        return changed
    }

    private mutating func record(_ changes: GridChanges) {
        pending.merge(changes)
        revision &+= 1
    }

    private static func blank(_ count: UInt16) -> [[Run]] {
        Array(repeating: [], count: Int(count))
    }
}

/// Links on the screen of the newest frame; links for a frame not drawn yet
/// stay hidden until it arrives.
public struct ScreenLinks: Hashable, Sendable {
    var rows: [LinkRow] = []
    var seq: UInt64 = 0
    var frameSeq: UInt64 = 0

    public mutating func replace(seq: UInt64, rows: [LinkRow]) {
        guard seq >= self.seq else { return }
        self.rows = rows
        self.seq = seq
    }

    public func row(_ row: UInt16, size: Size) -> [LinkSpan] {
        guard row < size.rows, seq <= frameSeq else { return [] }
        return rows.first { $0.row == row }?.spans ?? []
    }
}

/// Prompt marks for a frame that may arrive before or after them.
public struct ScreenPrompts: Hashable, Sendable {
    var rows: [UInt16] = []
    var seq: UInt64 = 0
    var frameSeq: UInt64 = 0
    var pending = false
}
