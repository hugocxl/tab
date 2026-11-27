import AppKit
import TabApp
import TabCore
import TabProtocol

/// Principal class loaded dynamically from `git-graph.bundle`.
@objc(TabGitGraphPluginFactory)
@MainActor
public final class GitGraphPluginFactory: TabPluginFactory {
    public required init() {
        super.init()
    }

    public override func makePlugin() -> any TabPlugin {
        GitGraphPlugin()
    }
}

/// The Git Graph plugin: adds the Git Graph tab to the right sidebar.
@MainActor
public final class GitGraphPlugin: TabPlugin {
    public let id: PluginId = .gitGraph
    private weak var panelContent: ProjectPanelContent<GitGraphController>?

    public init() {}

    public func activate(context: PluginContext) {
        let panel = PluginSidebarPanel(
            id: "gitGraph",
            pluginId: id,
            title: "Git Graph",
            icon: .gitGraph,
            order: 25
        ) { [weak self] model in
            let content = ProjectPanelContent<GitGraphController>(
                panelId: "gitGraph",
                make: { [weak model] project in
                    guard !project.home, let host = model?.projectHost(project.id) else { return nil }
                    let controller = GitGraphController(host: host)
                    controller.drawsCard = false
                    return (controller, host)
                },
                onShow: { $0.didShow() },
                onFocus: { $0.focus() }
            )
            self?.panelContent = content
            return content
        }
        context.registerSidebarPanel(panel)

        context.onGitChanged { [weak self] project in
            self?.panelContent?.controller(for: project)?.gitChanged()
        }

        context.onReconnected { [weak self, weak model = context.model] server in
            guard let model, let panelContent = self?.panelContent else { return }
            let projects = Set(model.state.projects.filter { $0.serverId == server }.map(\.id))
            for project in projects {
                panelContent.controller(for: project)?.reconnected()
            }
        }
    }

    public func deactivate() {
        panelContent = nil
    }
}
