import AppKit
import TabClient
import TabCore
import TabProtocol

/// What the Files and Source Control panels and the editor and diff panes
/// of one project need from the app.
@MainActor
final class ProjectHost: FilesPanelHost, SourceControlHost, EditorHost, DiffHost {
    unowned let model: AppModel
    let project: ProjectId

    init(model: AppModel, project: ProjectId) {
        self.model = model
        self.project = project
    }

    var nativeProject: NativeProject {
        let found = model.state.project(project)
        return NativeProject(
            id: project, name: found.map { model.title(of: $0) } ?? "", path: found?.directory.rawValue ?? "",
            serverId: found?.serverId ?? .local, isLocal: found?.serverId.isLocal ?? true
        )
    }

    var nativeTransport: NativeTransport? {
        model.sideClient(for: project).map { ServerAPITransport($0) }
    }

    var theme: AppTheme { model.theme }

    func showToast(_ message: String, style: Toast.Style) {
        model.presenter?.showToast(message, error: style == .error)
    }

    func confirm(title: String, message: String, confirmTitle: String, destructive: Bool, completion: @escaping (Bool) -> Void) {
        ConfirmSheet.present(on: model.presenter?.window, title: title, message: message, confirm: confirmTitle,
                             destructive: destructive, theme: model.theme, completion: completion)
    }

    // MARK: Files

    func openEditor(path: String, line: Int?, column: Int?) {
        model.openEditor(project: project, path: path, line: line, column: column)
    }

    func watchProjectFiles() {
        guard let side = model.sideClient(for: project) else { return }
        let project = project
        Task { _ = try? await side.files(FilesRequest(project: project, action: .watch)) }
    }

    func closeFilesPanel() {
        if model.rightPanel == .files { model.toggleRightPanel(.files) }
    }

    // MARK: Source Control

    func openDiff(path: String, staged: Bool) {
        model.openDiff(project: project, path: path, staged: staged)
    }

    func repositoryDidChange() {
        model.gitChanged(project)
    }

    func closeSourceControl() {
        if model.rightPanel == .sourceControl { model.toggleRightPanel(.sourceControl) }
    }

    // MARK: Editor and diff

    var codeFont: NSFont { NativeStyle.codeFont(model.terminalSettings) }

    func editorTitleDidChange(_ title: String, dirty: Bool) {
        model.notify(.state)
    }
}

extension AppModel {
    /// The host shared by a project's native panels and panes.
    func projectHost(_ project: ProjectId) -> ProjectHost {
        if let existing = projectHosts[project] { return existing }
        let host = ProjectHost(model: self, project: project)
        projectHosts[project] = host
        return host
    }

    /// Registers the editor, diff and browser pane kinds and the right panels.
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
        panes.register(.diff) { context in
            guard case let .diff(path, staged) = context.pane.content else { return PlaceholderPaneController(context: context) }
            let host = context.model.projectHost(context.project.id)
            return DiffPaneContent(host: host, path: path, staged: staged)
        }
        panes.register(.servers) { context in
            context.model.remoteController.makePane()
        }
        panes.register(.browser) { context in
            guard case .browser(let state) = context.pane.content else { return PlaceholderPaneController(context: context) }
            return BrowserPaneContent(pane: context.pane.id, state: state, model: context.model)
        }
        rightPanelFactory = { kind, model in
            switch kind {
            case .files:
                return ProjectPanelContent.files { [weak model] project in model?.projectHost(project.id) }
            case .sourceControl:
                return ProjectPanelContent.sourceControl { [weak model] project in model?.projectHost(project.id) }
            }
        }
    }

    /// Files changed on a project's server: the Files panel and editors follow.
    func filesChanged(_ project: ProjectId, _ changes: FileChanges) {
        if let files = rightPanels[.files] as? ProjectPanelContent<FilesPanelController> {
            files.controller(for: project)?.filesChanged(changes)
        }
        for editor in editors(in: project) { editor.controller.filesChanged(changes) }
    }

    /// The repository changed: Source Control, diffs and the cards follow.
    func gitChanged(_ project: ProjectId) {
        if let panel = rightPanels[.sourceControl] as? ProjectPanelContent<SourceControlController> {
            panel.controller(for: project)?.gitChanged()
        }
        for diff in diffs(in: project) { diff.controller.gitChanged() }
        refreshGit(project)
    }

    /// The side connection is back: native content lists everything again.
    func nativeReconnected(_ server: ServerId) {
        let projects = Set(state.projects.filter { $0.serverId == server }.map(\.id))
        if let files = rightPanels[.files] as? ProjectPanelContent<FilesPanelController> {
            for project in projects { files.controller(for: project)?.reconnected() }
        }
        if let panel = rightPanels[.sourceControl] as? ProjectPanelContent<SourceControlController> {
            for project in projects { panel.controller(for: project)?.reconnected() }
        }
        for project in projects {
            for editor in editors(in: project) { editor.controller.reconnected() }
            for diff in diffs(in: project) { diff.controller.reconnected() }
        }
    }

    private func editors(in project: ProjectId) -> [EditorPaneContent] {
        panes.all.compactMap { id, controller in
            state.paneProject(id) == project ? controller as? EditorPaneContent : nil
        }
    }

    private func diffs(in project: ProjectId) -> [DiffPaneContent] {
        panes.all.compactMap { id, controller in
            state.paneProject(id) == project ? controller as? DiffPaneContent : nil
        }
    }

    /// Editors with unsaved changes, asked about before quitting.
    public var openEditors: [EditorPaneController] {
        panes.all.compactMap { ($0.1 as? EditorPaneContent)?.controller }
    }
}
