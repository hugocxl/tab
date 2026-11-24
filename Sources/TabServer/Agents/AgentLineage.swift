import Foundation
import TabProtocol

/// Agent conversations started by other agent conversations.
///
/// The server records the caller of `create` and `fork` as the new conversation's
/// `parent`, from the process tree rather than anything the caller says (`AgentCallers`).
/// From then on:
///
/// - **Access only narrows.** A conversation an agent starts gets at most that agent's
///   access, and an agent can't drive or raise a conversation with more access than it
///   has, nor approve anything. It manages (stops, closes, answers, sets the access of) only
///   itself and the conversations below it. The user, calling with no agent, may do all.
/// - **Stop reaches the whole tree.** `stop` with `descendants` interrupts every open
///   conversation below the one stopped.
/// - **Children report back.** When work the parent asked for ends, fails, or waits for the
///   user, a report is queued to the parent, which delivers it when the parent is free, so
///   the parent can end its turn instead of waiting. Reading the child first withdraws it.
extension AgentSessions {
    /// How deep a tree of agents may grow: the user's agent, its agents, and so on.
    static let maxLineageDepth = 4
    /// Open conversations one agent may have started at once.
    static let maxOpenChildren = 16
    /// The most of a child's reply a report carries; the rest stays in the child.
    static let reportReplyBytes = 4 * 1024

    // MARK: Lineage

    /// `id`'s parent, its parent, and so on, nearest first. Call on `queue`.
    func ancestors(of id: SessionId) -> [SessionId] {
        var chain: [SessionId] = []
        var current = entries[id]?.snapshot.parent
        while let next = current, !chain.contains(next), chain.count <= Self.maxLineageDepth * 4 {
            chain.append(next)
            current = entries[next]?.snapshot.parent
        }
        return chain
    }

    /// Every open conversation below `id`, parents before their children. Call on `queue`.
    func openDescendants(of id: SessionId) -> [Entry] {
        var found: [Entry] = []
        var seen: Set<SessionId> = [id]
        var frontier = [id]
        while !frontier.isEmpty {
            let parents = Set(frontier)
            frontier = []
            for entry in entries.values where entry.snapshot.parent.map(parents.contains) == true
                && entry.snapshot.status != .closed && seen.insert(entry.snapshot.session).inserted {
                found.append(entry)
                frontier.append(entry.snapshot.session)
            }
        }
        return found
    }

    /// The most access a conversation `caller` starts may have, after checking the tree
    /// may grow there; nil when the user starts it. Call on `queue`.
    func admitChild(of caller: SessionId?) throws -> AgentAccessMode? {
        guard let caller else { return nil }
        guard let parent = entries[caller], parent.snapshot.status != .closed else {
            throw ServiceError(.unauthorized, "The agent asking for this is closed.")
        }
        guard ancestors(of: caller).count + 1 < Self.maxLineageDepth else {
            throw ServiceError(.badRequest, "Agents are nested \(Self.maxLineageDepth) deep here, the most Tab allows. Do this work yourself, or report back to the agent that started you.")
        }
        let open = entries.values.filter { $0.snapshot.parent == caller && $0.snapshot.status != .closed }.count
        guard open < Self.maxOpenChildren else {
            throw ServiceError(.badRequest, "You have \(open) agents open, the most Tab allows. Close finished ones with tab pane close, or wait for them.")
        }
        return access(of: caller)
    }

    /// Makes a fork the child of whoever forked it, whatever its source's parent was: the
    /// caller, or no one for the user. A caller's fork gets at most `ceiling`, its access.
    func adopt(_ snapshot: inout AgentChatSnapshot, by caller: SessionId?, ceiling: AgentAccessMode?) {
        snapshot.parent = caller
        if let caller { parents.insert(caller) }
        if let ceiling, (snapshot.accessMode ?? .standard).exceeds(ceiling) { snapshot.accessMode = ceiling }
    }

    // MARK: Access

    /// What `caller` may do without asking; a conversation that is gone may do the least.
    /// Call on `queue`.
    func access(of caller: SessionId) -> AgentAccessMode {
        entries[caller].map { $0.snapshot.accessMode ?? .standard } ?? .ask
    }

    /// Whether `caller` may type into a terminal `starter` asked for (nil: the user's).
    func mayType(_ caller: SessionId, into starter: SessionId?) -> Bool {
        queue.sync {
            if access(of: caller) == .fullAccess { return true }
            guard let starter else { return false }
            return starter == caller || ancestors(of: starter).contains(caller)
        }
    }

    /// Refuses what an agent `caller` may not do to `request`'s conversation: anything that
    /// would get around its own access. The user, with no caller, may do everything.
    /// Call on `queue`.
    func authorize(_ request: AgentChatRequest, caller: SessionId?) throws {
        guard let caller else { return }
        let mine = access(of: caller)
        func target(_ id: SessionId) throws -> Entry {
            guard let entry = entries[id] else { throw ServiceError.unknownSession(id) }
            return entry
        }
        func drivable(_ id: SessionId) throws {
            let access = try target(id).snapshot.accessMode ?? .standard
            guard !access.exceeds(mine) else {
                throw ServiceError(.unauthorized, "That agent has \(access.title) and you have \(mine.title), so you can't give it work. Ask the user to do it in its pane, or lower its access first.")
            }
        }
        func mineToManage(_ id: SessionId) throws {
            guard id == caller || ancestors(of: id).contains(caller) else {
                throw ServiceError(.unauthorized, "Only the user, or the agent that started that agent, can do that.")
            }
        }
        switch request {
        case .create(_, _, _, let options):
            if let access = options?.accessMode, access.exceeds(mine) {
                throw ServiceError(.unauthorized, "You have \(mine.title), so the agents you start can't have \(access.title). Ask the user to raise it in the new agent's pane.")
            }
        case .send(let id, _, _, _, _, _, _), .submit(let id, _), .schedule(let id, _, _), .deliverQueued(let id, _, _),
             .resumeQueue(let id), .editQueued(let id, _, _, _, _), .editQueuedPrompt(let id, _, _, _), .moveQueued(let id, _, _, _),
             .removeQueued(let id, _, _):
            try drivable(id)
        case .setAccess(let id, let access):
            try mineToManage(id)
            if access.exceeds(mine) {
                throw ServiceError(.unauthorized, "You have \(mine.title), so you can't give an agent \(access.title). Ask the user to change it in that agent's pane.")
            }
        case .approve, .decide:
            throw ServiceError(.unauthorized, "Only the user can approve an agent's requests, in that agent's pane.")
        case .answer(let id, _, _, _):
            guard id != caller else { throw ServiceError(.unauthorized, "Only the user can answer your own questions.") }
            try mineToManage(id)
            try drivable(id)
        case .setPlan(let id, _), .clear(let id, _, _), .interrupt(let id), .stop(let id, _), .close(let id):
            try mineToManage(id)
        case .read, .collect, .fork:
            break
        }
    }

    /// Refuses conversation changes that are the user's to make, such as restoring files a
    /// turn changed, when an agent asks. Reading and forking stay open. Call on `queue`.
    func authorize(_ request: AgentConversationRequest, caller: SessionId?) throws {
        guard caller != nil else { return }
        switch request {
        case .subagentSteps, .toolOutput, .earlier, .subagentEarlier, .searchEarlier, .readSince, .fork:
            return
        case .revert, .rewind, .retryCheckpoint, .reopen, .setRetention, .delete:
            throw ServiceError(.unauthorized, "Only the user can do that, in the agent's pane.")
        }
    }

    // MARK: Activity

    /// `entry`'s snapshot as the sidebar sees it. The agents it started that work for it,
    /// or whose reports wait for it, are listed with the agents its provider started, so a
    /// parent that ended its turn to wait on them shows as working until they report.
    /// Call on `queue`.
    func activitySnapshot(_ entry: Entry) -> AgentChatSnapshot {
        var snapshot = entry.snapshot
        let id = snapshot.session
        // Most conversations never start one; they skip the scan.
        guard parents.contains(id) else { return snapshot }
        let reporting = Set(entry.inbox.records.compactMap { $0.prompt == nil ? nil : $0.report })
        let children = entries.values.filter { child in
            child.snapshot.parent == id && (child.owesReport || reporting.contains(child.snapshot.session))
        }
        guard !children.isEmpty else { return snapshot }
        let listed = children.map { child -> AgentSubagent in
            let status: AgentSubagent.Status = switch child.snapshot.status {
            case .working, .waiting: child.owesReport ? .running : .completed
            // Idle, it may still be waiting on agents of its own before it reports.
            case .idle where child.owesReport && awaitsAgents(child): .running
            case .idle: child.snapshot.turns?.last?.outcome == .interrupted ? .stopped : .completed
            case .failed: .failed
            case .closed: .stopped
            }
            let started = child.snapshot.turns?.last?.startedAt
            let task = child.snapshot.items.first { $0.kind == .user && !$0.isAutomaticTurn }?.text
                .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
            return AgentSubagent(id: "tab-agent-" + child.snapshot.session.description,
                                 description: task ?? SessionName.of(child.snapshot.session), agentType: Self.tabAgentType,
                                 background: true, status: status,
                                 activity: child.snapshot.status == .waiting ? "Waiting for the user" : nil,
                                 startedAt: started, finishedAt: status == .running ? nil : child.snapshot.turns?.last?.completedAt)
        }.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
        let own = snapshot.subagents ?? []
        snapshot.subagents = own + listed.prefix(max(0, AgentSubagent.maxCount - own.count))
        return snapshot
    }

    /// `AgentSubagent.agentType` of an agent conversation listed under the one that started it.
    static let tabAgentType = "Tab agent"

    /// Tells the sidebar about `entry`'s parent when what it shows of `entry` changed.
    /// Call on `queue` when `entry` changes.
    func republishParent(of entry: Entry) {
        guard let parentID = entry.snapshot.parent, let parent = entries[parentID] else { return }
        let shown = "\(entry.snapshot.status.rawValue):\(entry.owesReport):\(entry.snapshot.turns?.count ?? 0):\(awaitsAgents(entry))"
        guard shown != entry.shownToParent else { return }
        entry.shownToParent = shown
        activityChanged(activitySnapshot(parent), parent.directory)
    }

    // MARK: Reports

    /// What a conversation's latest work came to, for its parent: nil while it works.
    /// `key` tells one outcome from the next; `final` outcomes end what the parent asked for.
    struct ReportOutcome: Equatable {
        var key: String
        var final: Bool
        var headline: String
        var includesReply: Bool
        /// The turn ended by itself, rather than stopping, failing, or closing.
        var finished = false
    }

    static func reportOutcome(_ snapshot: AgentChatSnapshot) -> ReportOutcome? {
        let turn = snapshot.turns?.last?.userItemID ?? "-"
        switch snapshot.status {
        case .working:
            return nil
        case .waiting:
            let pending = snapshot.items.last { $0.kind == .approval && !$0.isComplete }
            let asks = pending?.questionnaire != nil ? "for the user to answer a question" : "for the user to approve \(pending?.text ?? "a request")"
            return ReportOutcome(key: "\(turn):waiting:\(pending?.id ?? "-")", final: false,
                                 headline: "is waiting \(asks) in its pane. You can't answer that for it; tell the user if it holds you up.",
                                 includesReply: false)
        case .idle:
            if snapshot.turns?.last?.outcome == .interrupted {
                return ReportOutcome(key: "\(turn):stopped", final: true, headline: "was stopped before it finished.",
                                     includesReply: true)
            }
            return ReportOutcome(key: "\(turn):finished", final: true, headline: "finished.", includesReply: true,
                                 finished: true)
        case .failed:
            let notice = snapshot.items.last { $0.kind == .notice }?.text ?? "the provider stopped"
            return ReportOutcome(key: "\(turn):failed", final: true, headline: "failed: \(notice)", includesReply: true)
        case .closed:
            return ReportOutcome(key: "\(turn):closed", final: true, headline: "was closed.", includesReply: false)
        }
    }

    /// The last message of the latest reply, as `tab agent read` prints it.
    static func latestReply(_ snapshot: AgentChatSnapshot) -> String {
        let lastUser = snapshot.items.lastIndex { $0.kind == .user } ?? -1
        return snapshot.items.indices.reversed().first { index in
            index > lastUser && snapshot.items[index].kind == .assistant
        }.map { snapshot.items[$0].text } ?? ""
    }

    static func reportText(_ snapshot: AgentChatSnapshot, _ outcome: ReportOutcome) -> String {
        let id = snapshot.session.description
        var text = "Agent \(SessionName.of(snapshot.session)) (\(id)), which you started, \(outcome.headline)"
        if outcome.includesReply {
            let reply = latestReply(snapshot).trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                let clipped = utf8Prefix(reply, bytes: reportReplyBytes)
                text += "\n\nIts reply" + (clipped.count < reply.count ? ", cut short:" : ":") + "\n\n" + clipped
            }
        }
        text += "\n\nRead all of it with `tab agent read \(id) --all`; give it more work with `tab agent send \(id) \"…\"`."
        return text
    }

    /// Queues a report to `entry`'s parent when work the parent asked for reached a new
    /// outcome. Call on `queue` after `entry` changes.
    func reportIfDue(_ entry: Entry) {
        guard entry.owesReport, let parentID = entry.snapshot.parent,
              let outcome = Self.reportOutcome(entry.snapshot), outcome.key != entry.reportedOutcome else { return }
        // A turn that ended to wait on its own agents hasn't finished what the parent asked;
        // it reports once their reports are in and it is done.
        if outcome.finished, awaitsAgents(entry) { return }
        entry.reportedOutcome = outcome.key
        if outcome.final { entry.owesReport = false }
        persist(entry)
        // A closed parent has no one to tell; the child stays readable.
        guard let parent = entries[parentID], parent.snapshot.status != .closed, !parent.resetting else { return }
        let prompt = AgentPrompt(text: Self.reportText(entry.snapshot, outcome), model: parent.snapshot.model,
                                 effort: parent.snapshot.reasoningEffort, provider: parent.snapshot.provider,
                                 providerID: parent.snapshot.providerID, planMode: parent.snapshot.planMode == true)
        do {
            try mutateInbox(parent) { try $0.report(prompt, on: entry.snapshot.session) }
        } catch {
            parent.snapshot.items.append(AgentChatItem(kind: .notice, text:
                "Agent \(SessionName.of(entry.snapshot.session)) \(outcome.headline) Its report couldn't be queued: \(error.localizedDescription)"))
            touch(parent)
            persist(parent)
            return
        }
        // An idle parent takes it now. One that failed, or stopped with the server, waits
        // for the user to carry on, as its notice says; the report waits in its queue.
        if parent.snapshot.status == .idle { drainInbox(parent) }
    }

    /// Whether agents `entry` started still work for it, or their reports wait in its queue.
    /// Call on `queue`.
    func awaitsAgents(_ entry: Entry) -> Bool {
        let id = entry.snapshot.session
        guard parents.contains(id) else { return false }
        if entry.inbox.records.contains(where: { $0.report != nil && $0.prompt != nil }) { return true }
        return entries.values.contains { $0.snapshot.parent == id && $0.owesReport && $0.snapshot.status != .closed }
    }

    /// The parent collected `entry` after its work ended, so a report on it still queued
    /// is news it already has. Call on `queue`.
    func withdrawReport(_ entry: Entry, readBy caller: SessionId?) {
        guard let caller, entry.snapshot.parent == caller, entry.snapshot.status != .working,
              let parent = entries[caller], parent.inbox.records.contains(where: { $0.report == entry.snapshot.session }) else { return }
        try? mutateInbox(parent) { _ = $0.withdrawReport(on: entry.snapshot.session) }
    }
}
