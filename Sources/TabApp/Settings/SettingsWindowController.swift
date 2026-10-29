import AppKit
import Combine
import TabCore

/// The Settings window, laid out like System Settings: a 220pt sidebar with
/// search, the server tile and categories, and a page of section headers over
/// inset cards. It opens at 1040×780.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let defaultSize = NSSize(width: 1040, height: 780)
    public let store: SettingsStore
    let sidebar = SettingsSidebar()
    let page: SettingsPageView
    private var observations: Set<AnyCancellable> = []

    public init(store: SettingsStore) {
        self.store = store
        page = SettingsPageView(store: store)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("TabSettingsWindow")
        super.init(window: window)
        window.delegate = self
        let root = ThemedBackground(color: { $0.bg })
        root.theme = store.theme
        window.contentView = root
        sidebar.theme = store.theme
        page.theme = store.theme
        root.addSubview(sidebar)
        root.addSubview(page)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            page.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            page.topAnchor.constraint(equalTo: root.topAnchor),
            page.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        sidebar.onSelect = { [weak self] category, section in self?.select(category, section: section, toggles: true) }
        sidebar.serverTile.onClick = { [weak self] in self?.select(.server, section: nil) }
        sidebar.search.onChange = { [weak self] text in
            self?.page.query = text
            self?.reload()
        }
        page.onNavigate = { [weak self] category in self?.select(category, section: nil) }
        store.changes
            .sink { [weak self] in self?.scheduleReload() }
            .store(in: &observations)
        store.theme.$palette
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &observations)
        store.loadServerSettings()
        store.loadRemoteAccess()
        store.refreshBrowserProfiles()
        reload()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The page on screen.
    public var category: SettingsCategory { page.category }
    public var section: String? { page.section }

    /// Shows the window on `category`'s page.
    public func show(_ category: SettingsCategory? = nil) {
        if let category { select(category, section: nil) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        store.reloadTerminal()
    }

    /// Opens a page, or one of its sections, with its sections listed in
    /// the sidebar. A sidebar click on the open category (`toggles`)
    /// expands or collapses its sections instead.
    public func select(_ category: SettingsCategory, section: String?, toggles: Bool = false) {
        let searching = !page.query.isEmpty
        if toggles && section == nil && category == page.category && !searching && page.section == nil {
            page.expanded = page.expanded == category ? nil : category
        } else {
            page.expanded = category
        }
        page.category = category
        page.section = section
        page.query = ""
        sidebar.search.stringValue = ""
        page.resetScroll()
        if category == .server { store.loadServerSettings() }
        if category == .mobile { store.loadRemoteAccess() }
        if category == .browser { store.refreshBrowserProfiles() }
        reload()
    }

    /// Searches every page's settings, as typing in the search field does.
    public func search(_ text: String) {
        sidebar.search.stringValue = text
        page.query = text
        reload()
    }

    private var reloadScheduled = false

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            reloadScheduled = false
            reload()
        }
    }

    /// Rebuilds the sidebar and page from the store.
    public func reload() {
        window?.appearance = store.theme.nsAppearance
        let searching = !page.query.isEmpty
        var hidden: Set<String> = []
        if store.terminal.diagnostics.isEmpty { hidden.insert("Migration") }
        sidebar.reload(
            selected: searching ? nil : page.category,
            section: page.section,
            expanded: searching ? nil : page.expanded,
            hiddenSections: hidden
        )
        sidebar.serverTile.state = store.serverState
        page.reload()
        if (store.pairing != nil || store.pairingBusy) && page.lastBuild?.rowIds.contains("mobile-pair") != true {
            store.cancelPairing()
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        store.reloadTerminal()
    }

    public func windowWillClose(_ notification: Notification) {
        page.commitEdits()
        if store.pairing != nil || store.pairingBusy { store.cancelPairing() }
    }
}
