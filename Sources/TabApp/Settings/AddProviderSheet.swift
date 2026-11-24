import AppKit
import TabClient
import TabCore
import TabProtocol

/// The Add Provider dialog in three steps: the kind of agent, the provider's label, ID
/// and accent color, then how it runs and signs in. What this Mac's server finds, such
/// as the installed CLI and who it is signed in as, fills in and checks the form as it
/// goes. Another provider of a kind gets a folder of its own, so it can sign in to
/// another account.
@MainActor
final class AddProviderSheet: SheetWindow {
    enum Step: Int, CaseIterable {
        case provider, identity, config

        var title: String {
            switch self {
            case .provider: "Provider"
            case .identity: "Identity"
            case .config: "Config"
            }
        }
    }

    /// The form as the fields hold it, kept apart from the views for tests.
    struct Draft: Equatable {
        var kind: AgentChatProvider
        var label = ""
        var id = ""
        /// Whether the ID was typed rather than derived from the label.
        var idEdited = false
        var accentColor: String?
        var executable = ""
        /// The executable Tab filled in from the CLI it found; a newer find replaces it until it is edited.
        var suggestedExecutable: String?
        var home = ""
        var shadowHome = ""
        var arguments = ""
        var useAPIKey = false
        var apiKeyVariable = ""
        var apiKey = ""
        /// Installs Tab's skill and hooks into this provider's config folder on add.
        var installIntegration = true

        init(kind: AgentChatProvider, settings: AgentProviderSettings) {
            self.kind = kind
            reset(kind, settings: settings)
        }

        /// Starts over for `kind`: its derived ID and, when another provider of the kind
        /// exists, what keeps the new one a separate account: a folder of its own, or an
        /// API key for a kind that keeps one sign-in per Mac, and an accent color of its own.
        mutating func reset(_ kind: AgentChatProvider, settings: AgentProviderSettings) {
            self = Draft(empty: kind)
            id = settings.newID(kind, label: label)
            apiKeyVariable = kind.spec.apiKeyVariables.first ?? ""
            installIntegration = CodingAgent(provider: kind) != nil
            let others = settings.providers.filter { $0.kind == kind }
            guard !others.isEmpty, kind != .acp else { return }
            let taken = Set(others.compactMap { $0.accentColor?.uppercased() })
            accentColor = AgentProviderConfig.accentColors.first { !taken.contains($0) }
            if kind.spec.homeVariable == nil {
                useAPIKey = !kind.spec.apiKeyVariables.isEmpty
                return
            }
            let suffix = String(id.dropFirst(kind.rawValue.count).drop { $0 == "-" })
            let folder = suffix.isEmpty ? "2" : suffix
            if kind == .codex {
                shadowHome = "~/.codex-tab/\(folder)"
            } else if let home = kind.spec.defaultHome {
                // Gemini CLI's variable stands for the home folder it keeps `.gemini` in.
                self.home = home == "~" ? "~/.\(kind.rawValue)-\(folder)" : "\(home)-\(folder)"
            }
        }

        private init(empty kind: AgentChatProvider) { self.kind = kind }

        /// Follows a new label with the ID, and the folders while they still follow the ID.
        mutating func setLabel(_ text: String, settings: AgentProviderSettings) {
            label = text
            guard !idEdited else { return }
            let old = id
            id = settings.newID(kind, label: text)
            let oldSuffix = String(old.dropFirst(kind.rawValue.count).drop { $0 == "-" })
            let newSuffix = String(id.dropFirst(kind.rawValue.count).drop { $0 == "-" })
            guard !oldSuffix.isEmpty || !newSuffix.isEmpty else { return }
            let from = oldSuffix.isEmpty ? "2" : oldSuffix, to = newSuffix.isEmpty ? "2" : newSuffix
            if shadowHome.hasSuffix("/\(from)") { shadowHome = String(shadowHome.dropLast(from.count)) + to }
            if home.hasSuffix("-\(from)") { home = String(home.dropLast(from.count)) + to }
        }

        /// Fills in the executable the server found at `path`, unless one was typed.
        mutating func suggest(executable path: String?) {
            let typed = executable.trimmingCharacters(in: .whitespaces)
            guard typed.isEmpty || typed == suggestedExecutable else { return }
            let value = path.map(Self.suggestion) ?? ""
            executable = value
            suggestedExecutable = value.isEmpty ? nil : value
        }

        /// A found CLI's path, or only its name when the path names one installed version,
        /// such as a Node version's under nvm, which an upgrade would leave behind.
        static func suggestion(_ path: String) -> String {
            let pinned = ["/.nvm/", "/.fnm/", "/.volta/tools/", "/.asdf/installs/", "/mise/installs/", "/Cellar/", "/versions/"]
            return pinned.contains(where: path.contains) ? (path as NSString).lastPathComponent : path
        }

        /// The providers of the same kind already added.
        func siblings(_ settings: AgentProviderSettings) -> [AgentProviderConfig] {
            settings.providers.filter { $0.kind == kind }
        }

        /// Why the identity can't be used, or nil.
        func identityError(_ settings: AgentProviderSettings) -> String? {
            let id = id.trimmingCharacters(in: .whitespaces)
            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = siblings(settings)
            if let first = others.first, label.isEmpty {
                return "Enter a label, such as Work or Personal, to tell it apart from “\(first.title)”."
            }
            let title = label.isEmpty ? kind.name : label
            if others.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                return "Another \(kind.name) provider is called “\(title)”."
            }
            guard !id.isEmpty else { return "Enter an ID." }
            guard AgentProviderConfig.isValidID(id) else { return "An ID has up to 64 letters, digits, “-” and “_”." }
            guard settings.provider(id) == nil else { return "Another provider has the ID “\(id)”." }
            return nil
        }

        /// Why the configuration can't be used, or nil.
        func configError() -> String? {
            if kind.spec.executable == nil, executable.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Enter the agent's command."
            }
            if (try? Executable.commandArguments(arguments)) == nil, !arguments.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Close the quote in the launch arguments."
            }
            if useAPIKey, apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the API key." }
            return nil
        }

        /// The provider already added that this one would share a sign-in with, making it the same account.
        func sharedSignIn(_ settings: AgentProviderSettings) -> AgentProviderConfig? {
            let config = config
            return settings.providers.first { config.sharesSignIn(with: $0) }
        }

        var config: AgentProviderConfig {
            func trimmed(_ text: String) -> String? {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            let arguments = trimmed(arguments).flatMap { try? Executable.commandArguments($0) } ?? []
            let key = useAPIKey ? trimmed(apiKey) : nil
            return AgentProviderConfig(
                id: id.trimmingCharacters(in: .whitespaces), kind: kind, name: trimmed(label),
                executable: trimmed(executable), home: kind.spec.homeVariable == nil ? nil : trimmed(home),
                shadowHome: kind == .codex ? trimmed(shadowHome) : nil, accentColor: accentColor,
                arguments: arguments,
                environment: key.map { [AgentProviderVariable(name: apiKeyVariable, value: $0)] } ?? [])
        }
    }

    typealias Probe = (AgentProviderConfig) async -> AgentProviderHealth?

    private let state: AgentProvidersState
    private var settings: AgentProviderSettings { state.settings }
    private let kinds: [AgentChatProvider]
    private let add: (AgentProviderConfig, Bool) -> Void
    /// Checks a provider on the server; nil when the server can't.
    private var probe: Probe?
    private(set) var draft: Draft
    private(set) var step = Step.provider
    /// CLIs found in this app's own PATH and the usual install folders, by kind: what the
    /// dialog shows until, or when, the server can't say.
    private(set) var detected: [AgentChatProvider: String]
    /// What the server found for each kind's CLI in its default setup.
    private(set) var found: [AgentChatProvider: AgentProviderHealth] = [:]
    /// What the server found for the form as it stands, and the form it checked.
    private(set) var draftHealth: AgentProviderHealth?
    /// Each form checked so far, so going back to one doesn't wait for the server again.
    private var checked: [AgentProviderConfig: AgentProviderHealth] = [:]
    private var draftProbe: Task<Void, Never>?

    private let steps = NSStackView()
    private let body = NSStackView()
    private let errorLabel = DialogParts.note("", color: AppTheme.shared.danger)
    private let backButton = PillButton("Cancel")
    private let nextButton = PillButton("Next", style: .primary)
    private var tiles: [AgentChatProvider: ProviderTile] = [:]
    private var swatches: [String: NSButton] = [:]
    /// The config step's lines that follow what the server finds, updated in place so typing isn't interrupted.
    private let statusLabel = DialogParts.note("")
    private let warningLabel = DialogParts.note("", color: AppTheme.shared.warning)
    private let executableNote = DialogParts.note("")
    private weak var executableField: InsetTextField?

    init(state: AgentProvidersState, probe: Probe?, detected: [AgentChatProvider: String]? = nil,
         add: @escaping (AgentProviderConfig, Bool) -> Void) {
        self.state = state
        kinds = state.kinds
        self.probe = probe
        self.add = add
        let detected = detected ?? Self.detectInstallations(kinds: state.kinds)
        self.detected = detected
        let added = Set(state.settings.providers.map(\.kind))
        let initial = state.kinds.first { detected[$0] != nil && !added.contains($0) }
            ?? state.kinds.first { !added.contains($0) && $0 != .acp } ?? state.kinds.first ?? .claude
        draft = Draft(kind: initial, settings: state.settings)
        draft.suggest(executable: detected[initial])
        let content = NSStackView()
        super.init(content: content, width: 540)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        steps.orientation = .horizontal
        steps.spacing = 18
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        errorLabel.isHidden = true
        let intro = state.settings.providers.isEmpty
            ? "Choose the coding agent to use in agent panes. Tab fills in what it finds on this Mac; you can change any of it now or later."
            : "Add another coding agent, or another account of one you already use, such as a work and a personal subscription."
        let rows: [NSView] = [
            DialogParts.title("Add Provider"),
            DialogParts.note(intro),
            steps, body, errorLabel,
            DialogParts.buttons(trailing: [backButton, nextButton]),
        ]
        for row in rows {
            content.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        backButton.onPress = { [weak self] in self?.back() }
        nextButton.onPress = { [weak self] in self?.next() }
        onCancel = { [weak self] in self?.dismiss() }
        onDefault = { [weak self] in self?.next() }
        show(.provider)
        probeKinds()
    }

    override func dismiss() {
        draftProbe?.cancel()
        probe = nil
        super.dismiss()
    }

    /// Looks for each provider kind's default CLI on PATH and common macOS install directories.
    nonisolated static func detectInstallations(kinds: [AgentChatProvider],
                                                environment: [String: String] = ProcessInfo.processInfo.environment) -> [AgentChatProvider: String] {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.cargo/bin",
        ]
        var directories: [String] = []
        var seen = Set<String>()
        for dir in pathEntries + extra where !dir.isEmpty && seen.insert(dir).inserted {
            directories.append(dir)
        }
        var found: [AgentChatProvider: String] = [:]
        for kind in kinds {
            guard let executable = kind.spec.executable, !executable.isEmpty else { continue }
            for dir in directories {
                let candidate = (dir as NSString).appendingPathComponent(executable)
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    found[kind] = candidate
                    break
                }
            }
        }
        return found
    }

    // MARK: Checking on the server

    /// Asks the server about each kind's CLI as it runs with nothing set.
    private func probeKinds() {
        guard let probe else { return }
        for kind in kinds where kind.spec.executable != nil {
            Task { [weak self] in
                let health = await probe(AgentProviderConfig(id: kind.rawValue, kind: kind))
                guard let self, self.probe != nil else { return }
                guard let health else { return self.probeUnavailable() }
                self.found[kind] = health
                self.tiles[kind]?.detail = self.tileDetail(kind)
                if kind == self.draft.kind { self.suggestFound() }
            }
        }
    }

    /// Fills in the executable the server found for the draft's kind.
    private func suggestFound() {
        guard found[draft.kind] != nil else { return }
        let before = draft.executable
        draft.suggest(executable: foundPath(draft.kind))
        if draft.executable != before { executableField?.stringValue = draft.executable }
        if step == .config { refreshFindings() }
    }

    /// Where the kind's CLI is: as the server runs it, else as this app found it, as the
    /// server's PATH may leave out a folder such as `~/.bun/bin`.
    private func foundPath(_ kind: AgentChatProvider) -> String? {
        if let health = found[kind], health.installed, let path = health.executablePath { return path }
        return detected[kind]
    }

    /// An older server can't check providers it hasn't saved; the dialog keeps to what it detects itself.
    private func probeUnavailable() {
        probe = nil
        draftProbe?.cancel()
        for (kind, tile) in tiles { tile.detail = tileDetail(kind) }
        if step == .config { refreshFindings() }
    }

    /// Checks the form as it stands after a pause in typing.
    private func checkDraft(after delay: Duration = .milliseconds(450)) {
        draftProbe?.cancel()
        draftProbe = nil
        var config = draft.config
        config.id = draft.kind.rawValue
        config.name = nil
        config.accentColor = nil
        draftHealth = checked[config]
        guard let probe, draftHealth == nil, draft.kind.spec.executable != nil, draft.configError() == nil,
              (try? config.validate()) != nil else { return refreshFindings() }
        draftProbe = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let health = await probe(config)
            guard !Task.isCancelled, let self, self.probe != nil else { return }
            self.draftProbe = nil
            guard let health else { return self.probeUnavailable() }
            self.checked[config] = health
            self.draftHealth = health
            self.refreshFindings()
        }
        refreshFindings()
    }

    // MARK: Steps

    private func show(_ next: Step) {
        step = next
        errorLabel.isHidden = true
        backButton.title = step == .provider ? "Cancel" : "Back"
        nextButton.title = step == .config ? "Add Provider" : "Next"
        steps.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in Step.allCases {
            let done = item.rawValue < step.rawValue
            let label = makeLabel("\(done ? "✓" : String(item.rawValue + 1))  \(item.title)",
                                  font: item == step ? AppFont.bodyMedium : AppFont.body,
                                  color: item == step ? AppTheme.shared.fg : AppTheme.shared.fgMuted)
            steps.addArrangedSubview(label)
        }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let views: [NSView]
        switch step {
        case .provider: views = providerStep()
        case .identity: views = identityStep()
        case .config: views = configStep()
        }
        for view in views {
            body.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        if step == .config { checkDraft(after: .zero) }
        fitContent()
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return dismiss() }
        show(previous)
    }

    private func next() {
        switch step {
        case .provider:
            show(.identity)
        case .identity:
            if let error = draft.identityError(settings) { return fail(error) }
            show(.config)
        case .config:
            if let error = draft.configError() ?? draft.identityError(settings) { return fail(error) }
            dismiss()
            add(draft.config, draft.installIntegration)
        }
    }

    private func fail(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        fitContent()
    }

    // MARK: Provider

    private func providerStep() -> [NSView] {
        tiles = [:]
        var rows: [NSView] = []
        for pair in stride(from: 0, to: kinds.count, by: 2).map({ Array(kinds[$0 ..< min($0 + 2, kinds.count)]) }) {
            let views: [NSView] = pair.map(tile)
            let row = NSStackView(views: views)
            row.distribution = .fillEqually
            row.spacing = 10
            if views.count == 1 { row.addArrangedSubview(NSView()) }
            rows.append(row)
        }
        let grid = DialogParts.column(rows, spacing: 10)
        return [grid, DialogParts.note("Pick one you already added to connect another account, such as a second Claude subscription.")]
    }

    private func tile(_ kind: AgentChatProvider) -> ProviderTile {
        let title = kind.spec.vendor.map { "\(kind.name)  ·  \($0)" } ?? kind.name
        let logo = AgentLogo.image(for: kind.activityProvider, lightBackground: AppTheme.shared.palette.isLight)
        let tile = ProviderTile(kind: kind, title: title, image: logo)
        tile.detail = tileDetail(kind)
        tile.isSelected = kind == draft.kind
        tile.onPick = { [weak self] kind in self?.choose(kind) }
        tiles[kind] = tile
        return tile
    }

    /// The line under a kind's name: whether it is added already and what was found of its CLI.
    func tileDetail(_ kind: AgentChatProvider) -> String {
        if kind == .acp { return "Any Agent Client Protocol agent" }
        var parts: [String] = []
        let added = settings.providers.filter { $0.kind == kind }.count
        if added > 0 { parts.append(added == 1 ? "Added" : "\(added) added") }
        if let health = found[kind] {
            guard health.installed else { return (parts + ["Not installed"]).joined(separator: " · ") }
            parts.append(health.version ?? "Installed")
            if health.auth == .signedIn, let who = health.email ?? health.account { parts.append(who) }
            if health.auth == .signedOut { parts.append("Signed out") }
        } else if detected[kind] != nil {
            parts.append("Installed")
        } else {
            parts.append(probe == nil ? "Not found" : "Checking…")
        }
        return parts.joined(separator: " · ")
    }

    private func choose(_ kind: AgentChatProvider) {
        if kind != draft.kind {
            draft.reset(kind, settings: settings)
            draftHealth = nil
            draft.suggest(executable: foundPath(kind))
        }
        for (other, tile) in tiles { tile.isSelected = other == kind }
    }

    // MARK: Identity

    private func identityStep() -> [NSView] {
        let others = draft.siblings(settings)
        let label = InsetTextField(value: draft.label, placeholder: others.isEmpty ? draft.kind.name : "e.g. Work or Personal",
                                   label: "Label", width: nil)
        let id = InsetTextField(value: draft.id, placeholder: draft.kind.rawValue, label: "ID", width: nil, monospaced: true)
        label.onChange = { [weak self, weak id] text in
            guard let self else { return }
            draft.setLabel(text, settings: settings)
            if !draft.idEdited { id?.stringValue = draft.id }
        }
        id.onChange = { [weak self] text in
            self?.draft.id = text
            self?.draft.idEdited = true
        }
        initialFirstResponder = label.field
        let labelNote = others.isEmpty
            ? "Shown in the model menu and AI usage. Empty shows “\(draft.kind.name)”."
            : "You already have \(Self.list(others.map { "“\($0.title)”" })). A label, such as Work or Personal, tells the accounts apart in the model menu and AI usage."
        return [
            DialogParts.field("Label", label),
            DialogParts.note(labelNote),
            DialogParts.field("ID", id),
            DialogParts.note("Letters, digits, “-” or “_”. Conversations keep it, so it can't change later."),
            DialogParts.field("Accent color", accentPicker()),
            DialogParts.note(others.isEmpty ? "Optional dot beside the provider's logo, to tell accounts apart."
                                            : "A dot beside the logo, so you can tell this account from the others at a glance."),
        ]
    }

    private func accentPicker() -> NSView {
        swatches = [:]
        let none = swatch(nil)
        let row = DialogParts.row([none] + AgentProviderConfig.accentColors.map { swatch($0) }, spacing: 8)
        return DialogParts.row([row, DialogParts.spacer()])
    }

    private func swatch(_ hex: String?) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(chooseAccent(_:)))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        button.identifier = NSUserInterfaceItemIdentifier(hex ?? "")
        button.setAccessibilityLabel(hex.map { "Accent \($0)" } ?? "No accent color")
        button.toolTip = hex == nil ? "None" : nil
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 22), button.heightAnchor.constraint(equalToConstant: 22)])
        swatches[hex ?? ""] = button
        styleSwatch(button, hex: hex)
        return button
    }

    private func styleSwatch(_ button: NSButton, hex: String?) {
        let theme = AppTheme.shared
        let selected = hex == draft.accentColor
        button.layer?.backgroundColor = hex.flatMap(RGBColor.init(hex:))?.nsColor.cgColor ?? theme.rowFill.cgColor
        button.layer?.borderWidth = selected ? 2 : 1
        button.layer?.borderColor = (selected ? theme.fg : theme.rowBorder).cgColor
        button.setAccessibilityValue(selected ? "selected" : nil)
    }

    @objc private func chooseAccent(_ sender: NSButton) {
        let raw = sender.identifier?.rawValue ?? ""
        draft.accentColor = raw.isEmpty ? nil : raw
        for (hex, button) in swatches { styleSwatch(button, hex: hex.isEmpty ? nil : hex) }
    }

    // MARK: Config

    private func configStep() -> [NSView] {
        let spec = draft.kind.spec
        var views: [NSView] = []
        if spec.executable != nil { views.append(statusLabel) }
        if !spec.apiKeyVariables.isEmpty { views += signIn(spec) }
        if let variable = spec.homeVariable {
            let home = InsetTextField(value: draft.home, placeholder: spec.defaultHome ?? "", label: "\(variable) folder",
                                      width: nil, monospaced: true)
            home.onChange = edit { $0.home = $1 }
            views += [DialogParts.field("\(variable) folder", home),
                      DialogParts.note(draft.kind == .codex
                        ? "The shared Codex folder, with its settings and conversations. Empty uses \(spec.defaultHome ?? "Codex's own")."
                        : "Where it keeps its sign-in, settings and conversations. Empty uses \(spec.defaultHome ?? "its default"); "
                          + "a folder of its own signs in to another account.")]
        }
        if draft.kind == .codex {
            let shadow = InsetTextField(value: draft.shadowHome, placeholder: "e.g. ~/.codex-tab/personal", label: "Account folder",
                                        width: nil, monospaced: true)
            shadow.onChange = edit { $0.shadowHome = $1 }
            views += [DialogParts.field("Account folder", shadow),
                      DialogParts.note("Keeps this account's sign-in apart while sharing conversations, skills and settings "
                                       + "with the Codex folder. Empty signs in to the Codex folder itself.")]
        }
        views.append(warningLabel)
        let executable = InsetTextField(value: draft.executable, placeholder: spec.executable ?? "e.g. qwen",
                                        label: "Executable", width: nil, monospaced: true)
        executable.onChange = edit { $0.executable = $1 }
        executableField = executable
        views += [DialogParts.field("Executable", executable), executableNote]
        let arguments = InsetTextField(value: draft.arguments, placeholder: spec.argumentsExample ?? "", label: "Launch arguments",
                                       width: nil, monospaced: true)
        arguments.onChange = { [weak self] in self?.draft.arguments = $0 }
        views += [DialogParts.field("Launch arguments", arguments),
                  DialogParts.note(SettingsModel.argumentsDescription(draft.kind))]
        if CodingAgent(provider: draft.kind) != nil {
            let toggle = NSButton(checkboxWithTitle: "Set up Tab integration (skill and hooks)",
                                  target: self, action: #selector(toggleIntegration(_:)))
            toggle.state = draft.installIntegration ? .on : .off
            toggle.font = AppFont.body
            views += [toggle,
                      DialogParts.note("Installs Tab's skill and hooks into this provider's config folder so it operates smoothly in Tab.")]
        }
        return views
    }

    /// Applies a field's edit, then checks the form again.
    private func edit(_ change: @escaping (inout Draft, String) -> Void) -> (String) -> Void {
        { [weak self] text in
            guard let self else { return }
            change(&draft, text)
            checkDraft()
        }
    }

    @objc private func toggleIntegration(_ sender: NSButton) {
        draft.installIntegration = sender.state == .on
    }

    private func signIn(_ spec: AgentProviderSpec) -> [NSView] {
        let account = spec.signInCommand.map { "Account (\($0))" } ?? "Account"
        let method = PopUp(items: [PopUp.Item(id: "account", title: account), PopUp.Item(id: "key", title: "API key")],
                           selected: draft.useAPIKey ? "key" : "account", label: "Sign-in method")
        method.onChange = { [weak self] id in
            self?.draft.useAPIKey = id == "key"
            self?.show(.config)
        }
        let perMac = spec.homeVariable == nil
            ? " \(draft.kind.name) keeps one account sign-in per Mac, so another account needs an API key." : ""
        var views: [NSView] = [DialogParts.field("Sign-in method", DialogParts.row([method, DialogParts.spacer()])),
                               DialogParts.note("An account uses its subscription; an API key bills usage to the key.\(perMac)")]
        guard draft.useAPIKey else { return views }
        if spec.apiKeyVariables.count > 1 {
            let variable = PopUp(items: spec.apiKeyVariables.map { PopUp.Item(id: $0, title: $0) }, selected: draft.apiKeyVariable,
                                 label: "Key variable")
            variable.onChange = { [weak self] in self?.draft.apiKeyVariable = $0 }
            views.append(DialogParts.field("Variable", DialogParts.row([variable, DialogParts.spacer()])))
        }
        let key = InsetSecureField(placeholder: draft.apiKeyVariable, label: "API key")
        key.stringValue = draft.apiKey
        let changeKey = edit { $0.apiKey = $1 }
        key.onChange = { [weak key] in changeKey(key?.stringValue ?? "") }
        views += [DialogParts.field("API key", key),
                  DialogParts.note("Saved as \(draft.apiKeyVariable) under the provider's variables, in plain text on this Mac.")]
        return views
    }

    // MARK: Findings

    /// Updates the lines that follow what the server found for the form.
    private func refreshFindings() {
        let theme = AppTheme.shared
        let status = Self.status(draft, health: draftHealth, checking: draftProbe != nil)
        statusLabel.stringValue = status.text
        statusLabel.textColor = status.problem ? theme.warning : theme.fgMuted
        statusLabel.isHidden = status.text.isEmpty
        let warning = Self.warning(draft, health: draftHealth, state: state)
        warningLabel.stringValue = warning ?? ""
        warningLabel.isHidden = warning == nil
        executableNote.stringValue = executableDescription()
        fitContent()
    }

    private func executableDescription() -> String {
        let spec = draft.kind.spec
        guard let name = spec.executable else { return "The agent to run: a command on PATH, or a full path." }
        let typed = draft.executable.trimmingCharacters(in: .whitespaces)
        if let path = draftHealth?.executablePath, draftHealth?.installed == true {
            return typed.isEmpty || typed == path ? "Runs \(path)." : "Runs \(path). Empty runs \(name) from PATH."
        }
        if !typed.isEmpty, typed == draft.suggestedExecutable { return "Found on this Mac. Empty runs \(name) from PATH." }
        return "Empty runs \(name) from PATH."
    }

    /// The line on top of the config step: what the server found of the CLI and its sign-in.
    static func status(_ draft: Draft, health: AgentProviderHealth?, checking: Bool) -> (text: String, problem: Bool) {
        let name = draft.kind.name
        guard let health else { return (checking ? "Checking \(name)…" : "", false) }
        guard health.installed else {
            let install = health.installCommand.map { " Install it with `\($0)`, or add it now and install it from its page." } ?? ""
            return ("\(name) isn't installed.\(install)", true)
        }
        let version = health.version.map { "\(name) \($0)" } ?? name
        if let advisory = health.versionAdvisory, advisory.status == .unsupported, let minimum = advisory.minimumVersion {
            return ("\(version) is older than \(minimum), the oldest Tab works with. Update it from its page once it is added.", true)
        }
        switch health.auth {
        case .signedIn:
            let who = [health.email.map { "as \($0)" }, health.account].compactMap { $0 }.joined(separator: " · ")
            return ("\(version) · Signed in\(who.isEmpty ? "" : " " + who)", false)
        case .signedOut where draft.useAPIKey:
            return ("\(version) · Signs in with the API key.", false)
        case .signedOut:
            return ("\(version) · Not signed in here yet. Once it is added, sign in from its page.", false)
        case .unknown:
            return ("\(version) · Tab can't tell whether it is signed in.", false)
        }
    }

    /// Why the form may not be the separate account it is meant to be, or nil.
    static func warning(_ draft: Draft, health: AgentProviderHealth?, state: AgentProvidersState) -> String? {
        if let other = draft.sharedSignIn(state.settings) {
            if draft.useAPIKey { return "“\(other.title)” uses the same API key, so both are one account." }
            guard let folder = draft.config.signInFolder else {
                return "\(draft.kind.name) keeps one account sign-in per Mac, so this is the same account as “\(other.title)”. "
                    + "Choose API key to add another account."
            }
            return "“\(other.title)” already signs in from \(folder), so both would be one account. "
                + "Choose another folder to add a different account."
        }
        guard let email = health?.email?.lowercased(), health?.auth == .signedIn else { return nil }
        let same = draft.siblings(state.settings).first { state.health($0.id)?.email?.lowercased() == email }
        return same.map { "Signed in as \(email), the same account as “\($0.title)”." }
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }
}

/// One kind of agent in the dialog's first step: its logo, name and what was found of it.
@MainActor
final class ProviderTile: NSControl {
    let kind: AgentChatProvider
    var onPick: ((AgentChatProvider) -> Void)?
    var isSelected = false { didSet { restyle() } }
    var detail: String {
        get { detailLabel.stringValue }
        set {
            detailLabel.stringValue = newValue
            detailLabel.toolTip = newValue
            setAccessibilityValue(newValue)
        }
    }

    private let titleLabel: NSTextField
    private let detailLabel = makeLabel("", font: AppFont.footnote, color: AppTheme.shared.fgMuted)

    init(kind: AgentChatProvider, title: String, image: NSImage?) {
        self.kind = kind
        titleLabel = makeLabel(title, font: AppFont.body)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        let logo = NSImageView()
        logo.image = image
        logo.imageScaling = .scaleProportionallyUpOrDown
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [logo, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        row.pinEdges(to: self)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 20), logo.heightAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 48),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(kind.name)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onPick?(kind) }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onPick?(kind) } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        onPick?(kind)
        return true
    }

    private func restyle() {
        let theme = AppTheme.shared
        layer?.backgroundColor = (isSelected ? theme.accentSoft : theme.rowFill).cgColor
        layer?.borderColor = (isSelected ? theme.accent : theme.rowBorder).cgColor
        titleLabel.textColor = theme.fg
        setAccessibilityValue(isSelected ? "selected" : detailLabel.stringValue)
    }
}
