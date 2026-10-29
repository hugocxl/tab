import AppKit
import TabCore

extension SettingsPageView {
    func buildKeyboard(_ b: SettingsPageBuilder) {
        let keymap = store.settings.keymap
        for group in ShortcutGroup.allCases {
            for shortcut in ShortcutCatalog.all where shortcut.group == group {
                let name = shortcut.name
                let rowId = "shortcut.\(name)"
                guard b.shows(rowId) else { continue }
                let recorder = shortcutRecorder(rowId: rowId, action: name, chord: keymap.binding(name), placeholder: "Not assigned", label: shortcut.label)
                var controls: [NSView] = [recorder]
                if !keymap.isDefault(name) {
                    let reset = b.button("↺", style: .plain) { [store] in
                        store.setError(rowId, nil)
                        store.setBinding(name, nil)
                    }
                    reset.toolTip = "Reset to \(shortcut.defaultChord?.display ?? "no shortcut")"
                    reset.setAccessibilityLabel("Reset \(shortcut.label)")
                    controls.append(reset)
                }
                b.row(rowId, hstack(controls, spacing: 6))
            }
        }
    }

    /// A recorder that saves the chord for keymap `action`, showing a refusal
    /// (such as a conflict) under row `rowId`.
    func shortcutRecorder(rowId: String, action: String, chord: KeyChord?, placeholder: String, label: String) -> ShortcutRecorder {
        let recorder = ShortcutRecorder(chord: chord, placeholder: placeholder, label: label)
        recorder.onRecord = { [store] chord in
            let error = store.setBinding(action, chord)
            if let error, rowId != action { store.setError(rowId, error) }
            return error
        }
        recorder.onError = { [store] error in
            guard store.errors[rowId] != error else { return }
            store.setError(rowId, error)
        }
        return recorder
    }

    func buildCommands(_ b: SettingsPageBuilder) {
        let commands = store.settings.commands
        var heading: [NSView] = [
            NoteLabel("Run a saved shell command in a new tab in the selected project. Assign a direct shortcut or find it in the command palette."),
        ]
        let add = b.button("Add Command", enabled: commandDraft == nil) { [weak self] in
            self?.commandDraft = CustomCommand(name: "", command: "")
            self?.reload()
            if let field = self?.fields["command-name"] { self?.window?.makeFirstResponder(field.field) }
        }
        heading.append(add)
        if commands.isEmpty && commandDraft == nil { heading.append(NoteLabel("No custom commands yet.")) }
        if let draft = commandDraft { heading.append(commandEditor(b, draft)) }
        if let error = store.errors["commands"] { heading.append(NoteLabel(error, error: true)) }
        b.below("add-command", vstack(heading, spacing: 8))

        let keymap = store.settings.keymap
        for command in commands {
            let id = command.shortcutId
            guard b.shows(id) else { continue }
            let enabled = commandDraft == nil
            let recorder = shortcutRecorder(rowId: id, action: id, chord: keymap.binding(id), placeholder: "Record shortcut", label: "Shortcut for \(command.name)")
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
            b.row(id, hstack([recorder, unassign, edit, delete], spacing: 6), label: command.name, description: command.command)
        }
    }

    private func commandEditor(_ b: SettingsPageBuilder, _ draft: CustomCommand) -> NSView {
        let name = b.field("command-name", draft.name, placeholder: "Name", width: 300) { [weak self] in self?.commandDraft?.name = $0 }
        name.onChange = { [weak self] in self?.commandDraft?.name = $0 }
        let command = b.field("command-text", draft.command, placeholder: "cargo test", width: 300, monospaced: true) { [weak self] in
            self?.commandDraft?.command = $0
        }
        command.onChange = { [weak self] in self?.commandDraft?.command = $0 }
        let save = b.button("Save", style: .primary) { [weak self] in self?.saveCommandDraft() }
        let cancel = b.button("Cancel") { [weak self] in
            self?.commandDraft = nil
            self?.store.setError("commands", nil)
        }
        let card = Card(rows: [
            CardRow(id: "command-name", label: "Name", control: name),
            CardRow(id: "command-text", label: "Command", control: command, description: "A single-line shell command, such as cargo test or npm run dev."),
        ])
        card.theme = theme
        return vstack([card, hstack([save, cancel], spacing: 6)], alignment: .leading)
    }

    func saveCommandDraft() {
        guard var draft = commandDraft else { return }
        if let name = fields["command-name"] { draft.name = name.stringValue }
        if let command = fields["command-text"] { draft.command = command.stringValue }
        if store.saveCommand(draft) {
            commandDraft = nil
            reload()
        }
    }
}
