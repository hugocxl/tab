import AppKit
import TabCore
import TabProtocol

extension SettingsModel {
    func buildAgents(_ b: SettingsPageBuilder) {
        let state = store.agentProviders
        let settings = state?.settings ?? AgentProviderSettings()
        let light = AppTheme.shared.palette.isLight

        b.row("agent-check", b.button(store.checkingAgentProviders ? "Checking…" : "Check Now",
                                      enabled: state != nil && !store.checkingAgentProviders) { [store] in
            store.checkAgentProviders()
        }, description: Self.lastChecked(state))
        if let error = store.errors["agent-providers"] { b.note("agent-check", error, error: true) }

        if state == nil {
            b.row("agent-providers", .label("Looking for providers…", .secondary))
        }
        for provider in settings.providers where state != nil {
            let health = state?.health(provider.id)
            let run = state?.maintenance(provider.id)
            let open = SettingControl.disclosure { [weak self] in self?.openProvider(provider.id) }
            let badge = Self.badge(provider, health: health, run: run)
            b.item("agent-providers", key: provider.id, label: Self.listTitle(provider, health: health),
                   description: Self.status(provider, health: health, run: run),
                   icon: AgentLogo.image(for: provider, lightBackground: light),
                   badge.map { .row([.label($0, .badge), open]) } ?? open)
        }
        b.row("agent-add-provider", b.button("Add Provider…", enabled: state != nil) { [weak self] in self?.showAddProvider() })
        buildTerminalIntegration(b)

        b.row("agent-check-interval", b.stepper("agent-check-interval", Double(settings.healthCheckInterval / 60), range: 0 ... 1440,
                                                unit: "minutes") { [store] minutes in
            store.updateAgentProviders("agent-check-interval") { $0.healthCheckInterval = Int(minutes) * 60 }
        })

        if b.subpage == .agentProvider && !b.isSearching { buildProvider(b, state: state) }
    }

    /// The Add Provider dialog, which opens the new provider's page.
    func showAddProvider() {
        guard let state = store.agentProviders, store.canAddAgentProvider() else { return }
        let sheet = AddProviderSheet(settings: state.settings, kinds: state.kinds) { [weak self] config in
            guard let self, let id = store.addAgentProvider(config) else { return }
            openProvider(id)
        }
        sheet.present(on: window)
    }

    // MARK: A provider's page

    private func buildProvider(_ b: SettingsPageBuilder, state: AgentProvidersState?) {
        let provider = shownProvider
        let id = provider.id
        let health = state?.health(id)
        let light = AppTheme.shared.palette.isLight
        func update(_ row: String, _ change: @escaping (inout AgentProviderConfig) -> Void) {
            store.updateAgentProvider(id, row: row, change)
        }

        b.row("agent-provider-enabled", b.toggle("agent-provider-enabled", provider.enabled) { on in
            update("agent-provider-enabled") { $0.enabled = on }
        }, label: provider.title, description: Self.detail(provider, health: health),
           icon: AgentLogo.image(for: provider, lightBackground: light), iconSide: 28)
        buildStatus(b, provider: provider, health: health, run: state?.maintenance(id))

        // General
        b.row("agent-provider-name", b.field("agent-provider-name", provider.name ?? "", placeholder: provider.kind.name) { text in
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            update("agent-provider-name") { $0.name = name.isEmpty ? nil : name }
        })
        b.row("agent-provider-id", .label(id, .monospaced))
        let accent = SettingControl.color(ColorSpec(color: provider.accentColor.flatMap(RGBColor.init(hex:)), label: "Accent color") { color in
            update("agent-provider-accent") { $0.accentColor = color.hex.uppercased() }
        })
        b.row("agent-provider-accent", provider.accentColor == nil ? accent : .row([accent, b.button("Remove", icon: .trash) {
            update("agent-provider-accent") { $0.accentColor = nil }
        }]))

        // Runtime
        let spec = provider.kind.spec
        b.row("agent-provider-executable", b.field("agent-provider-executable", provider.executable ?? "",
                                                   placeholder: spec.executable ?? "e.g. qwen", monospaced: true) { text in
            let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
            update("agent-provider-executable") { $0.executable = path.isEmpty ? nil : path }
        }, description: spec.executable == nil ? "The agent to run: a command on PATH, or a full path. Required." : nil)
        if let variable = provider.homeVariable {
            b.row("agent-provider-home", b.field("agent-provider-home", provider.home ?? "",
                                                 placeholder: spec.defaultHome ?? "", monospaced: true) { text in
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                update("agent-provider-home") { $0.home = path.isEmpty ? nil : path }
            }, label: "\(variable) folder", description: provider.supportsShadowHome
                ? "The shared Codex folder, with its settings and conversations." : nil)
        }
        if provider.supportsShadowHome {
            b.row("agent-provider-shadow-home", b.field("agent-provider-shadow-home", provider.shadowHome ?? "",
                                                        placeholder: "e.g. ~/.codex-tab/personal", monospaced: true) { text in
                let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
                update("agent-provider-shadow-home") { $0.shadowHome = path.isEmpty ? nil : path }
            })
        }
        b.row("agent-provider-arguments", b.field("agent-provider-arguments", Executable.commandLine(provider.arguments),
                                                  placeholder: spec.argumentsExample ?? "", monospaced: true) { [store] text in
            do {
                let arguments = try Executable.commandArguments(text)
                update("agent-provider-arguments") { $0.arguments = arguments }
            } catch {
                store.setError("agent-provider-arguments", SettingsStore.message(error))
            }
        }, description: Self.argumentsDescription(provider.kind))
        if provider.kind == .claude {
            b.row("agent-provider-auto-compact", b.field("agent-provider-auto-compact", provider.autoCompactTokens.map(String.init) ?? "",
                                                         placeholder: "e.g. 300000") { [store] text in
                let digits = text.filter { !$0.isWhitespace && $0 != "," && $0 != "_" && $0 != "." }
                guard !digits.isEmpty else { return update("agent-provider-auto-compact") { $0.autoCompactTokens = nil } }
                guard let tokens = Int(digits), AgentProviderConfig.autoCompactRange.contains(tokens) else {
                    return store.setError("agent-provider-auto-compact", "Enter a number from 100,000 to 1,000,000.")
                }
                update("agent-provider-auto-compact") { $0.autoCompactTokens = tokens }
            })
        }

        buildVariables(b, provider: provider, update: update)
        buildModels(b, provider: provider)

        b.row("agent-provider-remove", b.button("Remove…", style: .destructive, enabled: !provider.isBuiltIn) { [weak self] in
            self?.confirm("Remove “\(provider.title)”?",
                          "Its settings are deleted. Conversations that use it stay in their panes but can't continue.",
                          "Remove") {
                self?.store.removeAgentProvider(id)
                self?.goBack()
            }
        }, description: provider.isBuiltIn ? "The built-in \(provider.kind.name) can be turned off but not removed." : nil)
    }

    private func buildVariables(_ b: SettingsPageBuilder, provider: AgentProviderConfig,
                                update: @escaping (String, @escaping (inout AgentProviderConfig) -> Void) -> Void) {
        for (index, variable) in provider.environment.enumerated() {
            let value = b.field("agent-provider-variables/\(index)", variable.value, placeholder: "Value", label: "\(variable.name) value",
                                monospaced: true) { text in
                update("agent-provider-variables") { config in
                    guard config.environment.indices.contains(index) else { return }
                    config.environment[index].value = text
                }
            }
            let remove = b.button("Remove \(variable.name)", icon: .trash) {
                update("agent-provider-variables") { config in
                    guard config.environment.indices.contains(index) else { return }
                    config.environment.remove(at: index)
                }
            }
            b.item("agent-provider-variables", key: "\(index)", label: variable.name, .row([value, remove]))
        }
        let name = b.field("agent-provider-variables", variableName, placeholder: "NAME", width: 140, label: "Variable name",
                           monospaced: true) { [weak self] text in
            self?.draft(\.variableName, text)
        } commit: { [weak self] in self?.variableName = $0 }
        let value = b.field("agent-provider-variable-value", variableValue, placeholder: "Value", width: 160, label: "Variable value",
                            monospaced: true,
                            change: { [weak self] in self?.variableValue = $0 }) { [weak self] in self?.variableValue = $0 }
        let trimmed = variableName.trimmingCharacters(in: .whitespaces)
        let add = b.button("Add", enabled: !trimmed.isEmpty) { [weak self] in
            guard let self else { return }
            let name = variableName.trimmingCharacters(in: .whitespaces)
            guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                return store.setError("agent-provider-variables", "A name has letters, digits and underscores, and doesn't start with a digit.")
            }
            let entry = AgentProviderVariable(name: name, value: variableValue)
            update("agent-provider-variables") { config in
                if let existing = config.environment.firstIndex(where: { $0.name == name }) {
                    config.environment[existing] = entry
                } else {
                    config.environment.append(entry)
                }
            }
            variableName = ""
            variableValue = ""
            reload()
        }
        b.row("agent-provider-variables", .row([name, value, add]),
              label: provider.environment.isEmpty ? "Variables" : "Add variable")
    }

    private func buildModels(_ b: SettingsPageBuilder, provider: AgentProviderConfig) {
        let id = provider.id
        let models = store.agentModels[id]
        let preferences = provider.models
        let hidden = Set(preferences.hidden)
        let favorites = Set(preferences.favorites)
        let custom = Set(preferences.custom.map(\.id))
        let summary: String
        if let models {
            let shown = models.filter { !hidden.contains($0.id) }.count
            summary = models.isEmpty ? "The CLI reported no models." : "\(shown) of \(models.count) shown in the model menu."
        } else {
            summary = store.agentModelsUnavailable.contains(id)
                ? "Couldn't list the models. Check that the CLI is installed and signed in." : "Loading models…"
        }
        b.row("agent-provider-models", b.button("Refresh models", icon: .refresh) { [store] in
            store.loadAgentModels(id, refresh: true)
        }, description: summary)

        func setModels(removing removed: String? = nil, _ change: @escaping (inout AgentProviderModels) -> Void) {
            store.updateAgentProvider(id, row: "agent-provider-models") { change(&$0.models) }
            store.rearrangeAgentModels(id, removing: removed)
        }
        let list = models ?? []
        for (index, model) in list.enumerated() {
            let isFavorite = favorites.contains(model.id)
            let isHidden = hidden.contains(model.id)
            // Favorites stay above the rest, so a model moves only among its own group.
            let canMoveUp = index > 0 && favorites.contains(list[index - 1].id) == isFavorite
            let canMoveDown = index + 1 < list.count && favorites.contains(list[index + 1].id) == isFavorite
            var controls: [SettingControl] = [
                b.button(isFavorite ? "Remove \(model.title) from favorites" : "Add \(model.title) to favorites",
                         icon: .star, isOn: isFavorite) {
                    setModels { models in
                        if isFavorite { models.favorites.removeAll { $0 == model.id } } else { models.favorites.append(model.id) }
                    }
                },
                b.button("Move \(model.title) up", enabled: canMoveUp, icon: .arrowUp) {
                    setModels { $0.order = Self.moving(list.map(\.id), from: index, to: index - 1) }
                },
                b.button("Move \(model.title) down", enabled: canMoveDown, icon: .arrowDown) {
                    setModels { $0.order = Self.moving(list.map(\.id), from: index, to: index + 1) }
                },
                .toggle(ToggleSpec(isOn: !isHidden, label: "Show \(model.title) in the model menu") { shown in
                    setModels { models in
                        models.hidden.removeAll { $0 == model.id }
                        if !shown { models.hidden.append(model.id) }
                    }
                }),
            ]
            if custom.contains(model.id) {
                controls.append(.actions("\(model.title) Actions", [ButtonSpec(title: "Remove", style: .destructive) {
                    setModels(removing: model.id) { models in
                        models.custom.removeAll { $0.id == model.id }
                        models.favorites.removeAll { $0 == model.id }
                        models.hidden.removeAll { $0 == model.id }
                        models.order.removeAll { $0 == model.id }
                    }
                }]))
            }
            let detail = custom.contains(model.id) ? "\(model.id) · Added by you" : model.title == model.id ? nil : model.id
            b.item("agent-provider-models", key: model.id, label: model.title, description: detail, .row(controls))
        }

        let field = b.field("agent-provider-custom-model", customModelID, placeholder: "Model ID",
                            monospaced: true) { [weak self] text in
            self?.draft(\.customModelID, text)
        } commit: { [weak self] in self?.customModelID = $0 }
        let modelID = customModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let add = b.button("Add", enabled: !modelID.isEmpty) { [weak self] in
            guard let self else { return }
            guard !list.contains(where: { $0.id == modelID }) else {
                return store.setError("agent-provider-custom-model", "\(modelID) is already listed.")
            }
            setModels { $0.custom.append(AgentCustomModel(id: modelID)) }
            customModelID = ""
            reload()
        }
        b.row("agent-provider-custom-model", .row([field, add]))
    }

    /// Keeps a text field's draft, rebuilding the page when it turns empty or not, so its Add button follows.
    private func draft(_ key: ReferenceWritableKeyPath<SettingsModel, String>, _ text: String) {
        let wasEmpty = self[keyPath: key].trimmingCharacters(in: .whitespaces).isEmpty
        self[keyPath: key] = text
        if wasEmpty != text.trimmingCharacters(in: .whitespaces).isEmpty { reload() }
    }

    static func moving(_ ids: [String], from: Int, to: Int) -> [String] {
        guard ids.indices.contains(from), ids.indices.contains(to) else { return ids }
        var ids = ids
        ids.swapAt(from, to)
        return ids
    }

    // MARK: Status

    /// The version, install and update controls, sign-in and the latest install or update.
    private func buildStatus(_ b: SettingsPageBuilder, provider: AgentProviderConfig, health: AgentProviderHealth?,
                             run: AgentProviderMaintenance?) {
        let id = provider.id
        let running = run?.isRunning == true
        guard provider.enabled, let health else {
            b.row("agent-provider-version", nil, description: provider.enabled ? "Not checked yet" : "Off")
            b.row("agent-provider-sign-in", nil, description: provider.enabled ? "Not checked yet" : "Off")
            return
        }
        let advisory = health.versionAdvisory
        var control: SettingControl?
        if !health.installed {
            control = b.button(running ? "Installing…" : "Install", enabled: health.canInstall && !running) { [store] in
                store.maintainAgentProvider(id, action: .install)
            }
        } else if let advisory, advisory.status == .behindLatest || advisory.status == .unsupported {
            let title = advisory.latestVersion.map { "Update to \($0)" } ?? "Update"
            control = b.button(running ? "Updating…" : title, enabled: advisory.canUpdate && !running) { [store] in
                store.maintainAgentProvider(id, action: .update)
            }
        } else if advisory?.canUpdate == true {
            control = b.button(running ? "Updating…" : "Update", enabled: !running) { [store] in
                store.maintainAgentProvider(id, action: .update)
            }
        }
        b.row("agent-provider-version", control, description: Self.versionDetail(provider, health: health))
        if let message = health.message {
            b.note("agent-provider-version", message, error: health.status == .error)
        }
        switch health.auth {
        case _ where !health.installed:
            b.row("agent-provider-sign-in", nil, description: "Install \(provider.kind.name) first.")
        case .signedIn:
            b.row("agent-provider-sign-in", .label("Signed in", .secondary),
                  description: [health.email, health.account].compactMap { $0 }.joined(separator: " · "))
        case .signedOut:
            b.row("agent-provider-sign-in", signInButton(b, health) ?? .label("Signed out", .badge),
                  description: health.message ?? health.signInCommand.map { "Sign in with `\($0)`." })
        case .unknown:
            b.row("agent-provider-sign-in", signInButton(b, health).map { .row([.label("Unknown", .badge), $0]) } ?? .label("Unknown", .badge),
                  description: Self.unknownSignIn(provider))
        }
        if let run {
            b.note("agent-provider-version", Self.maintenanceText(run), error: run.status == .failed)
            if let output = run.output, !running {
                b.below("agent-provider-version", .label(output, .monospaced))
            }
        }
    }

    /// Opens a terminal running the provider's sign-in in its own config folder.
    private func signInButton(_ b: SettingsPageBuilder, _ health: AgentProviderHealth) -> SettingControl? {
        guard let command = health.signInCommand else { return nil }
        return b.button("Sign In…", help: "Runs \(command) in a new terminal tab") { [weak self] in
            self?.store.host?.openTerminal(command: command)
            self?.window?.close()
        }
    }

    static func argumentsDescription(_ kind: AgentChatProvider) -> String {
        switch kind.spec.wire {
        case .claudeStream: "Added to Claude Code's command line when a conversation starts."
        case .codexAppServer: "Added after codex app-server when a conversation starts."
        case .acp where kind == .acp: "The arguments that start the agent's Agent Client Protocol server, such as --acp."
        case .acp: "Added after \(([kind.spec.executable ?? ""] + kind.spec.sessionArguments).joined(separator: " ")) when a conversation starts."
        }
    }

    static func unknownSignIn(_ provider: AgentProviderConfig) -> String {
        switch provider.kind {
        case .acp: "Tab can't tell whether this agent is signed in. A conversation says so when it isn't."
        case .openCode: "OpenCode has no saved model provider credentials, so only its free models may work. Run `opencode auth login` to add one."
        default: "Tab couldn't tell whether \(provider.title) is signed in."
        }
    }

    /// The version line: installed, latest and oldest supported, and how it updates.
    static func versionDetail(_ provider: AgentProviderConfig, health: AgentProviderHealth) -> String {
        guard health.installed else {
            return health.installCommand.map { "Not installed. Install it with `\($0)`." } ?? "Not installed."
        }
        var parts = [health.version.map { "Version \($0)" } ?? "Version unknown"]
        if let advisory = health.versionAdvisory {
            switch advisory.status {
            case .current: parts.append("Up to date")
            case .behindLatest: parts.append(advisory.latestVersion.map { "\($0) is available" } ?? "An update is available")
            case .unsupported: parts.append(advisory.minimumVersion.map { "Tab needs \($0) or later" } ?? "Too old for Tab")
            case .unknown: break
            }
            if let installedBy = advisory.installedBy { parts.append("Installed with \(installedBy)") }
            if !advisory.canUpdate, advisory.status != .current, let command = advisory.updateCommand {
                parts.append("Update it with `\(command)`")
            }
        }
        if let path = health.executablePath { parts.append(path) }
        return parts.joined(separator: " · ")
    }

    static func maintenanceText(_ run: AgentProviderMaintenance) -> String {
        let doing = run.action == .install ? "Installing" : "Updating"
        switch run.status {
        case .running: return "\(doing)… \(run.message ?? run.command)"
        case .succeeded, .unchanged, .failed: return run.message ?? "\(run.command) finished."
        }
    }

    /// A word beside a provider in the list when it needs attention.
    static func badge(_ provider: AgentProviderConfig, health: AgentProviderHealth?, run: AgentProviderMaintenance?) -> String? {
        guard provider.enabled else { return nil }
        if run?.isRunning == true { return run?.action == .install ? "Installing" : "Updating" }
        guard let health else { return nil }
        if !health.installed { return "Not installed" }
        if health.versionAdvisory?.status == .unsupported { return "Too old" }
        if health.auth == .signedOut { return "Signed out" }
        if health.versionAdvisory?.status == .behindLatest { return "Update" }
        return nil
    }

    static func listTitle(_ provider: AgentProviderConfig, health: AgentProviderHealth?) -> String {
        guard let version = health?.version, provider.enabled else { return provider.title }
        return "\(provider.title) \(version)"
    }

    /// One line under a provider in the list.
    static func status(_ provider: AgentProviderConfig, health: AgentProviderHealth?, run: AgentProviderMaintenance? = nil) -> String {
        guard provider.enabled else { return "Off" }
        if let run, run.isRunning { return maintenanceText(run) }
        guard let health else { return "Not checked yet" }
        guard health.installed else { return "Not found" }
        var parts: [String]
        switch health.auth {
        case .signedIn: parts = ["Signed in", health.account].compactMap { $0 }
        case .signedOut: parts = ["Not signed in"]
        case .unknown: parts = ["Installed"]
        }
        if let advisory = health.versionAdvisory {
            if advisory.status == .behindLatest, let latest = advisory.latestVersion { parts.append("\(latest) available") }
            if advisory.status == .unsupported, let minimum = advisory.minimumVersion { parts.append("needs \(minimum)") }
        }
        return parts.joined(separator: " · ")
    }

    /// The line under a provider's name on its page.
    static func detail(_ provider: AgentProviderConfig, health: AgentProviderHealth?) -> String {
        guard provider.enabled else { return "Off. Agent panes don't offer it, and its conversations can't start." }
        guard let health else { return "Not checked yet" }
        guard health.installed else { return "Not found" }
        var parts = health.version.map { ["Version \($0)"] } ?? []
        switch health.auth {
        case .signedIn: parts.append(health.email.map { "Signed in as \($0)" } ?? "Signed in")
        case .signedOut: parts.append("Not signed in")
        case .unknown: break
        }
        if let account = health.account { parts.append(account) }
        return parts.joined(separator: " · ")
    }

    static func lastChecked(_ state: AgentProvidersState?, now: Date = Date()) -> String {
        guard let latest = state?.health.map(\.checkedAt).max() else { return "Not checked yet" }
        if now.timeIntervalSince(latest) < 60 { return "Checked just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Checked \(formatter.localizedString(for: latest, relativeTo: now))"
    }
}
