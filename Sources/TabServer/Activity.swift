import Foundation
import TabProtocol

/// Live agent states and at most one unread event per session, in memory only.
final class Activity: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 1
    private var nextId: UInt64
    private var agents: [SessionId: AgentActivity] = [:]
    /// Newest first.
    private var events: [AgentEvent] = []
    private var claimed: Set<UInt64> = []
    /// Chats that work only because agents they started run in the background.
    private var backgroundWorking: Set<SessionId> = []
    /// Chats whose background agents just finished, held as working while the
    /// provider gets the chance to answer them: the latest snapshot and title,
    /// and the token of the timer that settles them.
    private var settling: [SessionId: (snapshot: AgentChatSnapshot, title: String?, token: UUID)] = [:]
    /// How long a chat whose background agents finished stays working before it
    /// counts as done. Claude usually answers its agents in a new turn by then,
    /// so the conversation finishes once, after that turn.
    let settleDelay: TimeInterval
    private let timers = DispatchQueue(label: "tab.activity.settle")
    /// Called with the new revision after every change, outside the lock.
    var onChange: (@Sendable (UInt64) -> Void)?

    init(settleDelay: TimeInterval = 10) {
        self.settleDelay = settleDelay
        // A notification from an earlier server must never point at a new event.
        nextId = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
    }

    func snapshot() -> ActivitySnapshot {
        lock.withLock {
            ActivitySnapshot(revision: revision, agents: agents.values.sorted { $0.session < $1.session }, events: events)
        }
    }

    var currentRevision: UInt64 { lock.withLock { revision } }

    /// Native chats share terminal agents' attention and completion tracking.
    /// `title` is the provider's own title for the chat, else its first message
    /// stands in.
    func updateChat(_ snapshot: AgentChatSnapshot, title providerTitle: String? = nil) {
        guard snapshot.status != .closed else { remove(snapshot.session); return }
        let title = providerTitle ?? snapshot.items.first { $0.kind == .user }?.text
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(160)) }
        notify(lock.withLock { recordChat(snapshot, title: title, settled: false) })
    }

    /// A chat's state as the sidebar shows it. Its background agents keep it
    /// working after its turn ends; the shells it left running only mark it.
    static func chatState(_ snapshot: AgentChatSnapshot) -> (AgentState, AgentCondition?) {
        let running = snapshot.subagents?.filter { $0.status == .running } ?? []
        switch snapshot.status {
        case .working: return (.working, snapshot.activity?.kind == .rateLimited ? .paused : nil)
        case .waiting: return (.blocked, nil)
        case .failed: return (.blocked, .failed)
        case .idle, .closed:
            if running.contains(where: { !isShell($0) }) { return (.working, nil) }
            if snapshot.queuePaused == true, snapshot.queuedPrompts?.isEmpty == false { return (.idle, .paused) }
            if running.contains(where: isShell) { return (.idle, .background) }
            return (.idle, nil)
        }
    }

    /// A shell the agent left running, such as a dev server, rather than an
    /// agent whose answer it waits for.
    private static func isShell(_ subagent: AgentSubagent) -> Bool { subagent.agentType == "Shell" }

    /// Records a chat's state; call inside the lock. When its background agents
    /// finish, the chat stays working for `settleDelay` unless `settled`.
    private func recordChat(_ snapshot: AgentChatSnapshot, title: String?, settled: Bool) -> UInt64? {
        let session = snapshot.session
        let (state, condition) = Self.chatState(snapshot)
        let wasBackground = backgroundWorking.remove(session) != nil
        if state == .working, snapshot.status == .idle { backgroundWorking.insert(session) }
        let held = settling[session]
        // Finished agents stay listed; stopped ones leave the list with their provider.
        let agentsFinished = snapshot.subagents?.isEmpty == false
        if !settled, state == .idle, wasBackground || held != nil, agentsFinished {
            if let held {
                settling[session] = (snapshot, title, held.token)
            } else {
                let token = UUID()
                settling[session] = (snapshot, title, token)
                timers.asyncAfter(deadline: .now() + settleDelay) { [weak self] in self?.settle(session, token: token) }
            }
            return nil
        }
        settling[session] = nil
        let previous = agents[session]
        let outcome = snapshot.turns?.last?.outcome
        let stopped = outcome == .interrupted || outcome == .cancelled || wasBackground && held == nil && !agentsFinished
        return record(AgentActivity(session: session, project: snapshot.project,
                                    provider: snapshot.provider == .claude ? .claude : .codex, state: state, title: title,
                                    condition: condition, subtasks: Self.subtasks(snapshot)),
                      completed: previous?.state == .working && state == .idle && !stopped)
    }

    /// A chat's running agents and shells, as the sidebar lists them. Only what
    /// starts or ends one changes it, so progress never bumps the revision.
    static func subtasks(_ snapshot: AgentChatSnapshot) -> [AgentSubtask]? {
        let running = (snapshot.subagents ?? []).filter { $0.status == .running }
        guard !running.isEmpty else { return nil }
        return running.prefix(AgentSubtask.maxCount).map { subagent in
            let title = subagent.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentSubtask(id: subagent.id, title: title.isEmpty ? subagent.agentType ?? "Agent" : title,
                                shell: isShell(subagent),
                                startedAt: subagent.startedAt.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) })
        }
    }

    private func settle(_ session: SessionId, token: UUID) {
        notify(lock.withLock {
            guard let held = settling[session], held.token == token else { return nil }
            return recordChat(held.snapshot, title: held.title, settled: true)
        })
    }

    /// Records an agent's state. A newly blocked agent gets an attention event,
    /// or a failure event when its turn failed; `completed` (working became
    /// idle) a completion event.
    func update(_ activity: AgentActivity, completed: Bool) {
        notify(lock.withLock { record(activity, completed: completed) })
    }

    /// Call inside the lock; returns the new revision when something changed.
    private func record(_ activity: AgentActivity, completed: Bool) -> UInt64? {
        let previous = agents[activity.session]
        var activity = activity
        activity.workingSince = Self.workingSince(activity.state, previous: previous)
        guard previous != activity else { return nil }
        var kind: EventKind?
        let failed = activity.condition == .failed
        if activity.state == .blocked, previous?.state != .blocked || previous?.provider != activity.provider
            || failed && previous?.condition != .failed {
            kind = failed ? .failed : .attention
        } else if completed {
            kind = .completed
        }
        if let kind {
            removeEvents { $0.session == activity.session }
            nextId += 1
            events.insert(AgentEvent(id: nextId, session: activity.session, project: activity.project,
                                     provider: activity.provider, timestamp: Clock.nowMilliseconds(),
                                     kind: kind), at: 0)
            if events.count > Limits.activityHistoryLimit, let expired = events.popLast() {
                claimed.remove(expired.id)
            }
        }
        agents[activity.session] = activity
        revision += 1
        return revision
    }

    /// A program in the session asked for a desktop notification; it
    /// replaces the session's unread event.
    func notification(session: SessionId, project: ProjectId, title: String, body: String) {
        let changed: UInt64 = lock.withLock {
            removeEvents { $0.session == session }
            nextId += 1
            events.insert(AgentEvent(id: nextId, session: session, project: project, provider: .unknown("terminal"),
                                     timestamp: Clock.nowMilliseconds(), kind: .notification,
                                     title: title.isEmpty ? nil : title, body: body.isEmpty ? nil : body), at: 0)
            if events.count > Limits.activityHistoryLimit, let expired = events.popLast() {
                claimed.remove(expired.id)
            }
            revision += 1
            return revision
        }
        notify(changed)
    }

    /// A turn starts when the agent starts working and lasts while it works
    /// or waits for you.
    private static func workingSince(_ state: AgentState, previous: AgentActivity?) -> UInt64? {
        switch state {
        case .working, .blocked:
            if let since = previous?.workingSince { return since }
            return state == .working ? Clock.nowMilliseconds() : nil
        case .idle, .unknown:
            return nil
        }
    }

    /// The session no longer runs an agent; its unread event stays.
    func clearAgent(_ session: SessionId) {
        let changed: UInt64? = lock.withLock {
            backgroundWorking.remove(session)
            settling[session] = nil
            guard agents.removeValue(forKey: session) != nil else { return nil }
            revision += 1
            return revision
        }
        notify(changed)
    }

    /// The session ended: forget its agent and its event.
    func remove(_ session: SessionId) {
        let changed: UInt64? = lock.withLock {
            backgroundWorking.remove(session)
            settling[session] = nil
            let agent = agents.removeValue(forKey: session) != nil
            let event = removeEvents { $0.session == session }
            guard agent || event else { return nil }
            revision += 1
            return revision
        }
        notify(changed)
    }

    func acknowledge(_ ids: [UInt64]) {
        let changed: UInt64? = lock.withLock {
            guard removeEvents({ ids.contains($0.id) }) else { return nil }
            revision += 1
            return revision
        }
        notify(changed)
    }

    /// The events among `ids` nobody claimed yet, now claimed.
    func claim(_ ids: [UInt64]) -> [UInt64] {
        lock.withLock {
            events.map(\.id).filter { ids.contains($0) && claimed.insert($0).inserted }
        }
    }

    @discardableResult
    private func removeEvents(_ matches: (AgentEvent) -> Bool) -> Bool {
        let before = events.count
        events.removeAll { event in
            guard matches(event) else { return false }
            claimed.remove(event.id)
            return true
        }
        return before != events.count
    }

    private func notify(_ revision: UInt64?) {
        guard let revision else { return }
        onChange?(revision)
    }
}
