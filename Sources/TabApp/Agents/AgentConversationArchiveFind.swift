import AppKit
import TabClient
import TabProtocol

/// What conversation Find knows of the server's archive, the items the conversation
/// dropped past its size limit, for the current query: the archived candidates found so
/// far, and how much of the conversation the search covered.
struct AgentConversationArchiveFind: Equatable {
    enum State: Equatable {
        /// Nothing is archived beyond what the pane shows, or there's no query.
        case idle
        case searching
        case complete
        /// The search found `maximumCandidates` and stopped there.
        case limited
        /// The search stopped before the archive's start, such as on a reconnect.
        case cancelled
        case failed(String)
        /// The server predates archive search.
        case unsupported
    }

    /// Archived candidates a search keeps before it stops; refining the query finds the rest.
    static let maximumCandidates = 2000

    var query = ""
    var state = State.idle
    /// Archived items that may match, oldest first, not among those the pane shows.
    var items: [AgentChatItem] = []
    /// Each candidate's archive position.
    var positions: [String: Int] = [:]
    /// Archived items scanned so far, and how many the archive holds.
    var scanned = 0
    var archived = 0
    /// Older items the server didn't keep, which nothing can search.
    var notKept = 0

    /// What the counter adds to "3 of 12" while the search doesn't cover everything.
    var counterSuffix: String {
        switch state {
        case .idle: return ""
        case .searching: return " · searching"
        case .complete: return notKept > 0 ? " · partial" : ""
        case .limited: return " · partial"
        case .cancelled, .failed, .unsupported: return " · loaded only"
        }
    }

    /// The search's scope in a sentence, for the bar's help and VoiceOver.
    var scope: String? {
        let earlier = archived == 1 ? "1 earlier message" : "\(archived) earlier messages"
        let lost = notKept == 0 ? "" : " \(notKept == 1 ? "1 older message wasn't" : "\(notKept) older messages weren't") kept by the server, so it wasn't searched."
        switch state {
        case .idle: return nil
        case .searching: return "Searching \(earlier) on the server (\(scanned) so far)."
        case .complete: return "Searched every loaded message and \(earlier) on the server." + lost
        case .limited:
            return "Stopped after \(Self.maximumCandidates) earlier messages that may match, \(scanned) of \(earlier) searched. Refine the search to find the rest."
        case .cancelled: return "Searched only the loaded messages and \(scanned) of \(earlier); the search of earlier messages stopped." + lost
        case .failed(let message): return "Searched only the loaded messages; searching earlier messages failed: \(message)"
        case .unsupported: return "Searched only the loaded messages. This server can't search earlier messages; update Tab on it, then restart it."
        }
    }
}

extension AgentPaneView {
    /// The items Find searches: archived candidates the pane doesn't show, oldest first,
    /// then the shown ones.
    var findItems: [AgentChatItem] {
        let shown = snapshot?.items ?? []
        guard !archiveFind.items.isEmpty else { return shown }
        let ids = Set(shown.map(\.id))
        return archiveFind.items.filter { !ids.contains($0.id) } + shown
    }

    /// The archive search found more, or its scope changed: rematch without moving the reader.
    func findArchiveDidChange() {
        guard var model = findModel else { return }
        model.update(findItems)
        findModel = model
        showFindCounter()
        paintFindMatches()
    }

    /// The counter, with the search's scope where it doesn't cover the whole conversation.
    func showFindCounter() {
        guard let model = findModel else { return }
        findBar?.counter = model.query.isEmpty ? "" : model.counter + archiveFind.counterSuffix
        findBar?.scope = model.query.isEmpty ? nil : archiveFind.scope
    }

    /// Whether `itemID` is an archived match the pane doesn't show yet.
    func isArchivedFindItem(_ itemID: String) -> Bool {
        archiveFind.positions[itemID] != nil && !(snapshot?.items.contains { $0.id == itemID } ?? false)
    }
}

extension AgentPaneController {
    /// Connects Find to the server's archive through `conversationRequest`.
    func connectArchiveFind() {
        guard conversationRequest != nil else {
            surface.onFindQueryChange = nil
            surface.onRevealArchivedFind = nil
            return
        }
        surface.onFindQueryChange = { [weak self] query in self?.searchArchive(query) }
        surface.onRevealArchivedFind = { [weak self] itemID in self?.revealArchived(itemID) }
    }

    /// Stops the archive search; `state` says how far it got.
    func cancelArchiveSearch(_ state: AgentConversationArchiveFind.State? = .cancelled) {
        archiveSearchTask?.cancel()
        archiveSearchTask = nil
        archiveRevealTask?.cancel()
        archiveRevealTask = nil
        guard let state, surface.archiveFind.state == .searching else { return }
        surface.archiveFind.state = state
        surface.findArchiveDidChange()
    }

    /// Searches again after a reconnect, or after the conversation was cleared, whose
    /// archive is another one, once the new snapshot shows.
    func restartArchiveSearch(afterReset: Bool) {
        let find = surface.archiveFind
        guard surface.findModel != nil, !find.query.isEmpty else { return cancelArchiveSearch(nil) }
        if afterReset {
            cancelArchiveSearch(nil)
            surface.archiveFind = AgentConversationArchiveFind(query: find.query)
            Task { @MainActor [weak self] in self?.searchArchive(find.query) }
        } else if find.state == .searching || find.state == .cancelled {
            searchArchive(find.query)
        }
    }

    /// Searches the archive of items this conversation dropped for `query`, page by page
    /// from the newest, adding candidates to Find as they arrive.
    func searchArchive(_ query: String) {
        archiveSearchTask?.cancel()
        archiveSearchTask = nil
        var find = AgentConversationArchiveFind()
        find.query = query
        let hidden = surface.snapshot?.omittedItems ?? 0
        guard !query.isEmpty, hidden > 0, let request = conversationRequest, let snapshot else {
            surface.archiveFind = find
            surface.findArchiveDidChange()
            return
        }
        find.state = .searching
        surface.archiveFind = find
        surface.findArchiveDidChange()
        let session = session
        let resetID = snapshot.resetID
        let omitted = snapshot.omittedItems ?? 0
        archiveSearchTask = Task { [weak self] in
            do {
                // Typing settles before the server reads its archive.
                try await Task.sleep(for: .milliseconds(150))
                var before: Int?
                repeat {
                    guard case .archiveSearch(let page) = try await request(.searchEarlier(session: session, query: query, before: before)) else {
                        throw ModelError("The server sent an unexpected reply.")
                    }
                    try Task.checkCancellation()
                    guard let self, !self.disposed, self.snapshot?.resetID == resetID,
                          self.surface.archiveFind.query == query else { return }
                    if let before, page.start >= before, page.start > 0 { throw ModelError("The archive search did not advance.") }
                    var find = self.surface.archiveFind
                    let shown = Set(self.surface.snapshot?.items.map(\.id) ?? [])
                    for (item, position) in zip(page.items, page.positions) where find.positions[item.id] == nil && !shown.contains(item.id) {
                        find.positions[item.id] = position
                        find.items.append(item)
                    }
                    find.items.sort { (find.positions[$0.id] ?? 0) < (find.positions[$1.id] ?? 0) }
                    find.archived = page.total
                    find.scanned = page.total - page.start
                    find.notKept = max(0, omitted - page.total)
                    if page.start == 0 { find.state = .complete }
                    else if find.items.count >= AgentConversationArchiveFind.maximumCandidates { find.state = .limited }
                    self.surface.archiveFind = find
                    self.surface.findArchiveDidChange()
                    if find.state == .limited { break }
                    before = page.start
                } while before != 0
                self?.archiveSearchTask = nil
            } catch is CancellationError {
            } catch {
                guard let self, self.surface.archiveFind.query == query else { return }
                self.archiveSearchTask = nil
                let client = error as? ClientError
                switch client {
                case .disconnected?, .timeout?: self.surface.archiveFind.state = .cancelled
                case .unsupported?: self.surface.archiveFind.state = .unsupported
                default:
                    self.surface.archiveFind.state = client?.serverCode == .unsupported ? .unsupported : .failed(error.localizedDescription)
                }
                self.surface.findArchiveDidChange()
            }
        }
    }

    /// Loads earlier pages until the archived item `itemID` shows, then reveals the
    /// current match in it.
    func revealArchived(_ itemID: String) {
        archiveRevealTask?.cancel()
        archiveRevealTask = Task { [weak self] in
            for _ in 0..<1024 {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                if self.surface.snapshot?.items.contains(where: { $0.id == itemID }) == true { break }
                if let task = self.earlierTask { await task.value; continue }
                guard self.surface.onLoadEarlier != nil else { break }
                let before = self.earlier.items.count
                self.loadEarlier()
                await self.earlierTask?.value
                if self.earlier.items.count == before, !self.earlier.needsGapFill { break }
            }
            guard let self, !Task.isCancelled, !self.disposed else { return }
            self.archiveRevealTask = nil
            if self.surface.snapshot?.items.contains(where: { $0.id == itemID }) == true {
                self.surface.revealFindSelection()
            } else {
                self.showNotice("That match is in history this server no longer keeps.", kind: .info)
            }
        }
    }
}
