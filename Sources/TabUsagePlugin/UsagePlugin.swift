import AppKit
import SwiftUI
import TabApp
import TabCore
import TabProtocol

/// Principal class loaded dynamically from `usage.bundle`.
@objc(TabUsagePluginFactory)
@MainActor
public final class UsagePluginFactory: TabPluginFactory {
    public required init() {
        super.init()
    }

    public override func makePlugin() -> any TabPlugin {
        UsagePlugin()
    }
}

/// The AI Usage plugin: adds the agents' plan limits to the right sidebar.
@MainActor
public final class UsagePlugin: TabPlugin {
    public let id: PluginId = .usage
    private weak var panelContent: UsagePanelContent?
    private var config = UsageConfig()

    public init() {}

    public func activate(context: PluginContext) {
        config = UsageConfig.current(in: context.model.settings)
        let panel = PluginSidebarPanel(
            id: UsagePanelContent.id,
            pluginId: id,
            title: "AI Usage",
            icon: .chartLine,
            order: 30
        ) { [weak self] model in
            let content = UsagePanelContent(model: model)
            content.controller.apply(self?.config ?? UsageConfig())
            self?.panelContent = content
            return content
        }
        context.registerSidebarPanel(panel)

        context.onReconnected { [weak self] server in
            self?.panelContent?.controller.reconnected(server)
        }
        context.onSettingsChanged { [weak self] settings in
            guard let self else { return }
            let next = UsageConfig.current(in: settings)
            guard next != config else { return }
            config = next
            panelContent?.controller.apply(next)
        }
        context.registerSettingsView { store in
            AnyView(UsageSettingsView(store: store, config: UsageConfig.current(in: store.settings)))
        }
    }

    public func deactivate() {
        panelContent = nil
    }
}

/// The right-sidebar content: the limits of the current project's server.
@MainActor
final class UsagePanelContent: RightPanelContent {
    static let id = "usage"

    let panelId = UsagePanelContent.id
    let controller: UsagePanelController
    var view: NSView { controller.view }

    init(model: AppModel) {
        controller = UsagePanelController(theme: model.theme) { [weak model] project in
            guard let model else { return nil }
            let server = model.state.projectServer(project)
            return (model.sideClient(for: project), server.flatMap { model.serverName($0) })
        }
    }

    func projectDidChange(_ project: Project?) {
        controller.show(project: project.map { ($0.id, $0.serverId) })
    }

    func didShow() {
        controller.didShow()
    }

    func didHide() {
        controller.didHide()
    }

    func focusContent() {
        view.window?.makeFirstResponder(view)
    }
}
