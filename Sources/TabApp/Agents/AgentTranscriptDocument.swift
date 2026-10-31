import AppKit
import TabProtocol

/// Estimated whole-transcript geometry with native rows mounted only around the viewport.
/// Snapshot grouping is O(n); native text layout is confined to changed/visible rows.
@MainActor
final class AgentTranscriptDocument: ThemedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        AgentTableCopyHitTesting.hitTest(point, in: self) ?? super.hitTest(point)
    }

    private enum Kind: Equatable { case message, activity, work, working, changes }
    private struct Entry: Equatable {
        var id: String
        var kind: Kind
        var items: [AgentChatItem]
        var turn: AgentChatTurn? = nil
        var timestamp: Date? = nil
        var groupedWork = false
        var showsResponseActions = true
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
    private var approvalsEnabled = true
    private let spareRowLimit = 32
    private let emptyTitle = makeLabel("What can I help with?", font: AppFont.system(21, weight: .medium))
    private let emptyDetail = makeLabel("Ask a question or make something new.", font: AppFont.body)
    private let earlier = makeLabel("", font: AppFont.footnote)
    private let showEarlier = PillButton("Show earlier messages", style: .plain)

    private(set) var viewportWidth: CGFloat = 0
    private(set) var viewportOrigin: CGFloat = 0
    private(set) var measurementCount = 0
    var entryCount: Int { entries.count }
    var mountedRowCount: Int { mounted.count }
    var retainedRowCount: Int { cache.count }
    var isUpdatingViewport: Bool { updatingViewport }
    var onApproval: ((String, Bool) -> Void)?
    var onDisclosure: (() -> Void)?
    var onRunShellCommand: ((String) -> Void)? { didSet { cache.values.forEach { $0.row.onRunShellCommand = onRunShellCommand } } }
    var onOpenAttachment: ((String, AgentChatAttachmentDescriptor, Bool) -> Void)?
    var fetchAttachment: AgentAttachmentCache.Fetch?
    var onPreviewAttachments: ((String, [AgentChatAttachmentDescriptor], Int) -> Void)?
    var onOpenFile: ((String, Int?) -> Void)?
    var workspaceRoot: String?
    var onOpenToolDiff: ((String, AgentToolActivity) -> Void)?
    var onOpenCheckpoint: ((String, String?) -> Void)?
    var onEarlier: (() -> Void)?
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
            update(sourceItems, omittedCount: omittedCount, turns: sourceTurns)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for label in [emptyTitle, emptyDetail, earlier] {
            label.translatesAutoresizingMaskIntoConstraints = true
            addSubview(label)
        }
        emptyTitle.alignment = .center
        emptyDetail.alignment = .center
        showEarlier.translatesAutoresizingMaskIntoConstraints = true
        showEarlier.onPress = { [weak self] in self?.onEarlier?() }
        addSubview(showEarlier)
        layoutHeader()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ sourceItems: [AgentChatItem], omittedCount: Int, turns: [AgentChatTurn] = []) {
        self.sourceItems = sourceItems
        sourceTurns = turns
        // Approval decisions remain in the authoritative audit snapshot, not the chat.
        let items = sourceItems.filter { $0.kind != .approval || !$0.isComplete }
        let anchor = captureAnchor(at: lastViewport.minY)
        captureStates()
        migrateToolGroupStates()
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let grouped = makeEntries(items, turns: turns)
        // Work history is projected into the same timeline as its answer. Keeping its
        // entries separate gives it the main scrollbar and the normal viewport budget.
        var allIDs = Set(grouped.map(\.id))
        let next = grouped.flatMap { entry -> [Entry] in
            guard entry.kind == .work else { return [entry] }
            let children = makeEntries(entry.items, turns: []).map { child in
                var child = child
                child.groupedWork = true
                child.showsResponseActions = false
                return child
            }
            allIDs.formUnion(children.map(\.id))
            // Migrate value-only state from the previous nested history renderer.
            for (id, state) in savedStates[entry.id]?.children ?? [:] where savedStates[id] == nil {
                savedStates[id] = state
            }
            return savedStates[entry.id]?.expanded == true ? [entry] + children : [entry]
        }
        // A newly folded work group inherits the disclosure states of its former rows.
        var previousOwner: [String: String] = [:]
        for entry in entries { for item in entry.items { previousOwner[item.id] = entry.id } }
        for entry in next where entry.kind == .work && savedStates[entry.id] == nil {
            var children: [String: AgentTimelineRowState] = [:]
            for item in entry.items {
                if let owner = previousOwner[item.id], let state = savedStates[owner] { children[owner] = state }
            }
            if !children.isEmpty { savedStates[entry.id] = AgentTimelineRowState(children: children) }
        }
        let retained = Set(next.map(\.id))
        for id in Array(cache.keys) where !retained.contains(id) { removeCachedRow(id) }
        savedStates = savedStates.filter { allIDs.contains($0.key) }
        heights = heights.filter { allIDs.contains($0.key) }
        for entry in next {
            if heights[entry.id] == nil { heights[entry.id] = Height(value: estimate(entry)) }
            if previous[entry.id] != entry { heights[entry.id]?.valid = false }
        }
        entries = next
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        self.omittedCount = omittedCount
        earlier.stringValue = "Earlier messages are saved · Showing \(items.count) retained entries"
        geometry.reset(heights: entries.map { heights[$0.id]?.value ?? 80 },
                       trailingSpaces: entries.enumerated().map { index, entry in
            if entry.groupedWork, entry.kind == .activity {
                return index + 1 < entries.count && entries[index + 1].groupedWork && entries[index + 1].kind == .activity ? 0 : 4
            }
            if entry.kind == .working || entry.kind == .work || entry.kind == .activity { return 8 }
            if entry.items.first?.kind == .assistant, index + 1 < entries.count,
               entries[index + 1].kind == .activity { return 8 }
            return 26
        })
        layoutHeader()
        lastViewport.origin.y = offset(for: anchor)
        pendingAnchor = anchor
        reflow(viewportWidth: viewportWidth)
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
            if needsLayout { cached.row.layoutRow(width: rowWidth); cached.needsLayout = false }
        }
        trimCache()
        viewportOrigin = origin
        lastViewport = NSRect(x: rect.minX, y: origin, width: viewportWidth, height: height)
        // Nested scroll surfaces use the same correction path. Suppress recursive
        // viewport work until the corrected geometry and clip origin agree.
        if let clip = superview as? NSClipView, clip.documentView === self {
            clip.scroll(to: NSPoint(x: rect.minX, y: origin))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        return frame.height
    }

    /// Geometry lookup does not instantiate the target row.
    func frameForEntry(_ id: String) -> NSRect? {
        positions[id].map { entryFrame(at: $0) }
    }

    func resolveConversationAnchor(_ source: AgentConversationAnchor) -> AgentTranscriptAnchor? {
        let targetID = source.messageID ?? source.itemID
        if let targetID, let owner = entries.first(where: { $0.items.contains(where: { $0.id == targetID }) }) {
            if owner.kind == .work {
                // Source can be reading an item inside an expanded completed
                // group. Reveal the corresponding native rows before anchoring.
                var states = rowStates
                var state = states[owner.id] ?? AgentTimelineRowState()
                state.expanded = true
                states[owner.id] = state
                rowStates = states
            }
            if let entry = entries.first(where: { $0.kind != .work && $0.items.contains(where: { $0.id == targetID }) }) {
                return AgentTranscriptAnchor(rowID: entry.id, localOffset: source.offset, fallback: lastViewport.minY)
            }
        }
        if let runID = source.runID, runID.hasPrefix("native-turn:") {
            let userID = String(runID.dropFirst("native-turn:".count))
            let id = positions["work:" + userID] != nil ? "work:" + userID : userID
            if positions[id] != nil { return AgentTranscriptAnchor(rowID: id, localOffset: source.offset, fallback: lastViewport.minY) }
        }
        return nil
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

    func setApprovalsEnabled(_ enabled: Bool) {
        approvalsEnabled = enabled
        for cached in cache.values { cached.row.setApprovalsEnabled(enabled) }
    }

    override func themeDidChange() {
        themeEpoch &+= 1
        emptyTitle.textColor = theme.fg
        emptyDetail.textColor = theme.fgDim
        earlier.textColor = theme.fgDim
        showEarlier.setTitleColor(theme.fgMuted)
        reflow(viewportWidth: viewportWidth)
    }

    private var rowWidth: CGFloat { max(1, min(AgentPaneView.readableWidth, viewportWidth - (isNested ? 0 : 40))) }

    private func layoutHeader() {
        let left = floor((viewportWidth - rowWidth) / 2)
        let start: CGFloat = isNested ? 0 : 28
        geometry.leading = start + (omittedCount > 0 ? 66 : 0)
        earlier.isHidden = omittedCount == 0
        showEarlier.isHidden = omittedCount == 0
        earlier.frame = NSRect(x: left, y: start, width: rowWidth, height: 18)
        showEarlier.frame = NSRect(x: left - 4, y: start + 22, width: min(rowWidth, 180), height: 26)
        emptyTitle.isHidden = !entries.isEmpty
        emptyDetail.isHidden = !entries.isEmpty
        emptyTitle.frame = NSRect(x: left, y: 88, width: rowWidth, height: 30)
        emptyDetail.frame = NSRect(x: left, y: 128, width: rowWidth, height: 42)
    }

    private func updateFrame() {
        let size = NSSize(width: max(0, viewportWidth), height: geometry.height)
        if frame.size != size { frame.size = size }
    }

    private func entryFrame(at index: Int) -> NSRect {
        NSRect(x: floor((viewportWidth - rowWidth) / 2), y: geometry.top(at: index),
               width: rowWidth, height: geometry.heights[index])
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
                    self.update(self.sourceItems, omittedCount: self.omittedCount, turns: self.sourceTurns)
                }
                if let onDisclosure = self.onDisclosure { onDisclosure() }
                else { self.reflow(viewportWidth: self.viewportWidth) }
            }
            row.onApproval = { [weak self] id, allow in self?.onApproval?(id, allow) }
            row.workspaceRoot = workspaceRoot
            row.onOpenToolDiff = { [weak self] id, activity in self?.onOpenToolDiff?(id, activity) }
            row.onOpenCheckpoint = { [weak self] id, path in self?.onOpenCheckpoint?(id, path) }
            row.onOpenAttachment = onOpenAttachment
            row.fetchAttachment = fetchAttachment
            row.onPreviewAttachments = onPreviewAttachments
            row.onRunShellCommand = onRunShellCommand
            row.onOpenFile = { [weak self] path, line in self?.onOpenFile?(path, line) }
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
            if let work = row as? AgentCompletedWorkRow { work.turn = entry.turn }
            if let working = row as? AgentWorkingRow { working.turn = entry.turn }
            if let message = row as? AgentMessageRow {
                message.showsResponseActions = entry.showsResponseActions
                message.checkpoint = entry.turn?.checkpoint
            }
            if let changes = row as? AgentChangedFilesRow { changes.checkpoint = entry.turn?.checkpoint }
            row.update(entry.items)
            row.setTimestamp(entry.timestamp)
            cached.rendered = entry
            cached.needsMeasurement = true
            cached.needsLayout = true
        }
        if fresh, let state = savedStates[entry.id] { row.restoreState(state) }
        row.setApprovalsEnabled(approvalsEnabled)
        if row.superview == nil { addSubview(row) }
        mounted.insert(entry.id)
        useSequence &+= 1
        cached.lastUse = useSequence
        let old = heights[entry.id]
        guard cached.needsMeasurement || old?.valid != true || old?.width != rowWidth || old?.epoch != themeEpoch else { return false }
        let height = max(1, row.preferredHeight(for: rowWidth))
        measurementCount += 1
        heights[entry.id] = Height(value: height, width: rowWidth, epoch: themeEpoch, valid: true)
        geometry.setHeight(height, at: index)
        cached.needsMeasurement = false
        cached.needsLayout = true
        return true
    }

    private func captureStates() {
        for (id, cached) in cache { savedStates[id] = cached.row.captureState() }
    }

    private func migrateToolGroupStates() {
        // Earlier versions stored all consecutive tools under the first tool's ID.
        // Split that value state before those entries are independently restored.
        for state in Array(savedStates.values) {
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
            if cached.kind != .message { removeCachedRow(id) }
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

    private func makeEntries(_ items: [AgentChatItem], turns: [AgentChatTurn]) -> [Entry] {
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
        var timestamps: [String: Date] = [:]
        var groups: [Int: (AgentChatTurn, Int)] = [:]
        for turn in turns {
            timestamps[turn.userItemID] = turn.startedAt
            guard let endDate = turn.completedAt, let start = itemIndices[turn.userItemID],
                  let end = userEnds[turn.userItemID], let answer = answers[turn.userItemID] else { continue }
            if answer < end { timestamps[items[answer].id] = endDate }
            guard answer > start + 1, toolCounts[answer] > toolCounts[start + 1],
                  approvalCounts[answer] == approvalCounts[start + 1] else { continue }
            groups[start + 1] = (turn, answer)
        }
        var result: [Entry] = []
        let activeTurns = Dictionary(turns.filter { $0.completedAt == nil }.map { ($0.userItemID, $0) }, uniquingKeysWith: { _, last in last })
        var index = 0
        while index < items.endIndex {
            let item = items[index]
            if let (turn, end) = groups[index] {
                result.append(Entry(id: "work:" + turn.userItemID, kind: .work,
                                    items: Array(items[index..<end]), turn: turn))
                index = end
                continue
            } else {
                result.append(Entry(id: item.kind == .tool ? "activity:" + item.id : item.id,
                                    kind: item.kind == .tool ? .activity : .message,
                                    items: [item], timestamp: timestamps[item.id]))
            }
            if let turn = activeTurns[item.id] {
                result.append(Entry(id: "working:" + item.id, kind: .working, items: [], turn: turn))
            }
            index += 1
        }
        var foundAnswer = false
        for position in result.indices.reversed() {
            if result[position].items.first?.kind == .user { foundAnswer = false }
            if result[position].kind == .message, result[position].items.first?.kind == .assistant {
                result[position].showsResponseActions = !foundAnswer && !isNested
                foundAnswer = true
            }
        }
        guard !isNested else { return result }
        var owners: [String: String] = [:]
        for entry in result { for item in entry.items { owners[item.id] = entry.id } }
        var cards: [String: AgentChatTurn] = [:]
        for turn in turns where turn.checkpoint?.totalFiles ?? 0 > 0 {
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
