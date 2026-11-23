import AppKit
import struct SwiftUI.AnyView
import TabCore
import TabProtocol

/// Loads, activates, installs and uninstalls Tab plugins lazily on demand.
/// No plugin code is linked into `TabApp` or `TabDesktop`; each plugin's
/// `.bundle` lives in `TAB_DIR/Plugins/` only while installed.
@MainActor
public final class PluginManager {
    private unowned let model: AppModel
    public var installer: PluginInstaller

    private var activePlugins: [PluginId: any TabPlugin] = [:]
    /// Principal factory classes already loaded in this process's dyld image table.
    /// Kept so re-installing a plugin in the same session doesn't re-dlopen it.
    private var loadedFactories: [PluginId: TabPluginFactory.Type] = [:]
    private var states: [PluginId: PluginInstallState] = [:]

    private var panelsByPlugin: [PluginId: [PluginSidebarPanel]] = [:]
    private var panesByPlugin: [PluginId: Set<PaneKind>] = [:]
    private var settingsViewByPlugin: [PluginId: @MainActor (SettingsStore) -> AnyView] = [:]
    private var filesHandlers: [PluginId: [@MainActor (ProjectId, FileChanges) -> Void]] = [:]
    private var gitHandlers: [PluginId: [@MainActor (ProjectId) -> Void]] = [:]
    private var reconnectHandlers: [PluginId: [@MainActor (ServerId) -> Void]] = [:]
    private var filesRootHandlers: [PluginId: [@MainActor (Project) -> Void]] = [:]
    private var settingsHandlers: [PluginId: [@MainActor (Settings) -> Void]] = [:]

    public init(model: AppModel, installer: PluginInstaller? = nil) {
        self.model = model
        self.installer = installer ?? PluginInstaller(dirs: model.dirs)
    }

    // MARK: Queries

    /// Current installation state of `id`.
    public func state(of id: PluginId) -> PluginInstallState {
        if let explicit = states[id] { return explicit }
        return activePlugins[id] != nil ? .installed : .notInstalled
    }

    /// Whether `id` is currently active.
    public func isActive(_ id: PluginId) -> Bool {
        activePlugins[id] != nil
    }

    /// All right-sidebar panels contributed by currently active plugins, in order.
    public var sidebarPanels: [RightPanelDescriptor] {
        panelsByPlugin.values
            .flatMap { $0 }
            .map(\.descriptor)
            .sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    /// Descriptor for a registered right-sidebar panel, if its plugin is active.
    public func sidebarPanel(_ id: String) -> PluginSidebarPanel? {
        for panels in panelsByPlugin.values {
            if let match = panels.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    /// Creates the content controller for a registered right-sidebar panel.
    public func makePanelContent(_ id: String) -> RightPanelContent? {
        sidebarPanel(id)?.makeContent(model)
    }

    /// Whether `id` is active and provides a Settings configuration page.
    public func hasSettingsView(for id: PluginId) -> Bool {
        settingsViewByPlugin[id] != nil
    }

    /// Builds `id`'s Settings configuration view, if registered.
    public func makeSettingsView(for id: PluginId, store: SettingsStore) -> AnyView? {
        settingsViewByPlugin[id]?(store)
    }

    // MARK: Startup

    /// Loads and activates every plugin listed in `settings.plugins.installed`
    /// whose `.bundle` is present in `TAB_DIR/Plugins/`.
    public func loadInstalled() {
        for id in model.settings.plugins.installed {
            guard activePlugins[id] == nil else { continue }
            guard installer.isBundlePresent(id) else {
                Log.app.warning("Installed plugin bundle missing on disk: \(id.rawValue)")
                states[id] = .notInstalled
                continue
            }
            do {
                try loadAndActivateBundle(for: id)
            } catch {
                Log.app.error("Failed to load plugin \(id.rawValue): \(error)")
                states[id] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Install / Uninstall

    /// Installs `id`'s `.bundle` into `TAB_DIR/Plugins/`, loads it dynamically,
    /// activates it, and persists `settings.plugins`.
    public func install(_ id: PluginId) async throws {
        guard let descriptor = PluginCatalog.descriptor(for: id) else {
            throw PluginError.unknownPlugin(id)
        }
        guard activePlugins[id] == nil else {
            states[id] = .installed
            return
        }
        states[id] = .installing
        model.notify(.settings)

        do {
            _ = try await installer.install(descriptor)
            try loadAndActivateBundle(for: id)
            try persistPluginInstalled(id, installed: true)
            states[id] = .installed
            // If the right sidebar was open on the empty state, jump straight to the new plugin's panel.
            if model.rightSidebarShowingEmpty, let first = panelsByPlugin[id]?.first {
                model.rightSidebarShowingEmpty = false
                model.selectRightPanel(first.id)
                model.notify(.settings)
                model.notify(.state)
            } else {
                model.notify(.panel)
                model.notify(.settings)
                model.notify(.state)
            }
        } catch {
            states[id] = .failed(error.localizedDescription)
            model.notify(.settings)
            throw error
        }
    }

    /// Deactivates `id`, removes its UI and hooks, deletes its `.bundle` from
    /// disk, and persists `settings.plugins`.
    public func uninstall(_ id: PluginId) throws {
        deactivate(id)
        try installer.remove(id)
        try persistPluginInstalled(id, installed: false)
        states[id] = .notInstalled
        model.notify(.panel)
        model.notify(.settings)
        model.notify(.state)
    }

    /// Activates an already-instantiated plugin directly (used by tests and
    /// dynamically loaded bundles).
    public func activate(plugin: any TabPlugin) {
        let id = plugin.id
        if activePlugins[id] != nil {
            deactivate(id)
        }
        let context = PluginContext(pluginId: id, model: model, manager: self)
        activePlugins[id] = plugin
        plugin.activate(context: context)
        states[id] = .installed
        if let kinds = panesByPlugin[id] {
            for kind in kinds {
                model.panes.rebuild(kind)
            }
        }
        model.notify(.panel)
        model.notify(.settings)
        model.notify(.state)
    }

    /// Deactivates `id` and cleans up all sidebar panels, pane providers, and
    /// event hooks it registered.
    public func deactivate(_ id: PluginId) {
        if let plugin = activePlugins.removeValue(forKey: id) {
            plugin.deactivate()
        }
        let removedPanels = panelsByPlugin.removeValue(forKey: id) ?? []
        let removedPanelIds = Set(removedPanels.map(\.id))
        for panelId in removedPanelIds {
            model.rightPanels.removeValue(forKey: panelId)
        }
        if let open = model.appearance.sidePanel.panelId, removedPanelIds.contains(open) {
            let fallback = sidebarPanels.first
            if let fallback {
                model.updateAppearance {
                    $0.sidePanel = .panel(fallback.id)
                    $0.lastSidePanel = .panel(fallback.id)
                }
            } else {
                model.updateAppearance { $0.sidePanel = .none }
            }
        }
        if let kinds = panesByPlugin.removeValue(forKey: id) {
            for kind in kinds {
                model.panes.unregister(kind)
                model.panes.rebuild(kind)
            }
        }
        settingsViewByPlugin.removeValue(forKey: id)
        filesHandlers.removeValue(forKey: id)
        gitHandlers.removeValue(forKey: id)
        reconnectHandlers.removeValue(forKey: id)
        filesRootHandlers.removeValue(forKey: id)
        settingsHandlers.removeValue(forKey: id)
    }

    // MARK: Dynamic Bundle Loading

    private func loadAndActivateBundle(for id: PluginId) throws {
        let factoryType: TabPluginFactory.Type
        if let cached = loadedFactories[id] {
            factoryType = cached
        } else {
            let bundleURL = model.dirs.pluginBundle(id)
            guard let bundle = Bundle(url: bundleURL) else {
                throw PluginError.invalidBundle("Could not open bundle at \(bundleURL.path).")
            }
            do {
                try bundle.loadAndReturnError()
            } catch {
                throw PluginError.loadFailed(error.localizedDescription)
            }
            guard let principal = bundle.principalClass as? TabPluginFactory.Type else {
                let name = bundle.object(forInfoDictionaryKey: "NSPrincipalClass") as? String ?? "nil"
                throw PluginError.invalidBundle("Principal class “\(name)” is not a TabPluginFactory subclass.")
            }
            loadedFactories[id] = principal
            factoryType = principal
        }
        let plugin = factoryType.init().makePlugin()
        activate(plugin: plugin)
    }

    private func persistPluginInstalled(_ id: PluginId, installed: Bool) throws {
        var updated = model.settings
        if installed {
            updated.plugins.markInstalled(id)
        } else {
            updated.plugins.markUninstalled(id)
        }
        try updated.savePlugins(to: model.dirs.settings)
        model.settings = updated
    }

    // MARK: Registration (called by PluginContext)

    func registerSidebarPanel(_ panel: PluginSidebarPanel, for pluginId: PluginId) {
        panelsByPlugin[pluginId, default: []].append(panel)
    }

    func registerPane(_ kind: PaneKind, factory: @escaping PaneRegistry.Factory, for pluginId: PluginId) {
        panesByPlugin[pluginId, default: []].insert(kind)
        model.panes.register(kind, factory: factory)
    }

    func addFilesChangedHandler(_ handler: @escaping @MainActor (ProjectId, FileChanges) -> Void, for pluginId: PluginId) {
        filesHandlers[pluginId, default: []].append(handler)
    }

    func addGitChangedHandler(_ handler: @escaping @MainActor (ProjectId) -> Void, for pluginId: PluginId) {
        gitHandlers[pluginId, default: []].append(handler)
    }

    func addReconnectedHandler(_ handler: @escaping @MainActor (ServerId) -> Void, for pluginId: PluginId) {
        reconnectHandlers[pluginId, default: []].append(handler)
    }

    func addUpdateFilesRootHandler(_ handler: @escaping @MainActor (Project) -> Void, for pluginId: PluginId) {
        filesRootHandlers[pluginId, default: []].append(handler)
    }

    func registerSettingsView(_ makeView: @escaping @MainActor (SettingsStore) -> AnyView, for pluginId: PluginId) {
        settingsViewByPlugin[pluginId] = makeView
    }

    func addSettingsChangedHandler(_ handler: @escaping @MainActor (Settings) -> Void, for pluginId: PluginId) {
        settingsHandlers[pluginId, default: []].append(handler)
    }

    // MARK: Event Dispatch

    func dispatchFilesChanged(_ project: ProjectId, _ changes: FileChanges) {
        for handlers in filesHandlers.values {
            for handler in handlers { handler(project, changes) }
        }
    }

    func dispatchGitChanged(_ project: ProjectId) {
        for handlers in gitHandlers.values {
            for handler in handlers { handler(project) }
        }
    }

    func dispatchReconnected(_ server: ServerId) {
        for handlers in reconnectHandlers.values {
            for handler in handlers { handler(server) }
        }
    }

    func dispatchUpdateFilesRoot(_ project: Project) {
        for handlers in filesRootHandlers.values {
            for handler in handlers { handler(project) }
        }
    }

    func dispatchSettingsChanged(_ settings: Settings) {
        for handlers in settingsHandlers.values {
            for handler in handlers { handler(settings) }
        }
    }
}
