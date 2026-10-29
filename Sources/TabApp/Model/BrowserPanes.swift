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
            openBrowser(url: url, profile: profile)
            return
        }
        guard state.project(project) != nil else { return }
        edit { _ = try $0.splitBrowser(pane, BrowserPane(url: url, profile: profile), focus: true) }
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
        let target = try browserProject(project: project, worktree: worktree)
        var opened: PaneId?
        guard edit({ state in
            if split, let active = state.window.activePane, state.paneProject(active) == target {
                opened = try state.splitBrowser(active, BrowserPane(url: url, profile: profile), focus: false)
            } else {
                opened = try state.openBrowser(target, BrowserPane(url: url, profile: profile), select: false).1
            }
        }), let opened, let controller = (controller(for: opened) as? BrowserPaneContent)?.controller else {
            throw ModelError("Could not open a browser pane")
        }
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
                                      active: state.window.activePane == pane.id)
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

    /// The project `tab browser` names by project and worktree name, or the
    /// current one.
    private func browserProject(project: String?, worktree: String?) throws -> ProjectId {
        guard project != nil || worktree != nil else { return currentProject.id }
        let parent = try project.map { name -> Project in
            guard let found = state.projects.first(where: {
                $0.parentId == nil && ($0.name == name || $0.directory.rawValue == name || $0.id.description == name)
            }) else { throw ModelError("no project named \(name)") }
            return found
        }
        if let worktree {
            guard let found = state.projects.first(where: {
                $0.parentId != nil && $0.name == worktree && (parent == nil || $0.parentId == parent?.id)
            }) else { throw ModelError("no worktree named \(worktree)") }
            return found.id
        }
        return parent?.id ?? currentProject.id
    }
}
