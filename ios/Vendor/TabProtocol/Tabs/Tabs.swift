import Foundation

// A server's tabs: each project's cards and their split layouts of panes.
// The server keeps them and every app connected to it shows the same ones;
// each app keeps only its own view of them (selection, focus, zoom, titles).

/// A pane in a split layout.
public struct PaneId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }

    /// The operation that creates this pane's terminal, so two apps creating
    /// it at once get the same one, and a cancelled creation can be named
    /// before the server answers.
    public var creationToken: OperationId { OperationId(uuid: uuid) }
}

/// A tab: one card in the sidebar, holding a split layout of panes.
public struct TabId: UUIDIdentifier {
    public let uuid: UUID
    public init(uuid: UUID) { self.uuid = uuid }
}

/// A tab's color from the tab palette, as `#rrggbb`.
public struct TabColor: Hashable, Codable, Sendable, CustomStringConvertible {
    public let hex: String

    public init(_ value: String) throws {
        let utf8 = Array(value.utf8)
        guard utf8.count == 7, utf8[0] == UInt8(ascii: "#"),
              value.dropFirst().allSatisfy(\.isHexDigit)
        else { throw LayoutError("color must be a #RRGGBB hex string") }
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

/// What a browser pane keeps: the page it opens on. Title, zoom and
/// back/forward history belong to each app's live page.
public struct BrowserPane: Codable, Hashable, Sendable {
    /// The page's address; `nil` shows the start page.
    public var url: String?
    /// The browser profile's id; `nil` means the default profile.
    public var profile: String?

    public init(url: String? = nil, profile: String? = nil) {
        self.url = url.flatMap { $0.isEmpty || $0 == "about:blank" ? nil : $0 }
        self.profile = profile
    }
}

/// What a simulator pane keeps: the iOS simulator or Android emulator it
/// shows. With neither, it shows the simulator picker.
public struct SimulatorPane: Codable, Hashable, Sendable {
    /// An iOS simulator's UDID.
    public var udid: String?
    /// An Android virtual simulator's name.
    public var avd: String?
    /// The simulator's name when it was chosen, shown until it is found.
    public var name: String?
    /// Whether the simulator has a hardware keyboard connected, so the Mac's
    /// keys type on it; `nil` means connected.
    public var hardwareKeyboard: Bool?

    public init(udid: String? = nil, avd: String? = nil, name: String? = nil, hardwareKeyboard: Bool? = nil) {
        self.udid = udid
        self.avd = avd
        self.name = name
        self.hardwareKeyboard = hardwareKeyboard
    }

    /// Whether a simulator was chosen.
    public var isChosen: Bool { udid != nil || avd != nil }

    /// Whether the Mac's keys type on the simulator instead of its on-screen
    /// keyboard.
    public var simulatesHardwareKeyboard: Bool { hardwareKeyboard ?? true }
}

/// What a pane shows: its kind and target.
public enum PaneContent: Codable, Hashable, Sendable {
    /// A terminal; `session` is `nil` until its server creates it.
    case terminal(session: SessionId?)
    /// A conversation identity is assigned before contacting its server.
    case agent(session: SessionId, provider: AgentChatProvider)
    case browser(BrowserPane)
    /// A simulator's or emulator's screen, on the tab's server.
    case simulator(SimulatorPane)
    /// A file editor; `path` is project-relative with `/` separators.
    case editor(path: String)
    /// One file's working tree (or, when `staged`, index) diff.
    case diff(path: String, staged: Bool)

    public var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    /// The terminal's session, if this is a terminal that has one.
    public var session: SessionId? {
        if case .terminal(let session) = self { return session }
        return nil
    }

    /// The agent conversation, if this is an agent pane.
    public var agentSession: SessionId? {
        if case .agent(let session, _) = self { return session }
        return nil
    }

    /// Session used for agent activity; terminal ownership remains separate.
    public var activitySession: SessionId? { agentSession ?? session }

    /// The title of an editor or diff pane of its path.
    public var nativeTitle: String? {
        switch self {
        case .editor(let path): return Self.basename(path)
        case let .diff(path, staged): return staged ? "\(Self.basename(path)) (staged)" : Self.basename(path)
        case .agent: return "Agent"
        case .terminal, .browser, .simulator: return nil
        }
    }

    /// The title a pane shows before it reports its own.
    public var defaultTitle: String {
        switch self {
        case .terminal: return "Terminal"
        case .browser: return "New Browser"
        case .simulator(let simulator): return simulator.name ?? "Simulator"
        case .agent, .editor, .diff: return nativeTitle ?? ""
        }
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "terminal":
            self = .terminal(session: try c("session"))
        case "agent":
            self = .agent(session: try c("session"), provider: try c("provider"))
        case "browser":
            self = .browser(BrowserPane(url: try c("url"), profile: try c("profile")))
        case "simulator":
            self = .simulator(SimulatorPane(udid: try c("udid"), avd: try c("avd"), name: try c("name"),
                                            hardwareKeyboard: try c("hardwareKeyboard")))
        case "editor":
            self = .editor(path: try c("path"))
        case "diff":
            self = .diff(path: try c("path"), staged: try c("staged"))
        default:
            throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .terminal(let session):
            var c = try TaggedEncoding(encoder, "terminal")
            try c(session, "session")
        case let .agent(session, provider):
            var c = try TaggedEncoding(encoder, "agent")
            try c(session, "session")
            try c(provider, "provider")
        case .browser(let browser):
            var c = try TaggedEncoding(encoder, "browser")
            try c(browser.url, "url")
            try c(browser.profile, "profile")
        case .simulator(let simulator):
            var c = try TaggedEncoding(encoder, "simulator")
            try c(simulator.udid, "udid")
            try c(simulator.avd, "avd")
            try c(simulator.name, "name")
            try c(simulator.hardwareKeyboard, "hardwareKeyboard")
        case .editor(let path):
            var c = try TaggedEncoding(encoder, "editor")
            try c(path, "path")
        case let .diff(path, staged):
            var c = try TaggedEncoding(encoder, "diff")
            try c(path, "path")
            try c(staged, "staged")
        }
    }
}

/// How a new terminal starts, kept in its pane until the server creates it,
/// so whichever app creates it starts the same one.
public struct TerminalLaunch: Codable, Hashable, Sendable {
    /// Where it starts; `nil` is its project's folder.
    public var directory: ServerPath?
    /// A command the server types once it starts.
    public var command: String?

    public init(directory: ServerPath? = nil, command: String? = nil) {
        self.directory = directory
        self.command = command
    }
}

/// A pane: one terminal, agent, browser, simulator, editor or diff in a tab's
/// split layout.
public struct Pane: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneId
    public var content: PaneContent
    /// The terminal started with its creating app's proxy.
    public var proxy: Bool
    /// How the terminal starts, until its server creates it.
    public var launch: TerminalLaunch?
    /// The title this app shows. Each app keeps its own; it is never sent.
    public var title: String

    public init(id: PaneId = PaneId(), title: String? = nil, content: PaneContent, proxy: Bool = false,
                launch: TerminalLaunch? = nil) {
        self.id = id
        self.title = title ?? content.defaultTitle
        self.content = content
        self.proxy = proxy
        self.launch = launch
    }

    enum CodingKeys: String, CodingKey {
        case id, content, proxy, launch
    }

    /// Panes are equal when their server keeps them alike; titles are each
    /// app's own.
    public static func == (lhs: Pane, rhs: Pane) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.proxy == rhs.proxy && lhs.launch == rhs.launch
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(content)
        hasher.combine(proxy)
        hasher.combine(launch)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PaneId.self, forKey: .id)
        content = try container.decode(PaneContent.self, forKey: .content)
        proxy = try container.decodeIfPresent(Bool.self, forKey: .proxy) ?? false
        launch = try container.decodeIfPresent(TerminalLaunch.self, forKey: .launch)
        title = content.defaultTitle
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        if proxy { try container.encode(proxy, forKey: .proxy) }
        try container.encodeIfPresent(launch, forKey: .launch)
    }
}

/// A tab: one card in the sidebar, holding a split layout of panes. A
/// project or worktree is a single tab; Home holds one tab per card.
public struct Tab: Codable, Hashable, Sendable, Identifiable {
    public var id: TabId
    public var customTitle: String?
    public var color: TabColor?
    public var pinned: Bool
    public var panes: [Pane]
    public var layout: Layout<PaneId>
    /// When the tab opened, by its server's clock.
    public var createdAt: Date?
    /// The pane this app shows alone, if one is zoomed. Each app keeps its
    /// own; it is never sent.
    public var zoomed: PaneId?

    public init(id: TabId = TabId(), panes: [Pane], layout: Layout<PaneId>) {
        self.id = id
        createdAt = Date()
        customTitle = nil
        color = nil
        pinned = false
        self.panes = panes
        self.layout = layout
        zoomed = nil
    }

    /// A tab of one pane.
    public init(pane: Pane) {
        self.init(panes: [pane], layout: .leaf(pane.id))
    }

    enum CodingKeys: String, CodingKey {
        case id, customTitle, color, pinned, panes, layout, createdAt
    }

    /// Tabs are equal when their server keeps them alike; zoom is each app's own.
    public static func == (lhs: Tab, rhs: Tab) -> Bool {
        lhs.id == rhs.id && lhs.customTitle == rhs.customTitle && lhs.color == rhs.color && lhs.pinned == rhs.pinned
            && lhs.panes == rhs.panes && lhs.layout == rhs.layout && lhs.createdAt == rhs.createdAt
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(panes)
        hasher.combine(layout)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabId.self, forKey: .id)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        color = try container.decodeIfPresent(TabColor.self, forKey: .color)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        panes = try container.decode([Pane].self, forKey: .panes)
        layout = try container.decode(Layout<PaneId>.self, forKey: .layout)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        zoomed = nil
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "\(error)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(color, forKey: .color)
        if pinned { try container.encode(pinned, forKey: .pinned) }
        try container.encode(panes, forKey: .panes)
        try container.encode(layout, forKey: .layout)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    /// The panes on screen: the zoomed one, or all of them.
    public var visiblePanes: [PaneId] { zoomed.map { [$0] } ?? layout.leaves }

    public func pane(_ id: PaneId) -> Pane? { panes.first { $0.id == id } }

    /// Whether a terminal in the tab started with an app's proxy.
    public var usesProxy: Bool { panes.contains { $0.proxy && $0.content.isTerminal } }

    /// The tab's title: its custom one, else the shown pane's.
    public func title(active: PaneId?) -> String {
        customTitle ?? displayedPane(active: active)?.title ?? ""
    }

    /// The active pane when it is here, else the first in reading order.
    public func displayedPane(active: PaneId?) -> Pane? {
        if let active, let pane = panes.first(where: { $0.id == active }) { return pane }
        let first = layout.leaves.first
        return panes.first { $0.id == first }
    }

    /// Checks the layout's ratios, and that its leaves are exactly the panes.
    public func validate() throws {
        try layout.validate()
        let leaves = layout.leaves
        let ids = Set(panes.map(\.id))
        if ids.count != panes.count || Set(leaves).count != leaves.count || ids != Set(leaves) {
            throw LayoutError("layout leaves must match the tab's panes exactly")
        }
        if let zoomed, !ids.contains(zoomed) {
            throw LayoutError("the zoomed pane must be a layout leaf")
        }
    }
}

/// One project's tabs, in order.
public struct ProjectTabs: Codable, Hashable, Sendable {
    public var project: ProjectId
    public var tabs: [Tab]

    public init(project: ProjectId, tabs: [Tab]) {
        self.project = project
        self.tabs = tabs
    }
}

/// Every tab a server keeps.
public struct TabsSnapshot: Codable, Hashable, Sendable {
    public var revision: UInt64
    /// The latest tab changes the snapshot includes, so a client can tell
    /// its own changes apart from ones still on their way.
    public var applied: [OperationId]
    /// Projects with at least one tab, in catalog order.
    public var projects: [ProjectTabs]

    public init(revision: UInt64, applied: [OperationId] = [], projects: [ProjectTabs] = []) {
        self.revision = revision
        self.applied = applied
        self.projects = projects
    }

    public func tabs(_ project: ProjectId) -> [Tab] {
        projects.first { $0.project == project }?.tabs ?? []
    }
}

/// A change to a server's tabs. Every change names what it is about by id,
/// so it means the same on every app and fails cleanly when another app
/// already removed its target.
public enum TabMutation: Hashable, Codable, Sendable {
    /// Adds a tab to Home, after `after` and any pinned tabs, or the one tab
    /// of a project that has none.
    case createTab(project: ProjectId, tab: Tab, after: TabId?)
    /// Closes a tab with its panes, ending their terminals unless
    /// `keepSessions`.
    case closeTab(TabId, keepSessions: Bool)
    /// Splits `anchor` with `pane` on its `edge`, equalizing the row or
    /// column it joins.
    case insertPane(Pane, anchor: PaneId, edge: Direction)
    /// Removes a pane, and its tab when it was the last. Its terminal ends
    /// unless `keepSession`.
    case removePane(PaneId, keepSession: Bool)
    /// Puts `new` where `old` is, ending `old`'s terminal.
    case replacePane(PaneId, with: Pane)
    /// Swaps two panes of a tab.
    case swapPanes(PaneId, PaneId)
    /// Docks a pane on `edge` of `anchor`, or of the row or column `level`
    /// picks, as `Layout.docked` does.
    case dockPane(PaneId, anchor: PaneId, edge: Direction, level: Int)
    case setRatio(TabId, split: SplitAnchor<PaneId>, ratio: Double)
    /// Gives every row and column of a tab equal shares.
    case equalize(TabId)
    /// Changes what a pane shows: a browser's page, a simulator.
    case updatePane(PaneId, content: PaneContent)
    /// Adds tabs an app kept before its server kept them. Home gets them as
    /// they are; another project's tabs merge into its one tab. Panes the
    /// server already has are left out.
    case adoptTabs(project: ProjectId, tabs: [Tab])

    public init(from decoder: Decoder) throws {
        let c = try TaggedDecoding(decoder)
        switch c.type {
        case "createTab": self = .createTab(project: try c("project"), tab: try c("tab"), after: try c("after"))
        case "closeTab": self = .closeTab(try c("tab"), keepSessions: try c("keepSessions"))
        case "insertPane": self = .insertPane(try c("pane"), anchor: try c("anchor"), edge: try c("edge"))
        case "removePane": self = .removePane(try c("pane"), keepSession: try c("keepSession"))
        case "replacePane": self = .replacePane(try c("pane"), with: try c("new"))
        case "swapPanes": self = .swapPanes(try c("pane"), try c("other"))
        case "dockPane":
            self = .dockPane(try c("pane"), anchor: try c("anchor"), edge: try c("edge"), level: try c("level"))
        case "setRatio": self = .setRatio(try c("tab"), split: try c("split"), ratio: try c("ratio"))
        case "equalize": self = .equalize(try c("tab"))
        case "updatePane": self = .updatePane(try c("pane"), content: try c("content"))
        case "adoptTabs": self = .adoptTabs(project: try c("project"), tabs: try c("tabs"))
        default: throw unknownCase(c.type, decoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .createTab(project, tab, after):
            var c = try TaggedEncoding(encoder, "createTab")
            try c(project, "project")
            try c(tab, "tab")
            try c(after, "after")
        case let .closeTab(tab, keepSessions):
            var c = try TaggedEncoding(encoder, "closeTab")
            try c(tab, "tab")
            try c(keepSessions, "keepSessions")
        case let .insertPane(pane, anchor, edge):
            var c = try TaggedEncoding(encoder, "insertPane")
            try c(pane, "pane")
            try c(anchor, "anchor")
            try c(edge, "edge")
        case let .removePane(pane, keepSession):
            var c = try TaggedEncoding(encoder, "removePane")
            try c(pane, "pane")
            try c(keepSession, "keepSession")
        case let .replacePane(pane, new):
            var c = try TaggedEncoding(encoder, "replacePane")
            try c(pane, "pane")
            try c(new, "new")
        case let .swapPanes(pane, other):
            var c = try TaggedEncoding(encoder, "swapPanes")
            try c(pane, "pane")
            try c(other, "other")
        case let .dockPane(pane, anchor, edge, level):
            var c = try TaggedEncoding(encoder, "dockPane")
            try c(pane, "pane")
            try c(anchor, "anchor")
            try c(edge, "edge")
            try c(level, "level")
        case let .setRatio(tab, split, ratio):
            var c = try TaggedEncoding(encoder, "setRatio")
            try c(tab, "tab")
            try c(split, "split")
            try c(ratio, "ratio")
        case .equalize(let tab):
            var c = try TaggedEncoding(encoder, "equalize")
            try c(tab, "tab")
        case let .updatePane(pane, content):
            var c = try TaggedEncoding(encoder, "updatePane")
            try c(pane, "pane")
            try c(content, "content")
        case let .adoptTabs(project, tabs):
            var c = try TaggedEncoding(encoder, "adoptTabs")
            try c(project, "project")
            try c(tabs, "tabs")
        }
    }
}

/// A tab change with the operation id that makes retrying it safe.
public struct TabIntent: Hashable, Codable, Sendable {
    public var operation: OperationId
    public var mutation: TabMutation

    public init(operation: OperationId = OperationId(), mutation: TabMutation) {
        self.operation = operation
        self.mutation = mutation
    }
}
