import Foundation
import TabCore
import TabProtocol

/// What a running agent is doing, in the order the panel lists them.
public enum AgentStatus: Int, Comparable, CaseIterable, Sendable {
    case blocked, working, completed, idle

    public static func < (lhs: AgentStatus, rhs: AgentStatus) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .blocked: return "Needs input"
        case .working: return "Working"
        case .completed: return "Completed"
        case .idle: return "Idle"
        }
    }
}

/// A terminal pane the app shows, as the Agents panel needs it.
public struct AgentPaneInfo: Hashable, Sendable {
    public var project: ProjectId
    /// The project's name, or "Parent › worktree" for a worktree.
    public var location: String
    public var pane: PaneId
    /// The pane's title; empty uses the provider's name.
    public var title: String
    public var session: SessionId

    public init(project: ProjectId, location: String, pane: PaneId, title: String, session: SessionId) {
        self.project = project
        self.location = location
        self.pane = pane
        self.title = title
        self.session = session
    }
}

/// One server's activity and the panes this app shows from it.
public struct AgentsPanelSource: Sendable {
    public var server: ServerId
    public var snapshot: ActivitySnapshot
    /// In sidebar order.
    public var panes: [AgentPaneInfo]

    public init(server: ServerId, snapshot: ActivitySnapshot, panes: [AgentPaneInfo]) {
        self.server = server
        self.snapshot = snapshot
        self.panes = panes
    }
}

/// An agent running in a pane of this app.
public struct RunningAgent: Hashable, Sendable {
    public var server: ServerId
    public var session: SessionId
    public var project: ProjectId
    public var location: String
    public var pane: PaneId
    public var title: String
    public var provider: AgentProvider
    public var status: AgentStatus

    /// Identifies the agent across updates.
    public struct Key: Hashable, Sendable {
        public var server: ServerId
        public var session: SessionId
    }

    public var key: Key { Key(server: server, session: session) }
}

public enum AgentsPanelModel {
    /// The agents in the panes of `sources`, once per session, most urgent
    /// first. An idle agent with an unread "finished" event is completed.
    public static func runningAgents(_ sources: [AgentsPanelSource]) -> [RunningAgent] {
        var agents: [RunningAgent] = []
        var seen = Set<String>()
        for source in sources where !source.snapshot.agents.isEmpty {
            var bySession: [SessionId: AgentActivity] = [:]
            for activity in source.snapshot.agents where bySession[activity.session] == nil {
                bySession[activity.session] = activity
            }
            let finished = Set(source.snapshot.events.filter { $0.kind == .completed && !$0.read }.map(\.session))
            for pane in source.panes {
                guard let activity = bySession[pane.session],
                      seen.insert("\(source.server)/\(pane.session)").inserted
                else { continue }
                let status: AgentStatus
                switch activity.state {
                case .blocked: status = .blocked
                case .working: status = .working
                default: status = finished.contains(pane.session) ? .completed : .idle
                }
                let title = pane.title.trimmingCharacters(in: .whitespacesAndNewlines)
                agents.append(RunningAgent(
                    server: source.server,
                    session: pane.session,
                    project: pane.project,
                    location: pane.location,
                    pane: pane.pane,
                    title: title.isEmpty ? activity.provider.displayName : title,
                    provider: activity.provider,
                    status: status
                ))
            }
        }
        return stableSorted(agents) { $0.status < $1.status }
    }

    /// "2 need input · 1 working", leaving out zero counts.
    public static func summary(_ agents: [RunningAgent]) -> String {
        let blocked = agents.filter { $0.status == .blocked }.count
        let working = agents.filter { $0.status == .working }.count
        var parts: [String] = []
        if blocked > 0 { parts.append("\(blocked) need input") }
        if working > 0 { parts.append("\(working) working") }
        return parts.joined(separator: " · ")
    }

    private static func stableSorted<T>(_ items: [T], by less: (T, T) -> Bool) -> [T] {
        items.enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}
