import AppKit
import TabApp
import TabCore
import TabProtocol

/// Principal class loaded dynamically from `diff.bundle`.
@objc(TabDiffPluginFactory)
@MainActor
public final class DiffPluginFactory: TabPluginFactory {
    public required init() {
        super.init()
    }

    public override func makePlugin() -> any TabPlugin {
        DiffPlugin()
    }
}

/// A diff pane in a pane card, provided by the Diff View plugin.
@MainActor
public final class DiffPaneContent: PaneContentController {
    public let controller: DiffPaneController
    private let host: DiffHost
    public var titleDidChange: (() -> Void)?

    public init(host: DiffHost, path: String, staged: Bool) {
        self.host = host
        controller = DiffPaneController(host: host, path: path, staged: staged)
    }

    public var view: NSView { controller.view }
    public var title: String { PaneContent.diff(path: controller.path, staged: controller.staged).nativeTitle ?? controller.path }
    public var icon: NSImage? { FileIcon.image(for: controller.path, theme: .shared, size: Metrics.glyph) }
    public func focusContent() { controller.view.window?.makeFirstResponder(controller.rowsView) }
    public func didShow() { controller.didShow() }
    public func didHide() {}
    public func willClose() async -> Bool { true }
}

/// The Diff View plugin: adds the Source Control tab to the right sidebar and
/// provides `.diff` split panes.
@MainActor
public final class DiffPlugin: TabPlugin {
    public let id: PluginId = .diff
    private weak var panelContent: ProjectPanelContent<SourceControlController>?

    public init() {}

    public func activate(context: PluginContext) {
        let panel = PluginSidebarPanel(
            id: "sourceControl",
            pluginId: id,
            title: "Source Control",
            icon: .gitBranch,
            shortcut: .toggleSourceControl,
            order: 20
        ) { [weak self] model in
            let content = ProjectPanelContent<SourceControlController>(
                panelId: "sourceControl",
                make: { [weak model] project in
                    guard !project.home, let host = model?.projectHost(project.id) else { return nil }
                    let controller = SourceControlController(host: host)
                    controller.drawsCard = false
                    return (controller, host)
                },
                onShow: { $0.didShow() },
                onFocus: { $0.focusMessage() }
            )
            self?.panelContent = content
            return content
        }
        context.registerSidebarPanel(panel)

        context.registerPane(.diff) { paneContext in
            guard case let .diff(path, staged) = paneContext.pane.content else {
                return EmptyDiffFallbackController(title: paneContext.pane.title)
            }
            let host = paneContext.model.projectHost(paneContext.project.id)
            return DiffPaneContent(host: host, path: path, staged: staged)
        }

        context.onGitChanged { [weak self, weak model = context.model] project in
            self?.panelContent?.controller(for: project)?.gitChanged()
            guard let model else { return }
            for (id, controller) in model.panes.all where model.state.paneProject(id) == project {
                (controller as? DiffPaneContent)?.controller.gitChanged()
            }
        }

        context.onReconnected { [weak self, weak model = context.model] server in
            guard let model else { return }
            let projects = Set(model.state.projects.filter { $0.serverId == server }.map(\.id))
            for project in projects {
                self?.panelContent?.controller(for: project)?.reconnected()
                for (id, controller) in model.panes.all where model.state.paneProject(id) == project {
                    (controller as? DiffPaneContent)?.controller.reconnected()
                }
            }
        }
    }

    public func deactivate() {
        panelContent = nil
    }
}

@MainActor
private final class EmptyDiffFallbackController: PaneContentController {
    let view = NSView()
    let title: String
    var titleDidChange: (() -> Void)?

    init(title: String) {
        self.title = title.isEmpty ? "Diff" : title
    }

    func focusContent() {}
    func willClose() async -> Bool { true }
    func didShow() {}
    func didHide() {}
}
