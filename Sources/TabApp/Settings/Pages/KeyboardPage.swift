import AppKit
import TabCore

extension SettingsModel {
    func buildKeyboard(_ b: SettingsPageBuilder) {
        let keymap = store.settings.keymap
        for group in ShortcutGroup.allCases {
            for shortcut in ShortcutCatalog.all where shortcut.group == group {
                let name = shortcut.name
                let rowId = "shortcut.\(name)"
                guard b.shows(rowId) else { continue }
                var controls: [SettingControl] = []
                if !keymap.isDefault(name) {
                    controls.append(b.button(
                        "Reset \(shortcut.label)",
                        symbol: "arrow.uturn.backward",
                        help: "Reset to \(shortcut.defaultChord?.display ?? "no shortcut")"
                    ) { [store] in
                        let error = store.setBinding(name, nil)
                        store.setError(rowId, error)
                    })
                }
                controls.append(shortcutRecorder(rowId: rowId, action: name, chord: keymap.binding(name), placeholder: "Not assigned", label: shortcut.label))
                b.row(rowId, .row(controls))
            }
        }
    }

    /// A recorder that saves the chord for keymap `action`, showing a refusal
    /// (such as a conflict) under row `rowId`.
    func shortcutRecorder(rowId: String, action: String, chord: KeyChord?, placeholder: String, label: String) -> SettingControl {
        .shortcut(ShortcutSpec(chord: chord, placeholder: placeholder, label: label) { [store] chord in
            let error = store.setBinding(action, chord)
            if let error, rowId != action { store.setError(rowId, error) }
            return error
        } error: { [store] error in
            guard store.errors[rowId] != error else { return }
            store.setError(rowId, error)
        })
    }

    func buildCommands(_ b: SettingsPageBuilder) {
        let commands = store.settings.commands
        var heading: [SettingControl] = [
            .label("Run a saved shell command in a new tab in the selected project. Assign a direct shortcut or find it in the command palette.", .note),
        ]
        if let draft = commandDraft {
            heading.append(commandEditor(b, draft))
        } else {
            heading.append(b.button("Add Command") { [weak self] in
                self?.commandDraft = CustomCommand(name: "", command: "")
                self?.reload()
            })
        }
        if commands.isEmpty && commandDraft == nil { heading.append(.label("No custom commands yet.", .note)) }
        if let error = store.errors["commands"] { heading.append(.label(error, .error)) }
        b.below("add-command", .column(heading))

        let keymap = store.settings.keymap
        for command in commands {
            let id = command.shortcutId
            guard b.shows(id) else { continue }
            let enabled = commandDraft == nil
            let recorder = shortcutRecorder(rowId: id, action: id, chord: keymap.binding(id), placeholder: "Record Shortcut", label: "Shortcut for \(command.name)")
            let unassign = b.button("Unassign", enabled: enabled && keymap.binding(id) != nil) { [store] in
                store.setBinding(id, nil)
            }
            let edit = b.button("Edit", enabled: enabled) { [weak self] in
                self?.commandDraft = command
                self?.reload()
            }
            let delete = b.button("Delete", style: .destructive, enabled: enabled) { [weak self] in
                self?.confirm("Delete “\(command.name)”?", "The command and its shortcut are removed.", "Delete") {
                    self?.store.removeCommand(command.id)
                }
            }
            b.row(id, .row([recorder, unassign, edit, delete]), label: command.name, description: command.command)
        }
    }

    private func commandEditor(_ b: SettingsPageBuilder, _ draft: CustomCommand) -> SettingControl {
        let name = b.field("command-name", draft.name, placeholder: "Name", width: 300, label: "Name") { [weak self] in
            self?.commandDraft?.name = $0
        } commit: { [weak self] in
            self?.commandDraft?.name = $0
        }
        let command = b.field("command-text", draft.command, placeholder: "cargo test", width: 300, label: "Command", monospaced: true) { [weak self] in
            self?.commandDraft?.command = $0
        } commit: { [weak self] in
            self?.commandDraft?.command = $0
        }
        let save = b.button("Save", style: .primary) { [weak self] in self?.saveCommandDraft() }
        let cancel = b.button("Cancel") { [weak self] in
            self?.commandDraft = nil
            self?.store.setError("commands", nil)
        }
        return .column([
            .row([.label("Name", .secondary), name]),
            .row([.label("Command", .secondary), command]),
            .label("A single-line shell command, such as cargo test or npm run dev.", .note),
            .row([cancel, save]),
        ])
    }

    func saveCommandDraft() {
        guard let draft = commandDraft else { return }
        if store.saveCommand(draft) {
            commandDraft = nil
            reload()
        }
    }
}
