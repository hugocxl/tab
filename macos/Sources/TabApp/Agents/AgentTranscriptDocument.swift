import AppKit
import TabProtocol

/// Estimated whole-transcript geometry with native rows mounted only around the viewport.
/// Snapshot grouping is O(n); native text layout is confined to changed/visible rows.
@MainActor
final class AgentTranscriptDocument: ThemedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        AgentTableCopyHitTesting.hitTest(point, in: self) ?? super.hitTest(point)
    }

    private enum Kind: Equatable {
        case message, activity, work, working, changes
        case card(AgentTypedCardKind)
        /// Work and tool rows can own nested scroll surfaces; only plain rows stay as spares.
        var isCard: Bool { if case .card = self { return true }; return false }
        var retainedWhenUnmounted: Bool {
            if case .card = self { return true }
            return self == .message
        }
    }
    private struct Entry: Equatable {
        var id: String
        var kind: Kind
        var items: [AgentChatItem]
        var turn: AgentChatTurn? = nil
        var timestamp: Date? = nil
        /// How long the turn took, on its answer, or on its work summary when it has no answer.
        var duration: TimeInterval? = nil
        var groupedWork = false
        var showsResponseActions = true
        /// Only compaction cards name the provider, so a provider change re-renders them alone.
        var provider: AgentChatProvider? = nil
        /// What a running turn is doing now, on its working row.
        var activity: String? = nil
        /// What the turn an answer ends used.
        var usage: AgentTurnUsage? = nil
    }
    private struct Height {
        var value: CGFloat
        var width: CGFloat = -1
        var epoch: UInt64 = 0
        var valid = false
    }
    private final class CachedRow {
        let row: AgentTimelineRow
        let kind: Kind
        var rendered: Entry?
        var epoch: UInt64 = 0
        var needsMeasurement = true
        var needsLayout = true
        var lastUse: UInt64 = 0
        init(row: AgentTimelineRow, kind: Kind) { self.row = row; self.kind = kind }
    }

    /// Remembers todo-list validity per item across snapshots.
    let classifier = AgentTypedCardClassifier()
    private var entries: [Entry] = []
    private var sourceItems: [AgentChatItem] = []
    private var sourceTurns: [AgentChatTurn] = []
    private var positions: [String: Int] = [:]
    private var heights: [String: Height] = [:]
    private var cache: [String: CachedRow] = [:]
    private var mounted: Set<String> = []
    private var savedStates: [String: AgentTimelineRowState] = [:]
    private var geometry = AgentTranscriptLayout()
    private var themeEpoch: UInt64 = 1
    private var useSequence: UInt64 = 0
    private var updatingViewport = false
    private var lastViewport = NSRect(x: 0, y: 0, width: 0, height: 700)
    private var lastFollowingEnd = false
    private var pendingAnchor: AgentTranscriptAnchor?
    private var omittedCount = 0
    /// What the last update built from, so the next one rebuilds only from the turn before
    /// its first change: streaming into a long conversation costs its last turns, not all of it.
    private struct Built {
        var source: [AgentChatItem]
        /// The source items shown, and where each is in `source`.
        var items: [AgentChatItem]
        var sourcePositions: [Int]
        var turns: [AgentChatTurn]
        var provider: AgentChatProvider?
        /// Where each turn's user item is, and how many entries come before its own.
        var segments: [(item: Int, entry: Int)]
        /// Typed todo and plan items, by position, with the provider item each one replaces.
        var typed: [(item: Int, nativeID: String)]
    }
    private var built: Built?
    /// Off only to check that reusing turns lays out what a whole rebuild would.
    var reusesUnchangedTurns = true
    /// How many entries the last update built rather than reused.
    private(set) var rebuiltEntryCount = 0
    /// An item whose rows must be rebuilt although it didn't change, as when its work unfolds.
    private var dirtyItemID: String?
    private var approvalsEnabled = true
    private let spareRowLimit = 32
    private let earlier = makeLabel("", font: AppFont.footnote)
    /// The first shown item when earlier items were last asked for, and when; see `loadEarlierIfNear`.
    private var earlierRequest: (firstID: String?, at: Date)?
    /// How far above the viewport, in viewports, earlier items load before the reader gets there.
    private let earlierPrefetch: CGFloat = 2

    /// Space under the last row for the composer and panels that float over the transcript.
    var bottomInset: CGFloat {
        get { geometry.trailingInset }
        set {
            guard geometry.trailingInset != newValue else { return }
            geometry.trailingInset = newValue
            updateFrame()
        }
    }
    private(set) var viewportWidth: CGFloat = 0
    private(set) var viewportOrigin: CGFloat = 0
    private(set) var measurementCount = 0
    var entryCount: Int { entries.count }
    /// Every entry as text, with its frame, for comparing how two updates laid one out.
    var entryDescriptions: [String] { entries.indices.map { "\(entries[$0]) @ \(entryFrame(at: $0))" } }
    var mountedRowCount: Int { mounted.count }
    var retainedRowCount: Int { cache.count }
    var isUpdatingViewport: Bool { updatingViewport }
    var onApproval: ((String, Bool) -> Void)?
    /// Allows a tool for the rest of the conversation, or denies it with a reason.
    var onApprovalChoice: ((String, AgentApprovalChoice) -> Void)?
    var onDisclosure: (() -> Void)?
    var onRunShellCommand: ((String) -> Void)? { didSet { cache.values.forEach { $0.row.onRunShellCommand = onRunShellCommand } } }
    var onOpenAttachment: ((String, AgentChatAttachmentDescriptor, Bool) -> Void)?
    var fetchAttachment: AgentAttachmentCache.Fetch?
    var onHTMLDocument: ((AgentHtmlDocumentCard.Action, AgentHtmlDocumentReference) -> Void)?
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    var onOpenFile: ((String, Int?) -> Void)?
    var workspaceRoot: String?
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onOpenCheckpoint: ((String, String?) -> Void)?
    var onOpenSubagent: ((String) -> Void)?
    var onEditPrompt: ((AgentChatItem) -> Void)?
    var onForkPrompt: ((AgentChatItem) -> Void)?
    var onRevert: ((AgentTurnCheckpoint, [String]?) -> Void)?
    var onRetryCheckpoint: ((String) -> Void)?
    /// What holds the provider up, from the snapshot, for the working line.
    var providerActivity: AgentChatActivity?
    var onShowFullOutput: ((String) -> Void)?
    /// Conversation-wide context menu items, for a click between rows.
    var conversationMenu: (() -> [NSMenuItem])?

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = conversationMenu?(), !items.isEmpty else { return super.menu(for: event) }
        let menu = NSMenu()
        for item in items { menu.addItem(item) }
        return menu
    }
    /// Says why `omittedCount` earlier items aren't shown, in place of the conversation's note.
    var earlierNote: ((Int) -> String)? { didSet { updateEarlierNote() } }
    /// Loads the items above the oldest shown. While set, they load by themselves as the
    /// reader scrolls toward them, so the conversation reads as one with no start cut off.
    var onEarlier: (() -> Void)? {
        didSet {
            guard (oldValue == nil) != (onEarlier == nil) else { return }
            earlierRequest = nil
            updateEarlierNote()
            layoutHeader()
        }
    }
    /// Saves a plan through the conversation's project actions: `(relativePath, contents, cwd)`.
    var writeProjectFile: ((String, String, String?) async throws -> String)?
    var pasteboard: NSPasteboard = .general
    var provider: AgentChatProvider? {
        didSet {
            guard oldValue != provider, !entries.isEmpty else { return }
            built = nil
            update(sourceItems, omittedCount: omittedCount, turns: sourceTurns)
        }
    }
    var onOpenCitation: ((AgentAssistantCitation) -> Void)?
    var onOpenThread: ((AgentThreadLink) -> Void)?
    var linkServices: AgentConversationLinkServices?
    var isNested = false
    /// Capture live state before returning; evicted rows retain only these value records.
    var rowStates: [String: AgentTimelineRowState] {
        get {
            captureStates()
            return savedStates
        }
        set {
            savedStates = newValue
            migrateToolGroupStates()
            for (id, cached) in cache {
                cached.row.restoreState(savedStates[id] ?? AgentTimelineRowState())
                cached.needsMeasurement = true
                cached.needsLayout = true
                heights[id]?.valid = false
            }
            built = nil
            update(sourceItems, omittedCount: omittedCount, turns: sourceTurns)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [earlier] {
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
        }
        layoutHeader()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `unchangedLead` counts leading items known to be those of the last update, which
    /// aren't compared again.
    func update(_ sourceItems: [AgentChatItem], omittedCount: Int, turns: [AgentChatTurn] = [], unchangedLead: Int = 0) {
        self.sourceItems = sourceItems
        sourceTurns = turns
        var anchor = captureAnchor(at: lastViewport.minY)
        captureStates()
        let (items, sourcePositions, reuse) = reusablePrefix(sourceItems, unchangedLead: unchangedLead, turns: turns)
        // Turns are in conversation order, so the rebuilt items' turns are the last ones.
        let tailTurns = reuse.items == 0 ? turns[...]
            : turns.lastIndex(where: { $0.userItemID == items[reuse.items].id }).map { turns[$0...] } ?? turns[...]
        // Copied out, so replacing the tail below doesn't copy every entry.
        let oldTail = Array(entries[reuse.entries...])
        var previous: [String: Entry] = [:]
        var previousOwner: [String: String] = [:]
        for entry in oldTail {
            previous[entry.id] = entry
            for item in entry.items { previousOwner[item.id] = entry.id }
        }
        let grouped = makeEntries(Array(items[reuse.items...]), turns: Array(tailTurns), typedNativeIDs: reuse.typed)
        // A turn that just finished folds its work, unless that would take away what the
        // reader is using: an open row, the keyboard focus or the row the view is anchored
        // to. Folding under the anchor moves it to the summary instead of jumping away.
        let focused = focusedRowID()
        for entry in grouped where entry.kind == .work && savedStates[entry.id] == nil {
            var children: [String: AgentTimelineRowState] = [:]
            var owners: Set<String> = []
            for item in entry.items {
                guard let owner = previousOwner[item.id] else { continue }
                owners.insert(owner)
                if let state = savedStates[owner] { children[owner] = state }
            }
            let inUse = owners.contains { owner in
                let state = savedStates[owner]
                return state?.expanded == true || state?.toolExpandedIDs.isEmpty == false || owner == focused
            }
            let anchored = anchor.rowID.map(owners.contains) ?? false
            if inUse || anchored, previous[entry.id] == nil {
                savedStates[entry.id] = AgentTimelineRowState(expanded: true, children: children)
            } else if !children.isEmpty {
                savedStates[entry.id] = AgentTimelineRowState(children: children)
            }
        }
        // Work history is projected into the same timeline as its answer. Keeping its
        // entries separate gives it the main scrollbar and the normal viewport budget.
        var tailIDs = Set(grouped.map(\.id))
        let tail = grouped.flatMap { entry -> [Entry] in
            guard entry.kind == .work else { return [entry] }
            // Migrate value-only state from the previous nested history renderer.
            for (id, state) in savedStates[entry.id]?.children ?? [:] where savedStates[id] == nil {
                savedStates[id] = state
                migrateToolGroupStates([state])
            }
            // A folded group keeps its rows' state and heights without building its rows,
            // so a long history of folded turns costs one entry each.
            guard savedStates[entry.id]?.expanded == true else {
                for item in entry.items { tailIDs.insert(Self.entryID(for: item)) }
                return [entry]
            }
            let children = makeEntries(entry.items, turns: []).map { child in
                var child = child
                child.groupedWork = true
                child.showsResponseActions = false
                return child
            }
            tailIDs.formUnion(children.map(\.id))
            return [entry] + children
        }
        // An anchor row that folded away moves to the summary that now holds it.
        if let id = anchor.rowID, positions[id].map({ $0 >= reuse.entries }) ?? true, !tail.contains(where: { $0.id == id }),
           let itemID = previous[id]?.items.first?.id,
           let group = tail.first(where: { $0.kind == .work && $0.items.contains { $0.id == itemID } }) {
            anchor = AgentTranscriptAnchor(rowID: group.id, localOffset: 0, fallback: anchor.fallback)
        }
        if reuse.entries == 0 {
            savedStates = savedStates.filter { tailIDs.contains($0.key) }
            heights = heights.filter { tailIDs.contains($0.key) }
        } else {
            // Only the rebuilt rows can have gone; the reused ones keep their state.
            for entry in oldTail {
                let ids = [entry.id] + (entry.kind == .work ? entry.items.map(Self.entryID(for:)) : [])
                for id in ids where !tailIDs.contains(id) {
                    savedStates.removeValue(forKey: id)
                    heights.removeValue(forKey: id)
                }
            }
        }
        for entry in tail {
            if heights[entry.id] == nil { heights[entry.id] = Height(value: estimate(entry)) }
            if previous[entry.id] != entry { heights[entry.id]?.valid = false }
        }
        for entry in oldTail { positions.removeValue(forKey: entry.id) }
        if reuse.entries == 0 { positions.removeAll(keepingCapacity: true) }
        entries.replaceSubrange(reuse.entries..., with: tail)
        rebuiltEntryCount = tail.count
        for index in reuse.entries..<entries.count { positions[entries[index].id] = index }
        for id in Array(cache.keys) where positions[id] == nil { removeCachedRow(id) }
        self.omittedCount = omittedCount
        updateEarlierNote()
        // The row before the rebuilt ones is laid out again too: its spacing depends on the next.
        let first = max(0, reuse.entries - 1)
        geometry.replace(from: first, heights: (first..<entries.count).map { heights[entries[$0].id]?.value ?? 80 },
                         trailingSpaces: (first..<entries.count).map(trailingSpace(at:)))
        recordBuilt(source: sourceItems, items: items, sourcePositions: sourcePositions, turns: turns, tailTurns: tailTurns, reuse: reuse)
        layoutHeader()
        lastViewport.origin.y = offset(for: anchor)
        pendingAnchor = anchor
        reflow(viewportWidth: viewportWidth)
    }

    private func trailingSpace(at index: Int) -> CGFloat {
        let entry = entries[index]
        let next = index + 1 < entries.count ? entries[index + 1] : nil
        if case .card = entry.kind { return entry.groupedWork ? 6 : 14 }
        if entry.groupedWork, entry.kind == .activity {
            return next.map { $0.groupedWork && $0.kind == .activity } == true ? 4 : 6
        }
        if entry.kind == .activity, next?.kind == .activity { return 4 }
        if entry.kind == .working || entry.kind == .work || entry.kind == .activity { return 10 }
        if entry.items.first?.kind == .assistant, next?.kind == .activity { return 8 }
        // A user message already reserves room below it for its hover actions.
        if entry.kind == .message, entry.items.first?.kind == .user { return 10 }
        return 26
    }

    private typealias Reuse = (items: Int, entries: Int, typed: Set<String>)

    /// Approval decisions remain in the authoritative audit snapshot, not the chat, and
    /// a pending question shows only in its form above the composer.
    private static func shows(_ item: AgentChatItem) -> Bool {
        item.kind != .approval || (!item.isComplete && item.questionnaire == nil)
    }

    /// The items to show, where each is among `source`, and how much of the last build
    /// still holds: the items and entries before the turn ahead of the first changed item
    /// or turn, and the typed items among them. A turn's entries depend only on its own
    /// items, except for the newest turn's notes and typed items replacing earlier provider
    /// items, which the step back and the typed check cover.
    private func reusablePrefix(_ source: [AgentChatItem], unchangedLead: Int, turns: [AgentChatTurn])
        -> (items: [AgentChatItem], sourcePositions: [Int], reuse: Reuse) {
        let none: Reuse = (0, 0, [])
        defer { dirtyItemID = nil }
        // Taken out of `built`, so the shown items are edited in place rather than copied.
        guard reusesUnchangedTurns, var last = built, last.provider == provider else {
            built = nil
            var items: [AgentChatItem] = [], positions: [Int] = []
            for (index, item) in source.enumerated() where Self.shows(item) { items.append(item); positions.append(index) }
            return (items, positions, none)
        }
        built = nil
        let shared = min(last.source.count, source.count)
        var changedSource = min(unchangedLead, shared)
        while changedSource < shared, last.source[changedSource] == source[changedSource] { changedSource += 1 }
        // The shown items before the first changed source item, by binary search.
        var low = 0, high = last.sourcePositions.count
        while low < high {
            let middle = (low + high) / 2
            if last.sourcePositions[middle] < changedSource { low = middle + 1 } else { high = middle }
        }
        let kept = low
        last.items.removeSubrange(kept...)
        last.sourcePositions.removeSubrange(kept...)
        for index in changedSource..<source.count where Self.shows(source[index]) {
            last.items.append(source[index])
            last.sourcePositions.append(index)
        }
        let items = last.items, positions = last.sourcePositions
        last.items = []; last.sourcePositions = []
        guard last.segments.count > 1 else { return (items, positions, none) }
        var changed = kept
        var turn = 0
        let sharedTurns = min(last.turns.count, turns.count)
        while turn < sharedTurns, last.turns[turn] == turns[turn] { turn += 1 }
        var touched: [String] = dirtyItemID.map { [$0] } ?? []
        if turn < max(last.turns.count, turns.count) {
            if turn < last.turns.count { touched.append(last.turns[turn].userItemID) }
            if turn < turns.count { touched.append(turns[turn].userItemID) }
        }
        if let newest = last.turns.last?.userItemID, newest != turns.last?.userItemID { touched.append(newest) }
        for id in touched {
            if let index = items[..<changed].lastIndex(where: { $0.id == id }) { changed = index }
        }
        // Step back one more turn: the newest turn's notes move when another starts.
        guard let segment = last.segments.lastIndex(where: { $0.item <= changed }), segment > 0 else {
            return (items, positions, none)
        }
        let start = last.segments[segment - 1]
        guard start.item > 0 else { return (items, positions, none) }
        // A typed item in the rebuilt part that replaces an item before it changes reused rows.
        let tailIDs = Set(items[start.item...].lazy.map(\.id))
        for item in items[start.item...] {
            guard let native = Self.typedNativeID(item.id) else { continue }
            if !tailIDs.contains(native) { return (items, positions, none) }
        }
        built = last
        let typed = Set(last.typed.lazy.filter { $0.item < start.item }.map(\.nativeID))
        return (items, positions, (start.item, start.entry, typed))
    }

    private func recordBuilt(source: [AgentChatItem], items: [AgentChatItem], sourcePositions: [Int], turns: [AgentChatTurn],
                             tailTurns: ArraySlice<AgentChatTurn>, reuse: Reuse) {
        var segments = reuse.items > 0 ? built?.segments ?? [] : []
        var typed = reuse.items > 0 ? built?.typed ?? [] : []
        built = nil
        while let last = segments.last, last.item >= reuse.items { segments.removeLast() }
        while let last = typed.last, last.item >= reuse.items { typed.removeLast() }
        let turnIDs = Set(tailTurns.lazy.map(\.userItemID))
        for index in reuse.items..<items.count {
            let item = items[index]
            if let native = Self.typedNativeID(item.id) { typed.append((index, native)) }
            guard item.kind == .user, turnIDs.contains(item.id), let entry = positions[item.id] else { continue }
            segments.append((index, entry))
        }
        built = Built(source: source, items: items, sourcePositions: sourcePositions, turns: turns,
                      provider: provider, segments: segments, typed: typed)
    }

    /// The provider item a typed todo or plan item stands for, from its ID.
    private static func typedNativeID(_ id: String) -> String? {
        for prefix in ["todo_list:", "proposed_plan:"] where id.hasPrefix(prefix) { return String(id.dropFirst(prefix.count)) }
        return nil
    }

    /// Renders retained rows again after the link services' pull-request hosts changed.
    func linkServicesDidChange() {
        for (id, cached) in cache {
            cached.row.linkServicesDidChange()
            cached.needsMeasurement = true
            cached.needsLayout = true
            heights[id]?.valid = false
        }
    }

    func reflow(viewportWidth: CGFloat) {
        self.viewportWidth = max(0, viewportWidth)
        layoutHeader()
        updateFrame()
        guard !updatingViewport, viewportWidth > 0 else { return }
        var rect = lastViewport
        rect.size.width = viewportWidth
        _ = updateViewport(rect, followingEnd: lastFollowingEnd)
    }

    /// Mount/measure one viewport of overscan on either side. Returns the corrected
    /// total document height; `viewportOrigin` is the corresponding corrected scroll Y.
    @discardableResult
    func updateViewport(_ rect: NSRect, followingEnd: Bool) -> CGFloat {
        guard !updatingViewport else { return frame.height }
        updatingViewport = true
        defer { updatingViewport = false }
        if rect.width > 0 { viewportWidth = rect.width }
        layoutHeader()
        updateFrame()
        let height = max(0, rect.height)
        let anchor = pendingAnchor ?? captureAnchor(at: rect.minY)
        pendingAnchor = nil
        lastFollowingEnd = followingEnd
        var origin = followingEnd ? max(0, geometry.height - height) : clampedOrigin(rect.minY, height: height)
        let focused = focusedRowID()
        var desired: Set<String> = []
        // Each pass either measures at least one previously invalid row or terminates.
        // Geometry corrections can reveal a few more rows; there is no async reflow loop.
        for _ in 0...entries.count {
            let overscan = NSRect(x: 0, y: max(0, origin - height), width: viewportWidth,
                                  height: max(0, origin + 2 * height - max(0, origin - height)))
            let range = geometry.rows(in: overscan)
            desired = Set(range.map { entries[$0].id })
            if let focused { desired.insert(focused) }
            unmount(except: desired)
            var measured = false
            for index in range { measured = prepareRow(at: index) || measured }
            if let focused, let index = positions[focused], !range.contains(index) {
                measured = prepareRow(at: index) || measured
            }
            updateFrame()
            origin = followingEnd ? max(0, geometry.height - height) : clampedOrigin(offset(for: anchor), height: height)
            let correctedOverscan = NSRect(x: 0, y: max(0, origin - height), width: viewportWidth,
                height: max(0, origin + 2 * height - max(0, origin - height)))
            let nextRange = geometry.rows(in: correctedOverscan)
            if nextRange == range || !measured { break }
        }
        mounted = desired
        for id in mounted {
            guard let index = positions[id], let cached = cache[id] else { continue }
            let target = entryFrame(at: index)
            let needsLayout = cached.needsLayout || cached.row.frame.size != target.size
            cached.row.frame = target
            if needsLayout {
                cached.row.layoutRow(width: target.width)
                cached.row.invalidateFindText()
                cached.needsLayout = false
            }
        }
        trimCache()
        viewportOrigin = origin
        lastViewport = NSRect(x: rect.minX, y: origin, width: viewportWidth, height: height)
        loadEarlierIfNear(origin: origin, height: height)
        // Nested scroll surfaces use the same correction path. Suppress recursive
        // viewport work until the corrected geometry and clip origin agree.
        if let clip = superview as? NSClipView, clip.documentView === self {
            clip.scroll(to: NSPoint(x: rect.minX, y: origin))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        onViewportSettled?()
        return frame.height
    }

    /// Called after every viewport pass, once mounted rows are laid out. Nil unless
    /// a decoration such as Find needs to follow mounting, so it costs nothing otherwise.
    var onViewportSettled: (() -> Void)?

    /// Each mounted row that shows a single retained item, with that item's ID.
    func forEachMountedItemRow(_ body: (_ itemID: String, _ row: AgentTimelineRow) -> Void) {
        for id in mounted {
            guard let index = positions[id], let cached = cache[id], cached.row.superview === self,
                  entries[index].kind == .message || entries[index].kind == .activity || entries[index].kind.isCard,
                  let item = entries[index].items.first else { continue }
            body(item.id, cached.row)
        }
    }

    /// The entry that shows `itemID` on its own row; nil while it is folded into a
    /// completed work group or no longer retained.
    func entryID(showing itemID: String) -> String? {
        entries.first { $0.kind != .work && $0.items.contains { $0.id == itemID } }?.id
    }

    /// The mounted row of an entry, if it is mounted.
    func mountedRow(_ entryID: String) -> AgentTimelineRow? {
        guard mounted.contains(entryID), let row = cache[entryID]?.row, row.superview === self else { return nil }
        return row
    }

    /// The mounted row showing `item` as it is now, if any; O(1), for Find's rendered text.
    func mountedRow(showing item: AgentChatItem) -> AgentTimelineRow? {
        let id = item.kind == .tool ? "activity:" + item.id : item.id
        guard mounted.contains(id), let cached = cache[id], cached.row.superview === self,
              cached.rendered?.items.first == item else { return nil }
        return cached.row
    }

    /// Geometry lookup does not instantiate the target row.
    func frameForEntry(_ id: String) -> NSRect? {
        positions[id].map { entryFrame(at: $0) }
    }

    /// The row showing a retained item (`.item`) or a turn's work group (`.turn`, by its
    /// user item), expanding a completed work group so the item has a row to anchor to.
    func anchor(revealing target: AgentTranscriptTarget, offset: CGFloat = 0) -> AgentTranscriptAnchor? {
        switch target {
        case .item(let targetID):
            guard let owner = entries.first(where: { $0.items.contains(where: { $0.id == targetID }) }) else { return nil }
            if owner.kind == .work {
                captureStates()
                var state = savedStates[owner.id] ?? AgentTimelineRowState()
                if state.expanded != true {
                    state.expanded = true
                    savedStates[owner.id] = state
                    if let cached = cache[owner.id] {
                        cached.row.restoreState(state)
                        cached.needsMeasurement = true
                        cached.needsLayout = true
                    }
                    heights[owner.id]?.valid = false
                    dirtyItemID = owner.turn?.userItemID
                    update(sourceItems, omittedCount: omittedCount, turns: sourceTurns)
                }
            }
            guard let entry = entries.first(where: { $0.kind != .work && $0.items.contains(where: { $0.id == targetID }) }) else { return nil }
            return AgentTranscriptAnchor(rowID: entry.id, localOffset: offset, fallback: lastViewport.minY)
        case .turn(let userID):
            let id = positions["work:" + userID] != nil ? "work:" + userID : userID
            guard positions[id] != nil else { return nil }
            return AgentTranscriptAnchor(rowID: id, localOffset: offset, fallback: lastViewport.minY)
        }
    }

    /// The mounted row showing a retained message, if it is in the viewport's overscan.
    func messageRow(for itemID: String) -> AgentMessageRow? {
        guard let entry = entries.first(where: { $0.kind == .message && $0.items.contains(where: { $0.id == itemID }) }),
              mounted.contains(entry.id) else { return nil }
        return cache[entry.id]?.row as? AgentMessageRow
    }

    func captureAnchor(at y: CGFloat) -> AgentTranscriptAnchor {
        guard let index = geometry.index(at: y), entries.indices.contains(index) else {
            return AgentTranscriptAnchor(rowID: nil, localOffset: 0, fallback: y)
        }
        return AgentTranscriptAnchor(rowID: entries[index].id,
                                     localOffset: y - geometry.top(at: index), fallback: y)
    }

    func offset(for anchor: AgentTranscriptAnchor) -> CGFloat {
        guard let id = anchor.rowID, let index = positions[id] else { return anchor.fallback }
        return geometry.top(at: index) + min(anchor.localOffset, geometry.heights[index] + geometry.spacing(at: index) - 1)
    }

    /// Preserve the exact logical anchor across a prepend or width correction,
    /// including when its viewport origin lies in the preceding row's spacing.
    @discardableResult
    func restoreAnchor(_ anchor: AgentTranscriptAnchor, viewport: NSRect, followingEnd: Bool) -> CGFloat {
        pendingAnchor = anchor
        var rect = viewport
        rect.origin.y = offset(for: anchor)
        return updateViewport(rect, followingEnd: followingEnd)
    }

    /// Loads again the mounted rows' attachment previews that failed; rows mounted
    /// later load theirs as they appear.
    func retryFailedAttachments() {
        func visit(_ view: NSView) {
            if let media = view as? AgentMessageMediaView { media.retryFailed(); return }
            if let images = view as? AgentToolImagesView { images.retryFailed(); return }
            view.subviews.forEach(visit)
        }
        subviews.forEach(visit)
    }

    /// Asks for earlier items once the viewport comes within `earlierPrefetch` viewports of
    /// the oldest shown, after this pass, so a page usually lands before the reader sees the
    /// top. A request that brought nothing new is asked again only after a pause, so a
    /// failing server isn't asked on every scroll.
    private func loadEarlierIfNear(origin: CGFloat, height: CGFloat) {
        guard omittedCount > 0, onEarlier != nil, height > 0,
              origin - geometry.leading < earlierPrefetch * height else { return }
        let firstID = sourceItems.first?.id
        if let request = earlierRequest, request.firstID == firstID, Date().timeIntervalSince(request.at) < 5 { return }
        earlierRequest = (firstID, Date())
        Task { @MainActor [weak self] in self?.onEarlier?() }
    }

    private func updateEarlierNote() {
        // Items that load as the reader nears them need no explanation, only a placeholder
        // for the moment before they arrive. Without a way to load them, they are gone from Tab.
        if let earlierNote { earlier.stringValue = earlierNote(omittedCount); return }
        earlier.stringValue = onEarlier != nil ? "Loading earlier messages…"
            : (omittedCount == 1 ? "1 earlier item isn't" : "\(omittedCount) earlier items aren't")
            + " shown, to keep this conversation within its size limit"
    }

    func setApprovalsEnabled(_ enabled: Bool) {
        approvalsEnabled = enabled
        for cached in cache.values { cached.row.setApprovalsEnabled(enabled) }
    }

    override func themeDidChange() {
        themeEpoch &+= 1
        earlier.textColor = theme.fgDim
        reflow(viewportWidth: viewportWidth)
    }

    private var rowWidth: CGFloat { max(1, min(AgentPaneView.readableWidth, viewportWidth - (isNested ? 0 : 40))) }

    private func layoutHeader() {
        let left = floor((viewportWidth - rowWidth) / 2)
        let start: CGFloat = isNested ? 0 : 28
        geometry.leading = start + (omittedCount > 0 ? 30 : 0)
        earlier.isHidden = omittedCount == 0
        earlier.frame = NSRect(x: left, y: start, width: rowWidth, height: 18)
    }

    private func updateFrame() {
        let size = NSSize(width: max(0, viewportWidth), height: geometry.height)
        if frame.size != size { frame.size = size }
    }

    /// User bubbles align to the right of the lane; every other row shares the
    /// assistant width, including cards and rows revealed by disclosures.
    private func entryWidth(at index: Int) -> CGFloat {
        if entries[index].kind == .message, entries[index].items.first?.kind == .user { return rowWidth }
        return isNested ? rowWidth : AgentMessageRow.responseWidth(rowWidth)
    }

    private func entryFrame(at index: Int) -> NSRect {
        NSRect(x: floor((viewportWidth - rowWidth) / 2), y: geometry.top(at: index),
               width: entryWidth(at: index), height: geometry.heights[index])
    }

    private func clampedOrigin(_ y: CGFloat, height: CGFloat) -> CGFloat {
        min(max(0, geometry.height - height), max(0, y))
    }

    @discardableResult
    private func prepareRow(at index: Int) -> Bool {
        let entry = entries[index]
        if let old = cache[entry.id], old.kind != entry.kind { removeCachedRow(entry.id) }
        let cached: CachedRow
        var fresh = false
        if let existing = cache[entry.id] { cached = existing }
        else {
            let row: AgentTimelineRow
            switch entry.kind {
            case .message: row = AgentMessageRow()
            case .activity: row = AgentActivityRow()
            case .work: row = AgentCompletedWorkRow()
            case .working: row = AgentWorkingRow()
            case .changes: row = AgentChangedFilesRow()
            case .card(let card): row = AgentCardRow.make(card)
            }
            cached = CachedRow(row: row, kind: entry.kind)
            cache[entry.id] = cached
            fresh = true
            let id = entry.id
            row.onDisclosure = { [weak self, weak row] in
                guard let self, let row else { return }
                self.savedStates[id] = row.captureState()
                self.heights[id]?.valid = false
                self.cache[id]?.needsMeasurement = true
                self.cache[id]?.needsLayout = true
                guard !self.updatingViewport else { return }
                if row is AgentCompletedWorkRow {
                    self.lastFollowingEnd = false
                    self.dirtyItemID = self.positions[id].flatMap { self.entries[$0].turn?.userItemID }
                    self.update(self.sourceItems, omittedCount: self.omittedCount, turns: self.sourceTurns)
                }
                if let onDisclosure = self.onDisclosure { onDisclosure() }
                else { self.reflow(viewportWidth: self.viewportWidth) }
            }
            row.onApproval = { [weak self] id, allow in self?.onApproval?(id, allow) }
            row.onApprovalChoice = { [weak self] id, choice in self?.onApprovalChoice?(id, choice) }
            row.workspaceRoot = workspaceRoot
            row.onOpenToolDiff = { [weak self] id, activity in self?.onOpenToolDiff?(id, activity) }
            row.onOpenCheckpoint = { [weak self] id, path in self?.onOpenCheckpoint?(id, path) }
            if onOpenSubagent != nil { row.onOpenSubagent = { [weak self] id in self?.onOpenSubagent?(id) } }
            if onEditPrompt != nil, entry.kind == .message { row.onEditPrompt = { [weak self] item in self?.onEditPrompt?(item) } }
            if onForkPrompt != nil, entry.kind == .message { row.onForkPrompt = { [weak self] item in self?.onForkPrompt?(item) } }
            if onRevert != nil { row.onRevert = { [weak self] checkpoint, paths in self?.onRevert?(checkpoint, paths) } }
            if onRetryCheckpoint != nil { row.onRetryCheckpoint = { [weak self] turn in self?.onRetryCheckpoint?(turn) } }
            if onShowFullOutput != nil { row.onShowFullOutput = { [weak self] id in self?.onShowFullOutput?(id) } }
            row.onOpenAttachment = onOpenAttachment
            row.fetchAttachment = fetchAttachment
            row.onHTMLDocument = onHTMLDocument
            row.onPreviewAttachments = onPreviewAttachments
            row.onRunShellCommand = onRunShellCommand
            row.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
            row.onOpenCitation = { [weak self] citation in self?.onOpenCitation?(citation) }
            row.onOpenThread = { [weak self] link in self?.onOpenThread?(link) }
            row.linkServices = linkServices
        }
        let row = cached.row
        if cached.epoch != themeEpoch || row.theme !== theme {
            if row.theme !== theme { row.theme = theme }
            row.themeDidChange()
            cached.epoch = themeEpoch
            cached.needsMeasurement = true
        }
        if cached.rendered != entry {
            if let activity = row as? AgentActivityRow { activity.grouped = entry.groupedWork }
            if let work = row as? AgentCompletedWorkRow { work.turn = entry.turn; work.duration = entry.duration }
            if let working = row as? AgentWorkingRow { working.turn = entry.turn; working.activity = entry.activity }
            if let message = row as? AgentMessageRow {
                // Claude resumes at any message; Codex forks only whole threads.
                message.forkable = entry.provider == .claude
                message.alwaysAllowable = entry.provider == .claude
                message.showsResponseActions = entry.showsResponseActions
                message.turnID = entry.turn?.userItemID
                message.checkpointPhase = entry.turn?.reviewPhase ?? .unknown
                message.checkpoint = entry.turn?.checkpoint
                message.duration = entry.duration
                message.usage = entry.usage
            }
            if let changes = row as? AgentChangedFilesRow {
                changes.turnID = entry.turn?.userItemID
                changes.phase = entry.turn?.reviewPhase ?? .unknown
                changes.checkpoint = entry.turn?.checkpoint
            }
            if let compaction = row as? AgentCompactionRow { compaction.provider = entry.provider }
            row.update(entry.items)
            row.invalidateFindText()
            row.setTimestamp(entry.timestamp)
            cached.rendered = entry
            cached.needsMeasurement = true
            cached.needsLayout = true
        }
        if let plan = row as? AgentPlanCardRow {
            plan.services.writeProjectFile = writeProjectFile
            plan.services.pasteboard = pasteboard
            plan.services.cwd = workspaceRoot
        }
        if fresh, let state = savedStates[entry.id] { row.restoreState(state) }
        row.setApprovalsEnabled(approvalsEnabled)
        if row.superview == nil { addSubview(row) }
        mounted.insert(entry.id)
        useSequence &+= 1
        cached.lastUse = useSequence
        let old = heights[entry.id]
        let width = entryWidth(at: index)
        guard cached.needsMeasurement || old?.valid != true || old?.width != width || old?.epoch != themeEpoch else { return false }
        let height = max(1, row.preferredHeight(for: width))
        row.invalidateFindText()
        measurementCount += 1
        heights[entry.id] = Height(value: height, width: width, epoch: themeEpoch, valid: true)
        geometry.setHeight(height, at: index)
        cached.needsMeasurement = false
        cached.needsLayout = true
        return true
    }

    private func captureStates() {
        for (id, cached) in cache { savedStates[id] = cached.row.captureState() }
    }

    private func migrateToolGroupStates() { migrateToolGroupStates(Array(savedStates.values)) }

    private func migrateToolGroupStates(_ states: [AgentTimelineRowState]) {
        // Earlier versions stored all consecutive tools under the first tool's ID.
        // Split that value state before those entries are independently restored.
        for state in states {
            for id in state.toolExpandedIDs where savedStates["activity:" + id] == nil {
                savedStates["activity:" + id] = AgentTimelineRowState(toolExpandedIDs: [id])
            }
        }
    }

    private func focusedRowID() -> String? {
        guard let responder = window?.firstResponder as? NSView else { return nil }
        return cache.first { responder === $0.value.row || responder.isDescendant(of: $0.value.row) }?.key
    }

    private func unmount(except retained: Set<String>) {
        for id in mounted.subtracting(retained) {
            guard let cached = cache[id] else { continue }
            savedStates[id] = cached.row.captureState()
            cached.row.removeFromSuperview()
            // A work/tool row can own another virtualized scroll surface. Do not
            // multiply the spare-view budget by retaining its entire child cache.
            if !cached.kind.retainedWhenUnmounted { removeCachedRow(id) }
        }
        mounted.formIntersection(retained)
        trimCache()
    }

    private func removeCachedRow(_ id: String) {
        guard let cached = cache.removeValue(forKey: id) else { return }
        savedStates[id] = cached.row.captureState()
        cached.row.removeFromSuperview()
        mounted.remove(id)
    }

    private func trimCache() {
        let spares = cache.filter { !mounted.contains($0.key) }.sorted { $0.value.lastUse < $1.value.lastUse }
        for (id, _) in spares.prefix(max(0, spares.count - spareRowLimit)) { removeCachedRow(id) }
    }

    private func estimate(_ entry: Entry) -> CGFloat {
        if entry.kind == .activity { return entry.groupedWork ? 24 : 28 }
        if case .card(let card) = entry.kind { return card == .compaction || card == .notice ? 28 : 120 }
        if entry.kind != .message { return 24 }
        guard let item = entry.items.first else { return 40 }
        let lines = min(40, max(1, item.text.utf16.count / 70 + item.text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }))
        switch item.kind {
        case .user: return min(260, CGFloat(lines) * 24 + 50)
        case .assistant: return CGFloat(lines) * 24 + 28
        case .approval: return CGFloat(lines) * 24 + 100
        default: return CGFloat(lines) * 24
        }
    }

    /// The ID of the entry that shows `item` on its own row.
    private static func entryID(for item: AgentChatItem) -> String {
        item.kind == .tool ? "activity:" + item.id : item.id
    }

    /// `typedNativeIDs` are the provider items typed items before `items` replace.
    private func makeEntries(_ items: [AgentChatItem], turns: [AgentChatTurn], typedNativeIDs earlierTyped: Set<String> = []) -> [Entry] {
        var userEnds: [String: Int] = [:]
        var answers: [String: Int] = [:]
        var nextUser = items.endIndex
        var lastAssistant: Int?
        for index in items.indices.reversed() {
            if items[index].kind == .user {
                userEnds[items[index].id] = nextUser
                answers[items[index].id] = lastAssistant ?? nextUser
                nextUser = index
                lastAssistant = nil
            } else if items[index].kind == .assistant, lastAssistant == nil {
                lastAssistant = index
            }
        }
        let itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        var toolCounts = [0]
        var approvalCounts = [0]
        for item in items {
            toolCounts.append((toolCounts.last ?? 0) + (item.kind == .tool ? 1 : 0))
            approvalCounts.append((approvalCounts.last ?? 0) + (item.kind == .approval && !item.isComplete ? 1 : 0))
        }
        // Messages sent while the agent works join its turn, so a turn's answer is its
        // last one before the next turn starts, not before the next user message.
        let turnIDs = Set(turns.map(\.userItemID))
        var turnAnswers: [String: Int] = [:]
        var lastTurnAnswer: Int?
        for index in items.indices.reversed() {
            if items[index].kind == .assistant, lastTurnAnswer == nil { lastTurnAnswer = index }
            guard items[index].kind == .user, turnIDs.contains(items[index].id) else { continue }
            if let lastTurnAnswer { turnAnswers[items[index].id] = lastTurnAnswer }
            lastTurnAnswer = nil
        }
        var timestamps: [String: Date] = [:]
        var durations: [String: TimeInterval] = [:]
        var usages: [String: AgentTurnUsage] = [:]
        var groups: [Int: (AgentChatTurn, Int)] = [:]
        for turn in turns {
            timestamps[turn.userItemID] = turn.startedAt
            guard let endDate = turn.completedAt, let start = itemIndices[turn.userItemID],
                  let answer = answers[turn.userItemID] else { continue }
            if let turnAnswer = turnAnswers[turn.userItemID] {
                timestamps[items[turnAnswer].id] = endDate
                durations[items[turnAnswer].id] = turn.workingTime(at: endDate)
                usages[items[turnAnswer].id] = turn.usage
            }
            guard answer > start + 1, toolCounts[answer] > toolCounts[start + 1],
                  approvalCounts[answer] == approvalCounts[start + 1] else { continue }
            groups[start + 1] = (turn, answer)
        }
        let runningUserIDs = Set(turns.filter { $0.completedAt == nil }.map(\.userItemID))
        var currentTurnIsRunning = false
        // Each turn shows its newest todo list as a card; earlier updates are one line each.
        // A provider's raw tool row for a todo or plan its typed card already shows is hidden.
        var newestTodos: Set<String> = []
        var typedNativeIDs = earlierTyped
        var segmentTodo: String?
        for item in items {
            if item.kind == .user {
                if let todo = segmentTodo { newestTodos.insert(todo) }
                segmentTodo = nil
            } else if item.kind == .tool, item.workContext?.itemType == "todo_list" {
                segmentTodo = item.id
            }
            if let native = Self.typedNativeID(item.id) { typedNativeIDs.insert(native) }
        }
        if let todo = segmentTodo { newestTodos.insert(todo) }
        func shadowed(_ item: AgentChatItem) -> Bool {
            item.kind == .tool && typedNativeIDs.contains(item.id)
                && item.tool?.name.map({ ["TodoWrite", "ExitPlanMode"].contains($0) }) == true
        }
        func entry(for item: AgentChatItem) -> Entry {
            // A turn the agent began itself, or a report from an agent it started, opens with a note, not a message from the user.
            var card = item.isAutomaticTurn ? .notice : classifier.classify(item)
            if card == .todo, !newestTodos.contains(item.id) { card = nil }
            return Entry(id: Self.entryID(for: item),
                         kind: card.map { .card($0) } ?? (item.kind == .tool ? .activity : .message),
                         items: [item], timestamp: timestamps[item.id], duration: durations[item.id],
                         showsResponseActions: !currentTurnIsRunning,
                         provider: card == .compaction || (card == nil && (item.kind == .user || item.kind == .approval)) ? provider : nil,
                         usage: usages[item.id])
        }
        var result: [Entry] = []
        var index = 0
        while index < items.endIndex {
            let item = items[index]
            if item.kind == .user { currentTurnIsRunning = runningUserIDs.contains(item.id) }
            if let (turn, end) = groups[index] {
                // Failures stay visible below the fold; every other card folds like a tool.
                let work = items[index..<end]
                // The turn's newest proposed plan stays visible below its summary, like a failure.
                let plan = work.last { classifier.classify($0) == .plan }?.id
                let visible = { (item: AgentChatItem) in self.classifier.classify(item)?.folds == false || item.id == plan }
                let folded = work.filter { !visible($0) && !shadowed($0) }
                let unanswered = turnAnswers[turn.userItemID] == nil
                result.append(Entry(id: "work:" + turn.userItemID, kind: .work, items: folded, turn: turn,
                                    duration: unanswered ? turn.completedAt.map { turn.workingTime(at: $0) } : nil))
                result.append(contentsOf: work.filter(visible).map(entry(for:)))
                index = end
                continue
            }
            if !shadowed(item) { result.append(entry(for: item)) }
            index += 1
        }
        // Only the newest turn can still be running, and its timer is always the
        // conversation's last row, below messages sent while it works.
        if let turn = turns.last, turn.completedAt == nil, itemIndices[turn.userItemID] != nil {
            result.append(Entry(id: "working:" + turn.userItemID, kind: .working, items: [], turn: turn,
                                activity: AgentWorkingRow.describe(providerActivity)))
        }
        var foundAnswer = false
        for position in result.indices.reversed() {
            if result[position].items.first?.kind == .user { foundAnswer = false }
            if result[position].kind == .message, result[position].items.first?.kind == .assistant {
                result[position].showsResponseActions = result[position].showsResponseActions && !foundAnswer && !isNested
                foundAnswer = true
            }
        }
        guard !isNested else { return result }
        var owners: [String: String] = [:]
        for entry in result { for item in entry.items { owners[item.id] = entry.id } }
        var cards: [String: AgentChatTurn] = [:]
        // A folder outside Git says so once, on its latest turn, rather than on every answer.
        for turn in turns where turn.reviewPhase.showsCard {
            if case .untracked = turn.reviewPhase, turn.userItemID != turns.last?.userItemID { continue }
            guard let end = userEnds[turn.userItemID], let answer = answers[turn.userItemID],
                  let start = itemIndices[turn.userItemID], end > start + 1 else { continue }
            let target = answer < end ? answer : end - 1
            if let owner = owners[items[target].id] { cards[owner] = turn }
        }
        return result.flatMap { entry -> [Entry] in
            guard let turn = cards[entry.id] else { return [entry] }
            if entry.kind == .message, entry.items.first?.kind == .assistant {
                var answer = entry
                answer.turn = turn
                return [answer]
            }
            return [entry, Entry(id: "changes:" + turn.userItemID, kind: .changes, items: [], turn: turn)]
        }
    }
}
