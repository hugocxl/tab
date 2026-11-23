import AppKit
import TabApp
import TabCore
import TabProtocol

/// Principal class loaded dynamically from `explorer.bundle`.
@objc(TabExplorerPluginFactory)
@MainActor
public final class ExplorerPluginFactory: TabPluginFactory {
    public required init() {
        super.init()
    }

    public override func makePlugin() -> any TabPlugin {
        ExplorerPlugin()
    }
}

/// The Files explorer plugin: adds the Files tab to the right sidebar.
@MainActor
public final class ExplorerPlugin: TabPlugin {
    public let id: PluginId = .explorer
    private weak var panelContent: ProjectPanelContent<FilesPanelController>?

    public init() {}

    public func activate(context: PluginContext) {
        let panel = PluginSidebarPanel(
            id: "files",
            pluginId: id,
            title: "Files",
            icon: .folder,
            shortcut: .toggleFiles,
            order: 10
        ) { [weak self] model in
            let content = ProjectPanelContent<FilesPanelController>(
                panelId: "files",
                make: { [weak model] project in
                    guard let host = model?.projectHost(project.id) else { return nil }
                    let controller = FilesPanelController(host: host)
                    controller.drawsCard = false
                    return (controller, host)
                },
                onShow: { $0.ensureRoot() },
                onFocus: { $0.focus() }
            )
            self?.panelContent = content
            return content
        }
        context.registerSidebarPanel(panel)

        context.onFilesChanged { [weak self] project, changes in
            self?.panelContent?.controller(for: project)?.filesChanged(changes)
        }

        context.onReconnected { [weak self, weak model = context.model] server in
            guard let model, let panelContent = self?.panelContent else { return }
            let projects = Set(model.state.projects.filter { $0.serverId == server }.map(\.id))
            for project in projects {
                panelContent.controller(for: project)?.reconnected()
            }
        }

        context.onUpdateFilesRoot { [weak self, weak model = context.model] project in
            guard project.home, let model,
                  let controller = self?.panelContent?.controller(for: project.id) else { return }
            let supported = model.sideClient(for: project.id)?.supports(.fileRoots) ?? false
            controller.show(root: supported ? model.newPaneDirectory(in: project) : nil)
        }
    }

    public func deactivate() {
        panelContent = nil
    }
}
