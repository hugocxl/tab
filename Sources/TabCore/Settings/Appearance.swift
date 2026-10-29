import Foundation

/// Which computers' projects the sidebar shows.
public enum SidebarHost: Hashable, Codable, Sendable {
    case all
    case local
    case server(ServerId)

    public func matches(_ server: ServerId) -> Bool {
        switch self {
        case .all: return true
        case .local: return server.isLocal
        case .server(let id): return id == server
        }
    }

    /// `all`, `local`, or the server's id.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        switch text {
        case "all": self = .all
        case "local": self = .local
        default:
            guard let server = ServerId(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "expected all, local or a server id")
            }
            self = .server(server)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode("all")
        case .local: try container.encode("local")
        case .server(let id): try container.encode(id.description)
        }
    }
}

public enum ProjectOrder: String, Codable, Sendable, CaseIterable {
    case manual, name, nameDescending, recentlyActive, dateAdded
}

public enum AgentsPanelGrouping: String, Codable, Sendable, CaseIterable {
    /// Rows grouped by agent state.
    case agents
    /// Rows grouped by project and worktree.
    case worktrees
}

public enum AgentsPanelDock: String, Codable, Sendable, CaseIterable {
    case left, right
}

public enum AgentSessionsPosition: String, Codable, Sendable, CaseIterable {
    case right, bottom
}

/// The native panel pinned on the right of the workspace.
public enum SidePanel: String, Codable, Sendable, CaseIterable {
    case none, files, sourceControl
}

/// How the app looks and what the sidebar and panels remember.
public struct Appearance: Codable, Equatable, Sendable {
    public var darkTheme: String
    public var lightTheme: String
    public var sidebarExpanded: Bool
    public var sidebarHost: SidebarHost
    public var sidebarExpandedWidth: Double?
    public var autoExpandWorktrees: Bool
    public var worktreeShowUnread: Bool
    /// Orders the worktree switcher by recent use instead of sidebar order.
    public var worktreeRecentOrder: Bool
    public var worktreeRecent: [ProjectId]
    public var projectRecent: [ProjectId]
    /// Recently run palette commands, most recent first.
    public var paletteRecent: [String]
    /// Projects whose worktrees the sidebar hides.
    public var hiddenWorktrees: Set<ProjectId>
    /// The sidebar has the keyboard rather than the workspace.
    public var sidebarFocus: Bool
    public var sidebarProjectOrder: ProjectOrder
    public var agentsPanelVisible: Bool
    public var agentsPanelDetached: Bool
    public var agentsPanelDock: AgentsPanelDock
    public var agentsPanelRightWidth: Double?
    /// The detached panel's frame: x, y, width, height.
    public var agentsPanelFrame: [Double]?
    public var agentsPanelDockedHeight: Double?
    public var agentsPanelGrouping: AgentsPanelGrouping
    public var agentSessionsVisible: Bool
    public var agentSessionsPosition: AgentSessionsPosition
    public var agentSessionsPinned: Bool
    public var agentSessionsWidth: Double?
    public var agentSessionsHeight: Double?
    /// Providers the Agent Sessions panel lists.
    public var agentSessionsProviders: [AgentProvider]
    public var sidePanel: SidePanel
    public var sidePanelWidth: Double?

    enum CodingKeys: String, CodingKey {
        case darkTheme, lightTheme, sidebarExpanded, sidebarHost, sidebarExpandedWidth, autoExpandWorktrees
        case worktreeShowUnread, worktreeRecentOrder, worktreeRecent, projectRecent, paletteRecent
        case hiddenWorktrees, sidebarFocus, sidebarProjectOrder, agentsPanelVisible, agentsPanelDetached
        case agentsPanelDock, agentsPanelRightWidth, agentsPanelFrame, agentsPanelDockedHeight
        case agentsPanelGrouping, agentSessionsVisible, agentSessionsPosition, agentSessionsPinned
        case agentSessionsWidth, agentSessionsHeight, agentSessionsProviders, sidePanel, sidePanelWidth
    }

    /// Providers whose saved sessions the Agent Sessions panel can read.
    public static let agentSessionProviders: [AgentProvider] = [.claude, .codex, .copilot, .droid, .pi, .ohMyPi, .xal]

    public init() {
        darkTheme = ThemeCatalog.defaultDark
        lightTheme = ThemeCatalog.defaultLight
        sidebarExpanded = true
        sidebarHost = .all
        sidebarExpandedWidth = nil
        autoExpandWorktrees = false
        worktreeShowUnread = true
        worktreeRecentOrder = true
        worktreeRecent = []
        projectRecent = []
        paletteRecent = []
        hiddenWorktrees = []
        sidebarFocus = false
        sidebarProjectOrder = .manual
        agentsPanelVisible = false
        agentsPanelDetached = false
        agentsPanelDock = .left
        agentsPanelRightWidth = nil
        agentsPanelFrame = nil
        agentsPanelDockedHeight = nil
        agentsPanelGrouping = .agents
        agentSessionsVisible = false
        agentSessionsPosition = .right
        agentSessionsPinned = true
        agentSessionsWidth = nil
        agentSessionsHeight = nil
        agentSessionsProviders = Self.agentSessionProviders
        sidePanel = .none
        sidePanelWidth = nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        darkTheme = try container.value(.darkTheme, d.darkTheme)
        lightTheme = try container.value(.lightTheme, d.lightTheme)
        sidebarExpanded = try container.value(.sidebarExpanded, d.sidebarExpanded)
        sidebarHost = try container.value(.sidebarHost, d.sidebarHost)
        sidebarExpandedWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarExpandedWidth)
        autoExpandWorktrees = try container.value(.autoExpandWorktrees, d.autoExpandWorktrees)
        worktreeShowUnread = try container.value(.worktreeShowUnread, d.worktreeShowUnread)
        worktreeRecentOrder = try container.value(.worktreeRecentOrder, d.worktreeRecentOrder)
        worktreeRecent = try container.value(.worktreeRecent, d.worktreeRecent)
        projectRecent = try container.value(.projectRecent, d.projectRecent)
        paletteRecent = try container.value(.paletteRecent, d.paletteRecent)
        hiddenWorktrees = try container.value(.hiddenWorktrees, d.hiddenWorktrees)
        sidebarFocus = try container.value(.sidebarFocus, d.sidebarFocus)
        sidebarProjectOrder = try container.value(.sidebarProjectOrder, d.sidebarProjectOrder)
        agentsPanelVisible = try container.value(.agentsPanelVisible, d.agentsPanelVisible)
        agentsPanelDetached = try container.value(.agentsPanelDetached, d.agentsPanelDetached)
        agentsPanelDock = try container.value(.agentsPanelDock, d.agentsPanelDock)
        agentsPanelRightWidth = try container.decodeIfPresent(Double.self, forKey: .agentsPanelRightWidth)
        agentsPanelFrame = try container.decodeIfPresent([Double].self, forKey: .agentsPanelFrame)
        agentsPanelDockedHeight = try container.decodeIfPresent(Double.self, forKey: .agentsPanelDockedHeight)
        agentsPanelGrouping = try container.value(.agentsPanelGrouping, d.agentsPanelGrouping)
        agentSessionsVisible = try container.value(.agentSessionsVisible, d.agentSessionsVisible)
        agentSessionsPosition = try container.value(.agentSessionsPosition, d.agentSessionsPosition)
        agentSessionsPinned = try container.value(.agentSessionsPinned, d.agentSessionsPinned)
        agentSessionsWidth = try container.decodeIfPresent(Double.self, forKey: .agentSessionsWidth)
        agentSessionsHeight = try container.decodeIfPresent(Double.self, forKey: .agentSessionsHeight)
        agentSessionsProviders = try container.value(.agentSessionsProviders, d.agentSessionsProviders)
        sidePanel = try container.value(.sidePanel, d.sidePanel)
        sidePanelWidth = try container.decodeIfPresent(Double.self, forKey: .sidePanelWidth)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(darkTheme, forKey: .darkTheme)
        try container.encode(lightTheme, forKey: .lightTheme)
        try container.encode(sidebarExpanded, forKey: .sidebarExpanded)
        try container.encode(sidebarHost, forKey: .sidebarHost)
        try container.encodeIfPresent(sidebarExpandedWidth, forKey: .sidebarExpandedWidth)
        try container.encode(autoExpandWorktrees, forKey: .autoExpandWorktrees)
        try container.encode(worktreeShowUnread, forKey: .worktreeShowUnread)
        try container.encode(worktreeRecentOrder, forKey: .worktreeRecentOrder)
        try container.encode(worktreeRecent, forKey: .worktreeRecent)
        try container.encode(projectRecent, forKey: .projectRecent)
        try container.encode(paletteRecent, forKey: .paletteRecent)
        try container.encode(hiddenWorktrees.sorted(), forKey: .hiddenWorktrees)
        try container.encode(sidebarFocus, forKey: .sidebarFocus)
        try container.encode(sidebarProjectOrder, forKey: .sidebarProjectOrder)
        try container.encode(agentsPanelVisible, forKey: .agentsPanelVisible)
        try container.encode(agentsPanelDetached, forKey: .agentsPanelDetached)
        try container.encode(agentsPanelDock, forKey: .agentsPanelDock)
        try container.encodeIfPresent(agentsPanelRightWidth, forKey: .agentsPanelRightWidth)
        try container.encodeIfPresent(agentsPanelFrame, forKey: .agentsPanelFrame)
        try container.encodeIfPresent(agentsPanelDockedHeight, forKey: .agentsPanelDockedHeight)
        try container.encode(agentsPanelGrouping, forKey: .agentsPanelGrouping)
        try container.encode(agentSessionsVisible, forKey: .agentSessionsVisible)
        try container.encode(agentSessionsPosition, forKey: .agentSessionsPosition)
        try container.encode(agentSessionsPinned, forKey: .agentSessionsPinned)
        try container.encodeIfPresent(agentSessionsWidth, forKey: .agentSessionsWidth)
        try container.encodeIfPresent(agentSessionsHeight, forKey: .agentSessionsHeight)
        try container.encode(agentSessionsProviders, forKey: .agentSessionsProviders)
        try container.encode(sidePanel, forKey: .sidePanel)
        try container.encodeIfPresent(sidePanelWidth, forKey: .sidePanelWidth)
    }

    /// The `appearance` section of `url`, or the defaults without one.
    public static func load(_ url: URL) throws -> Appearance {
        let document = try SettingsDocument.read(url)
        guard let section = document.root["appearance"] else { return Appearance() }
        do {
            return try SettingsJSON.decode(Appearance.self, from: section)
        } catch {
            throw SettingsError("appearance", SettingsJSON.describe(error))
        }
    }

    /// Writes the whole section over the file's current one.
    public func save(to url: URL) throws {
        var document = try SettingsDocument.read(url)
        try document.merge("appearance", self)
        try document.write(to: url)
    }

    /// Saves only what changed since `previous`, over what the file holds now,
    /// so another window's changes in between are kept. Hidden worktrees merge
    /// as additions and removals. Returns the appearance as saved.
    @discardableResult
    public func saveChanges(since previous: Appearance, to url: URL) throws -> Appearance {
        guard let current = try SettingsJSON.object(self) as? [String: Any],
              let old = try SettingsJSON.object(previous) as? [String: Any]
        else { throw SettingsError("appearance", "must be an object") }
        var document = try SettingsDocument.read(url)
        if document.root["appearance"] != nil && !(document.root["appearance"] is [String: Any]) {
            throw SettingsError("appearance", "must be an object")
        }
        var target = document.root["appearance"] as? [String: Any] ?? old
        for (key, value) in current where key != CodingKeys.hiddenWorktrees.stringValue {
            let unchanged = old[key].map { ($0 as AnyObject).isEqual(value) } ?? false
            if !unchanged { target[key] = value }
        }
        var saved: Appearance
        do {
            saved = try SettingsJSON.decode(Appearance.self, from: target)
        } catch {
            throw SettingsError("appearance", SettingsJSON.describe(error))
        }
        saved.hiddenWorktrees.formUnion(hiddenWorktrees.subtracting(previous.hiddenWorktrees))
        saved.hiddenWorktrees.subtract(previous.hiddenWorktrees.subtracting(hiddenWorktrees))
        target[CodingKeys.hiddenWorktrees.stringValue] = saved.hiddenWorktrees.sorted().map(\.description)
        document.root["appearance"] = target
        try document.write(to: url)
        return saved
    }
}
