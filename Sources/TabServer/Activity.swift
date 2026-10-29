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
    /// Called with the new revision after every change, outside the lock.
    var onChange: (@Sendable (UInt64) -> Void)?

    init() {
        // A notification from an earlier server must never point at a new event.
        nextId = UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
    }

    func snapshot() -> ActivitySnapshot {
        lock.withLock {
            ActivitySnapshot(revision: revision, agents: agents.values.sorted { $0.session < $1.session }, events: events)
        }
    }

    var currentRevision: UInt64 { lock.withLock { revision } }

    /// Records an agent's state. A newly blocked agent gets an attention event;
    /// `completed` (working became idle) a completion event.
    func update(_ activity: AgentActivity, completed: Bool) {
        let changed: UInt64? = lock.withLock {
            let previous = agents[activity.session]
            guard previous != activity else { return nil }
            var kind: EventKind?
            if activity.state == .blocked, previous?.state != .blocked || previous?.provider != activity.provider {
                kind = .attention
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
        notify(changed)
    }

    /// The session no longer runs an agent; its unread event stays.
    func clearAgent(_ session: SessionId) {
        let changed: UInt64? = lock.withLock {
            guard agents.removeValue(forKey: session) != nil else { return nil }
            revision += 1
            return revision
        }
        notify(changed)
    }

    /// The session ended: forget its agent and its event.
    func remove(_ session: SessionId) {
        let changed: UInt64? = lock.withLock {
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
