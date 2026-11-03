import AppKit
import Combine
import TabCore

/// What the Settings window shows: the open page or the search, the
/// back/forward history, the editors open on the page, and the page's rows
/// built from the store.
@MainActor
final class SettingsModel: ObservableObject {
    /// A page: a category's, or one of its subpages.
    struct Location: Equatable {
        var category: SettingsCategory
        var subpage: SettingsSubpage?
    }

    let store: SettingsStore
    private(set) var category: SettingsCategory = .general
    private(set) var subpage: SettingsSubpage?
    private(set) var query = ""
    private(set) var backStack: [Location] = []
    private(set) var forwardStack: [Location] = []
    @Published private(set) var lastBuild: SettingsPageBuilder?
    /// The window sheets and panels attach to.
    weak var window: NSWindow?

    /// Transient editors on the page.
    var profileName = ""
    /// The bundled changelog, read when its page first opens.
    private(set) lazy var changelog: Changelog? = Changelog.bundled()

    /// Saves of text fields being edited, run when Settings closes.
    private var pendingEdits: [String: () -> Void] = [:]
    private var observations: Set<AnyCancellable> = []
    private var reloadScheduled = false

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
    }

    var fields: [String: TextSpec] { lastBuild?.fields ?? [:] }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var title: String { isSearching ? "Search" : subpage?.title ?? category.title }
    private var location: Location { Location(category: category, subpage: subpage) }

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
        category = location.category
        subpage = location.subpage
        query = ""
        if category == .server || category == .terminal { store.loadServerSettings() }
        if category == .mobile { store.loadRemoteAccess() }
        if category == .browser { store.refreshBrowserProfiles() }
        if category == .integrations { store.loadAgentIntegrations() }
        reload()
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
        case .integrations: buildIntegrations(builder)
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
