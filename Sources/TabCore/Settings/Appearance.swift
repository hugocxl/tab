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
    /// The expanded sidebar's width, as last dragged.
    public var sidebarExpandedWidth: Double?
    public var worktreeRecent: [ProjectId]
    public var projectRecent: [ProjectId]
    /// Recently run palette commands, most recent first.
    public var paletteRecent: [String]
    /// The sidebar has the keyboard rather than the workspace.
    public var sidebarFocus: Bool
    public var sidebarProjectOrder: ProjectOrder
    public var sidePanel: SidePanel
    /// The tab the right sidebar opens on when it is shown again.
    public var lastSidePanel: SidePanel
    public var sidePanelWidth: Double?

    enum CodingKeys: String, CodingKey {
        case darkTheme, lightTheme, sidebarExpanded, sidebarHost, sidebarExpandedWidth
        case worktreeRecent, projectRecent, paletteRecent
        case sidebarFocus, sidebarProjectOrder, sidePanel, lastSidePanel, sidePanelWidth
    }

    public init() {
        darkTheme = ThemeCatalog.defaultDark
        lightTheme = ThemeCatalog.defaultLight
        sidebarExpanded = true
        sidebarHost = .all
        sidebarExpandedWidth = nil
        worktreeRecent = []
        projectRecent = []
        paletteRecent = []
        sidebarFocus = false
        sidebarProjectOrder = .manual
        sidePanel = .none
        lastSidePanel = .files
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
        worktreeRecent = try container.value(.worktreeRecent, d.worktreeRecent)
        projectRecent = try container.value(.projectRecent, d.projectRecent)
        paletteRecent = try container.value(.paletteRecent, d.paletteRecent)
        sidebarFocus = try container.value(.sidebarFocus, d.sidebarFocus)
        sidebarProjectOrder = try container.value(.sidebarProjectOrder, d.sidebarProjectOrder)
        sidePanel = try container.value(.sidePanel, d.sidePanel)
        lastSidePanel = try container.value(.lastSidePanel, d.lastSidePanel)
        sidePanelWidth = try container.decodeIfPresent(Double.self, forKey: .sidePanelWidth)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(darkTheme, forKey: .darkTheme)
        try container.encode(lightTheme, forKey: .lightTheme)
        try container.encode(sidebarExpanded, forKey: .sidebarExpanded)
        try container.encode(sidebarHost, forKey: .sidebarHost)
        try container.encodeIfPresent(sidebarExpandedWidth, forKey: .sidebarExpandedWidth)
        try container.encode(worktreeRecent, forKey: .worktreeRecent)
        try container.encode(projectRecent, forKey: .projectRecent)
        try container.encode(paletteRecent, forKey: .paletteRecent)
        try container.encode(sidebarFocus, forKey: .sidebarFocus)
        try container.encode(sidebarProjectOrder, forKey: .sidebarProjectOrder)
        try container.encode(sidePanel, forKey: .sidePanel)
        try container.encode(lastSidePanel, forKey: .lastSidePanel)
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
    /// so another window's changes in between are kept. Returns the appearance
    /// as saved.
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
        for (key, value) in current {
            let unchanged = old[key].map { ($0 as AnyObject).isEqual(value) } ?? false
            if !unchanged { target[key] = value }
        }
        let saved: Appearance
        do {
            saved = try SettingsJSON.decode(Appearance.self, from: target)
        } catch {
            throw SettingsError("appearance", SettingsJSON.describe(error))
        }
        document.root["appearance"] = target
        try document.write(to: url)
        return saved
    }
}
