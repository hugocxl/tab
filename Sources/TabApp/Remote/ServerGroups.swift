import Foundation
import TabCore

/// Servers under their groups in the listed order of first appearance, then
/// the ungrouped ones last.
public func serversByGroup<T>(_ servers: [T], entry: (T) -> ServerEntry) -> [(group: String?, members: [T])] {
    var groups: [(group: String?, members: [T])] = []
    for server in servers {
        let group = entry(server).group
        if let index = groups.firstIndex(where: { $0.group == group }) {
            groups[index].members.append(server)
        } else {
            groups.append((group, [server]))
        }
    }
    let named = groups.filter { $0.group != nil }
    let ungrouped = groups.filter { $0.group == nil }
    return named + ungrouped
}

/// Servers whose name or destination holds every word of `query`, by group;
/// groups left empty are dropped.
public func shownServers(_ servers: [RemoteServerStatus], query: String) -> [(group: String?, members: [RemoteServerStatus])] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace)
    return serversByGroup(servers, entry: \.entry).compactMap { group, members in
        let kept = members.filter { server in
            let text = "\(server.entry.name) \(server.entry.destination) \(server.entry.group ?? "")".lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        return kept.isEmpty ? nil : (group, kept)
    }
}

/// The servers ticked in the Remote Servers pane, in the order ticked, and
/// the box Shift-click ranges from.
public struct ServerSelection: Equatable, Sendable {
    public private(set) var ids: [ServerId] = []
    public private(set) var anchor: ServerId?

    public init() {}

    public func contains(_ id: ServerId) -> Bool { ids.contains(id) }
    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }

    /// Ticks a server or clears its box; with `range`, ticks every shown
    /// server from the last one ticked to this one.
    public mutating func tick(_ id: ServerId, range: Bool, shown: [ServerId]) {
        if range, let anchor, let from = shown.firstIndex(of: anchor), let to = shown.firstIndex(of: id) {
            for server in shown[min(from, to)...max(from, to)] where !ids.contains(server) {
                ids.append(server)
            }
        } else if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        anchor = id
    }

    /// Ticks every shown server, or clears them all once all are ticked.
    public mutating func tickAll(shown: [ServerId]) {
        if !shown.isEmpty && shown.allSatisfy(ids.contains) {
            ids.removeAll()
        } else {
            for server in shown where !ids.contains(server) { ids.append(server) }
        }
        anchor = nil
    }

    /// Keeps only `servers`, such as after a search or a forget.
    public mutating func retain(_ servers: [ServerId]) {
        ids.removeAll { !servers.contains($0) }
        if let anchor, !servers.contains(anchor) { self.anchor = nil }
    }

    public mutating func clear() {
        ids.removeAll()
        anchor = nil
    }
}

/// What connecting several servers means now: Connect for those offline,
/// or Reconnect when none are, so live connections stay up.
public enum ConnectChoice: Equatable, Sendable {
    case connect(count: Int)
    case reconnect(count: Int)

    public init(_ members: [RemoteServerStatus]) {
        let offline = members.filter { $0.state == .offline }.count
        self = offline == 0 ? .reconnect(count: members.count) : .connect(count: offline)
    }

    public var title: String {
        switch self {
        case .reconnect(let count): return count == 1 ? "Reconnect" : "Reconnect \(count) Servers"
        case .connect(let count): return count == 1 ? "Connect" : "Connect \(count) Servers"
        }
    }
}
