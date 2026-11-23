import AppKit
import TabCore
import TabProtocol

/// The host API passed to a plugin during `activate(context:)`.
/// Every registration made through `PluginContext` is tracked under the plugin's
/// `PluginId` and automatically torn down when the plugin is uninstalled.
@MainActor
public final class PluginContext {
    public let pluginId: PluginId
    public unowned let model: AppModel
    private unowned let manager: PluginManager

    init(pluginId: PluginId, model: AppModel, manager: PluginManager) {
        self.pluginId = pluginId
        self.model = model
        self.manager = manager
    }

    /// Returns the shared project host for `project`.
    public func projectHost(for project: ProjectId) -> ProjectHost {
        model.projectHost(project)
    }

    /// Registers a right-sidebar panel owned by this plugin.
    public func registerSidebarPanel(_ panel: PluginSidebarPanel) {
        manager.registerSidebarPanel(panel, for: pluginId)
    }

    /// Registers a pane content provider (such as `.diff`) owned by this plugin.
    public func registerPane(_ kind: PaneKind, factory: @escaping PaneRegistry.Factory) {
        manager.registerPane(kind, factory: factory, for: pluginId)
    }

    /// Subscribes to server file-change events.
    public func onFilesChanged(_ handler: @escaping @MainActor (ProjectId, FileChanges) -> Void) {
        manager.addFilesChangedHandler(handler, for: pluginId)
    }

    /// Subscribes to Git repository change events.
    public func onGitChanged(_ handler: @escaping @MainActor (ProjectId) -> Void) {
        manager.addGitChangedHandler(handler, for: pluginId)
    }

    /// Subscribes to server reconnect events.
    public func onReconnected(_ handler: @escaping @MainActor (ServerId) -> Void) {
        manager.addReconnectedHandler(handler, for: pluginId)
    }

    /// Subscribes to Home terminal folder changes (used by Explorer).
    public func onUpdateFilesRoot(_ handler: @escaping @MainActor (Project) -> Void) {
        manager.addUpdateFilesRootHandler(handler, for: pluginId)
    }
}
