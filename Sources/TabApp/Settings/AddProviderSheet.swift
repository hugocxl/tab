import AppKit
import TabCore
import TabProtocol

/// The Add Provider dialog in three steps: the kind of agent, the provider's label, ID
/// and accent color, then how it runs and signs in. A second provider of a kind gets
/// its own config folder, so it can sign in to another account.
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
        var home = ""
        var shadowHome = ""
        var arguments = ""
        var useAPIKey = false
        var apiKeyVariable = ""
        var apiKey = ""

        init(kind: AgentChatProvider, settings: AgentProviderSettings) {
            self.kind = kind
            reset(kind, settings: settings)
        }

        /// Starts over for `kind`: its derived ID, and a folder of its own when another provider
        /// of the kind exists, so the new one signs in separately.
        mutating func reset(_ kind: AgentChatProvider, settings: AgentProviderSettings) {
            self = Draft(empty: kind)
            id = settings.newID(kind, label: label)
            apiKeyVariable = kind.spec.apiKeyVariables.first ?? ""
            guard settings.providers.contains(where: { $0.kind == kind }) else { return }
            let suffix = String(id.dropFirst(kind.rawValue.count).drop { $0 == "-" })
            let folder = suffix.isEmpty ? "2" : suffix
            if kind == .codex {
                shadowHome = "~/.codex-tab/\(folder)"
            } else if let home = kind.spec.defaultHome, home != "~", kind.spec.homeVariable != nil {
                self.home = "\(home)-\(folder)"
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

        /// Why the identity can't be used, or nil.
        func identityError(_ settings: AgentProviderSettings) -> String? {
            let id = id.trimmingCharacters(in: .whitespaces)
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

    private let settings: AgentProviderSettings
    private let kinds: [AgentChatProvider]
    private let add: (AgentProviderConfig) -> Void
    private(set) var draft: Draft
    private(set) var step = Step.provider

    private let steps = NSStackView()
    private let body = NSStackView()
    private let errorLabel = DialogParts.note("", color: AppTheme.shared.danger)
    private let backButton = PillButton("Cancel")
    private let nextButton = PillButton("Next", style: .primary)
    private var tiles: [AgentChatProvider: NSButton] = [:]
    private var swatches: [String: NSButton] = [:]

    init(settings: AgentProviderSettings, kinds: [AgentChatProvider], add: @escaping (AgentProviderConfig) -> Void) {
        self.settings = settings
        self.kinds = kinds
        self.add = add
        draft = Draft(kind: kinds.first ?? .claude, settings: settings)
        let content = NSStackView()
        super.init(content: content, width: 520)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        steps.orientation = .horizontal
        steps.spacing = 18
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        errorLabel.isHidden = true
        let rows: [NSView] = [
            DialogParts.title("Add Provider"),
            DialogParts.note("Add an account, or another coding agent, to this Mac's agent panes."),
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
            add(draft.config)
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
            let buttons = pair.map(tile)
            let row = NSStackView(views: buttons)
            row.distribution = .fillEqually
            row.spacing = 10
            if buttons.count == 1 { row.addArrangedSubview(NSView()) }
            rows.append(row)
        }
        let grid = DialogParts.column(rows, spacing: 10)
        return [makeLabel("Provider", font: AppFont.bodyMedium), grid,
                DialogParts.note("Add the same agent again to use another account, such as a second Claude subscription.")]
    }

    private func tile(_ kind: AgentChatProvider) -> NSButton {
        let title = kind.spec.vendor.map { "\(kind.name)  ·  \($0)" } ?? kind.name
        let button = NSButton(title: title, target: self, action: #selector(chooseKind(_:)))
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.alignment = .left
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.font = AppFont.body
        button.contentTintColor = AppTheme.shared.fg
        let logo = AgentLogo.image(for: kind.activityProvider, lightBackground: AppTheme.shared.palette.isLight)
        logo?.size = NSSize(width: 18, height: 18)
        button.image = logo
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.borderWidth = 1
        button.tag = AgentChatProvider.allCases.firstIndex(of: kind) ?? 0
        button.setAccessibilityLabel(kind.name)
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        tiles[kind] = button
        style(button, selected: kind == draft.kind)
        return button
    }

    private func style(_ button: NSButton, selected: Bool) {
        let theme = AppTheme.shared
        button.state = selected ? .on : .off
        button.layer?.backgroundColor = (selected ? theme.accentSoft : theme.rowFill).cgColor
        button.layer?.borderColor = (selected ? theme.accent : theme.rowBorder).cgColor
    }

    @objc private func chooseKind(_ sender: NSButton) {
        let kind = AgentChatProvider.allCases[sender.tag]
        if kind != draft.kind { draft.reset(kind, settings: settings) }
        for (other, button) in tiles { style(button, selected: other == kind) }
    }

    // MARK: Identity

    private func identityStep() -> [NSView] {
        let label = InsetTextField(value: draft.label, placeholder: draft.kind.name, label: "Label", width: nil)
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
        return [
            DialogParts.field("Label", label),
            DialogParts.note("Shown in the model menu, such as “Work” or “Personal”."),
            DialogParts.field("ID", id),
            DialogParts.note("Letters, digits, “-” or “_”. Conversations keep it, so it can't change later."),
            DialogParts.field("Accent color", accentPicker()),
            DialogParts.note("Optional dot beside the provider's logo, to tell accounts apart."),
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
        if !spec.apiKeyVariables.isEmpty { views += signIn(spec) }
        if let variable = spec.homeVariable {
            let home = InsetTextField(value: draft.home, placeholder: spec.defaultHome ?? "", label: "\(variable) folder",
                                      width: nil, monospaced: true)
            home.onChange = { [weak self] in self?.draft.home = $0 }
            views += [DialogParts.field("\(variable) folder", home),
                      DialogParts.note(draft.kind == .codex
                        ? "The shared Codex folder, with its settings and conversations. Empty uses \(spec.defaultHome ?? "Codex's own")."
                        : "Where it keeps its sign-in, settings and conversations. A folder of its own signs in to another account.")]
        }
        if draft.kind == .codex {
            let shadow = InsetTextField(value: draft.shadowHome, placeholder: "e.g. ~/.codex-tab/personal", label: "Account folder",
                                        width: nil, monospaced: true)
            shadow.onChange = { [weak self] in self?.draft.shadowHome = $0 }
            views += [DialogParts.field("Account folder", shadow),
                      DialogParts.note("Keeps this account's sign-in apart while sharing conversations, skills and settings "
                                       + "with the Codex folder. Empty signs in to the Codex folder itself.")]
        }
        let executable = InsetTextField(value: draft.executable, placeholder: spec.executable ?? "e.g. qwen", label: "Executable",
                                        width: nil, monospaced: true)
        executable.onChange = { [weak self] in self?.draft.executable = $0 }
        views += [DialogParts.field("Executable", executable),
                  DialogParts.note(spec.executable == nil ? "The agent to run: a command on PATH, or a full path."
                                   : "Empty runs \(spec.executable ?? "") from PATH.")]
        let arguments = InsetTextField(value: draft.arguments, placeholder: spec.argumentsExample ?? "", label: "Launch arguments",
                                       width: nil, monospaced: true)
        arguments.onChange = { [weak self] in self?.draft.arguments = $0 }
        views += [DialogParts.field("Launch arguments", arguments),
                  DialogParts.note(SettingsModel.argumentsDescription(draft.kind))]
        if !draft.useAPIKey, spec.signInCommand != nil {
            views.append(DialogParts.note("Once it is added, sign in from its page in Settings › Agents."))
        }
        return views
    }

    private func signIn(_ spec: AgentProviderSpec) -> [NSView] {
        let account = spec.signInCommand.map { "Account (\($0))" } ?? "Account"
        let method = PopUp(items: [PopUp.Item(id: "account", title: account), PopUp.Item(id: "key", title: "API key")],
                           selected: draft.useAPIKey ? "key" : "account", label: "Sign-in method")
        method.onChange = { [weak self] id in
            self?.draft.useAPIKey = id == "key"
            self?.show(.config)
        }
        var views: [NSView] = [DialogParts.field("Sign-in method", DialogParts.row([method, DialogParts.spacer()])),
                               DialogParts.note("An account uses its subscription; an API key bills usage to the key.")]
        guard draft.useAPIKey else { return views }
        if spec.apiKeyVariables.count > 1 {
            let variable = PopUp(items: spec.apiKeyVariables.map { PopUp.Item(id: $0, title: $0) }, selected: draft.apiKeyVariable,
                                 label: "Key variable")
            variable.onChange = { [weak self] in self?.draft.apiKeyVariable = $0 }
            views.append(DialogParts.field("Variable", DialogParts.row([variable, DialogParts.spacer()])))
        }
        let key = InsetSecureField(placeholder: draft.apiKeyVariable, label: "API key")
        key.stringValue = draft.apiKey
        key.onChange = { [weak self, weak key] in self?.draft.apiKey = key?.stringValue ?? "" }
        views += [DialogParts.field("API key", key),
                  DialogParts.note("Saved as \(draft.apiKeyVariable) under the provider's variables, in plain text on this Mac.")]
        return views
    }
}
