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
        /// Idle, with shells an agent left running in the background.
        case background
        /// A terminal runs a command.
        case running
        case idle
    }

    /// One pane in the card's list: what it is, its title and what it is doing.
    struct PaneRow: Equatable {
        enum Icon: Equatable {
            case kind(PaneKind)
            case agent(AgentProvider)
            case command(AppIcon)
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
            /// Idle, with shells the agent left running in the background.
            case background
            /// A terminal runs a command, such as a script or a server.
            case running

            /// How much the status asks for the user's eye, for the card's
            /// title row to show the most pressing of its panes'.
            var urgency: Int {
                switch self {
                case .idle: return 0
                case .background: return 1
                case .running: return 2
                case .done: return 3
                case .paused: return 4
                case .working, .progress: return 5
                case .error: return 6
                case .blocked: return 7
                }
            }
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

        /// An agent or shell the pane's agent started that still runs.
        struct Subtask: Equatable {
            var id: String
            var icon: Icon
            var title: String
            var shell: Bool
            var since: Date?
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
        /// What the pane's agent runs in the background, oldest first.
        var subtasks: [Subtask] = []
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

    /// The pane the card's title row stands for: a lone pane, else the most
    /// pressing one, else the one the title names, else the focused one.
    /// Several panes list their own folders and running times, so the title
    /// row leaves them out.
    var lead: PaneRow? {
        guard panes.count > 1 else { return panes.first }
        let pressing = panes.filter { $0.status != .idle }.max { $0.status.urgency < $1.status.urgency }
        guard var lead = pressing ?? panes.first(where: { $0.topic?.text == title }) ?? panes.first(where: \.active) ?? panes.first else { return nil }
        lead.detail = nil
        lead.workingSince = nil
        return lead
    }

    @MainActor
    static func make(project: Project, tab: Tab?, primary: Bool, model: AppModel) -> ActivityCardData {
        let tabs = tab.map { [$0] } ?? project.tabs
        let selectedTab = model.state.window.selectedTab[project.id]
        let shownTab = tabs.first { $0.id == selectedTab } ?? tabs.first
        let shownId = shownTab.flatMap { model.state.shownPane($0) }
        let shownPane = shownTab?.displayedPane(active: shownId)
        let title = shownTab.map { $0.title(active: shownId).trimmingCharacters(in: .whitespaces) } ?? ""
        // The pane is the project's, so its server is the project's.
        let agent = shownPane?.content.activitySession.flatMap { model.connections[project.serverId]?.agent($0) }
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
        let info = project.home ? nil : model.shownGit(project.id)
        let branch = info?.summary?.branch.flatMap { $0 == project.name ? nil : $0 }
        let name = tab != nil ? shownPane.flatMap { idleDirectory($0.title) } : project.name
        let selected: Bool
        if model.selectedWorktreeCreation != nil {
            selected = false
        } else if let tab {
            selected = model.currentProject.id == project.id && model.activeTab?.id == tab.id
        } else {
            selected = model.currentProject.id == project.id
        }
        let status = status(tabs: tabs, server: project.serverId, model: model)
        let rows = paneRows(tabs: tabs, server: project.serverId, model: model)
        // A Home tab's folder follows its shell's name in the title or pane rows.
        let location = tab != nil ? nil : name
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

    /// The most pressing of the card's panes' statuses, by the same rules.
    @MainActor
    private static func status(tabs: [Tab], server: ServerId, model: AppModel) -> Status {
        let rows = tabs.flatMap(\.panes).map { paneStatus($0, server: server, model: model) }
        switch rows.max(by: { $0.urgency < $1.urgency }) ?? .idle {
        case .blocked, .done: return .attention
        case .error: return .error
        case .working, .progress: return .working
        case .paused: return .paused
        case .background: return .background
        case .running: return .running
        case .idle: return .idle
        }
    }

    /// An agent chat's provider: the composer's choice, as the pane's header
    /// shows it, else the activity's or the seed's.
    @MainActor
    private static func chatProvider(controller: AgentPaneController?, agent: AgentActivity?, seed: AgentChatProvider) -> AgentProvider {
        if let controller { return controller.selection.provider.activityProvider }
        return agent?.provider ?? seed.activityProvider
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
        case .browser(let browser):
            // A pane not shown yet has no page; its site's last favicon stands in.
            let favicon = model.panes.controller(for: pane.id).map(\.icon) ?? browser.url.flatMap { model.rememberedFavicon(for: $0) }
            if let favicon { icon = .image(favicon) }
            text = title.isEmpty ? pane.content.defaultTitle : title
            topic = title.isEmpty ? nil : .page(title)
        case .simulator:
            text = title.isEmpty ? pane.content.defaultTitle : title
            topic = .simulator(text)
        case .terminal:
            let controller = model.panes.controller(for: pane.id) as? TerminalPane
            icon = .command(TerminalCommandIcon.icon(for: controller?.session?.process))
            if let agent {
                icon = .agent(agent.provider)
                // A terminal agent titles its terminal with a summary of its task.
                let task = agent.title.flatMap { taskTitle($0, provider: agent.provider) } ?? taskTitle(title, provider: agent.provider)
                text = task ?? agent.provider.displayName
                topic = task.map { .task($0) }
            } else if let directory = idleDirectory(title) {
                text = shellName
                detail = idlePath(title)
                topic = .folder(directory)
            } else {
                text = title.isEmpty ? pane.content.defaultTitle : command(title)
                topic = title.isEmpty ? nil : .command(text)
            }
        }
        let status = paneStatus(pane, server: server, model: model)
        let notifications = model.settings.notifications
        let started: UInt64?
        switch status {
        case .working, .blocked, .paused: started = agent?.workingSince
        case .running: started = session.flatMap { connection?.metadata[$0]?.processSince }
        default: started = nil
        }
        let since = started.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let subtasks = (agent?.subtasks ?? []).map { task -> PaneRow.Subtask in
            let subtaskIcon: PaneRow.Icon
            if task.shell {
                subtaskIcon = TerminalCommandIcon.subtaskIcon(command: task.command, title: task.title)
            } else if let provider = task.provider ?? agent?.provider {
                subtaskIcon = .agent(provider)
            } else {
                subtaskIcon = .kind(.agent)
            }
            return PaneRow.Subtask(id: task.id, icon: subtaskIcon, title: task.title, shell: task.shell,
                                   since: task.startedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) })
        }
        return PaneRow(id: pane.id, icon: icon, title: text, detail: detail, status: status, workingSince: since, active: active,
                       topic: topic, subtasks: notifications.showsInTabs(.working) ? subtasks : [])
    }

    /// What a tab is about, the same whichever pane is focused: its custom
    /// title, else the task of its lead agent (the one waiting for you, else
    /// working, else the first), its worktree's branch, then the first
    /// command, page, simulator, file or folder its panes show.
    static func title(rows: [PaneRow], customTitle: String?, branch: String?) -> String {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespaces), !customTitle.isEmpty { return customTitle }
        let agents = rows.filter { if case .task = $0.topic { return true } else { return false } }
        let lead = agents.first { $0.status == .blocked || $0.status == .error } ?? agents.first { $0.status == .working } ?? agents.first
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

    /// What one pane is doing, by Notifications settings: a failed turn is
    /// an error rather than a wait for you, a message on its way already
    /// counts as work, and a usage limit or a paused queue holds an agent up.
    @MainActor
    static func paneStatus(_ pane: Pane, server: ServerId, model: AppModel) -> PaneRow.Status {
        guard let session = pane.content.activitySession, let connection = model.connections[server] else { return .idle }
        let notifications = model.settings.notifications
        let agent = connection.agent(session)
        let sending = (model.panes.controller(for: pane.id) as? AgentPaneController)?.submitting == true
        if sending && notifications.showsInTabs(.working) { return .working }
        if agent?.condition == .failed {
            if notifications.showsInTabs(.error) { return .error }
        } else if agent?.state == .blocked && notifications.showsInTabs(.blocked) {
            return .blocked
        }
        if let progress = connection.progress[session]?.progress {
            switch progress.state {
            case .error where notifications.showsInTabs(.error): return .error
            case .error: break
            case .paused where notifications.showsInTabs(.working): return .paused
            case _ where notifications.showsInTabs(.working): return progress.percent.map { .progress(Int($0)) } ?? .working
            default: break
            }
        }
        if notifications.showsInTabs(.working) {
            if agent?.condition == .paused { return .paused }
            if agent?.state == .working { return .working }
            // An agent's own program is the agent, idle or not.
            if agent == nil, runsCommand(connection.metadata[session]) { return .running }
        }
        let event = connection.activity.events.first {
            !$0.read && $0.session == session && model.reports($0) && notifications.showsInTabs($0.kind.status)
        }
        switch event?.kind {
        case .attention?: return .blocked
        case .failed?: return .error
        case .some: return .done
        case nil: break
        }
        if agent?.condition == .background && notifications.showsInTabs(.working) { return .background }
        return .idle
    }

    /// Whether a terminal runs a program in front of its shell that works on
    /// its own, such as a script, a build or a server, rather than one that
    /// waits for typing, such as an editor, a pager or a remote shell.
    static func runsCommand(_ metadata: SessionMetadata?) -> Bool {
        guard let process = metadata?.process, !process.isShell else { return false }
        var name = String(process.name.split(separator: "/").last ?? "").lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return !name.isEmpty && !interactivePrograms.contains(name)
    }

    private static let interactivePrograms: Set<String> = [
        "vim", "nvim", "vi", "view", "nano", "micro", "emacs", "hx", "helix", "kak",
        "less", "more", "most", "man", "top", "htop", "btop", "atop", "glances", "watch",
        "ssh", "mosh", "mosh-client", "telnet", "tmux", "screen", "zellij",
        "lazygit", "lazydocker", "tig", "ranger", "nnn", "yazi", "lf", "mc", "fzf", "k9s",
        "psql", "mysql", "sqlite3", "redis-cli", "mongosh",
        "claude", "codex", "opencode", "cursor-agent", "copilot", "droid", "gemini", "aider", "amp", "kiro-cli",
    ]

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

    /// The agent's task from its terminal title, without spinner glyphs;
    /// `nil` when the title only names the agent.
    static func taskTitle(_ title: String, provider: AgentProvider) -> String? {
        let task = title.drop { !$0.isLetter && !$0.isNumber }.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty, task.caseInsensitiveCompare(provider.displayName) != .orderedSame,
              task.caseInsensitiveCompare(provider.rawValue) != .orderedSame, task != "Claude Code"
        else { return nil }
        return task
    }

    /// Read once: the environment is copied whole on every read, and every
    /// card asks for it on every change.
    static let shellName: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        let name = shell.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "shell" : name
    }()
}
