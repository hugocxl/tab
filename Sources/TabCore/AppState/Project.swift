import Foundation

public enum ProjectStatus: Sendable {
    case available
    /// The folder is gone: the project can only be removed.
    case missing
}

/// A tab's color from the tab palette, as `#rrggbb`.
public struct TabColor: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hex: String

    public init(_ value: String) throws {
        let utf8 = Array(value.utf8)
        guard utf8.count == 7, utf8[0] == UInt8(ascii: "#"),
              value.dropFirst().allSatisfy(\.isHexDigit)
        else { throw AppError.invalidState("color must be a #RRGGBB hex string") }
        hex = value.lowercased()
    }

    public var description: String { hex }

    /// The palette, by English name.
    public static let palette: [(name: String, hex: String)] = [
        ("Red", "#e5484d"), ("Orange", "#f76b15"), ("Amber", "#f5a623"), ("Yellow", "#ebcb00"),
        ("Lime", "#9bcd1e"), ("Green", "#30a46c"), ("Teal", "#12a594"), ("Cyan", "#05a2c2"),
        ("Blue", "#3e63dd"), ("Indigo", "#5b5bd6"), ("Violet", "#8e4ec6"), ("Pink", "#d6409f"),
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A project as this app shows it: the server's description plus the app's
/// own tabs and layouts.
public struct Project: Codable, Equatable, Sendable, Identifiable {
    public var id: ProjectId
    public var home: Bool
    public var name: String
    public var createdAt: Date?
    public var serverId: ServerId
    public var directory: ServerPath
    public var kind: ProjectKind?
    public var parentId: ProjectId?
    /// The server hides the project's worktrees in sidebars.
    public var worktreesHidden: Bool
    public var tabs: [Tab]
    /// Checked on disk for this computer's projects; never saved.
    public internal(set) var status: ProjectStatus = .available

    enum CodingKeys: String, CodingKey {
        case id, home, name, createdAt, serverId, directory, kind, parentId, worktreesHidden, tabs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProjectId.self, forKey: .id)
        home = try container.value(.home, false)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        serverId = try container.decode(ServerId.self, forKey: .serverId)
        directory = try container.decode(ServerPath.self, forKey: .directory)
        kind = try container.decodeIfPresent(ProjectKind.self, forKey: .kind)
        parentId = try container.decodeIfPresent(ProjectId.self, forKey: .parentId)
        worktreesHidden = try container.value(.worktreesHidden, false)
        tabs = try container.value(.tabs, [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(home, forKey: .home)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(directory, forKey: .directory)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(parentId, forKey: .parentId)
        if worktreesHidden { try container.encode(worktreesHidden, forKey: .worktreesHidden) }
        try container.encode(tabs, forKey: .tabs)
    }

    /// `server`'s project as `descriptor` describes it, with no tabs yet.
    init(server: ServerId, descriptor: ProjectDescriptor) {
        id = descriptor.id
        home = descriptor.home
        name = descriptor.name
        createdAt = Date()
        serverId = server
        directory = descriptor.directory
        kind = descriptor.kind
        parentId = descriptor.parentId
        worktreesHidden = descriptor.worktreesHidden
        tabs = []
        refreshStatus()
    }

    mutating func apply(_ descriptor: ProjectDescriptor) {
        id = descriptor.id
        home = descriptor.home
        name = descriptor.name
        directory = descriptor.directory
        kind = descriptor.kind
        parentId = descriptor.parentId
        worktreesHidden = descriptor.worktreesHidden
        refreshStatus()
    }

    public var descriptor: ProjectDescriptor {
        ProjectDescriptor(
            id: id, home: home, directory: directory, name: name, kind: kind, parentId: parentId,
            worktreesHidden: worktreesHidden
        )
    }

    /// The first character of a name, which stands for it on a project's tile.
    public static func initial(_ name: String) -> String {
        name.first.map(String.init) ?? "?"
    }

    /// Another computer's Home, which stands for its server.
    public var isRemoteHome: Bool { home && !serverId.isLocal }

    /// Only this computer's folders can be checked here. Another computer's
    /// projects keep what their server last said.
    mutating func refreshStatus() {
        guard serverId.isLocal else { return }
        var isDirectory: ObjCBool = false
        let path = directory.rawValue
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        var gitIsFile = false
        if kind == .worktree {
            var gitDirectory: ObjCBool = false
            gitIsFile = FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &gitDirectory)
                && !gitDirectory.boolValue
        }
        status = exists && (kind != .worktree || gitIsFile) ? .available : .missing
    }

    func requireAvailable() throws {
        if status == .missing { throw AppError.invalidState("project folder is missing") }
    }

    /// The tabs a bulk close of `scope` around `anchor` closes; pinned tabs stay.
    public func closableTabs(around anchor: TabId, scope: TabCloseScope) -> [TabId] {
        guard let index = tabs.firstIndex(where: { $0.id == anchor }) else { return [] }
        return tabs.enumerated().filter { candidate, tab in
            guard !tab.pinned else { return false }
            switch scope {
            case .other: return candidate != index
            case .left: return candidate < index
            case .right: return candidate > index
            }
        }.map(\.element.id)
    }

    /// The tab shown once `tab` closes: its right neighbor, else its left.
    func tabAfterClose(_ tab: TabId) -> TabId? {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return nil }
        if index + 1 < tabs.count { return tabs[index + 1].id }
        return index > 0 ? tabs[index - 1].id : nil
    }
}

public enum TabCloseScope: Sendable {
    case other, left, right
}

extension ProjectDescriptor {
    /// `validate()` as an app-state error.
    func check() throws {
        do {
            try validate()
        } catch {
            throw AppError.invalidState("invalid project metadata")
        }
    }
}

extension ProjectMutation {
    /// `validate()` as an app-state error.
    func check() throws {
        do {
            try validate()
        } catch {
            throw AppError.invalidState("invalid project metadata")
        }
    }

    /// The project the edit is about.
    public var project: ProjectId {
        switch self {
        case .create(let descriptor): return descriptor.id
        case .rename(let id, _), .delete(let id), .pruneWorktree(let id), .setWorktreesVisible(let id, _): return id
        }
    }
}
