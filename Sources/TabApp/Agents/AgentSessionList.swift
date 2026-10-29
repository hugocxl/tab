import Foundation
import TabProtocol

/// How long ago a session was last written, for the list's sections.
public enum AgentSessionRecency: Equatable, Sendable {
    case recent, week, older

    public init(age seconds: TimeInterval) {
        switch seconds {
        case ..<86_400: self = .recent
        case ..<604_800: self = .week
        default: self = .older
        }
    }

    public var title: String {
        switch self {
        case .recent: return "Last 24 hours"
        case .week: return "Previous 7 days"
        case .older: return "Older sessions"
        }
    }
}

/// A session's identity across rescans.
public struct AgentSessionKey: Hashable, Sendable {
    public var provider: AgentProvider
    public var id: String

    public init(_ session: AgentSession) {
        provider = session.provider
        id = session.id
    }
}

/// The filtered, sectioned rows of the Agent Sessions panel and its
/// keyboard selection.
public struct AgentSessionList: Sendable {
    public enum Entry: Equatable, Sendable {
        case section(AgentSessionRecency)
        /// `index` into the listing's sessions.
        case session(index: Int, key: AgentSessionKey)
    }

    public private(set) var entries: [Entry] = []
    public private(set) var selected: AgentSessionKey?
    /// Sessions matching the search, per provider, whether or not the
    /// provider is selected; the filter menu shows them.
    public private(set) var counts: [AgentProvider: Int] = [:]
    private var filter: (query: String, providers: [AgentProvider])?

    public init() {}

    /// Rebuilds the rows for `query` and the selected `providers`. The
    /// selection stays on the same session unless the filter changed, else
    /// moves to the first row. Returns the indexes of the sessions shown.
    @discardableResult
    public mutating func rebuild(_ sessions: [AgentSession], providers: [AgentProvider], query: String, now: Date = Date()) -> [Int] {
        let reset = filter.map { $0.query != query || $0.providers != providers } ?? true
        counts = [:]
        var shown: [Int] = []
        var rows: [Entry] = []
        var previous: AgentSessionRecency?
        for (index, session) in sessions.enumerated() {
            guard AgentSessionProviders.all.contains(session.provider), session.matches(query) else { continue }
            counts[session.provider, default: 0] += 1
            guard providers.contains(session.provider) else { continue }
            let recency = AgentSessionRecency(age: now.timeIntervalSince(session.modified))
            if previous != recency { rows.append(.section(recency)) }
            previous = recency
            rows.append(.session(index: index, key: AgentSessionKey(session)))
            shown.append(index)
        }
        let kept = reset ? nil : selected
        selected = kept.flatMap { key in rows.contains { if case .session(_, key) = $0 { return true } else { return false } } ? key : nil }
            ?? shown.first.map { AgentSessionKey(sessions[$0]) }
        entries = rows
        filter = (query, providers)
        return shown
    }

    /// The listing index of the selected session.
    public var selectedIndex: Int? {
        for entry in entries {
            if case .session(let index, let key) = entry, key == selected { return index }
        }
        return nil
    }

    /// The row of the selected session.
    public var selectedRow: Int? {
        entries.firstIndex { if case .session(_, let key) = $0 { return key == selected } else { return false } }
    }

    /// Moves the selection to the next or previous session, skipping
    /// sections. Returns the new row.
    @discardableResult
    public mutating func advance(backwards: Bool) -> Int? {
        guard let current = selectedRow else { return nil }
        let candidates = backwards ? Array(entries.indices[..<current].reversed()) : Array(entries.indices[(current + 1)...])
        for row in candidates {
            if case .session(_, let key) = entries[row] {
                selected = key
                return row
            }
        }
        return nil
    }

    public mutating func select(_ key: AgentSessionKey) {
        selected = key
    }
}
