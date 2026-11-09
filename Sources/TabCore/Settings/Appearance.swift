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

/// The appearance used to select the light or dark theme.
public enum InterfaceColorScheme: String, Codable, Sendable, CaseIterable {
    case auto, light, dark
}

/// The material used throughout the native interface.
public enum InterfaceStyle: String, Codable, Sendable, CaseIterable {
    case classic, glass
}

/// The timing of pane and sidebar transitions.
public enum InterfaceAnimation: String, Codable, Sendable, CaseIterable {
    case snappy, natural, off
}

/// How the sidebar lists tabs: under their projects, or as one flat list of
/// the open ones, each card naming its project.
public enum SidebarLayout: String, Codable, Sendable, CaseIterable {
    case projects, tabs
}

/// An optional trackpad gesture for opening and closing the sidebar.
public enum SidebarGesture: String, Codable, Sendable, CaseIterable {
    case off, swipe
}

/// How the app looks and what the sidebar and panels remember.
public struct Appearance: Codable, Equatable, Sendable {
    /// The system appearance, or an explicit light or dark appearance.
    public var colorScheme: InterfaceColorScheme
    /// Classic opaque surfaces or theme-tinted macOS glass.
    public var interfaceStyle: InterfaceStyle
    /// Extends Glass to pane backgrounds; content colors remain intact.
    public var glassPanes: Bool
    /// Pane and sidebar transitions, subject to Reduce Motion.
    public var animationStyle: InterfaceAnimation
    /// Resizes the window with the sidebar to preserve the content width.
    public var preservePaneWidth: Bool
    /// The trackpad gesture used to toggle the sidebar.
    public var sidebarGesture: SidebarGesture
    public var darkTheme: String
    public var lightTheme: String
    public var sidebarExpanded: Bool
    public var sidebarLayout: SidebarLayout
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
    /// Shows changed files as a folder tree in Source Control.
    public var sourceControlTree: Bool

    enum CodingKeys: String, CodingKey {
        case colorScheme
        case interfaceStyle
        case glassPanes
        case animationStyle
        case preservePaneWidth
        case sidebarGesture
        case darkTheme, lightTheme, sidebarExpanded, sidebarLayout, sidebarHost, sidebarExpandedWidth
        case worktreeRecent, projectRecent, paletteRecent
        case sidebarFocus, sidebarProjectOrder, sidePanel, lastSidePanel, sidePanelWidth, sourceControlTree
    }

    public init() {
        colorScheme = .auto
        interfaceStyle = .classic
        glassPanes = true
        animationStyle = .natural
        preservePaneWidth = false
        sidebarGesture = .off
        darkTheme = ThemeCatalog.defaultDark
        lightTheme = ThemeCatalog.defaultLight
        sidebarExpanded = true
        sidebarLayout = .projects
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
        sourceControlTree = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = Appearance()
        colorScheme = try container.value(.colorScheme, d.colorScheme)
        interfaceStyle = try container.value(.interfaceStyle, d.interfaceStyle)
        glassPanes = try container.value(.glassPanes, d.glassPanes)
        animationStyle = try container.value(.animationStyle, d.animationStyle)
        preservePaneWidth = try container.value(.preservePaneWidth, d.preservePaneWidth)
        sidebarGesture = try container.value(.sidebarGesture, d.sidebarGesture)
        darkTheme = try container.value(.darkTheme, d.darkTheme)
        lightTheme = try container.value(.lightTheme, d.lightTheme)
        sidebarExpanded = try container.value(.sidebarExpanded, d.sidebarExpanded)
        sidebarLayout = try container.value(.sidebarLayout, d.sidebarLayout)
        sidebarHost = try container.value(.sidebarHost, d.sidebarHost)
        sidebarExpandedWidth = try container.decodeIfPresent(Double.self, forKey: .sidebarExpandedWidth)
        worktreeRecent = try container.value(.worktreeRecent, d.worktreeRecent)
        projectRecent = try container.value(.projectRecent, d.projectRecent)
        paletteRecent = try container.value(.paletteRecent, d.paletteRecent)
        sidebarFocus = try container.value(.sidebarFocus, d.sidebarFocus)
        sidebarProjectOrder = try container.value(.sidebarProjectOrder, d.sidebarProjectOrder)
        sidePanel = try container.value(.sidePanel, d.sidePanel)
        lastSidePanel = try container.value(.lastSidePanel, d.lastSidePanel)
        sourceControlTree = try container.value(.sourceControlTree, d.sourceControlTree)
        sidePanelWidth = try container.decodeIfPresent(Double.self, forKey: .sidePanelWidth)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorScheme, forKey: .colorScheme)
        try container.encode(interfaceStyle, forKey: .interfaceStyle)
        try container.encode(glassPanes, forKey: .glassPanes)
        try container.encode(animationStyle, forKey: .animationStyle)
        try container.encode(preservePaneWidth, forKey: .preservePaneWidth)
        try container.encode(sidebarGesture, forKey: .sidebarGesture)
        try container.encode(darkTheme, forKey: .darkTheme)
        try container.encode(lightTheme, forKey: .lightTheme)
        try container.encode(sidebarExpanded, forKey: .sidebarExpanded)
        try container.encode(sidebarLayout, forKey: .sidebarLayout)
        try container.encode(sidebarHost, forKey: .sidebarHost)
        try container.encodeIfPresent(sidebarExpandedWidth, forKey: .sidebarExpandedWidth)
        try container.encode(worktreeRecent, forKey: .worktreeRecent)
        try container.encode(projectRecent, forKey: .projectRecent)
        try container.encode(paletteRecent, forKey: .paletteRecent)
        try container.encode(sidebarFocus, forKey: .sidebarFocus)
        try container.encode(sidebarProjectOrder, forKey: .sidebarProjectOrder)
        try container.encode(sidePanel, forKey: .sidePanel)
        try container.encode(lastSidePanel, forKey: .lastSidePanel)
        try container.encode(sourceControlTree, forKey: .sourceControlTree)
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
