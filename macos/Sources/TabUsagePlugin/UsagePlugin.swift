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

/// The AI Usage plugin: adds the agents' plan limits to the right sidebar
/// and a quick-glance floating card toggled from the left sidebar's footer.
@MainActor
public final class UsagePlugin: TabPlugin {
    public let id: PluginId = .usage
    private let store = UsageStore()
    private weak var panelContent: UsagePanelContent?
    private weak var compactCard: UsageCompactCardContent?
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
            let store = self?.store ?? UsageStore()
            let content = UsagePanelContent(model: model, store: store)
            content.controller.apply(self?.config ?? UsageConfig())
            self?.panelContent = content
            return content
        }
        context.registerSidebarPanel(panel)

        let footerItem = PluginSidebarFooterItem(
            id: UsageCompactCardContent.id,
            pluginId: id,
            title: "AI Usage",
            icon: .chartLine,
            order: 30
        ) { [weak self] model, dismiss in
            let store = self?.store ?? UsageStore()
            let content = UsageCompactCardContent(model: model, store: store, dismiss: dismiss)
            content.controller.apply(self?.config ?? UsageConfig())
            self?.compactCard = content
            return content
        }
        context.registerSidebarFooterItem(footerItem)

        context.onReconnected { [weak self] server in
            self?.panelContent?.controller.reconnected(server)
            self?.compactCard?.controller.reconnected(server)
        }
        context.onAgentProvidersChanged { [weak self] server in
            self?.panelContent?.controller.providersChanged(server)
            self?.compactCard?.controller.providersChanged(server)
        }
        context.onSettingsChanged { [weak self] settings in
            guard let self else { return }
            let next = UsageConfig.current(in: settings)
            guard next != config else { return }
            config = next
            panelContent?.controller.apply(next)
            compactCard?.controller.apply(next)
        }
        context.registerSettingsView { store in
            AnyView(UsageSettingsView(store: store, config: UsageConfig.current(in: store.settings)))
        }
    }

    public func deactivate() {
        panelContent = nil
        compactCard = nil
    }
}

/// The right-sidebar content: the limits of the current project's server.
@MainActor
final class UsagePanelContent: RightPanelContent {
    static let id = "usage"

    let panelId = UsagePanelContent.id
    let controller: UsagePanelController
    var view: NSView { controller.view }

    init(model: AppModel, store: UsageStore) {
        controller = UsagePanelController(theme: model.theme, store: store) { [weak model] project in
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

/// The left-sidebar floating card content: a compressed view of the current
/// project's server limits.
@MainActor
final class UsageCompactCardContent: SidebarFooterCardContent {
    static let id = "usage-summary"

    let controller: UsageCompactCardController
    var view: NSView { controller.view }
    var onPreferredSizeChange: (() -> Void)? {
        get { controller.onPreferredSizeChange }
        set { controller.onPreferredSizeChange = newValue }
    }

    init(model: AppModel, store: UsageStore, dismiss: @escaping @MainActor () -> Void) {
        controller = UsageCompactCardController(
            theme: model.theme,
            store: store,
            onOpenPanel: { [weak model] in
                model?.selectRightPanel(UsagePanelContent.id)
                dismiss()
            }
        ) { [weak model] project in
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

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        controller.preferredHeight(forWidth: width)
    }
}
