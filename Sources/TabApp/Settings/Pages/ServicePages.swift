import AppKit
import TabClient
import TabCore
import TabProtocol

extension SettingsModel {
    // MARK: Browser

    func buildBrowser(_ b: SettingsPageBuilder) {
        let browser = store.settings.browser
        b.row("browser-enabled", b.toggle("browser-enabled", browser.enabled) { [store] value in
            store.updateBrowser("browser-enabled") { $0.enabled = value }
        })
        if !browser.enabled {
            b.note("browser-enabled", "The built-in browser is off. Browser tabs and browser commands are disabled, and terminal links open in your system browser.")
        }
        b.row("browser-terminal-links", b.toggle("browser-terminal-links", browser.openTerminalLinks) { [store] value in
            store.updateBrowser("browser-terminal-links") { $0.openTerminalLinks = value }
        })
        b.row("browser-search-engine", b.popUp("browser-search-engine", SearchEngine.allCases.map { Choice(id: $0.rawValue, title: $0.name) }, selected: browser.searchEngine.rawValue) { [store] id in
            store.updateBrowser("browser-search-engine") { $0.searchEngine = SearchEngine(rawValue: id) ?? .google }
        })
        b.row("browser-home-page", b.field("browser-home-page", browser.homePage, placeholder: "Start page") { [store] text in
            store.updateBrowser("browser-home-page") { $0.homePage = text }
        })
        profiles(b)
        browserImports(b)
    }

    /// A row per profile with its actions, then a row adding one.
    private func profiles(_ b: SettingsPageBuilder) {
        let defaultId = store.settings.browser.defaultProfile
        for profile in store.browserProfiles {
            let isDefault = profile.id == defaultId
            var actions = [
                ButtonSpec(title: "Rename…") { [weak self] in self?.renameProfile(profile) },
                ButtonSpec(title: "Clear Data…") { [weak self] in
                    self?.confirm(
                        "Clear data for “\(profile.name)”?",
                        "This signs out and removes all cookies, cache, history, and logins for this profile, including imported ones.",
                        "Clear Data"
                    ) { self?.store.clearBrowserProfile(profile.id) }
                },
            ]
            if !profile.id.isEmpty {
                actions.append(ButtonSpec(title: "Delete…", style: .destructive) { [weak self] in
                    self?.confirm(
                        "Delete “\(profile.name)”?",
                        "This permanently deletes the profile's cookies, history, and browsing data. Its tabs use the default profile.",
                        "Delete"
                    ) { self?.store.deleteBrowserProfile(profile.id) }
                })
            }
            var controls: [SettingControl] = []
            if !isDefault {
                controls.append(b.button("Make Default") { [store] in
                    store.updateBrowser("browser-profiles") { $0.defaultProfile = profile.id }
                })
            }
            controls.append(.actions("\(profile.name) Actions", actions))
            b.item("browser-profiles", key: profile.id, label: profile.name, description: isDefault ? "New browser panes use this profile" : nil, .row(controls))
        }
        let name = b.field("browser-profiles", profileName, placeholder: "Profile name") { [weak self] text in
            guard let self else { return }
            let hadName = !profileName.trimmingCharacters(in: .whitespaces).isEmpty
            profileName = text
            if hadName != !text.trimmingCharacters(in: .whitespaces).isEmpty { reload() }
        } commit: { [weak self] in
            self?.profileName = $0
        }
        let add = b.button("Add", enabled: !profileName.trimmingCharacters(in: .whitespaces).isEmpty) { [weak self] in
            guard let self else { return }
            store.addBrowserProfile(profileName)
            if store.errors["browser-profiles"] == nil { profileName = "" }
            reload()
        }
        b.row("browser-profiles", .row([name, add]), label: "New profile", description: "")
        b.note("browser-profiles", SettingsCatalog.item("browser-profiles")?.description ?? "")
    }

    private func renameProfile(_ profile: BrowserProfileSummary) {
        guard nameSheet == nil else { return }
        let sheet = NamePromptSheet(title: "Rename “\(profile.name)”", label: "Profile name", value: profile.name, confirm: "Rename") { [weak self] name in
            guard let self else { return }
            nameSheet = nil
            guard let name else { return }
            store.renameBrowserProfile(profile.id, name)
            reload()
        }
        nameSheet = sheet
        sheet.present(on: window)
    }

    /// A row per other browser, with what Tab can import from it.
    private func browserImports(_ b: SettingsPageBuilder) {
        let sources = store.host?.browserImportSources() ?? []
        guard !sources.isEmpty else {
            b.row("browser-import", .label("No other browsers found", .secondary))
            return
        }
        for source in sources {
            var controls: [SettingControl] = [
                b.button("History & Bookmarks") { [store] in store.importBrowserData(source, cookies: false) },
            ]
            if source.supportsCookies {
                controls.append(b.button("Cookies") { [store] in store.importBrowserData(source, cookies: true) })
            }
            b.item("browser-import", key: source.name, label: "Import from \(source.name)", .row(controls))
        }
        b.note("browser-import", "Imports go into the default profile. Cookies bring your sign-ins; macOS may ask to allow access to the browser's key.")
    }

    // MARK: Server

    func buildServer(_ b: SettingsPageBuilder) {
        let running = store.serverState == .running
        b.row("server", b.button(running ? "Reload Settings" : "Connect", enabled: !store.serverBusy && store.serverState != .connecting) { [store] in
            if running { store.loadServerSettings() } else { store.connectServer() }
        })
        guard running else {
            b.note("server", "Server disconnected. App preferences still work. Connect to edit server settings.")
            return
        }
        b.row("stop-server", b.button("Stop Server", style: .destructive, enabled: !store.serverBusy) { [weak self] in
            self?.confirm("Stop the server?", "Every terminal session on this Mac ends. Saved terminal records are kept.", "Stop Server") {
                self?.store.controlServer(restart: false)
            }
        })
        b.row("restart-server", b.button("Restart Server", enabled: !store.serverBusy && (store.host?.canRestartServer ?? false), help: store.host?.canRestartServer == false ? "Wait for the current update to finish." : nil) { [weak self] in
            self?.confirm("Restart the server?", "Every terminal session on this Mac ends and the server starts again. Saved terminal records are kept.", "Restart Server") {
                self?.store.controlServer(restart: true)
            }
        })
    }

    // MARK: Mobile

    func buildMobile(_ b: SettingsPageBuilder) {
        guard store.serverState == .running else {
            b.note("mobile-access", "Connect to the server to manage mobile access.")
            return
        }
        guard let state = store.remoteAccess else {
            b.note("mobile-access", store.errors["mobile-access"] ?? "Loading mobile access…", error: store.errors["mobile-access"] != nil)
            return
        }
        b.row("mobile-access", b.toggle("mobile-access", state.settings.enabled, enabled: !store.mobileBusy) { [store] in store.setMobileEnabled($0) })
        b.row("mobile-port", b.field("mobile-port", String(state.settings.port), width: 80, enabled: !store.mobileBusy) { [store] in store.setMobilePort($0) })
        let (status, failed) = Self.status(state)
        b.row("mobile-status", .label(status, failed ? .error : .secondary))
        b.row("mobile-pair", pairing(b, state), stacked: store.pairing != nil)
        guard !state.devices.isEmpty else {
            b.row("mobile-devices", .label("None", .secondary))
            return
        }
        for device in state.devices {
            b.item("mobile-devices", key: device.id.uuid.uuidString, label: device.name, description: Self.lastSeen(device),
                   b.button("Revoke", style: .destructive) { [weak self] in
                       self?.confirm("Revoke “\(device.name)”?", "The phone disconnects now and must be paired again to connect.", "Revoke") {
                           self?.store.revokeDevice(device.id)
                       }
                   })
        }
        b.note("mobile-devices", "Phones that can connect. Revoking one disconnects it immediately.")
    }

    static func status(_ state: RemoteAccessState) -> (String, Bool) {
        switch (state.status, state.settings.enabled) {
        case (.listening, _): return ("Listening on port \(state.settings.port)", false)
        case (.failed(let message), _): return ("Not listening: \(message)", true)
        case (.disabled, true): return ("Starting", false)
        case (.disabled, false): return ("Off", false)
        case (.unknown, _): return ("Update Tab to see this status", false)
        }
    }

    private func pairing(_ b: SettingsPageBuilder, _ state: RemoteAccessState) -> SettingControl {
        guard let offer = store.pairing else {
            return b.button("Show Pairing Code", enabled: state.settings.enabled && !store.mobileBusy) { [store] in store.startPairing() }
        }
        let link = offer.invite.link
        var views: [SettingControl] = []
        if let code = QRCode(link) {
            views.append(.qrCode(code))
        } else {
            views.append(.label("The pairing code is too long to show.", .note))
        }
        views.append(.label("Scan with the Tab app. The code works once and expires in 5 minutes.", .note))
        let copy = b.button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        let cancel = b.button("Cancel") { [store] in store.cancelPairing() }
        views.append(.row([cancel, copy]))
        return .column(views)
    }

    static func lastSeen(_ device: PairedDevice) -> String {
        if device.connected { return "Connected" }
        guard let seen = device.lastSeen else { return "Never connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last seen \(formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seen)), relativeTo: Date()))"
    }

    // MARK: Backup

    func buildBackup(_ b: SettingsPageBuilder) {
        b.row("backup-export", b.button("Export…", enabled: !store.backupBusy) { [weak self] in self?.exportBackup() })
        var restore: [SettingControl] = [b.button("Choose File…", enabled: !store.backupBusy) { [weak self] in self?.chooseBackup() }]
        if store.hasPendingRestore {
            restore.append(b.button("Cancel Import") { [store] in store.cancelRestore() })
        }
        b.row("backup-restore", .row(restore))
        if !store.backupStatus.isEmpty { b.note("backup-restore", store.backupStatus) }
        b.row("backup-folder", b.button("Show in Finder") { [store] in
            try? FileManager.default.createDirectory(at: store.dirs.backups, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([store.dirs.backups])
        })
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Tab-backup.\(BackupArchive.fileExtension)"
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.store.exportBackup(to: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.prompt = "Choose"
        panel.message = "Choose a Tab backup"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let archive = try BackupArchive.read(url)
                confirm("Restore backup on next launch?", archive.summary, "Restore on Next Launch") { [weak self] in
                    self?.store.restoreBackup(from: url)
                }
            } catch {
                store.setError("backup-restore", SettingsStore.message(error))
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }
}
