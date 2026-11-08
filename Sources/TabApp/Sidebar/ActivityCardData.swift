import AppKit
import TabCore
import TabProtocol

/// What a sidebar card shows, derived from the model only: the headline of
/// the pane the project shows, its folder or name, branch, pull request and
/// activity. Equatable so the sidebar rebuilds only when a card changes.
struct ActivityCardData: Equatable {
    enum Headline: Equatable {
        /// A command running, as its terminal titles it.
        case command(String)
        case browser(String)
        case simulator(String)
        case editor(String)
        case diff(String)
        /// An agent and what it is working on.
        case agent(provider: AgentProvider, task: String?)
        /// An idle shell: its name and folder.
        case shell(String, directory: String?)
        /// No pane is open.
        case empty
    }

    enum Status: Equatable {
        /// Needs the user, or finished with an unread event.
        case attention
        case working
        case error
        case paused
        case idle
    }

    /// One pane in the card's list: what it is, its title and what it is doing.
    struct PaneRow: Equatable {
        enum Icon: Equatable {
            case kind(PaneKind)
            case agent(AgentProvider)
            /// An editor's or diff's file, drawn with its file type's icon.
            case file(String)
            /// A page's favicon.
            case image(NSImage)
        }

        enum Status: Equatable {
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
        }

        /// What a pane says its tab is about, for the card's title, in the
        /// order the title prefers them.
        enum Topic: Equatable {
            case task(String)
            case command(String)
            case page(String)
            case simulator(String)
            case file(String)
            case folder(String)

            var rank: Int {
                switch self {
                case .task: return 0
                case .command: return 1
                case .page: return 2
                case .simulator: return 3
                case .file: return 4
                case .folder: return 5
                }
            }

            var text: String {
                switch self {
                case .task(let text), .command(let text), .page(let text), .simulator(let text), .file(let text): return text
                // The location row shows the folder.
                case .folder: return ActivityCardData.shellName
                }
            }
        }

        var id: PaneId
        var icon: Icon
        var title: String
        /// The muted text after the title: an idle shell's folder.
        var detail: String?
        var status: Status
        /// When the pane's agent started its turn, while it works.
        var workingSince: Date?
        /// The pane its tab shows focused.
        var active: Bool
        var topic: Topic?
    }

    var headline: Headline
    /// What the tab is about, whichever pane is focused; see `title(rows:customTitle:branch:)`.
    var title: String
    /// The location row's first word: the shown terminal's folder for a
    /// Home tab, the project or worktree name otherwise. Nil when a Home
    /// tab's folder isn't known.
    var name: String?
    var branch: String?
    /// The branch this worktree's branch started from, and how far apart
    /// they are.
    var base: String?
    var baseAhead: UInt64?
    var baseBehind: UInt64?
    var primary: Bool
    var pullRequest: UInt64?
    var status: Status
    /// Every pane in the card's tabs, in reading order.
    var panes: [PaneRow]
    var selected: Bool
    var unavailable: Bool
    /// Another computer's card while its server isn't connected: dimmed,
    /// but selecting it still connects.
    var offline: Bool

    @MainActor
    static func make(project: Project, tab: Tab?, primary: Bool, model: AppModel) -> ActivityCardData {
        let tabs = tab.map { [$0] } ?? project.tabs
        let selectedTab = model.state.window.selectedTab[project.id]
        let shownTab = tabs.first { $0.id == selectedTab } ?? tabs.first
        let shownId = shownTab.flatMap { model.state.shownPane($0) }
        let shownPane = shownTab?.displayedPane(active: shownId)
        let title = shownTab.map { $0.title(active: shownId).trimmingCharacters(in: .whitespaces) } ?? ""
        let agent = shownPane.flatMap { model.agent(in: $0.id) }
        let headline: Headline
        switch shownPane?.content {
        case .agent(_, let seed)?:
            let controller = shownPane.flatMap { model.panes.controller(for: $0.id) as? AgentPaneController }
            let provider = chatProvider(controller: controller, agent: agent, seed: seed)
            let task = agent?.title ?? controller?.title
            headline = .agent(provider: provider, task: task == "Agent" ? nil : task)
        case .editor(let path)?:
            headline = .editor(basename(path))
        case .diff(let path, _)?:
            headline = .diff(basename(path))
        default:
            if let agent {
                headline = .agent(provider: agent.provider, task: taskTitle(title, provider: agent.provider))
            } else if title.isEmpty || shownPane == nil {
                headline = .empty
            } else if case .browser? = shownPane?.content {
                headline = .browser(title)
            } else if case .simulator? = shownPane?.content {
                headline = .simulator(title)
            } else if let directory = idleDirectory(title) {
                headline = .shell(shellName, directory: !project.home && directory != project.name ? directory : nil)
            } else {
                headline = .command(withoutHost(title))
            }
        }
        let info = project.home ? nil : model.git[project.id]
        let branch = info?.summary?.branch.flatMap { $0 == project.name ? nil : $0 }
        let name = tab != nil ? shownPane.flatMap { idleDirectory($0.title) } : project.name
        let selected: Bool
        if let tab {
            selected = model.currentProject.id == project.id && model.activeTab?.id == tab.id
        } else {
            selected = model.currentProject.id == project.id
        }
        let status = status(tabs: tabs, server: project.serverId, model: model)
        let rows = paneRows(tabs: tabs, server: project.serverId, model: model)
        // A Home tab's pane rows show each folder; only a lone pane's needs the row.
        let location = tab != nil && rows.count > 1 ? nil : name
        // A worktree's branch usually names the feature it is for.
        let cardTitle = Self.title(rows: rows, customTitle: shownTab?.customTitle, branch: tab == nil && !primary ? branch : nil)
        return ActivityCardData(
            headline: headline, title: cardTitle, name: location, branch: branch, base: info?.summary?.base, baseAhead: info?.summary?.baseAhead,
            baseBehind: info?.summary?.baseBehind, primary: primary, pullRequest: info?.pullRequest,
            status: status,
            panes: rows,
            selected: selected,
            unavailable: project.status == .missing || model.worktreeRemovals.contains(project.id),
            offline: !project.serverId.isLocal && model.connectionState(project.serverId).isOffline
        )
    }

    @MainActor
    private static func status(tabs: [Tab], server: ServerId, model: AppModel) -> Status {
        let panes = tabs.flatMap(\.panes)
        let sessions = panes.compactMap(\.content.activitySession)
        guard let connection = model.connections[server] else { return .idle }
        let notifications = model.settings.notifications
        let agents = connection.activity.agents.filter { sessions.contains($0.session) }
        if notifications.showsInTabs(.blocked) && agents.contains(where: { $0.state == .blocked }) { return .attention }
        for session in sessions {
            guard let progress = connection.progress[session]?.progress else { continue }
            switch progress.state {
            case .error where notifications.showsInTabs(.error): return .error
            case .error: continue
            case .paused where notifications.showsInTabs(.working): return .paused
            case _ where notifications.showsInTabs(.working): return .working
            default: continue
            }
        }
        if connection.activity.events.contains(where: {
            !$0.read && sessions.contains($0.session) && model.reports($0) && notifications.showsInTabs($0.kind.status)
        }) { return .attention }
        if notifications.showsInTabs(.working) && agents.contains(where: { $0.state == .working }) { return .working }
        return .idle
    }

    /// An agent chat's provider: the composer's choice, as the pane's header
    /// shows it, else the activity's or the seed's.
    @MainActor
    private static func chatProvider(controller: AgentPaneController?, agent: AgentActivity?, seed: AgentChatProvider) -> AgentProvider {
        if let controller { return controller.selection.provider == .claude ? .claude : .codex }
        return agent?.provider ?? (seed == .claude ? .claude : .codex)
    }

    @MainActor
    private static func paneRows(tabs: [Tab], server: ServerId, model: AppModel) -> [PaneRow] {
        tabs.flatMap { tab -> [PaneRow] in
            let active = model.state.shownPane(tab)
            return tab.layout.leaves.compactMap { id in
                tab.pane(id).map { paneRow($0, active: $0.id == active, server: server, model: model) }
            }
        }
    }

    @MainActor
    private static func paneRow(_ pane: Pane, active: Bool, server: ServerId, model: AppModel) -> PaneRow {
        let connection = model.connections[server]
        let session = pane.content.activitySession
        let agent = session.flatMap { connection?.agent($0) }
        let title = pane.title.trimmingCharacters(in: .whitespaces)
        var icon = PaneRow.Icon.kind(PaneKind(pane.content))
        var text: String
        var detail: String?
        var topic: PaneRow.Topic?
        switch pane.content {
        case .agent(_, let seed):
            let controller = model.panes.controller(for: pane.id) as? AgentPaneController
            let provider = chatProvider(controller: controller, agent: agent, seed: seed)
            icon = .agent(provider)
            // A chat's task is its opening message, so tidy it into a title.
            let task = (agent?.title ?? controller?.title).flatMap { $0 == "Agent" ? nil : chatTopic($0) }
            text = task ?? provider.displayName
            topic = task.map { .task($0) }
        case .editor(let path), .diff(let path, _):
            icon = .file(basename(path))
            text = pane.content.nativeTitle ?? basename(path)
            topic = .file(text)
        case .browser:
            if let favicon = model.panes.controller(for: pane.id)?.icon { icon = .image(favicon) }
            text = title.isEmpty ? pane.content.defaultTitle : title
            topic = title.isEmpty ? nil : .page(title)
        case .simulator:
            text = title.isEmpty ? pane.content.defaultTitle : title
            topic = .simulator(text)
        case .terminal:
            if let agent {
                icon = .agent(agent.provider)
                // A terminal agent titles its terminal with a summary of its task.
                let task = agent.title.flatMap { taskTitle($0, provider: agent.provider) } ?? taskTitle(title, provider: agent.provider)
                text = task ?? agent.provider.displayName
                topic = task.map { .task($0) }
            } else if let directory = idleDirectory(title) {
                text = shellName
                detail = directory
                topic = .folder(directory)
            } else {
                text = title.isEmpty ? pane.content.defaultTitle : command(title)
                topic = title.isEmpty ? nil : .command(text)
            }
        }
        let status = paneStatus(session: session, agent: agent, connection: connection, model: model)
        let since = status == .working || status == .blocked ? agent?.workingSince.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } : nil
        return PaneRow(id: pane.id, icon: icon, title: text, detail: detail, status: status, workingSince: since, active: active, topic: topic)
    }

    /// What a tab is about, the same whichever pane is focused: its custom
    /// title, else the task of its lead agent (the one waiting for you, else
    /// working, else the first), its worktree's branch, then the first
    /// command, page, simulator, file or folder its panes show.
    static func title(rows: [PaneRow], customTitle: String?, branch: String?) -> String {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespaces), !customTitle.isEmpty { return customTitle }
        let agents = rows.filter { if case .task = $0.topic { return true } else { return false } }
        let lead = agents.first { $0.status == .blocked } ?? agents.first { $0.status == .working } ?? agents.first
        if let lead = lead?.topic { return lead.text }
        if let branch { return branch }
        let topics = rows.compactMap(\.topic)
        if let best = topics.min(by: { $0.rank < $1.rank }) { return best.text }
        return rows.first?.title ?? "Empty tab"
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

    /// What one pane is doing, by the same rules and Notifications settings
    /// as the card's status.
    @MainActor
    private static func paneStatus(session: SessionId?, agent: AgentActivity?, connection: ServerConnection?, model: AppModel) -> PaneRow.Status {
        guard let session, let connection else { return .idle }
        let notifications = model.settings.notifications
        if agent?.state == .blocked && notifications.showsInTabs(.blocked) { return .blocked }
        if let progress = connection.progress[session]?.progress {
            switch progress.state {
            case .error where notifications.showsInTabs(.error): return .error
            case .error: break
            case .paused where notifications.showsInTabs(.working): return .paused
            case _ where notifications.showsInTabs(.working): return progress.percent.map { .progress(Int($0)) } ?? .working
            default: break
            }
        }
        if agent?.state == .working && notifications.showsInTabs(.working) { return .working }
        let event = connection.activity.events.first {
            !$0.read && $0.session == session && model.reports($0) && notifications.showsInTabs($0.kind.status)
        }
        guard let event else { return .idle }
        return event.kind == .attention ? .blocked : .done
    }

    /// How long a turn has run: `43s` under a minute, `3m` under an hour,
    /// then `1h 3m`.
    static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Seconds until `elapsedText` changes: the next second under a minute,
    /// the next minute after.
    static func secondsUntilElapsedChanges(_ seconds: TimeInterval) -> TimeInterval {
        let seconds = max(seconds, 0)
        let step: TimeInterval = seconds < 60 ? 1 : 60
        return step - seconds.truncatingRemainder(dividingBy: step)
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
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

    /// The agent's task from its terminal title, without spinner glyphs;
    /// `nil` when the title only names the agent.
    static func taskTitle(_ title: String, provider: AgentProvider) -> String? {
        let task = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty, task.caseInsensitiveCompare(provider.displayName) != .orderedSame,
              task.caseInsensitiveCompare(provider.rawValue) != .orderedSame, task != "Claude Code"
        else { return nil }
        return task
    }

    static var shellName: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let name = shell.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "shell" : name
    }
}
