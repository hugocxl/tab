import Foundation

/// What a browser pane keeps across restarts. Title, zoom and back/forward
/// history belong to the live page and are not saved.
public struct BrowserPane: Codable, Hashable, Sendable {
    /// The page's address; `nil` shows the start page.
    public var url: String?
    /// The browser profile's id; `nil` means the default profile.
    public var profile: String?

    public init(url: String? = nil, profile: String? = nil) {
        self.url = url.flatMap { BrowserAddress.isBlank($0) ? nil : $0 }
        self.profile = profile
    }
}

/// What a device pane keeps across restarts: the iOS simulator or Android
/// emulator it shows. With neither, it shows the device picker.
public struct DevicePane: Codable, Hashable, Sendable {
    /// An iOS simulator's UDID.
    public var udid: String?
    /// An Android virtual device's name.
    public var avd: String?
    /// The device's name when it was chosen, shown until it is found.
    public var name: String?

    public init(udid: String? = nil, avd: String? = nil, name: String? = nil) {
        self.udid = udid
        self.avd = avd
        self.name = name
    }

    /// Whether a device was chosen.
    public var isChosen: Bool { udid != nil || avd != nil }
}

/// What a pane shows: its kind and target.
public enum PaneContent: Codable, Hashable, Sendable {
    /// A terminal; `session` is `nil` until its server creates it.
    case terminal(session: SessionId?)
    /// A conversation identity is assigned before contacting its server.
    case agent(session: SessionId, provider: AgentChatProvider)
    case browser(BrowserPane)
    /// A simulated device's screen, on this Mac.
    case device(DevicePane)
    /// The Remote Servers pane, which manages other computers' servers.
    case servers
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

    /// Session used for agent activity; terminal ownership remains separate.
    public var activitySession: SessionId? {
        if case .agent(let session, _) = self { return session }
        return session
    }

    /// The title of an editor or diff pane of its path.
    public var nativeTitle: String? {
        switch self {
        case .editor(let path): return Self.basename(path)
        case let .diff(path, staged): return staged ? "\(Self.basename(path)) (staged)" : Self.basename(path)
        case .agent: return "Agent"
        case .terminal, .browser, .device, .servers: return nil
        }
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private enum CodingKeys: String, CodingKey {
        case type, session, provider, url, profile, path, staged, udid, avd, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "terminal":
            self = .terminal(session: try container.decodeIfPresent(SessionId.self, forKey: .session))
        case "agent":
            self = .agent(session: try container.decode(SessionId.self, forKey: .session),
                          provider: try container.decode(AgentChatProvider.self, forKey: .provider))
        case "browser":
            self = .browser(BrowserPane(
                url: try container.decodeIfPresent(String.self, forKey: .url),
                profile: try container.decodeIfPresent(String.self, forKey: .profile)
            ))
        case "device":
            self = .device(DevicePane(
                udid: try container.decodeIfPresent(String.self, forKey: .udid),
                avd: try container.decodeIfPresent(String.self, forKey: .avd),
                name: try container.decodeIfPresent(String.self, forKey: .name)
            ))
        case "servers":
            self = .servers
        case "editor":
            self = .editor(path: try container.decode(String.self, forKey: .path))
        case "diff":
            self = .diff(
                path: try container.decode(String.self, forKey: .path),
                staged: try container.value(.staged, false)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown pane type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let session):
            try container.encode("terminal", forKey: .type)
            try container.encodeIfPresent(session, forKey: .session)
        case let .agent(session, provider):
            try container.encode("agent", forKey: .type)
            try container.encode(session, forKey: .session)
            try container.encode(provider, forKey: .provider)
        case .browser(let browser):
            try container.encode("browser", forKey: .type)
            try container.encodeIfPresent(browser.url, forKey: .url)
            try container.encodeIfPresent(browser.profile, forKey: .profile)
        case .device(let device):
            try container.encode("device", forKey: .type)
            try container.encodeIfPresent(device.udid, forKey: .udid)
            try container.encodeIfPresent(device.avd, forKey: .avd)
            try container.encodeIfPresent(device.name, forKey: .name)
        case .servers:
            try container.encode("servers", forKey: .type)
        case .editor(let path):
            try container.encode("editor", forKey: .type)
            try container.encode(path, forKey: .path)
        case let .diff(path, staged):
            try container.encode("diff", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(staged, forKey: .staged)
        }
    }

    /// A project-relative path with `/` separators, refusing paths that
    /// leave the project.
    static func relativePath(_ path: String) throws -> String {
        var path = Substring(path)
        while path.hasPrefix("./") { path = path.dropFirst(2) }
        while path.hasSuffix("/") { path = path.dropLast() }
        if path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
            throw AppError.invalidState("pane path must be relative to the project")
        }
        return String(path)
    }
}

/// A pane: one terminal, agent, browser, device, editor or diff in a tab's
/// split layout. New Pane adds one to an existing tab; it never adds a
/// sidebar card.
public struct Pane: Codable, Hashable, Sendable, Identifiable {
    public var id: PaneId
    public var title: String
    public var content: PaneContent
    /// The terminal started with the app's proxy.
    public var proxy: Bool

    public init(id: PaneId = PaneId(), title: String, content: PaneContent, proxy: Bool = false) {
        self.id = id
        self.title = title
        self.content = content
        self.proxy = proxy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PaneId.self, forKey: .id)
        title = try container.value(.title, "")
        content = try container.decode(PaneContent.self, forKey: .content)
        proxy = try container.value(.proxy, false)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(content, forKey: .content)
        if proxy { try container.encode(proxy, forKey: .proxy) }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, content, proxy
    }

    static func terminal(title: String = "Terminal") -> Pane {
        Pane(title: title, content: .terminal(session: nil))
    }
}

/// A tab: one card in the sidebar, holding a split layout of panes. A
/// project or worktree is a single tab; Home holds one tab per card. New Tab
/// adds a card, so it always adds a tab to Home.
public struct Tab: Codable, Equatable, Sendable, Identifiable {
    public var id: TabId
    public var customTitle: String?
    public var color: TabColor?
    public var pinned: Bool
    public var panes: [Pane]
    public var layout: Layout<PaneId>
    /// The pane shown alone, if one is zoomed.
    public var zoomed: PaneId?

    public init(id: TabId = TabId(), panes: [Pane], layout: Layout<PaneId>) {
        self.id = id
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
        case id, customTitle, color, pinned, panes, layout, zoomed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(TabId.self, forKey: .id)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        color = try container.decodeIfPresent(TabColor.self, forKey: .color)
        pinned = try container.value(.pinned, false)
        panes = try container.decode([Pane].self, forKey: .panes)
        layout = try container.decode(Layout<PaneId>.self, forKey: .layout)
        zoomed = try container.decodeIfPresent(PaneId.self, forKey: .zoomed)
        sanitizeTitles()
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
        try container.encodeIfPresent(zoomed, forKey: .zoomed)
    }

    mutating func sanitizeTitles() {
        for index in panes.indices {
            if case .agent = panes[index].content { panes[index].title = "Agent" }
        }
        var terminal = false
        for index in panes.indices where panes[index].content.isTerminal {
            panes[index].title = TerminalTitle.sanitizeOrDefault(panes[index].title)
            terminal = true
        }
        customTitle = customTitle.map {
            terminal ? TerminalTitle.sanitize($0) : $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether a terminal in the tab started with the app's proxy.
    public var usesProxy: Bool { panes.contains { $0.proxy && $0.content.isTerminal } }

    /// The panes on screen: the zoomed one, or all of them.
    public var visiblePanes: [PaneId] { zoomed.map { [$0] } ?? layout.leaves }

    func validate() throws {
        do {
            try layout.validate()
        } catch {
            throw AppError.invalidState("\(error)")
        }
        let leaves = layout.leaves
        let ids = Set(panes.map(\.id))
        if ids.count != panes.count || Set(leaves).count != leaves.count || ids != Set(leaves) {
            throw AppError.invalidState("layout leaves must match the tab's panes exactly")
        }
        if let zoomed, !ids.contains(zoomed) {
            throw AppError.invalidState("active and zoomed panes must be layout leaves")
        }
    }

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

    public func pane(_ id: PaneId) -> Pane? { panes.first { $0.id == id } }
}
