import Foundation
import TabProtocol

/// Archived items loaded above a transcript's retained ones, kept in step as the retained
/// window moves. Pages are keyed by the conversation's reset identity and the archive
/// position (cursor) of the oldest loaded item, and merged by item identity:
///
/// - Items a newer snapshot trims from the retained window, which the reader already had,
///   stay where they were, after the loaded pages.
/// - When more items were trimmed than the timeline holds, as after a reconnect, there is
///   a gap between the loaded items and the retained ones. `needsGapFill` says so until
///   `fillGap` merges the newest archive pages that lead back to what is held.
/// - A page that arrives after the retained window moved still applies: archive positions
///   don't change while the conversation isn't reset, and items already held are skipped.
/// - Turns of trimmed items stay with them, so a carried turn keeps its shape.
struct AgentEarlierTimeline {
    /// The conversation reset the loaded items belong to.
    private(set) var resetID: SessionId?
    /// Loaded and carried items, oldest first, none of them retained.
    private(set) var items: [AgentChatItem] = []
    private var ids: Set<String> = []
    /// The archive position of the oldest loaded item; nil until a page loads.
    private(set) var cursor: Int?
    /// Items trimmed from the window that this timeline doesn't hold yet.
    private(set) var needsGapFill = false
    private var retained: [AgentChatItem] = []
    private var retainedIDs: Set<String> = []
    private var retainedTurns: [AgentChatTurn] = []
    /// Turns of the carried items, oldest first.
    private var carriedTurns: [AgentChatTurn] = []
    private var omitted = 0
    /// How many items `shown` began with when it was last read, while none came before them
    /// since; see `unchangedLead`.
    private var lead = 0

    /// True once any archived page loaded.
    var isLoaded: Bool { cursor != nil }

    /// Whether `id` is shown, loaded or retained.
    func holds(_ id: String) -> Bool { ids.contains(id) || retainedIDs.contains(id) }

    /// Whether the archive holds items older than those loaded, or a gap remains.
    var canLoadMore: Bool {
        guard let cursor else { return omitted > 0 }
        return cursor > 0 || needsGapFill
    }

    /// The position to read older items before: nil for the newest page.
    var olderCursor: Int? { cursor }

    /// Takes a new retained window and its omitted count, and returns what to show: the
    /// loaded items then the retained ones, and how many older items stay hidden.
    mutating func observe(_ window: [AgentChatItem], omitted newOmitted: Int, resetID reset: SessionId?) -> (items: [AgentChatItem], omitted: Int) {
        observe(window, turns: [], omitted: newOmitted, resetID: reset).items
    }

    /// Like `observe(_:omitted:resetID:)`, with the window's turns: the turns to show are
    /// those of carried items, then the window's. `unchangedLead` says how many leading
    /// items are the ones the previous result began with, so a reader can skip them.
    mutating func observe(_ window: [AgentChatItem], turns windowTurns: [AgentChatTurn], omitted newOmitted: Int,
                          resetID reset: SessionId?) -> (items: (items: [AgentChatItem], omitted: Int), turns: [AgentChatTurn], unchangedLead: Int) {
        if reset != resetID { self = AgentEarlierTimeline(); resetID = reset }
        let windowIDs = Set(window.map(\.id))
        if isLoaded {
            // What the reader had in the window and the server trimmed since. It was shown
            // just after the carried items, so the shown items still begin the same way.
            let trimmed = retained.filter { !windowIDs.contains($0.id) && !ids.contains($0.id) }
            items.append(contentsOf: trimmed)
            for item in trimmed { ids.insert(item.id) }
            if !trimmed.isEmpty {
                let trimmedIDs = Set(trimmed.map(\.id))
                carriedTurns.append(contentsOf: retainedTurns.filter { trimmedIDs.contains($0.userItemID) })
            }
            if newOmitted - omitted > trimmed.count { needsGapFill = true }
        }
        retained = window
        retainedIDs = windowIDs
        retainedTurns = windowTurns
        omitted = newOmitted
        let result = shown
        let above = result.items.count - window.count
        let unchanged = above == items.count ? min(lead, above) : 0
        lead = above == items.count ? above : 0
        let windowTurnIDs = Set(windowTurns.map(\.userItemID))
        let turns = carriedTurns.isEmpty ? windowTurns : carriedTurns.filter { !windowTurnIDs.contains($0.userItemID) } + windowTurns
        return (result, turns, unchanged)
    }

    /// The loaded items above the retained window, and the older items still hidden.
    var shown: (items: [AgentChatItem], omitted: Int) {
        guard !items.isEmpty else { return (retained, omitted) }
        // Loaded items are never retained ones, unless the server sent one back.
        let overlaps = retained.contains { ids.contains($0.id) }
        let above = overlaps ? items.filter { !retainedIDs.contains($0.id) } : items
        return (above + retained, max(0, omitted - above.count))
    }

    /// Merges a page read `before` an archive position (nil for the newest), returning
    /// false when it belongs to another reset of the conversation. `omittedWhenRequested`
    /// is the omitted count when the newest page was asked for: if the server trimmed more
    /// before it arrived, what it trimmed may sit between the page and the window.
    @discardableResult
    mutating func accept(_ page: AgentEarlierItems, before: Int?, resetID reset: SessionId?,
                         omittedWhenRequested: Int? = nil) -> Bool {
        guard reset == resetID else { return false }
        if before == nil, cursor == nil, let requested = omittedWhenRequested, omitted > requested { needsGapFill = true }
        if let before, let cursor, before != cursor {
            // A page from an older cursor merges only where it continues what is loaded.
            guard page.start < cursor else { return true }
        }
        let fresh = page.items.filter { !holds($0.id) }
        if !fresh.isEmpty { lead = 0 }
        items.insert(contentsOf: fresh, at: 0)
        for item in fresh { ids.insert(item.id) }
        cursor = min(cursor ?? page.start, page.start)
        return true
    }

    /// Merges the newest archive pages, newest first, read to fill a gap: the items not yet
    /// held go after the loaded ones, in archive order.
    mutating func fillGap(_ pages: [AgentEarlierItems], resetID reset: SessionId?) {
        guard reset == resetID else { return }
        var fresh: [AgentChatItem] = []
        var seen: Set<String> = []
        for page in pages {
            let new = page.items.filter { !holds($0.id) && !seen.contains($0.id) }
            for item in new { seen.insert(item.id) }
            fresh = new + fresh
        }
        // A gap's items go after those already shown, which keep their place.
        lead = min(lead, items.count)
        items.append(contentsOf: fresh)
        for item in fresh { ids.insert(item.id) }
        if cursor == nil, let oldest = pages.last { cursor = oldest.start }
        needsGapFill = false
    }

    /// Whether a page read for a gap reached what the timeline holds, or the archive's
    /// start, so no older page is needed.
    func gapReached(_ page: AgentEarlierItems) -> Bool {
        page.start == 0 || page.items.contains { ids.contains($0.id) } || cursor.map { page.start <= $0 } == true
    }
}
