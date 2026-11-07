import Foundation
import TabProtocol
import TabShared

/// What a card's glyph shows, in the desktop sidebar's order of precedence.
public enum CardStatus: Hashable, Sendable {
    case idle
    case working
    /// An agent waits for an answer, or something unread happened.
    case attention
    case error
    case paused
}

/// A card's first line: what runs in the pane its tab shows.
public enum CardHeadline: Hashable, Sendable {
    /// An agent and what it is working on, if it said.
    case agent(AgentProvider, task: String?)
    /// An idle shell: its name, and its folder when that adds anything.
    case shell(String, directory: String?)
    /// A command running, as its terminal titles it.
    case command(String)
    /// A simulator pane: the simulator's name.
    case simulator(String)
    /// A browser, editor or diff pane, which opens on the Mac.
    case other(String)
    case empty
}

/// One card of the tab list, as the desktop sidebar's Open Tabs layout shows
/// it: what runs, where (name, branch, base), and which project.
public struct TabCard: Identifiable, Hashable, Sendable {
    public var id: TabId { tab.id }
    public var server: ServerId
    public var project: ProjectDescriptor
    public var tab: Tab
    public var headline: CardHeadline
    /// The folder for Home tabs; the project or worktree name otherwise.
    public var name: String
    public var branch: String?
    public var base: String?
    public var baseAhead: UInt64?
    /// A repository's own checkout, beside its worktrees.
    public var primary: Bool
    public var status: CardStatus
    /// When the longest-running working agent started its turn.
    public var workingSince: Date?
    /// The third line: the root project, or the Mac for Home.
    public var header: String
    /// Whose icon the third line shows; nil for Home.
    public var iconProject: ProjectId?
    public var panes: [PaneSummary]
}

/// A pane as a tab view lists it.
public struct PaneSummary: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case terminal
        case agent(AgentChatProvider)
        case simulator
        /// Browser, editor or diff: shown on the Mac only.
        case other
    }

    public var id: PaneId
    public var kind: Kind
    public var title: String
}

extension ServerModel {
    /// Every open tab, oldest first, as the desktop's Open Tabs sidebar lists
    /// them: Home's tabs and each project or worktree with a tab. Tabs saved
    /// before Tab recorded when they opened come first, in grouped order.
    public var cards: [TabCard] {
        guard let board, let home else { return [] }
        let tabsByProject = Dictionary(board.projects.map { ($0.project, $0.tabs) }, uniquingKeysWith: { first, _ in first })
        var ordered: [(TabCard, Date?)] = []
        if let homeProject = project(home) {
            for tab in tabsByProject[home] ?? [] where !tab.panes.isEmpty {
                ordered.append((card(tab, in: homeProject, root: homeProject), tab.createdAt))
            }
        }
        let known = Set(projects.map(\.id))
        let parents = projects.filter { !$0.home && ($0.parentId.map { !known.contains($0) } ?? true) }
        for parent in parents {
            for project in [parent] + projects.filter({ $0.parentId == parent.id }) {
                let tabs = (tabsByProject[project.id] ?? []).filter { !$0.panes.isEmpty }
                guard let tab = tabs.first else { continue }
                let opened = tabs.contains { $0.createdAt == nil } ? nil : tabs.compactMap(\.createdAt).min()
                ordered.append((card(tab, in: project, root: parent), opened))
            }
        }
        return ordered.enumerated().sorted { left, right in
            switch (left.element.1, right.element.1) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return true
            case (_?, nil): return false
            default: return left.offset < right.offset
            }
        }.map(\.element.0)
    }

    /// Projects and worktrees with no tab open, for starting one.
    public var projectsWithoutTabs: [ProjectDescriptor] {
        let open = Set(board?.projects.filter { $0.tabs.contains { !$0.panes.isEmpty } }.map(\.project) ?? [])
        return projects.filter { !$0.home && !open.contains($0.id) }
    }

    private func card(_ tab: Tab, in project: ProjectDescriptor, root: ProjectDescriptor) -> TabCard {
        let shown = tab.panes.first { $0.content.isTerminal || $0.content.agentSession != nil } ?? tab.panes.first
        let git = project.home ? nil : gitSummaries[project.id] ?? nil
        let name: String
        if project.home {
            let title = shown.flatMap(\.content.session).flatMap { metadata[$0]?.title } ?? ""
            name = Self.idleDirectory(title) ?? (shown?.content.agentSession != nil ? "Agent" : "Terminal")
        } else {
            name = project.name
        }
        return TabCard(
            server: id, project: project, tab: tab, headline: headline(shown, project: project), name: name,
            branch: git?.branch.flatMap { $0 == project.name ? nil : $0 }, base: git?.base,
            baseAhead: git?.baseAhead,
            primary: !project.home && project.parentId == nil && git != nil
                && projects.contains { $0.parentId == project.id },
            status: status(of: tab), workingSince: workingSince(tab),
            header: project.home ? server.name : root.name, iconProject: project.home ? nil : root.id,
            panes: tab.panes.map { summary(of: $0) }
        )
    }

    private func headline(_ pane: Pane?, project: ProjectDescriptor) -> CardHeadline {
        guard let pane else { return .empty }
        switch pane.content {
        case .agent(let session, let seed):
            // As on the desktop: the agent this pane chose for its next message, else the one it started with.
            let provider = agentController(session)?.selection.provider ?? seed
            let task = agentActivity(session)?.title
            return .agent(provider == .claude ? .claude : .codex, task: task?.isEmpty == false && task != "Agent" ? task : nil)
        case .terminal(let session):
            let value = session.flatMap { metadata[$0] }
            let title = value?.title.trimmingCharacters(in: .whitespaces) ?? ""
            if let session, let agent = agentActivity(session) {
                return .agent(agent.provider, task: Self.taskTitle(title, provider: agent.provider))
            }
            let shell = value?.process.flatMap { $0.isShell ? $0.name : nil } ?? "shell"
            guard !title.isEmpty else { return value == nil ? .empty : .shell(shell, directory: nil) }
            if let directory = Self.idleDirectory(title) {
                return .shell(shell, directory: !project.home && directory != project.name ? directory : nil)
            }
            return .command(Self.withoutHost(title))
        case .simulator:
            return .simulator(pane.content.defaultTitle)
        default:
            return .other(pane.content.defaultTitle)
        }
    }

    public func summary(of pane: Pane) -> PaneSummary {
        switch pane.content {
        case .terminal(let session):
            return PaneSummary(id: pane.id, kind: .terminal, title: session.map(terminalTitle) ?? "Terminal")
        case .agent(let session, let provider):
            let task = agentActivity(session)?.title ?? ""
            return PaneSummary(id: pane.id, kind: .agent(provider), title: task.isEmpty || task == "Agent" ? "Agent" : task)
        case .simulator:
            return PaneSummary(id: pane.id, kind: .simulator, title: pane.content.defaultTitle)
        default:
            return PaneSummary(id: pane.id, kind: .other, title: pane.content.defaultTitle)
        }
    }

    private func terminalTitle(_ session: SessionId) -> String {
        guard let value = metadata[session] else { return "Terminal" }
        if !value.title.isEmpty { return Self.withoutHost(value.title) }
        if let process = value.process, !process.isShell { return process.name }
        return Self.abbreviate(value.directory)
    }

    /// The desktop sidebar's rule: blocked agent, terminal progress, unread
    /// event, working agent, else idle.
    private func status(of tab: Tab) -> CardStatus {
        let sessions = tab.panes.compactMap(\.content.activitySession)
        let agents = sessions.compactMap(agentActivity)
        if agents.contains(where: { $0.state == .blocked }) { return .attention }
        for session in sessions {
            guard let state = progress[session]?.progress?.state else { continue }
            switch state {
            case .error: return .error
            case .paused: return .paused
            default: return .working
            }
        }
        let set = Set(sessions)
        if activity.events.contains(where: { !$0.read && set.contains($0.session) }) { return .attention }
        if agents.contains(where: { $0.state == .working }) { return .working }
        return .idle
    }

    private func workingSince(_ tab: Tab) -> Date? {
        let sessions = Set(tab.panes.compactMap(\.content.activitySession))
        let since = activity.agents.filter { $0.state == .working && sessions.contains($0.session) }
            .compactMap(\.workingSince).min()
        return since.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    // MARK: Titles, read as the desktop reads them

    /// `~/code/tab` for a folder in the server's home.
    public static func abbreviate(_ path: ServerPath) -> String {
        let value = path.rawValue
        if let range = value.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + value[range.upperBound...]
        }
        return value
    }

    /// Drops the `(host) ` prefix some prompts put before the folder or command.
    static func withoutHost(_ title: String) -> String {
        guard title.hasPrefix("("), let close = title.range(of: ") ") else { return title }
        let host = title[title.index(after: title.startIndex)..<close.lowerBound]
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return title }
        return String(title[close.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// An idle shell titles its terminal with its folder, as `user@host:dir`,
    /// `(host) dir` or a bare path; returns the folder's last component.
    static func idleDirectory(_ title: String) -> String? {
        let title = withoutHost(title.trimmingCharacters(in: .whitespaces))
        var directory: Substring
        if title.hasPrefix("~") || title.hasPrefix("/") {
            if title.contains(where: \.isWhitespace) { return nil }
            directory = Substring(title)
        } else {
            guard let at = title.firstIndex(of: "@") else { return nil }
            let user = title[..<at]
            let rest = title[title.index(after: at)...]
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            let host = rest[..<colon]
            directory = rest[rest.index(after: colon)...]
            if user.isEmpty || host.isEmpty || user.contains(where: \.isWhitespace) || host.contains(where: \.isWhitespace) {
                return nil
            }
        }
        guard !directory.isEmpty else { return nil }
        while directory.count > 1, directory.hasSuffix("/") { directory = directory.dropLast() }
        if directory == "/" { return "/" }
        if let slash = directory.lastIndex(of: "/"), directory.index(after: slash) < directory.endIndex {
            return String(directory[directory.index(after: slash)...])
        }
        return String(directory)
    }

    /// The agent's task from its terminal title, without spinner glyphs; nil
    /// when the title only names the agent.
    static func taskTitle(_ title: String, provider: AgentProvider) -> String? {
        let task = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty, task.caseInsensitiveCompare(provider.displayName) != .orderedSame,
              task.caseInsensitiveCompare(provider.rawValue) != .orderedSame, task != "Claude Code"
        else { return nil }
        return task
    }

    /// How long a turn has run: `43s` under a minute, `3m` under an hour, then `1h 3m`.
    public static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Seconds until `elapsedText` changes.
    public static func secondsUntilElapsedChanges(_ seconds: TimeInterval) -> TimeInterval {
        let seconds = max(seconds, 0)
        let step: TimeInterval = seconds < 60 ? 1 : 60
        return step - seconds.truncatingRemainder(dividingBy: step)
    }
}
