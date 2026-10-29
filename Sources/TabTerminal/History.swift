import CGhosttyVT
import Foundation
import TabProtocol

/// History rows (scrollback above the screen) read from the engine.
public struct TerminalHistoryRows: Hashable, Sendable {
    /// Row `index` is the position within this slice.
    public var rows: [Row]
    /// Indexes into `rows` that start a shell prompt.
    public var prompts: [UInt16]

    public init(rows: [Row] = [], prompts: [UInt16] = []) {
        self.rows = rows
        self.prompts = prompts
    }
}

/// Where the next older history page ends.
public struct TerminalHistoryCursor: Hashable, Codable, Sendable {
    public var generation: UInt64
    public var end: Int

    public init(generation: UInt64, end: Int) {
        self.generation = generation
        self.end = end
    }
}

/// One page of history, newest pages first.
public struct TerminalHistoryPage: Hashable, Sendable {
    public var rows: [Row]
    public var prompts: [UInt16]
    /// History index of the first row; history index 0 is the oldest row.
    public var start: Int
    public var totalRows: Int
    public var generation: UInt64
    /// The next older page, or nil at the top of history.
    public var next: TerminalHistoryCursor?
}

/// Detects when history indexes stop meaning the same rows: a resize, a
/// clear, a screen switch or pruning of the oldest rows. A tracked engine
/// reference near the top of history moves or disappears when that happens.
struct HistoryTracking {
    var generation: UInt64 = 0
    var anchor: HistoryAnchor?
    var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
    var count = 0

    mutating func invalidate() {
        generation &+= 1
        anchor = nil
    }
}

final class HistoryAnchor {
    let reference: GhosttyTrackedGridRef
    let point: GhosttyPointCoordinate

    init(reference: GhosttyTrackedGridRef, point: GhosttyPointCoordinate) {
        self.reference = reference
        self.point = point
    }

    deinit {
        ghostty_tracked_grid_ref_free(reference)
    }

    var moved: Bool {
        var current = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(reference, GHOSTTY_POINT_TAG_SCREEN, &current) == GHOSTTY_SUCCESS else {
            return true
        }
        return current.x != point.x || current.y != point.y
    }
}

extension Terminal {
    /// Rows of scrollback above the screen.
    public func historyCount() throws -> Int {
        try value(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, 0, .history)
    }

    /// Changes whenever history indexes stop referring to the same rows.
    /// Appending output keeps it.
    public func historyGeneration() throws -> UInt64 {
        let screen = try activeScreen(.history)
        let count = try historyCount()
        if screen != tracking.screen || tracking.anchor?.moved == true || count < tracking.count {
            tracking.invalidate()
            tracking.screen = screen
        }
        tracking.count = count
        if tracking.anchor == nil {
            let point = GhosttyPointCoordinate(x: 0, y: count + Int(size.rows) > 1 ? 1 : 0)
            var reference: GhosttyTrackedGridRef?
            try Ghostty.check(
                ghostty_terminal_grid_ref_track(
                    handle, GhosttyPoint(tag: GHOSTTY_POINT_TAG_SCREEN, value: GhosttyPointValue(coordinate: point)),
                    &reference),
                .history)
            if let reference {
                tracking.anchor = HistoryAnchor(reference: reference, point: point)
            }
        }
        return tracking.generation
    }

    /// History rows `range` (clamped), read by scrolling the engine viewport
    /// one screen at a time. Leaves the viewport and dirty rows as they were,
    /// so the next `render()` reports only real changes.
    public func history(_ range: Range<Int>) throws -> TerminalHistoryRows {
        let end = min(range.upperBound, try historyCount())
        let start = max(0, range.lowerBound)
        guard start < end else { return TerminalHistoryRows() }

        try updateRenderState(.history)
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        try Ghostty.check(ghostty_render_state_get(engineRender.state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty), .history)
        var rowDirty: [Bool] = []
        try forEachRow { _, rows in
            var flag = false
            ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &flag)
            rowDirty.append(flag)
        }
        let viewportActive = try value(GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, true, .history)
        let scrollbar = try value(GHOSTTY_TERMINAL_DATA_SCROLLBAR, GhosttyTerminalScrollbar(), .history)

        var result = TerminalHistoryRows()
        result.rows.reserveCapacity(end - start)
        var failure: Error?
        do {
            var chunk = start
            while chunk < end {
                scroll(.row(chunk))
                let screen = try readViewport(.history)
                let remaining = end - chunk
                for prompt in screen.prompts where Int(prompt) < remaining {
                    result.prompts.append(UInt16(clamping: result.rows.count + Int(prompt)))
                }
                for var row in screen.rows.prefix(remaining) {
                    row.index = UInt16(clamping: result.rows.count)
                    result.rows.append(row)
                }
                chunk += Int(size.rows)
            }
        } catch {
            failure = error
        }

        scroll(viewportActive ? .bottom : .row(Int(scrollbar.offset)))
        try updateRenderState(.history)
        try Ghostty.check(ghostty_render_state_set(engineRender.state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty), .history)
        try forEachRow { index, rows in
            guard index < rowDirty.count else { return }
            var flag = rowDirty[index]
            ghostty_render_state_row_set(rows, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &flag)
        }
        if let failure { throw failure }
        return result
    }

    /// Pages through history from the newest rows up. A cursor from before a
    /// resize, clear, screen switch or pruning throws `.staleCursor`.
    public func historyPage(before cursor: TerminalHistoryCursor? = nil, maxRows: Int) throws -> TerminalHistoryPage {
        let generation = try historyGeneration()
        let total = try historyCount()
        var end = total
        if let cursor {
            guard cursor.generation == generation, cursor.end <= total else {
                throw TerminalError(.history, .staleCursor)
            }
            end = cursor.end
        }
        let start = max(0, end - max(1, maxRows))
        let slice = try history(start..<end)
        return TerminalHistoryPage(
            rows: slice.rows, prompts: slice.prompts, start: start, totalRows: total, generation: generation,
            next: start > 0 ? TerminalHistoryCursor(generation: generation, end: start) : nil)
    }

    func captureHistory() throws -> [[Run]] {
        try history(0..<historyCount()).rows.map(\.runs)
    }
}
