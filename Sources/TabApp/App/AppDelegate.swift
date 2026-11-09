import AppKit
import TabClient
import TabCore

/// Starts the app: the model, the main window, the menu bar, `app.sock`,
/// and folders opened from Finder or `tab <folder>`.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dirs: TabDirs
    private var model: AppModel?
    private var windowController: MainWindowController?
    private var socket: AppSocketHandler?
    private var pendingFolders: [String] = []
    private var terminating = false

    public init(dirs: TabDirs, folder: String?) {
        self.dirs = dirs
        if let folder { pendingFolders.append(folder) }
        super.init()
    }

    public func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let theme = AppTheme.shared
        theme.followSystem()
        let model = AppModel(dirs: dirs, theme: theme)
        self.model = model
        Task { await theme.loadCatalog(customDirectory: dirs.themes) }
        Task.detached(priority: .utility) {
            do {
                try AgentIntegrations.current().refresh()
            } catch {
                Log.app.error("agent integrations: \(String(describing: error), privacy: .public)")
            }
        }
        let controller = MainWindowController(model: model)
        windowController = controller
        NSApp.mainMenu = MenuBarBuilder.build(keymap: model.settings.keymap, actions: controller.actions, available: Self.features)
        let socket = AppSocketHandler(model: model)
        do {
            try socket.listen()
        } catch {
            Log.app.error("app.sock: \(error.localizedDescription, privacy: .public)")
            FileHandle.standardError.write(Data("Tab: app.sock: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        self.socket = socket
        model.start()
        controller.show()
        for folder in pendingFolders { model.addProject(folder) }
        pendingFolders = []
        NSApp.activate(ignoringOtherApps: true)
    }

    /// What this build can offer in its menus.
    static var features: Set<ShortcutFeature> {
        var features: Set<ShortcutFeature> = [.notifications, .appHiding, .updates]
        if Executable.currentURL().flatMap(Executable.containingBundle(of:)) != nil { features.insert(.commandLineTool) }
        return features
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "tab" {
                handle(url)
                continue
            }
            var isDirectory: ObjCBool = false
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            if let model { model.addProject(url.path) } else { pendingFolders.append(url.path) }
        }
        windowController?.bringToFront()
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        handle(url)
    }

    /// `tab://pair` opens the pairing code in Settings → Mobile.
    private func handle(_ url: URL) {
        guard url.scheme == "tab" else { return }
        if url.host == "pair" || url.path.hasPrefix("/pair") {
            windowController?.showSettings(.mobile)
        }
        windowController?.bringToFront()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController?.bringToFront()
        return true
    }

    private var terminationPending = false

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, let controller = windowController, !terminating else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        let editors = model.openEditors.filter(\.isDirty)
        guard !editors.isEmpty else {
            finishAfterSavingDrafts()
            return .terminateLater
        }
        EditorPaneController.confirmClose(editors, window: controller.window) { [weak self] proceed in
            guard proceed else {
                self?.terminationPending = false
                NSApp.reply(toApplicationShouldTerminate: false)
                return
            }
            self?.finishAfterSavingDrafts()
        }
        return .terminateLater
    }

    private func finishAfterSavingDrafts() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.model?.flushAgentDrafts()
                self.finish()
                NSApp.reply(toApplicationShouldTerminate: true)
            } catch {
                self.terminationPending = false
                let alert = NSAlert()
                alert.messageText = "Your agent drafts could not be saved"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Tab open")
                alert.runModal()
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    /// Quitting never ends terminals: the state is saved and the servers
    /// keep them.
    private func finish() {
        terminating = true
        model?.saveNow()
        model?.sidebarMemory.saveNow()
        model?.browserProfiles.saveHistories()
        model?.updater.stop()
        socket?.close()
    }
}
