import AppKit
import TabClient
import TabCore
import TabProtocol

/// What the native editor and plugin panels/panes of one project need from the app.
@MainActor
public final class ProjectHost: FilesPanelHost, SourceControlHost, GitGraphHost, EditorHost, DiffHost {
    unowned let model: AppModel
    public let project: ProjectId

    init(model: AppModel, project: ProjectId) {
        self.model = model
        self.project = project
    }

    public var nativeProject: NativeProject {
        let found = model.state.project(project)
        return NativeProject(
            id: project, name: found.map { model.title(of: $0) } ?? "", path: found?.directory.rawValue ?? "",
            serverId: found?.serverId ?? .local, isLocal: found?.serverId.isLocal ?? true
        )
    }

    public var nativeTransport: NativeTransport? {
        model.sideClient(for: project).map { ServerAPITransport($0) }
    }

    public var theme: AppTheme { model.theme }

    public func showToast(_ message: String, style: Toast.Style) {
        model.presenter?.showToast(message, style: style)
    }

    public func confirm(title: String, message: String, confirmTitle: String, destructive: Bool, completion: @escaping (Bool) -> Void) {
        ConfirmSheet.present(on: model.presenter?.window, title: title, message: message, confirm: confirmTitle,
                             destructive: destructive, theme: model.theme, completion: completion)
    }

    // MARK: Files

    public func openEditor(path: String, line: Int?, column: Int?) {
        model.openEditor(project: project, path: path, line: line, column: column)
    }

    public func watchProjectFiles() {
        guard let side = model.sideClient(for: project) else { return }
        let project = project
        Task { _ = try? await side.files(FilesRequest(project: project, action: .watch)) }
    }

    // MARK: Source Control

    public var sourceControlTree: Bool { model.appearance.sourceControlTree }

    public func setSourceControlTree(_ enabled: Bool) {
        model.updateAppearance { $0.sourceControlTree = enabled }
    }

    public func openDiff(path: String, staged: Bool) {
        model.openDiff(project: project, path: path, staged: staged)
    }

    public func repositoryDidChange() {
        model.gitChanged(project)
    }

    // MARK: Git Graph

    public var supportsGitGraph: Bool { model.sideClient(for: project)?.supports(.gitGraph) ?? false }

    // MARK: Editor and diff

    public var codeFont: NSFont { NativeStyle.codeFont(model.terminalSettings) }

    public func editorTitleDidChange(_ title: String, dirty: Bool) {
        model.notify(.state)
    }
}

extension AppModel {
    /// The host shared by a project's native panels and panes.
    public func projectHost(_ project: ProjectId) -> ProjectHost {
        if let existing = projectHosts[project] { return existing }
        let host = ProjectHost(model: self, project: project)
        projectHosts[project] = host
        return host
    }

    /// Registers the built-in editor, browser and simulator pane kinds.
    /// Explorer and Diff View register themselves lazily when their plugins are installed.
    func registerNativeContent() {
        panes.register(.editor) { context in
            guard case .editor(let path) = context.pane.content else { return PlaceholderPaneController(context: context) }
            if let copy = RemoteFileCopy.url(for: path) {
                let host = RemoteCopyHost(model: context.model, project: context.project.id, path: copy.path)
                let content = EditorPaneContent(host: host, path: copy.path)
                _ = content.view
                content.controller.textView.isEditable = false
                return content
            }
            let host = context.model.projectHost(context.project.id)
            return EditorPaneContent(host: host, path: path)
        }
        panes.register(.browser) { context in
            guard case .browser(let state) = context.pane.content else { return PlaceholderPaneController(context: context) }
            return BrowserPaneContent(pane: context.pane.id, state: state, model: context.model)
        }
        panes.register(.simulator) { context in
            guard case .simulator(let state) = context.pane.content else { return PlaceholderPaneController(context: context) }
            return SimulatorPaneController(pane: context.pane.id, state: state, model: context.model,
                                           server: context.project.serverId)
        }
    }

    /// Files changed on a project's server: active plugins and editors follow.
    func filesChanged(_ project: ProjectId, _ changes: FileChanges) {
        plugins.dispatchFilesChanged(project, changes)
        guard changes.root == nil else { return }
        for editor in editors(in: project) { editor.controller.filesChanged(changes) }
    }

    /// Home's Files panel shows the focused terminal's folder, since Home's
    /// tabs belong to no project.
    func updateFilesRoot() {
        plugins.dispatchUpdateFilesRoot(currentProject)
    }

    /// The repository changed: active plugins and the cards follow.
    public func gitChanged(_ project: ProjectId) {
        plugins.dispatchGitChanged(project)
        refreshGit(project)
    }

    /// The side connection is back: native content and plugins list everything again.
    func nativeReconnected(_ server: ServerId) {
        plugins.dispatchReconnected(server)
        let projects = Set(state.projects.filter { $0.serverId == server }.map(\.id))
        for project in projects {
            for editor in editors(in: project) { editor.controller.reconnected() }
        }
        simulatorsChanged(server)
    }

    /// A server's simulators booted, stopped, came or went: its simulator panes follow.
    func simulatorsChanged(_ server: ServerId) {
        for (id, controller) in panes.all where state.paneServer(id) == server {
            (controller as? SimulatorPaneController)?.simulatorsChanged()
        }
    }

    private func editors(in project: ProjectId) -> [EditorPaneContent] {
        panes.all.compactMap { id, controller in
            state.paneProject(id) == project ? controller as? EditorPaneContent : nil
        }
    }

    /// Waits for draft bytes before normal application termination.
    func flushAgentDrafts() async throws {
        for controller in panes.all.compactMap({ $0.1 as? AgentPaneController }) {
            try await controller.flushDraft()
        }
    }

    /// Editors with unsaved changes, asked about before quitting.
    public var openEditors: [EditorPaneController] {
        panes.all.compactMap { ($0.1 as? EditorPaneContent)?.controller }
    }
}
