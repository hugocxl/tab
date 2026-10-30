import AppKit
import Combine
import TabCore

/// What the Settings window shows: the open page or the search, the
/// back/forward history, the editors open on the page, and the page's rows
/// built from the store.
@MainActor
final class SettingsModel: ObservableObject {
    let store: SettingsStore
    private(set) var category: SettingsCategory = .general
    private(set) var query = ""
    private(set) var backStack: [SettingsCategory] = []
    private(set) var forwardStack: [SettingsCategory] = []
    @Published private(set) var lastBuild: SettingsPageBuilder?
    /// The window sheets and panels attach to.
    weak var window: NSWindow?

    /// Transient editors on the page.
    var commandDraft: CustomCommand?
    var bindingDraft: BindingDraft?
    var codepointDraft: CodepointDraft?
    var profileName = ""
    /// The project whose pull request prompt the AI page edits.
    var promptProject: String?
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
        store.theme.$palette
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &observations)
    }

    var fields: [String: TextSpec] { lastBuild?.fields ?? [:] }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var title: String { isSearching ? "Search" : category.title }

    /// The page selected in the sidebar: none while searching.
    var selection: SettingsCategory? { isSearching ? nil : category }

    // MARK: Navigation

    /// Opens `category`'s page, ending a search, and remembers the page it
    /// leaves for Back.
    func select(_ category: SettingsCategory) {
        if category != self.category {
            backStack.append(self.category)
            forwardStack = []
        }
        open(category)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(category)
        open(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(category)
        open(next)
    }

    private func open(_ category: SettingsCategory) {
        self.category = category
        query = ""
        if category == .server { store.loadServerSettings() }
        if category == .mobile { store.loadRemoteAccess() }
        if category == .browser { store.refreshBrowserProfiles() }
        reload()
    }

    /// Searches every page's settings, as typing in the search field does.
    func search(_ text: String) {
        guard text != query else { return }
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
        let builder = SettingsPageBuilder(store: store, query: query, category: category)
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
        case .terminal: buildTerminal(builder)
        case .keyboard: buildKeyboard(builder)
        case .commands: buildCommands(builder)
        case .browser: buildBrowser(builder)
        case .server: buildServer(builder)
        case .mobile: buildMobile(builder)
        case .ai: buildAI(builder)
        case .backup: buildBackup(builder)
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

extension SettingsModel {
    /// The file behind the open page, for "Edit in …"; none while searching.
    var configurationFile: String? { isSearching ? nil : category.configurationFile }
}
