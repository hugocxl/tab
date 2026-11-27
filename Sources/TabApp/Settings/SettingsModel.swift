import AppKit
import Combine
import TabCore
import TabProtocol

/// What the Settings window shows: the open page or the search, the
/// back/forward history, the editors open on the page, and the page's rows
/// built from the store.
@MainActor
final class SettingsModel: ObservableObject {
    /// A page: a category's, or one of its subpages.
    struct Location: Equatable {
        var category: SettingsCategory
        var subpage: SettingsSubpage?
        /// The coding agent an `agentProvider` page shows.
        var provider: String?
        /// The plugin a `pluginConfig` page shows.
        var pluginId: PluginId?
    }

    let store: SettingsStore
    private(set) var category: SettingsCategory = .general
    private(set) var subpage: SettingsSubpage?
    /// The coding agent the open provider page shows.
    private(set) var provider: String?
    /// The plugin the open plugin config page shows.
    private(set) var pluginId: PluginId?
    private(set) var query = ""
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    @Published private(set) var lastBuild: SettingsPageBuilder?
    /// The window sheets and panels attach to.
    weak var window: NSWindow?

    /// Transient editors on the page.
    var profileName = ""
    /// A provider page's unsaved new variable and custom model.
    var variableName = ""
    var variableValue = ""
    var customModelID = ""
    var nameSheet: NamePromptSheet?
    /// The bundled changelog, read when its page first opens.
    private(set) lazy var changelog: Changelog? = Changelog.bundled()

    /// Saves of text fields being edited, run when Settings closes.
    private var pendingEdits: [String: () -> Void] = [:]
    private var observations: Set<AnyCancellable> = []
    private var reloadScheduled = false
    /// Opens the Add Provider dialog once the providers are read.
    private var addProviderWhenLoaded = false
    /// Lists the open provider's models once another computer's providers are read.
    private var loadProviderWhenLoaded = false
    /// Permissions whose macOS prompt is waiting for an answer.
    private(set) var privacyRequests: Set<PrivacyPermission> = []

    init(store: SettingsStore) {
        self.store = store
        store.changes
            .sink { [weak self] in self?.scheduleReload() }
            .store(in: &observations)
        Publishers.Merge3(store.theme.$palette.dropFirst().map { _ in () },
                          store.theme.$interface.dropFirst().map { _ in () },
                          store.theme.$accessibility.dropFirst().map { _ in () })
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &observations)
        // Answers change in System Settings and prompts, which Tab returns from.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self, category == .privacy || isSearching else { return }
                scheduleReload()
            }
            .store(in: &observations)
    }

    var fields: [String: TextSpec] { lastBuild?.fields ?? [:] }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var title: String {
        if isSearching { return "Search" }
        if subpage == .agentProvider { return shownProvider?.title ?? "Provider" }
        if subpage == .pluginConfig, let pluginId {
            return PluginCatalog.descriptor(for: pluginId)?.name ?? pluginId.rawValue
        }
        return subpage?.title ?? category.title
    }
    private var location: Location { Location(category: category, subpage: subpage, provider: provider, pluginId: pluginId) }

    /// The provider the open provider page shows, or nil when none is configured.
    var shownProvider: AgentProviderConfig? {
        let settings = store.agentProviders?.settings ?? AgentProviderSettings()
        return settings.provider(provider) ?? settings.providers.first
    }

    /// The page selected in the sidebar: none while searching.
    var selection: SettingsCategory? { isSearching ? nil : category }

    // MARK: Navigation

    /// Opens `category`'s page, ending a search, and remembers the page it
    /// leaves for Back.
    func select(_ category: SettingsCategory) {
        go(to: Location(category: category))
    }

    /// Opens a subpage of the current page, such as Advanced Font Settings.
    func open(_ subpage: SettingsSubpage) {
        go(to: Location(category: subpage.category, subpage: subpage))
    }

    /// Opens the Agents page with the Add Provider dialog, once the providers are read.
    func addProvider() {
        if subpage != nil || category != .agents { select(.agents) }
        addProviderWhenLoaded = true
        reload()
    }

    /// Opens the Agents page on `server`'s providers, then `provider`'s page when it is given.
    func showAgents(on server: ServerId, provider: String? = nil) {
        if server != store.agentComputer {
            store.selectAgentComputer(server)
            loadProviderWhenLoaded = provider != nil
            // A provider page of the other computer would show one of this one's.
            if subpage == .agentProvider { backStack = []; forwardStack = [] }
        }
        if let provider {
            openProvider(provider)
        } else if category != .agents || subpage != nil {
            go(to: Location(category: .agents))
        } else {
            reload()
        }
    }

    /// Opens a coding agent's page.
    func openProvider(_ id: String) {
        go(to: Location(category: .agents, subpage: .agentProvider, provider: id))
    }

    /// Opens an installed plugin's configuration page.
    func openPlugin(_ id: PluginId) {
        go(to: Location(category: .plugins, subpage: .pluginConfig, pluginId: id))
    }

    private func go(to next: Location) {
        if next != location {
            backStack.append(location)
            forwardStack = []
        }
        open(next)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(location)
        open(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(location)
        open(next)
    }

    private func open(_ location: Location) {
        addProviderWhenLoaded = false
        category = location.category
        subpage = location.subpage
        provider = location.provider
        pluginId = location.pluginId
        query = ""
        if category == .server || category == .terminal { store.loadServerSettings() }
        if category == .mobile { store.loadRemoteAccess() }
        if category == .browser { store.refreshBrowserProfiles() }
        if category == .agents {
            refreshAgentsPage()
        }
        reload()
    }

    /// Refreshes the currently open page (e.g. when reopening the Settings window).
    func refreshCurrentPage() {
        if category == .agents { refreshAgentsPage() }
        if category == .privacy { reload() }
    }

    /// Shows macOS's prompt for `permission`. When macOS answers without
    /// one, such as with Location Services off, opens System Settings.
    func requestPrivacyAccess(_ permission: PrivacyPermission) {
        guard let host = store.host, !privacyRequests.contains(permission) else { return }
        privacyRequests.insert(permission)
        reload()
        Task { [weak self] in
            let answered = await host.requestPrivacyAccess(permission)
            guard let self else { return }
            privacyRequests.remove(permission)
            if answered && host.privacyAccess(permission) == .notAsked {
                PrivacyPermission.openSettings(permission.settingsPane)
            }
            reload()
        }
    }

    private func refreshAgentsPage() {
        loadProviderPage()
        store.loadAgentProviders(check: true)
    }

    /// Lists the open provider's models and reads its Tab integration.
    private func loadProviderPage() {
        if subpage == .agentProvider, let shown = shownProvider {
            store.loadAgentModels(shown.id)
            store.loadAgentProviderIntegration(shown)
        }
    }

    /// Searches every page's settings, as typing in the search field does.
    func search(_ text: String) {
        guard text != query else { return }
        if !text.isEmpty && store.serverSettings == nil { store.loadServerSettings() }
        query = text
        reload()
    }

    // MARK: Building

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            reload()
        }
    }

    /// Rebuilds the page from the store.
    func reload() {
        let builder = SettingsPageBuilder(store: store, query: query, category: category, subpage: subpage)
        if builder.isSearching {
            for page in SettingsCategory.allCases { build(page, into: builder) }
        } else {
            build(category, into: builder)
        }
        lastBuild = builder
        if addProviderWhenLoaded, category == .agents, store.agentProviders != nil, window?.isVisible == true {
            addProviderWhenLoaded = false
            DispatchQueue.main.async { [weak self] in self?.showAddProvider() }
        }
        if loadProviderWhenLoaded, store.agentProviders != nil {
            loadProviderWhenLoaded = false
            loadProviderPage()
        }
        if (store.pairing != nil || store.pairingBusy) && !builder.rowIds.contains("mobile-pair") {
            store.cancelPairing()
        }
    }

    private func build(_ page: SettingsCategory, into builder: SettingsPageBuilder) {
        switch page {
        case .general: buildGeneral(builder)
        case .appearance: buildAppearance(builder)
        case .interface: buildInterface(builder)
        case .terminal: buildTerminal(builder)
        case .keyboard: buildKeyboard(builder)
        case .agents: buildAgents(builder)
        case .plugins:
            builder.row("plugins", .disclosure { [weak self] in self?.select(.plugins) })
        case .notifications: buildNotifications(builder)
        case .privacy: buildPrivacy(builder)
        case .browser: buildBrowser(builder)
        case .server: buildServer(builder)
        case .mobile: buildMobile(builder)
        case .backup: buildBackup(builder)
        case .remoteServers:
            builder.row("remote-servers", .disclosure { [weak self] in self?.select(.remoteServers) })
        case .changelog: break
        }
    }

    // MARK: Editing

    /// Remembers how to save a field being typed in, until it is saved.
    func editing(_ id: String, save: (() -> Void)?) {
        pendingEdits[id] = save
    }

    /// Saves unfinished text fields when Settings closes.
    func commitEdits() {
        let edits = pendingEdits.values
        pendingEdits = [:]
        for save in edits { save() }
    }

    /// Asks before something that cannot be undone.
    func confirm(_ title: String, _ message: String, _ action: String, destructive: Bool = true, then run: @escaping () -> Void) {
        ConfirmSheet.present(on: window, title: title, message: message, confirm: action, destructive: destructive, theme: store.theme) { confirmed in
            if confirmed { run() }
        }
    }
}
