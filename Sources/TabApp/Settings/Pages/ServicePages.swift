import AppKit
import TabClient
import TabCore
import TabProtocol

extension SettingsPageView {
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
        b.row("browser-search-engine", b.popUp("browser-search-engine", SearchEngine.allCases.map { .init(id: $0.rawValue, title: $0.name) }, selected: browser.searchEngine.rawValue) { [store] id in
            store.updateBrowser("browser-search-engine") { $0.searchEngine = SearchEngine(rawValue: id) ?? .google }
        })
        b.row("browser-home-page", b.field("browser-home-page", browser.homePage, placeholder: "Start page") { [store] text in
            store.updateBrowser("browser-home-page") { $0.homePage = text }
        })
        b.row("browser-profiles", profileList(b), stacked: true)
        b.row("browser-import", importButtons(b), stacked: true)
    }

    private func profileList(_ b: SettingsPageBuilder) -> NSView {
        let defaultId = store.settings.browser.defaultProfile
        var rows: [NSView] = [NoteLabel("Each profile keeps its own cookies, cache, history, and logins. Pick a profile per tab from the browser toolbar.")]
        var renameButtons: [PillButton] = []
        for profile in store.browserProfiles {
            let name = makeLabel(profile.name, font: AppFont.body, color: theme.fg)
            var controls: [NSView] = [name]
            if profile.id == defaultId {
                controls.append(Badge("Default"))
            } else {
                controls.append(b.button("Make Default") { [store] in
                    store.updateBrowser("browser-profiles") { $0.defaultProfile = profile.id }
                })
            }
            let rename = b.button("Rename to Name Below", enabled: !profileName.trimmingCharacters(in: .whitespaces).isEmpty) { [weak self] in
                guard let self else { return }
                store.renameBrowserProfile(profile.id, profileName)
                profileName = ""
            }
            renameButtons.append(rename)
            controls.append(rename)
            controls.append(b.button("Clear Data") { [weak self] in
                self?.confirm(
                    "Clear data for “\(profile.name)”?",
                    "This signs out and removes all cookies, cache, history, and logins for this profile, including imported ones.",
                    "Clear Data"
                ) { self?.store.clearBrowserProfile(profile.id) }
            })
            if !profile.id.isEmpty {
                controls.append(b.button("Delete", style: .destructive) { [weak self] in
                    self?.confirm(
                        "Delete “\(profile.name)”?",
                        "This permanently deletes the profile's cookies, history, and browsing data. Its tabs use the default profile.",
                        "Delete"
                    ) { self?.store.deleteBrowserProfile(profile.id) }
                })
            }
            rows.append(vstack([hstack(Array(controls.prefix(2)), spacing: 6), hstack(Array(controls.dropFirst(2)), spacing: 6)]))
        }
        let name = b.field("browser-profiles", profileName, placeholder: "Profile name") { [weak self] in self?.profileName = $0 }
        name.onChange = { [weak self] text in
            self?.profileName = text
            for button in renameButtons { button.isEnabled = !text.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let add = b.button("Add Profile") { [weak self] in
            guard let self else { return }
            store.addBrowserProfile(fields["browser-profiles"]?.stringValue ?? profileName)
            if store.errors["browser-profiles"] == nil { profileName = "" }
            reload()
        }
        rows.append(hstack([name, add]))
        return vstack(rows)
    }

    private func importButtons(_ b: SettingsPageBuilder) -> NSView {
        let sources = store.host?.browserImportSources() ?? []
        guard !sources.isEmpty else { return NoteLabel("No other browsers were found on this computer.") }
        var rows: [NSView] = sources.map { source in
            var controls: [NSView] = [
                makeLabel(source.name, font: AppFont.body, color: theme.fg),
                b.button("History & Bookmarks") { [store] in store.importBrowserData(source, cookies: false) },
            ]
            if source.supportsCookies {
                controls.append(b.button("Cookies") { [store] in store.importBrowserData(source, cookies: true) })
            }
            return hstack(controls, spacing: 6)
        }
        rows.append(NoteLabel("Imports go into the default profile. Cookies bring your sign-ins; macOS may ask to allow access to the browser's key."))
        return vstack(rows)
    }

    // MARK: Server

    func buildServer(_ b: SettingsPageBuilder) {
        let running = store.serverState == .running
        b.row("server", b.button(running ? "Reload Settings" : "Connect", enabled: !store.serverBusy) { [store] in
            if running { store.loadServerSettings() } else { store.connectServer() }
        })
        guard running else {
            b.note("server", "Server disconnected. App preferences still work. Connect to edit server settings.")
            return
        }
        if let server = store.serverSettings {
            b.row("default-shell", b.field("default-shell", server.defaultShell?.rawValue ?? "", placeholder: "$SHELL") { [store] in
                store.setServer("default-shell", $0)
            })
            b.row("history-budget", b.field("history-budget", String(server.historyBudgetBytes / (1024 * 1024))) { [store] in
                store.setServer("history-budget", $0)
            })
            b.row("shell-integration", b.toggle("shell-integration", server.shellIntegration) { [store] in
                store.setServer("shell-integration", String($0))
            })
        } else {
            b.note("server", "Loading the server's settings…")
        }
        b.row("stop-server", b.button("Stop Server", style: .destructive, enabled: !store.serverBusy) { [weak self] in
            self?.confirm("Stop the server?", "Every terminal session on this Mac ends. Saved terminal records are kept.", "Stop Server") {
                self?.store.controlServer(restart: false)
            }
        })
        b.row("restart-server", b.button("Restart Server", enabled: !store.serverBusy) { [weak self] in
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
        let enabled = b.toggle("mobile-access", state.settings.enabled) { [store] in store.setMobileEnabled($0) }
        enabled.isEnabled = !store.mobileBusy
        b.row("mobile-access", enabled)
        let port = b.field("mobile-port", String(state.settings.port)) { [store] in store.setMobilePort($0) }
        port.field.isEnabled = !store.mobileBusy
        b.row("mobile-port", port)
        let (status, failed) = Self.status(state)
        b.row("mobile-status", makeLabel(status, font: AppFont.body, color: failed ? theme.danger : theme.fgMuted))
        b.row("mobile-pair", pairing(b, state), stacked: store.pairing != nil)
        b.row("mobile-devices", devices(b, state), stacked: true)
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

    private func pairing(_ b: SettingsPageBuilder, _ state: RemoteAccessState) -> NSView {
        guard let offer = store.pairing else {
            return b.button("Show Pairing Code", enabled: state.settings.enabled && !store.mobileBusy) { [store] in store.startPairing() }
        }
        let link = offer.invite.link
        var views: [NSView] = []
        if let code = QRCode(link) {
            let view = QRCodeView(code: code)
            view.widthAnchor.constraint(equalToConstant: 200).isActive = true
            view.heightAnchor.constraint(equalToConstant: 200).isActive = true
            views.append(view)
        } else {
            views.append(NoteLabel("The pairing code is too long to show."))
        }
        views.append(NoteLabel("Scan with the Tab app. The code works once and expires in 5 minutes."))
        let copy = b.button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        }
        let cancel = b.button("Cancel") { [store] in store.cancelPairing() }
        views.append(hstack([copy, cancel], spacing: 6))
        return vstack(views)
    }

    private func devices(_ b: SettingsPageBuilder, _ state: RemoteAccessState) -> NSView {
        guard !state.devices.isEmpty else { return NoteLabel("No paired devices yet.") }
        return vstack(state.devices.map { device in
            let name = makeLabel(device.name, font: AppFont.body, color: theme.fg)
            let seen = makeLabel(Self.lastSeen(device), font: AppFont.footnote, color: theme.fgMuted)
            let revoke = b.button("Revoke", style: .destructive) { [weak self] in
                self?.confirm("Revoke “\(device.name)”?", "The phone disconnects now and must be paired again to connect.", "Revoke") {
                    self?.store.revokeDevice(device.id)
                }
            }
            return hstack([vstack([name, seen], spacing: 1), revoke])
        })
    }

    static func lastSeen(_ device: PairedDevice) -> String {
        if device.connected { return "Connected" }
        guard let seen = device.lastSeen else { return "Never connected" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last seen \(formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(seen)), relativeTo: Date()))"
    }

    // MARK: AI

    func buildAI(_ b: SettingsPageBuilder) {
        let installed = store.host?.installedAIProviders() ?? []
        for action in AIAction.allCases {
            let current = store.settings.ai.providers[action.rawValue] ?? ""
            let auto = installed.first.flatMap { id in AIAction.providers.first { $0.id == id }?.name }
            var items = [PopUp.Item(id: "", title: auto.map { "Auto · \($0)" } ?? "Auto · None installed")]
            for provider in AIAction.providers {
                let title = installed.contains(provider.id) ? provider.name : "\(provider.name) · Not installed"
                items.append(.init(id: provider.id, title: title, separatorBefore: provider.id == AIAction.providers.first?.id))
            }
            if !current.isEmpty && !items.contains(where: { $0.id == current }) {
                items.append(.init(id: current, title: "\(current) · Unsupported"))
            }
            b.row(action.providerSetting, b.popUp(action.providerSetting, items, selected: current) { [store] in
                store.setAIProvider(action, $0)
            })
            let prompt = b.field(action.promptSetting, store.prompt(action), width: nil, height: 88, multiline: true) { [store] in
                store.setAIPrompt(action, $0)
            }
            let restore = b.button("Restore Default", enabled: store.prompt(action) != action.defaultPrompt) { [store] in
                store.setAIPrompt(action, action.defaultPrompt)
            }
            let control = vstack([prompt, restore], alignment: .trailing)
            prompt.widthAnchor.constraint(equalTo: control.widthAnchor).isActive = true
            b.row(action.promptSetting, control, stacked: true)
            if action == .createPullRequest { buildProjectPrompt(b) }
            if action == .commit {
                let choices = store.settings.ai.commit
                b.row("ai-commit-include-unstaged", b.toggle("ai-commit-include-unstaged", choices.includeUnstaged) { [store] value in
                    var next = choices
                    next.includeUnstaged = value
                    store.setCommitChoices(next)
                })
                b.row("ai-commit-push", b.toggle("ai-commit-push", choices.push) { [store] value in
                    var next = choices
                    next.push = value
                    store.setCommitChoices(next)
                })
            }
        }
    }

    /// One project's own pull request prompt, chosen from a pop-up.
    private func buildProjectPrompt(_ b: SettingsPageBuilder) {
        let id = "ai-project-pr-prompt"
        let projects = store.host?.aiPromptProjects() ?? []
        guard let project = projects.first(where: { $0.id == promptProject }) ?? projects.first else {
            b.row(id, NoteLabel("Add a project to give it its own prompt."), stacked: true)
            return
        }
        let picker = b.popUp(id, projects.map { PopUp.Item(id: $0.id, title: $0.name) }, selected: project.id) { [weak self] in
            self?.promptProject = $0
            self?.reload()
        }
        let saved = store.projectPRPrompt(project.id)
        let prompt = b.field(id, saved, placeholder: "Uses the pull request prompt above", width: nil, height: 88,
                             multiline: true, label: "\(project.name) pull request prompt") { [store] in
            store.setProjectPRPrompt(project.id, $0)
        }
        let reset = b.button("Use General Prompt", enabled: !saved.isEmpty) { [store] in
            store.setProjectPRPrompt(project.id, "")
        }
        let control = vstack([picker, prompt, reset], alignment: .trailing)
        prompt.widthAnchor.constraint(equalTo: control.widthAnchor).isActive = true
        b.row(id, control, stacked: true)
    }

    // MARK: Backup

    func buildBackup(_ b: SettingsPageBuilder) {
        b.row("backup-export", b.button("Export…", enabled: !store.backupBusy) { [weak self] in self?.exportBackup() })
        var restore: [NSView] = [b.button("Choose file…", enabled: !store.backupBusy) { [weak self] in self?.chooseBackup() }]
        if store.hasPendingRestore {
            restore.append(b.button("Cancel Import") { [store] in store.cancelRestore() })
        }
        b.row("backup-restore", hstack(restore, spacing: 6))
        if !store.backupStatus.isEmpty { b.note("backup-restore", store.backupStatus) }
        let files = ["settings.json", "terminal.json", "server.json"].map { name in
            b.button(name) { [store] in store.openConfiguration(name) }
        }
        b.row("backup-files", hstack(files, spacing: 6))
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
