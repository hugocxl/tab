import AppKit
import Combine
import SwiftUI
import TabCore

/// The Settings window: a small System Settings–style window whose SwiftUI
/// content brings its own toolbar (back, forward, title) and sidebar search.
/// It is 740pt wide with a 215pt sidebar and grows only in height.
@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    public static let defaultSize = NSSize(width: 740, height: 580)
    static let sidebarWidth: CGFloat = 215
    public let store: SettingsStore
    let model: SettingsModel
    private var observations: Set<AnyCancellable> = []

    public init(store: SettingsStore) {
        self.store = store
        model = SettingsModel(store: store)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "Settings"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: Self.defaultSize.width, height: 480)
        window.maxSize = NSSize(width: Self.defaultSize.width, height: .greatestFiniteMagnitude)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenNone)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: SettingsRootView(model: model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = hosting
        window.setContentSize(Self.defaultSize)
        // A new name: frames saved by the old, wider window would restore it.
        window.setFrameAutosaveName("TabSettings")
        if window.frame.width != Self.defaultSize.width {
            window.setContentSize(NSSize(width: Self.defaultSize.width, height: window.contentLayoutRect.height))
        }
        model.window = window
        store.theme.$palette
            .sink { [weak window] palette in window?.appearance = NSAppearance(named: palette.isLight ? .aqua : .darkAqua) }
            .store(in: &observations)
        store.loadServerSettings()
        store.loadRemoteAccess()
        store.refreshBrowserProfiles()
        model.reload()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The page on screen.
    public var category: SettingsCategory { model.category }

    /// Shows the window on `category`'s page.
    public func show(_ category: SettingsCategory? = nil) {
        if let category { select(category) }
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        store.reloadTerminal()
    }

    /// Opens a page, as clicking it in the sidebar does.
    public func select(_ category: SettingsCategory) {
        model.select(category)
    }

    /// Searches every page's settings, as typing in the search field does.
    public func search(_ text: String) {
        model.search(text)
    }

    /// Rebuilds the page from the store.
    public func reload() {
        model.reload()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        store.reloadTerminal()
    }

    public func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        model.commitEdits()
        if store.pairing != nil || store.pairingBusy { store.cancelPairing() }
    }
}
