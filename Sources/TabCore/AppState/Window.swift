import Foundation

public struct WindowBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw AppError.invalidState("window bounds must be finite with positive width and height")
        }
    }
}

/// What the window shows and remembers about focus.
public struct WindowState: Codable, Equatable, Sendable {
    public internal(set) var activePane: PaneId?
    /// Panes in the order they were last focused, most recent last.
    public internal(set) var focusHistory: [PaneId]
    public internal(set) var currentProject: ProjectId
    public internal(set) var selectedTab: [ProjectId: TabId]
    public internal(set) var bounds: WindowBounds?
    /// The workspace filtering the sidebar.
    public internal(set) var workspace: WorkspaceId?
    /// The fixed Remote Servers workspace filters the sidebar instead.
    public internal(set) var remoteServers: Bool

    init(currentProject: ProjectId) {
        activePane = nil
        focusHistory = []
        self.currentProject = currentProject
        selectedTab = [:]
        bounds = nil
        workspace = nil
        remoteServers = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activePane = try container.decodeIfPresent(PaneId.self, forKey: .activePane)
        focusHistory = try container.value(.focusHistory, [])
        currentProject = try container.decode(ProjectId.self, forKey: .currentProject)
        selectedTab = try container.value(.selectedTab, [:])
        bounds = try container.decodeIfPresent(WindowBounds.self, forKey: .bounds)
        workspace = try container.decodeIfPresent(WorkspaceId.self, forKey: .workspace)
        remoteServers = try container.value(.remoteServers, false)
    }

    mutating func activate(_ pane: PaneId?) {
        activePane = pane
        guard let pane else { return }
        focusHistory.removeAll { $0 == pane }
        focusHistory.append(pane)
    }
}

/// A client-owned group of top-level projects; groups may overlap.
public struct Workspace: Codable, Equatable, Sendable, Identifiable {
    public var id: WorkspaceId
    public var name: String
    public var projects: Set<ProjectId>

    public init(id: WorkspaceId = WorkspaceId(), name: String, projects: Set<ProjectId> = []) {
        self.id = id
        self.name = name
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(WorkspaceId.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        projects = try container.value(.projects, [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(projects.sorted(), forKey: .projects)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, projects
    }
}
