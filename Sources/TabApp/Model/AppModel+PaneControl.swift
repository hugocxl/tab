import Foundation
import TabClient
import TabCore
import TabProtocol

/// `tab pane list`, `focus`, `close`, `zoom`, `move`, `swap`, `resize` and
/// `equalize`, and `tab tab close`: what agents and scripts do to the panes
/// and tabs the window shows, by the same paths the user's own actions take.
/// A caller may close its own pane or tab: it asked, so its own pane doesn't
/// ask the user, and it closes just after the reply, which it couldn't hear
/// once its pane is gone.
extension AppModel {
    /// Carries out `request`. Thrown errors are messages for the command line.
    func control(_ request: AppPaneControl) async throws -> JSONValue {
        let caller = request.caller.flatMap(state.paneShowing)
        let selector = paneSelector(caller: caller)
        switch request.action {
        case .list:
            return paneList(all: request.all ?? false, caller: caller)
        case .focus:
            focusPane(try selector.resolve(request.pane))
            presenter?.bringToFront()
        case .close:
            let pane = try selector.resolve(request.pane)
            if let project = worktreeClosingLastPane(pane) {
                closeWorktree(project, approved: pane == caller ? [pane] : [], requiresConfirmation: true)
                return .bool(true)
            }
            guard pane != caller else {
                Task { await commitClose([pane]) }
                return .bool(true)
            }
            guard await controller(for: pane)?.willClose() ?? true else { throw ModelError("the user kept the pane open") }
            guard await controller(for: pane)?.commitClose() ?? true else { throw ModelError("the pane couldn't close") }
            remove(pane)
            focusActiveContent()
        case .closeTab:
            let (project, tab) = try resolveTab(request.pane, selector: selector)
            let panes = tab.panes.map(\.id)
            let own = caller.map(panes.contains) ?? false
            if project.kind == .worktree {
                closeWorktree(project.id, approved: caller.map { [$0] } ?? [])
                return .bool(true)
            }
            guard await panesWillClose(panes.filter { $0 != caller }) else { throw ModelError("the user kept the tab open") }
            guard !own else {
                Task { await commitClose(panes) }
                return .bool(true)
            }
            guard await commitClose(panes) else { throw ModelError("a pane of the tab couldn't close") }
        case .zoom:
            let pane = try selector.resolve(request.pane)
            let zoomed = tab(holding: pane)?.zoomed == pane
            if zoomed != (request.zoomed ?? true) { try apply { try $0.toggleZoom(pane) } }
            focusActiveContent()
        case .move:
            let pane = try selector.resolve(request.pane)
            let anchor = try selector.resolve(request.other)
            guard let edge = request.edge else { throw ModelError("give the side to move the pane to") }
            try requireSameTab(pane, anchor, doing: "move a pane beside itself")
            try apply { try $0.dockPane(pane, beside: anchor, edge: edge, level: 0) }
            focusActiveContent()
        case .swap:
            let pane = try selector.resolve(request.pane)
            let other = try selector.resolve(request.other)
            try requireSameTab(pane, other, doing: "swap a pane with itself")
            try apply { try $0.movePane(pane, onto: other, edge: nil) }
            focusActiveContent()
        case .resize:
            let pane = try selector.resolve(request.pane)
            guard let percent = request.percent, (1...100).contains(percent), let axis = request.axis else {
                throw ModelError("give the share of the tab, from 1 to 100 percent")
            }
            guard let tab = tab(holding: pane),
                  let change = tab.layout.resize(pane, to: Double(percent) / 100, along: axis) else {
                throw ModelError("no pane is \(axis == .horizontal ? "left or right of" : "above or below") it to give it room")
            }
            try apply { try $0.setRatio(tab.id, path: change.path, ratio: change.ratio) }
        case .equalize:
            let pane = try selector.resolve(request.pane)
            try apply { try $0.equalizeSplits(pane) }
        }
        return .bool(true)
    }

    /// Names panes against `caller`, the pane the command runs in.
    func paneSelector(caller: PaneId?) -> PaneSelector {
        let candidates = state.projects.flatMap(\.tabs).flatMap(\.panes).map { pane in
            PaneSelector.Candidate(id: pane.id, session: pane.content.activitySession, title: pane.title)
        }
        return PaneSelector(candidates: candidates, caller: caller, focused: state.window.activePane,
                            neighbor: { [state] pane, direction in state.neighbor(of: pane, direction) })
    }

    /// The tab `name` gives by its ID or a unique start of one, else the tab
    /// holding the pane it names, with its project.
    func resolveTab(_ name: String?, selector: PaneSelector) throws -> (Project, Tab) {
        let tabs = state.projects.flatMap { project in project.tabs.map { (project, $0) } }
        let word = name?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if let uuid = UUID(uuidString: word), let found = tabs.first(where: { $0.1.id.uuid == uuid }) { return found }
        if PaneSelector.isPrefix(word) {
            let started = tabs.filter { $0.1.id.description.hasPrefix(word) }
            if started.count > 1 { throw ModelError("\(word) names more than one tab; use its ID from tab pane list --all") }
            if let found = started.first { return found }
        }
        let pane = try selector.resolve(name)
        guard let found = tabs.first(where: { $0.1.layout.contains(pane) }) else { throw ModelError("that pane is in no tab") }
        return found
    }

    /// The tab holding `pane`.
    func tab(holding pane: PaneId) -> Tab? {
        state.projects.lazy.flatMap(\.tabs).first { $0.layout.contains(pane) }
    }

    private func requireSameTab(_ pane: PaneId, _ other: PaneId, doing action: String) throws {
        guard pane != other else { throw ModelError("can't \(action)") }
        guard let tab = tab(holding: pane), tab.layout.contains(other) else {
            throw ModelError("both panes must be in the same tab")
        }
    }

    /// Applies `change` like `edit`, but hands its error to the caller
    /// instead of showing it.
    func apply(_ change: (inout AppState) throws -> Void) throws {
        var next = state
        try change(&next)
        guard next != state else { return }
        state = next
        stateDidChange()
    }

    // MARK: Listing

    /// The tab holding `caller`, else the tab on screen, or with `all` every
    /// tab, each with its panes: `{"tabs":[{…,"panes":[{…}]}]}`.
    func paneList(all: Bool, caller: PaneId?) -> JSONValue {
        var tabs = state.projects.flatMap { project in project.tabs.map { (project, $0) } }
        if !all {
            let shown = activeTab?.id
            let own = caller.flatMap { pane in tabs.first { $0.1.layout.contains(pane) } }
            tabs = (own ?? tabs.first { $0.1.id == shown }).map { [$0] } ?? []
        }
        return .object(["tabs": .array(tabs.map { project, tab in record(tab, of: project, caller: caller) })])
    }

    private func record(_ tab: Tab, of project: Project, caller: PaneId?) -> JSONValue {
        let onScreen = project.id == currentProject.id && activeTab?.id == tab.id
        let titled = tab.customTitle ?? (project.home ? tab.panes.first.map(\.title) ?? project.name : project.name)
        let panes = tab.layout.rects.compactMap { id, rect -> JSONValue? in
            guard let pane = tab.pane(id) else { return nil }
            var flags: [String] = []
            if id == caller { flags.append("self") }
            if onScreen && id == state.window.activePane { flags.append("focused") }
            if tab.zoomed == id { flags.append("zoomed") }
            if !onScreen || (tab.zoomed != nil && tab.zoomed != id) { flags.append("hidden") }
            var fields: [String: JSONValue] = [
                "id": .string(id.description),
                "kind": .string(Self.kindName(pane.content)),
                "position": .string(PaneSelector.position(rect)),
                "flags": .string(flags.joined(separator: ",")),
                "title": .string(pane.title),
                "project": .string(project.name),
                "tab": .string(tab.id.description),
                "x": .int(Int64((rect.x * 100).rounded())),
                "y": .int(Int64((rect.y * 100).rounded())),
                "width": .int(Int64((rect.width * 100).rounded())),
                "height": .int(Int64((rect.height * 100).rounded())),
            ]
            if let session = pane.content.activitySession {
                fields["session"] = .string(session.description)
                fields["sessionName"] = .string(SessionName.of(session))
            }
            switch pane.content {
            case .agent(_, let provider): fields["provider"] = .string(provider.rawValue)
            case .browser(let browser):
                let live = browserProfiles.panes.pane(id.description)?.page.url
                if let url = live.flatMap({ $0.isEmpty ? nil : $0 }) ?? browser.url { fields["url"] = .string(url) }
            case .editor(let path): fields["path"] = .string(path)
            case .diff(let path, let staged):
                fields["path"] = .string(path)
                fields["staged"] = .bool(staged)
            case .simulator(let simulator):
                if let name = simulator.name { fields["simulator"] = .string(name) }
            case .terminal:
                if let directory = (controller(for: id) as? TerminalPane)?.directory {
                    fields["directory"] = .string(directory.rawValue)
                }
            }
            return .object(fields)
        }
        return .object([
            "id": .string(tab.id.description),
            "title": .string(titled),
            "project": .string(project.name),
            "projectId": .string(project.id.description),
            "directory": .string(project.directory.rawValue),
            "kind": .string(project.home ? "home" : project.kind == .worktree ? "worktree" : "project"),
            "shown": .bool(onScreen),
            "panes": .array(panes),
        ])
    }

    static func kindName(_ content: PaneContent) -> String {
        switch PaneKind(content) {
        case .terminal: "terminal"
        case .agent: "agent"
        case .browser: "browser"
        case .simulator: "simulator"
        case .editor: "editor"
        case .diff: "diff"
        }
    }
}
