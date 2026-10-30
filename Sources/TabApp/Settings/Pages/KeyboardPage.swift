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
}
