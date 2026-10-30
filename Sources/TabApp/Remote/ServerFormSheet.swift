import AppKit
import Combine
import TabCore

/// The Add Server and Edit Server dialog: name, group, the SSH host, user,
/// port, identity file and password login, or a custom command; Test
/// Connection with its live result, the offer to install Tab there, and
/// trusting a new host key; Save.
@MainActor
final class ServerFormSheet: SheetWindow {
    private static let newGroupID = "\u{0}new"
    private static let noGroupID = "\u{0}none"

    var onClose: (() -> Void)?
    private let controller: RemoteServersController
    private let editing: ServerId?
    private var model: RemoteServersModel { controller.model }
    private var subscription: AnyCancellable?

    private let name: InsetTextField
    private let groupPopUp: PopUp
    private let newGroup: InsetTextField
    private let customSwitch: Switch
    private let command: InsetTextField
    private let host: InsetTextField
    private let user: InsetTextField
    private let port: InsetTextField
    private let identity: InsetTextField
    private let passwordSwitch: Switch
    private let password = InsetSecureField(placeholder: "Asked when connecting if empty", label: "Password")
    private let status = DialogParts.note("")
    private let spinner = Spinner()
    private let errorLabel = DialogParts.note("")
    private var sshFields: NSView!
    private var commandFields: NSView!
    private var passwordField: NSView!
    private var newGroupField: NSView!
    private let testButton = PillButton("Test Connection")
    private let trustButton = PillButton("Trust & Test")
    private let installButton = PillButton("Install & Test")
    private let saveButton = PillButton("Save", style: .primary)

    init(controller: RemoteServersController, editing: ServerId?) {
        self.controller = controller
        self.editing = editing
        let form = editing.flatMap(controller.model.entry).map(ServerForm.init) ?? ServerForm()
        name = InsetTextField(value: form.name, placeholder: "Shown in the sidebar", label: "Name", width: nil)
        let groups = controller.model.groups
        var items = [PopUp.Item(id: Self.noGroupID, title: "No Group")]
        items += groups.map { PopUp.Item(id: $0, title: $0) }
        items.append(PopUp.Item(id: Self.newGroupID, title: "New Group…", separatorBefore: true))
        groupPopUp = PopUp(items: items, selected: form.group.isEmpty ? Self.noGroupID : form.group, label: "Group")
        newGroup = InsetTextField(value: "", placeholder: "Group name", label: "New group name", width: nil)
        customSwitch = Switch(isOn: form.customCommand != nil, label: "Custom command")
        command = InsetTextField(value: form.customCommand ?? "", placeholder: "vm ssh devbox --",
                                 label: "Command", width: nil, monospaced: true)
        host = InsetTextField(value: form.host, placeholder: "Host name, address or ~/.ssh/config alias",
                              label: "SSH host", width: nil)
        user = InsetTextField(value: form.user, placeholder: "Optional", label: "User", width: nil)
        port = InsetTextField(value: form.port, placeholder: "22", label: "Port", width: 80)
        identity = InsetTextField(value: form.identityFile, placeholder: "Use SSH config or agent",
                                  label: "Identity file", width: nil)
        passwordSwitch = Switch(isOn: form.passwordLogin, label: "Log in with a password")
        let content = NSStackView()
        super.init(content: content, width: 460)
        build(content)
        wire()
        subscription = model.changes.receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }
        refresh()
    }

    private func build(_ content: NSStackView) {
        let title = DialogParts.title(editing == nil ? "Add Remote Server" : "Edit Remote Server")
        let groupRow = DialogParts.row([makeLabel("Group", font: AppFont.body), DialogParts.spacer(), groupPopUp])
        newGroupField = DialogParts.field("New group", newGroup)
        newGroupField.isHidden = true
        let custom = DialogParts.row([makeLabel("Custom command", font: AppFont.body), DialogParts.spacer(), customSwitch])
        commandFields = DialogParts.column([
            DialogParts.field("Command", command),
            DialogParts.note("Runs a local program with Tab's remote command appended as one argument. It must connect without prompts or a TTY. Use an absolute program path if it isn't on Tab's PATH."),
        ], spacing: 6)
        let browse = PillButton("Browse…") { [weak self] in self?.chooseIdentity() }
        let identityRow = DialogParts.row([identity, browse])
        identity.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let userField = DialogParts.field("User", user)
        let portField = DialogParts.field("Port", port)
        let login = DialogParts.row([userField, portField], spacing: 12)
        login.alignment = .top
        userField.widthAnchor.constraint(equalTo: login.widthAnchor, constant: -92).isActive = true
        passwordField = DialogParts.field("Password", password)
        sshFields = DialogParts.column([
            DialogParts.field("SSH host", host),
            login,
            DialogParts.field("Identity file", identityRow),
            DialogParts.row([makeLabel("Log in with a password", font: AppFont.body), DialogParts.spacer(), passwordSwitch]),
            passwordField,
        ])
        let statusRow = DialogParts.row([spinner, status])
        statusRow.alignment = .top
        errorLabel.textColor = AppTheme.shared.danger
        let actions = DialogParts.buttons(
            leading: [testButton, trustButton, installButton],
            trailing: [PillButton("Cancel") { [weak self] in self?.close(saved: false) }, saveButton]
        )
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        let rows: [NSView] = [
            title,
            DialogParts.field("Name", name),
            groupRow,
            newGroupField,
            custom,
            commandFields,
            sshFields,
            statusRow,
            errorLabel,
            actions,
        ]
        for row in rows {
            content.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.setCustomSpacing(18, after: errorLabel)
    }

    private func wire() {
        for field in [name, newGroup, command, host, user, port, identity] {
            field.onChange = { [weak self] _ in self?.formChanged() }
        }
        password.onCommit = nil
        password.onChange = { [weak self] in self?.formChanged() }
        groupPopUp.onChange = { [weak self] _ in
            guard let self else { return }
            self.newGroupField.isHidden = self.groupPopUp.selectedId != Self.newGroupID
            if !self.newGroupField.isHidden { self.makeFirstResponder(self.newGroup.field) }
            self.formChanged()
        }
        customSwitch.onChange = { [weak self] _ in self?.formChanged() }
        passwordSwitch.onChange = { [weak self] _ in self?.formChanged() }
        testButton.onPress = { [weak self] in self?.test() }
        trustButton.onPress = { [weak self] in self?.test(trust: true) }
        installButton.onPress = { [weak self] in self?.test(install: true) }
        saveButton.onPress = { [weak self] in self?.save() }
        onCancel = { [weak self] in self?.close(saved: false) }
    }

    /// The form as the fields hold it now.
    var form: ServerForm {
        var form = ServerForm()
        form.name = name.stringValue
        let group = groupPopUp.selectedId
        form.group = group == Self.newGroupID ? newGroup.stringValue : (group == Self.noGroupID ? "" : group)
        if customSwitch.isOn {
            form.customCommand = command.stringValue
        } else {
            form.host = host.stringValue
            form.user = user.stringValue
            form.port = port.stringValue
            form.identityFile = identity.stringValue
            form.passwordLogin = passwordSwitch.isOn
            form.password = passwordSwitch.isOn ? password.stringValue : ""
        }
        return form
    }

    private func formChanged() {
        errorLabel.stringValue = ""
        model.clearTest()
        refresh()
    }

    private func refresh() {
        let custom = customSwitch.isOn
        commandFields.isHidden = !custom
        sshFields.isHidden = custom
        passwordField.isHidden = !passwordSwitch.isOn
        let result = model.testResult(for: form)
        let message = result?.message ?? (custom
            ? ("Authentication and host keys belong to the command; set them up in a terminal first.", .muted)
            : ("Tab uses your SSH config, keys, and agent. A password is never saved.", .muted))
        status.stringValue = message.text
        let theme = AppTheme.shared
        switch message.tone {
        case .muted: status.textColor = theme.fgMuted
        case .good: status.textColor = theme.accent
        case .warning: status.textColor = theme.warning
        case .error: status.textColor = theme.danger
        }
        let running = result?.isRunning == true
        spinner.isHidden = !running
        testButton.isEnabled = !running
        saveButton.isEnabled = !running
        if case .untrustedHost? = result { trustButton.isHidden = false } else { trustButton.isHidden = true }
        if case .notInstalled? = result, let version = RemoteRelease.installableVersion {
            installButton.title = "Install Tab \(version) & Test"
            installButton.isHidden = false
        } else {
            installButton.isHidden = true
        }
        errorLabel.isHidden = errorLabel.stringValue.isEmpty
        fitContent()
    }

    private func test(trust: Bool = false, install: Bool = false) {
        errorLabel.stringValue = ""
        model.testConnection(form, id: editing, trust: trust, install: install)
    }

    private func save() {
        do {
            try model.save(form, id: editing)
            close(saved: true)
        } catch {
            errorLabel.stringValue = error.localizedDescription
            refresh()
        }
    }

    private func chooseIdentity() {
        let panel = NSOpenPanel()
        panel.message = "Choose a private key"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
        panel.beginSheetModal(for: self) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.identity.setSavedValue(url.path)
            self.formChanged()
        }
    }

    private func close(saved: Bool) {
        subscription = nil
        dismiss()
        onClose?()
    }
}

/// Asks for a server's password; it stays in memory until Tab quits.
@MainActor
final class PasswordSheet: SheetWindow {
    private let field = InsetSecureField(placeholder: "Password", label: "Password")
    private let done: (String?) -> Void

    init(name: String, wrong: Bool, done: @escaping (String?) -> Void) {
        self.done = done
        let connect = PillButton("Connect", style: .primary)
        let cancel = PillButton("Cancel")
        let note = wrong
            ? DialogParts.note("\(name) didn't accept the password. Try again.", color: AppTheme.shared.danger)
            : DialogParts.note("Kept in memory until Tab quits, never saved.")
        let content = DialogParts.column([
            DialogParts.title("Password for \(name)"),
            field,
            note,
            DialogParts.buttons(trailing: [cancel, connect]),
        ])
        super.init(content: content, width: 360)
        connect.onPress = { [weak self] in self?.finish(true) }
        cancel.onPress = { [weak self] in self?.finish(false) }
        field.onCommit = { [weak self] in self?.finish(true) }
        onCancel = { [weak self] in self?.finish(false) }
        initialFirstResponder = field.field
    }

    private func finish(_ confirmed: Bool) {
        let password = field.stringValue
        guard !confirmed || !password.isEmpty else { return }
        field.stringValue = ""
        dismiss()
        done(confirmed ? password : nil)
    }
}

/// Asks for a name, such as a new or renamed group.
@MainActor
final class NamePromptSheet: SheetWindow {
    private let field: InsetTextField
    private let error = DialogParts.note("", color: AppTheme.shared.danger)
    private let done: (String?) -> Void

    init(title: String, label: String, value: String, confirm: String, done: @escaping (String?) -> Void) {
        self.done = done
        field = InsetTextField(value: value, placeholder: label, label: label, width: nil)
        let ok = PillButton(confirm, style: .primary)
        let cancel = PillButton("Cancel")
        error.isHidden = true
        let content = DialogParts.column([
            DialogParts.title(title),
            field,
            error,
            DialogParts.buttons(trailing: [cancel, ok]),
        ])
        super.init(content: content, width: 320)
        ok.onPress = { [weak self] in self?.finish(true) }
        cancel.onPress = { [weak self] in self?.finish(false) }
        field.onCommit = { [weak self] _ in self?.finish(true) }
        onCancel = { [weak self] in self?.finish(false) }
        initialFirstResponder = field.field
    }

    private func finish(_ confirmed: Bool) {
        let name = field.field.stringValue.trimmingCharacters(in: .whitespaces)
        if confirmed && name.isEmpty {
            error.stringValue = "Enter a group name"
            error.isHidden = false
            fitContent()
            return
        }
        dismiss()
        done(confirmed ? name : nil)
    }
}
