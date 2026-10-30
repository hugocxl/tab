import AppKit
import TabClient
import TabCore

/// A browser pane in a pane card.
@MainActor
final class BrowserPaneContent: PaneContentController {
    let pane: PaneId
    let controller: BrowserPaneController
    var titleDidChange: (() -> Void)?

    init(pane: PaneId, state: BrowserPane, model: AppModel) {
        self.pane = pane
        controller = model.browserProfiles.panes.pane(pane.description)
            ?? BrowserPaneController(tabId: pane.description, state: state, host: model)
    }

    var view: NSView { controller.view }
    var title: String { controller.pageTitle ?? "New Browser" }
    var icon: NSImage? { controller.favicon }

    func focusContent() {
        if controller.isBlank {
            controller.focusAddress()
        } else {
            controller.focusPage()
        }
    }

    func willClose() async -> Bool { true }
    func didShow() {}
    func didHide() {}

    func dispose() {
        controller.host?.browserProfiles.panes.unregister(controller.tabId)
    }

    var headerActions: [PaneAction] { [] }
}

extension AppModel: BrowserHost {
    public var browserSettings: BrowserSettings { settings.browser }

    public func openBrowserPane(url: String, profile: String, from source: BrowserPaneController) {
        guard let pane = PaneId(source.tabId), let project = state.paneProject(pane) else {
            openBrowser(url: url, profile: profile.isEmpty ? BrowserProfiles.defaultName : profile)
            return
        }
        guard state.project(project) != nil else { return }
        let browser: BrowserPane
        do {
            browser = try newBrowserState(url: url, profile: profile)
        } catch {
            report(error)
            return
        }
        edit { _ = try $0.splitBrowser(pane, browser, focus: true) }
        focusActiveContent()
    }

    public func browserPane(_ pane: BrowserPaneController, didChange saved: BrowserPane) {
        guard let id = PaneId(pane.tabId), let current = state.browser(id), current != saved else { return }
        edit { state in
            try state.setBrowserURL(id, saved.url)
            try state.setBrowserProfile(id, saved.profile)
        }
    }

    public func browserPane(_ pane: BrowserPaneController, didChangeTitle title: String?, favicon: NSImage?) {
        guard let id = PaneId(pane.tabId) else { return }
        panes.controller(for: id)?.titleDidChange?()
        let title = title ?? "New Browser"
        if state.pane(id)?.title != title { edit { try $0.setPaneTitle(id, title) } }
    }

    public func browserPaneRequestsClose(_ pane: BrowserPaneController) {
        guard let id = PaneId(pane.tabId) else { return }
        remove(id)
    }

    public func showToast(_ message: String, isError: Bool) {
        presenter?.showToast(message, error: isError)
    }

    public func manageBrowserProfiles() {
        showSettingsAction?(.browser)
    }

    public func openBrowserPane(url: String?, profile: String?, project: String?, worktree: String?, split: Bool) throws
        -> BrowserPaneController {
        let browser = try newBrowserState(url: url, profile: profile)
        let target = try browserProject(project: project, worktree: worktree)
        let select = project == nil && worktree == nil
        let anchor = split ? shownPane(of: target) : nil
        var opened: PaneId?
        guard edit({ state in
            if let anchor {
                opened = try state.splitBrowser(anchor, browser, focus: select)
            } else {
                opened = try state.openBrowser(target, browser, select: select).1
            }
        }), let opened, let controller = (controller(for: opened) as? BrowserPaneContent)?.controller else {
            throw ModelError("Could not open a browser pane")
        }
        if select { focusActiveContent() }
        return controller
    }

    public func browserTabs(project: String?, worktree: String?) throws -> [BrowserTab] {
        let scope: [Project]
        if project == nil && worktree == nil {
            scope = state.projects
        } else {
            let id = try browserProject(project: project, worktree: worktree)
            scope = state.projects.filter { $0.id == id }
        }
        return scope.flatMap { project in
            project.tabs.flatMap { tab in
                tab.panes.compactMap { pane -> BrowserTab? in
                    guard case .browser(let browser) = pane.content else { return nil }
                    let live = browserProfiles.panes.pane(pane.id.description)
                    return BrowserTab(tabId: pane.id.description, state: live?.state ?? browser,
                                      active: shownPane(of: project.id) == pane.id)
                }
            }
        }
    }

    public func browserPane(tabId: String) -> BrowserPaneController? {
        if let live = browserProfiles.panes.pane(tabId) { return live }
        guard let pane = state.browserPane(named: tabId) else { return nil }
        let controller = (controller(for: pane) as? BrowserPaneContent)?.controller
        _ = controller?.view
        return controller
    }

    public func closeBrowserPane(tabId: String) -> Bool {
        guard let pane = state.browserPane(named: tabId) else { return false }
        remove(pane)
        return true
    }

    /// Resolves creation settings before the pane is saved or shown.
    func newBrowserState(url: String?, profile: String?) throws -> BrowserPane {
        guard settings.browser.enabled else { throw ModelError("the built-in browser is disabled") }
        let chosen = try browserProfiles.profiles.first { $0.id == profile } ?? browserProfiles.resolve(profile)
        return BrowserPane(url: url ?? settings.browser.homeURL, profile: chosen.id)
    }

    /// The pane a project shows in its selected tab, even in the background.
    func shownPane(of project: ProjectId) -> PaneId? {
        if project == currentProject.id { return activePane }
        guard let selected = state.window.selectedTab[project],
              let tab = state.project(project)?.tabs.first(where: { $0.id == selected }) else { return nil }
        return state.shownPane(tab) ?? tab.layout.leaves.first
    }

    /// Resolves IDs, names and canonical paths, preferring the current family
    /// before searching all worktrees, as Codesh's `resolve_target` does.
    func browserProject(project: String?, worktree: String?) throws -> ProjectId {
        let root = try project.map { name in
            try uniqueBrowserProject(state.projects.filter { Self.browserNames($0, name) },
                                     missing: "no project named '\(name)'",
                                     ambiguous: "project '\(name)' is ambiguous; pass its ID")
        }
        guard let name = worktree else { return root ?? currentProject.id }
        let family = root ?? currentProject.parentId ?? currentProject.id
        let nearby = state.projects.filter {
            ($0.id == family || $0.parentId == family) && Self.browserNamesWorktree($0, name)
        }
        if nearby.count == 1 || root != nil {
            return try uniqueBrowserProject(nearby, missing: "no worktree named '\(name)'",
                                            ambiguous: "worktree '\(name)' is ambiguous; pass its ID")
        }
        return try uniqueBrowserProject(state.projects.filter {
            $0.parentId != nil && Self.browserNamesWorktree($0, name)
        }, missing: "no worktree named '\(name)'",
           ambiguous: "worktree '\(name)' is ambiguous across projects; pass --project to disambiguate")
    }

    private func uniqueBrowserProject(_ candidates: [Project], missing: String, ambiguous: String) throws -> ProjectId {
        guard let first = candidates.first else { throw ModelError(missing) }
        guard candidates.count == 1 else { throw ModelError(ambiguous) }
        return first.id
    }

    private static func browserNames(_ project: Project, _ text: String) -> Bool {
        if project.id.description == text || project.name == text { return true }
        guard text.hasPrefix("/") else { return false }
        if project.directory.rawValue == text { return true }
        guard FileManager.default.fileExists(atPath: text) else { return false }
        return URL(fileURLWithPath: text).resolvingSymlinksInPath().path == project.directory.rawValue
    }

    private static func browserNamesWorktree(_ project: Project, _ text: String) -> Bool {
        browserNames(project, text) || URL(fileURLWithPath: project.directory.rawValue).lastPathComponent == text
    }
}
