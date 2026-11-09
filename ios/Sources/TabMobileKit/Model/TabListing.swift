import Foundation
import TabProtocol
import TabShared

/// What a card's tab is doing, in the desktop sidebar's order of precedence.
public enum CardStatus: Hashable, Sendable {
    case idle
    case working
    /// An agent waits for an answer, or something unread happened.
    case attention
    case error
    case paused
}

/// One pane in a card's list, as the desktop sidebar lists it: what it is,
/// its title and what it is doing.
public struct CardPane: Hashable, Sendable {
    public enum Icon: Hashable, Sendable {
        case terminal
        case agent(AgentProvider)
        case simulator
        case browser
        /// An editor's or diff's file.
        case file(String)
    }

    public enum Status: Hashable, Sendable {
        case idle
        case working
        /// A terminal's progress report, 0...100.
        case progress(Int)
        /// Waiting for you.
        case blocked
        /// Finished with an unread event.
        case done
        case error
        case paused

        /// How much the status asks for the user's eye, for the card's title
        /// row to show the most pressing of its panes'.
        var urgency: Int {
            switch self {
            case .idle: 0
            case .done: 1
            case .paused: 2
            case .working, .progress: 3
            case .error: 4
            case .blocked: 5
            }
        }
    }

    /// What a pane says its tab is about, for the card's title, in the order
    /// the title prefers them.
    public enum Topic: Hashable, Sendable {
        case task(String)
        case command(String)
        case page(String)
        case simulator(String)
        case file(String)
        case folder(String)

        var rank: Int {
            switch self {
            case .task: 0
            case .command: 1
            case .page: 2
            case .simulator: 3
            case .file: 4
            case .folder: 5
            }
        }
    }

    public var id: PaneId
    public var icon: Icon
    public var title: String
    /// The muted text after the title: an idle shell's folder, as `~/repos/tab`.
    public var detail: String?
    public var status: Status
    /// When the pane's agent started its turn, while it works or waits.
    public var workingSince: Date?
    public var topic: Topic?

    /// The topic as a card title; a folder reads as its shell, which the
    /// folder follows.
    var topicText: String {
        switch topic {
        case .task(let text)?, .command(let text)?, .page(let text)?, .simulator(let text)?, .file(let text)?: text
        case .folder?, nil: title
        }
    }
}

/// One card of the tab list, as the desktop sidebar's Open Tabs layout shows
/// it: what the tab is about, every pane and what it is doing, then the
/// folder or branch and the project.
public struct TabCard: Identifiable, Hashable, Sendable {
    public var id: TabId { tab.id }
    public var server: ServerId
    public var project: ProjectDescriptor
    public var tab: Tab
    /// What the tab is about, whichever pane is focused.
    public var title: String
    /// Every pane, in reading order.
    public var rows: [CardPane]
    /// The location row's first word: the project or worktree name. Nil for
    /// a Home tab, whose shells show their folders after their names.
    public var location: String?
    public var branch: String?
    public var base: String?
    public var baseAhead: UInt64?
    /// A repository's own checkout, beside its worktrees.
    public var primary: Bool
    public var status: CardStatus
    /// The project row: the root project's name; nil for Home.
    public var projectName: String?
    /// Whose icon the project row shows.
    public var iconProject: ProjectId?
    public var panes: [PaneSummary]

    /// The pane the card's title row stands for: a lone pane, else the most
    /// pressing one, else the one the title names, else the first. Several
    /// panes list their own folders and running times, so the title row
    /// leaves them out.
    public var lead: CardPane? { Self.lead(rows: rows, title: title) }

    static func lead(rows: [CardPane], title: String) -> CardPane? {
        guard rows.count > 1 else { return rows.first }
        let pressing = rows.filter { $0.status != .idle }.max { $0.status.urgency < $1.status.urgency }
        guard var lead = pressing ?? rows.first(where: { $0.topicText == title }) ?? rows.first else { return nil }
        lead.detail = nil
        lead.workingSince = nil
        return lead
    }
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

    private func card(_ tab: Tab, in project: ProjectDescriptor, root: ProjectDescriptor) -> TabCard {
        let git = project.home ? nil : gitSummaries[project.id] ?? nil
        let branch = git?.branch.flatMap { $0 == project.name ? nil : $0 }
        // A repository's own checkout, as the desktop marks it.
        let primary = !project.home && project.parentId == nil && git != nil
        let rows = tab.layout.leaves.compactMap { tab.pane($0).map(row) }
        return TabCard(
            server: id, project: project, tab: tab,
            // A worktree's branch usually names the feature it is for.
            title: Self.title(rows: rows, customTitle: tab.customTitle, branch: project.home || primary ? nil : branch),
            rows: rows,
            // A Home tab's folder follows its shell's name in the title or pane rows.
            location: project.home ? nil : project.name,
            branch: branch, base: git?.base, baseAhead: git?.baseAhead, primary: primary,
            status: status(of: tab),
            projectName: project.home ? nil : root.name, iconProject: project.home ? nil : root.id,
            panes: tab.panes.map { summary(of: $0) }
        )
    }

    private func row(_ pane: Pane) -> CardPane {
        let session = pane.content.activitySession
        let agent = session.flatMap(agentActivity)
        var icon = CardPane.Icon.terminal
        var title: String
        var detail: String?
        var topic: CardPane.Topic?
        switch pane.content {
        case .agent(let session, let seed):
            // As on the desktop: the agent this pane chose for its next message, else the one it started with.
            let provider: AgentProvider = (agentController(session)?.selection.provider ?? seed) == .claude ? .claude : .codex
            icon = .agent(provider)
            // A chat's task is its opening message, so tidy it into a title.
            let task = agent?.title.flatMap { $0 == "Agent" ? nil : Self.chatTopic($0) }
            title = task ?? provider.displayName
            topic = task.map { .task($0) }
        case .editor(let path), .diff(let path, _):
            let file = Self.basename(path)
            icon = .file(file)
            title = pane.content.nativeTitle ?? file
            topic = .file(title)
        case .browser:
            icon = .browser
            title = pane.content.defaultTitle
        case .simulator:
            icon = .simulator
            title = pane.content.defaultTitle
            topic = .simulator(title)
        case .terminal(let session):
            let value = session.flatMap { metadata[$0] }
            let text = value?.title.trimmingCharacters(in: .whitespaces) ?? ""
            let shell = value?.process.flatMap { $0.isShell ? $0.name : nil } ?? "shell"
            if let agent {
                icon = .agent(agent.provider)
                // A terminal agent titles its terminal with a summary of its task.
                let task = agent.title.flatMap { Self.taskTitle($0, provider: agent.provider) } ?? Self.taskTitle(text, provider: agent.provider)
                title = task ?? agent.provider.displayName
                topic = task.map { .task($0) }
            } else if let directory = Self.idleDirectory(text) {
                title = shell
                detail = Self.idlePath(text)
                topic = .folder(directory)
            } else if text.isEmpty {
                title = value == nil ? "Terminal" : shell
            } else {
                title = Self.command(text)
                topic = .command(title)
            }
        }
        let status = paneStatus(session: session, agent: agent)
        let working = status == .working || status == .blocked
        let since = working ? agent?.workingSince.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } : nil
        return CardPane(id: pane.id, icon: icon, title: title, detail: detail, status: status, workingSince: since, topic: topic)
    }

    /// What a tab is about, the same whichever pane is focused: its custom
    /// title, else the task of its lead agent (the one waiting for you, else
    /// working, else the first), its worktree's branch, then the first
    /// command, page, simulator, file or folder its panes show.
    static func title(rows: [CardPane], customTitle: String?, branch: String?) -> String {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespaces), !customTitle.isEmpty { return customTitle }
        let agents = rows.filter { if case .task = $0.topic { true } else { false } }
        let lead = agents.first { $0.status == .blocked } ?? agents.first { $0.status == .working } ?? agents.first
        if let lead { return lead.topicText }
        if let branch { return branch }
        let best = rows.filter { $0.topic != nil }.min { ($0.topic?.rank ?? 0) < ($1.topic?.rank ?? 0) }
        return best?.topicText ?? rows.first?.title ?? "Empty tab"
    }

    /// What one pane is doing, by the same rules as the card's status.
    private func paneStatus(session: SessionId?, agent: AgentActivity?) -> CardPane.Status {
        guard let session else { return .idle }
        if agent?.state == .blocked { return .blocked }
        if let report = progress[session]?.progress {
            switch report.state {
            case .error: return .error
            case .paused: return .paused
            default: return report.percent.map { .progress(Int($0)) } ?? .working
            }
        }
        if agent?.state == .working { return .working }
        guard let event = activity.events.first(where: { !$0.read && $0.session == session }) else { return .idle }
        return event.kind == .attention ? .blocked : .done
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
        guard let path = idlePath(title) else { return nil }
        if path == "/" { return "/" }
        if let slash = path.lastIndex(of: "/"), path.index(after: slash) < path.endIndex {
            return String(path[path.index(after: slash)...])
        }
        return path
    }

    /// An idle shell's folder as its title gives it, such as `~/repos/tab`.
    static func idlePath(_ title: String) -> String? {
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

    private static let leadIns = [
        "hey", "hi", "hello", "ok", "okay", "so", "now", "also", "please", "pls",
        "can you", "could you", "would you", "will you", "can we", "could we", "do you know",
        "i want you to", "i want to", "i need you to", "i need to", "i'd like you to", "i would like you to",
        "i'd like to", "let's", "lets", "help me",
    ]

    /// A chat's opening message as a title: its first sentence without the
    /// greeting or request around it, capitalized. "can you write a lorem
    /// ipsum? thanks" reads "Write a lorem ipsum". Nil when nothing is left,
    /// as from "hi".
    static func chatTopic(_ message: String) -> String? {
        var text = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // The first sentence ends at punctuation followed by a space or the end.
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".?!".contains(text[index]), next == text.endIndex || text[next] == " ", text.distance(from: text.startIndex, to: index) >= 8 {
                text = String(text[..<index])
                break
            }
            index = next
        }
        let trim = CharacterSet(charactersIn: " ,.?!:;").union(.whitespaces)
        text = text.trimmingCharacters(in: trim)
        var stripped = true
        while stripped {
            stripped = false
            let lower = text.lowercased()
            for lead in leadIns where lower == lead || lower.hasPrefix(lead + " ") || lower.hasPrefix(lead + ",") {
                text = String(text.dropFirst(lead.count)).trimmingCharacters(in: trim)
                stripped = true
                break
            }
        }
        guard text.count >= 3 else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A running command's terminal title without the host before it or the
    /// folder some shells append: "htop — ~/repos" reads "htop".
    static func command(_ title: String) -> String {
        let command = withoutHost(title)
        guard let dash = command.range(of: " — ", options: .backwards) else { return command }
        let folder = command[dash.upperBound...]
        guard folder.hasPrefix("~") || folder.hasPrefix("/") else { return command }
        return String(command[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
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
