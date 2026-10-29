import Foundation
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

    var headline: Headline
    /// The second line's first word: the folder for Home terminals, the
    /// project or worktree name otherwise.
    var name: String
    var branch: String?
    var primary: Bool
    var pullRequest: UInt64?
    var status: Status
    var selected: Bool
    var unavailable: Bool

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
            } else if let directory = idleDirectory(title) {
                headline = .shell(shellName, directory: !project.home && directory != project.name ? directory : nil)
            } else {
                headline = .command(withoutHost(title))
            }
        }
        let info = project.home ? nil : model.git[project.id]
        let branch = info?.summary?.branch.flatMap { $0 == project.name ? nil : $0 }
        let name = tab != nil ? (shownPane.flatMap { idleDirectory($0.title) } ?? "Terminal") : project.name
        let selected: Bool
        if let tab {
            selected = model.currentProject.id == project.id && model.activeTab?.id == tab.id
        } else {
            selected = model.currentProject.id == project.id
        }
        return ActivityCardData(
            headline: headline, name: name, branch: branch, primary: primary, pullRequest: info?.pullRequest,
            status: status(tabs: tabs, server: project.serverId, model: model), selected: selected,
            unavailable: project.status == .missing || model.worktreeRemovals.contains(project.id)
        )
    }

    @MainActor
    private static func status(tabs: [Tab], server: ServerId, model: AppModel) -> Status {
        let panes = tabs.flatMap(\.panes)
        let sessions = panes.compactMap(\.content.session)
        guard let connection = model.connections[server] else { return .idle }
        let agents = connection.activity.agents.filter { sessions.contains($0.session) }
        if agents.contains(where: { $0.state == .blocked }) { return .attention }
        for session in sessions {
            guard let progress = connection.progress[session]?.progress else { continue }
            switch progress.state {
            case .error: return .error
            case .paused: return .paused
            default: return .working
            }
        }
        if connection.activity.events.contains(where: { !$0.read && sessions.contains($0.session) }) { return .attention }
        if agents.contains(where: { $0.state == .working }) { return .working }
        return .idle
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
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
