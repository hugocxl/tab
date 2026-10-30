import AppKit
import TabCore

/// A key binding being added or edited on the Terminal page.
struct BindingDraft: Equatable {
    var previous: KeyChord?
    var chord: KeyChord?
    var action: String
    var parameter: String
}

/// A Unicode range font being added or edited.
struct CodepointDraft: Equatable {
    var previous: FontMap?
    var range: String
    var family: String
}

/// Font families for the font pickers, read once.
@MainActor
enum FontCatalog {
    /// Fixed-pitch families, for the main terminal font.
    static let monospaced: [String] = {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }()

    /// Every family, for fallbacks and Unicode range fonts.
    static let all: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}

/// Terminal key binding actions as the editor offers them.
enum BindingActions {
    static let all: [(id: String, title: String)] = [
        ("text", "Send text"), ("esc", "Send Escape sequence"), ("csi", "Send CSI sequence"),
        ("copy_to_clipboard", "Copy"), ("paste_from_clipboard", "Paste"), ("select_all", "Select all"),
        ("clear_screen", "Clear screen"), ("scroll_to_top", "Scroll to top"), ("scroll_to_bottom", "Scroll to bottom"),
        ("scroll_page_up", "Scroll page up"), ("scroll_page_down", "Scroll page down"),
        ("increase_font_size", "Increase font size"), ("decrease_font_size", "Decrease font size"),
        ("reset_font_size", "Reset font size"), ("reload_config", "Reload terminal settings"),
        ("ignore", "Ignore key"), ("unbind", "Remove built-in binding"),
    ]

    static let parameterized: Set<String> = ["text", "esc", "csi", "increase_font_size", "decrease_font_size"]

    /// Splits `text:\n` into its action and parameter.
    static func split(_ action: TerminalAction) -> (String, String) {
        let text = action.description
        guard let colon = text.firstIndex(of: ":") else { return (text, "") }
        return (String(text[..<colon]), String(text[text.index(after: colon)...]))
    }

    static func title(_ action: TerminalAction) -> String {
        let (name, parameter) = split(action)
        let title = all.first { $0.id == name }?.title ?? name
        return parameter.isEmpty ? title : "\(title): \(parameter)"
    }
}

extension SettingsModel {
    private static let pixelRange = -5.0...20.0
    private static let percentRange = -50.0...200.0

    func buildTerminal(_ b: SettingsPageBuilder) {
        let terminal = store.terminal
        let options = terminal.options
        let set: (String) -> (String) -> Void = { [store] id in { store.setTerminal(id, $0) } }

        // Font
        let family = terminal.fontFamilies.first ?? "Menlo"
        b.row("font-family", fontPopUp(b, "font-family", families: FontCatalog.monospaced, selected: family, allowDefault: false, set("font-family")))
        b.row("font-fallbacks", fallbackList(b), stacked: true)
        b.row("font-size", numberSlider(b, "font-size", terminal.fontSize, 6...48, 0.5))
        b.row("adjust-cell-height", adjustment(b, "adjust-cell-height", terminal.cellHeight))
        b.row("adjust-cell-width", adjustment(b, "adjust-cell-width", terminal.font.cellWidth))
        b.row("font-family-bold", fontPopUp(b, "font-family-bold", families: FontCatalog.all, selected: terminal.font.bold.first ?? "", allowDefault: true, set("font-family-bold")))
        b.row("font-family-italic", fontPopUp(b, "font-family-italic", families: FontCatalog.all, selected: terminal.font.italic.first ?? "", allowDefault: true, set("font-family-italic")))
        b.row("font-family-bold-italic", fontPopUp(b, "font-family-bold-italic", families: FontCatalog.all, selected: terminal.font.boldItalic.first ?? "", allowDefault: true, set("font-family-bold-italic")))
        b.row("font-feature", b.field("font-feature", terminal.font.featureList, placeholder: "ss01, -calt", monospaced: true, commit: set("font-feature")))
        toggle(b, "font-ligatures", terminal.ligaturesEnabled)
        b.row("font-codepoint-map", codepointList(b), stacked: true)
        toggle(b, "font-thicken", terminal.font.thicken)
        b.row("font-thicken-strength", numberSlider(b, "font-thicken-strength", Double(terminal.font.thickenStrength), 0...255, 1))
        toggle(b, "bold-is-bright", options.boldIsBright)

        // Background
        b.row("background-transparency", numberSlider(b, "background-transparency", (1 - (options.backgroundOpacity ?? 1)) * 100, 0...100, 1, suffix: "%"))
        b.row("background-vibrancy", numberSlider(b, "background-vibrancy", Double(options.backgroundVibrancy), 0...100, 1, suffix: "%"))
        if !store.theme.accessibility.allowsVibrancy {
            b.note("background-vibrancy", "Reduce Transparency or Increase Contrast is on in Accessibility settings, so terminals stay opaque.")
        }
        toggle(b, "background-opacity-cells", options.backgroundOpacityCells)
        b.row("window-padding-x", paddingSliders(b, [("padding-left", "Left", options.paddingX[0]), ("padding-right", "Right", options.paddingX[1])]), stacked: true)
        b.row("window-padding-y", paddingSliders(b, [("padding-top", "Top", options.paddingY[0]), ("padding-bottom", "Bottom", options.paddingY[1])]), stacked: true)
        toggle(b, "window-padding-balance", options.paddingBalance)
        b.row("window-padding-color", b.popUp("window-padding-color", [
            .init(id: "background", title: "Background"), .init(id: "extend", title: "Extend"), .init(id: "extend-always", title: "Extend always"),
        ], selected: options.paddingColor == .background ? "background" : (options.paddingColor == .extend ? "extend" : "extend-always"), set("window-padding-color")))

        // Colors
        let colors: [(String, CellColor?)] = [
            ("background", options.background.map(CellColor.rgb)), ("foreground", options.foreground.map(CellColor.rgb)),
            ("cursor-color", options.cursorColor), ("cursor-text", options.cursorText),
            ("selection-foreground", options.selectionForeground), ("selection-background", options.selectionBackground),
        ]
        for (id, color) in colors { b.row(id, colorControl(b, id, color)) }
        b.row("palette", paletteGrid(b), stacked: true)

        // Cursor
        let shape: String
        switch options.cursorStyle {
        case nil: shape = ""
        case .block: shape = "block"
        case .bar: shape = "bar"
        case .underline: shape = "underline"
        case .blockHollow: shape = "block_hollow"
        }
        b.row("cursor-style", b.popUp("cursor-style", [
            .init(id: "", title: "Default"), .init(id: "block", title: "Block"), .init(id: "bar", title: "Bar"),
            .init(id: "underline", title: "Underline"), .init(id: "block_hollow", title: "Outline"),
        ], selected: shape, set("cursor-style")))
        b.row("cursor-style-blink", b.popUp("cursor-style-blink", [
            .init(id: "", title: "Default"), .init(id: "true", title: "On"), .init(id: "false", title: "Off"),
        ], selected: options.cursorBlink.map { $0 ? "true" : "false" } ?? "", set("cursor-style-blink")))
        b.row("adjust-cursor-thickness", adjustment(b, "adjust-cursor-thickness", options.cursorThickness))
        b.row("cursor-opacity", numberSlider(b, "cursor-opacity", options.cursorOpacity * 100, 0...100, 1, suffix: "%"))

        // Selection
        toggle(b, "copy-on-select", options.copyOnSelect ?? store.settings.clipboard.copyOnSelect)
        toggle(b, "selection-clear-on-typing", options.selectionClearOnTyping)
        toggle(b, "selection-clear-on-copy", options.selectionClearOnCopy)

        // Scrolling
        b.row("scroll-precision", numberSlider(b, "scroll-precision", options.scrollPrecision, 0.01...10, 0.01))
        b.row("scroll-discrete", numberSlider(b, "scroll-discrete", options.scrollDiscrete, 0.01...10, 0.01))
        toggle(b, "scroll-on-keystroke", options.scrollOnKeystroke)
        toggle(b, "scroll-on-output", options.scrollOnOutput)

        // Input
        toggle(b, "mouse-reporting", options.mouseReporting)
        b.row("macos-option-as-alt", b.popUp("macos-option-as-alt", [
            .init(id: "both", title: "Both"), .init(id: "none", title: "Neither"), .init(id: "left", title: "Left"), .init(id: "right", title: "Right"),
        ], selected: terminal.optionAsAlt.rawValue, set("macos-option-as-alt")))
        b.row("directory", b.popUp("directory", [.init(id: "project", title: "Project"), .init(id: "current", title: "Current pane")],
                                    selected: store.settings.panes.newPaneDirectory.rawValue) { [store] in
            store.setNewPaneDirectory(NewPaneDirectory(rawValue: $0) ?? .project)
        })

        // Key bindings
        b.row("terminal-keybindings", bindingList(b), stacked: true)
        toggle(b, "keybind-clear-defaults", terminal.keybindings.clearDefaults)

        // Migration and reset
        if !terminal.diagnostics.isEmpty {
            let notes = terminal.diagnostics.map { SettingControl.label($0, .note) }
            let dismiss = b.button("Dismiss") { [store] in store.setTerminal("dismiss-import-notes", "") }
            b.row("terminal-import-notes", .column(notes + [dismiss]), stacked: true)
        }
        b.row("terminal-reset", b.button("Reset", style: .destructive, enabled: store.terminalIsCustomized) { [weak self] in
            self?.confirm(
                "Reset terminal settings?",
                "Every setting on this page, including key bindings, returns to its default. This can't be undone.",
                "Reset"
            ) { self?.store.resetTerminal() }
        })
    }

    private func toggle(_ b: SettingsPageBuilder, _ id: String, _ value: Bool) {
        b.row(id, b.toggle(id, value) { [store] in store.setTerminal(id, String($0)) })
    }

    /// A slider for a terminal number, previewing while dragged.
    private func numberSlider(_ b: SettingsPageBuilder, _ id: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double, suffix: String = "") -> SettingControl {
        b.slider(id, value: value, range: range, step: step, suffix: suffix) { [store] in
            store.previewTerminal(id, SliderSpec.format($0, step: step))
        } commit: { [store] in
            store.setTerminal(id, SliderSpec.format($0, step: step))
        }
    }

    private func paddingSliders(_ b: SettingsPageBuilder, _ edges: [(String, String, Double)]) -> SettingControl {
        .column(edges.map { id, title, value in
            .row([
                .label(title, .secondary),
                b.slider("window-padding-x", value: value, range: 0...64, step: 1, label: "\(title) padding") { [store] in
                    store.previewTerminal(id, SliderSpec.format($0, step: 1))
                } commit: { [store] in
                    store.setTerminal(id, SliderSpec.format($0, step: 1))
                },
            ])
        })
    }

    /// A pixel or percent adjustment: a slider and its unit.
    private func adjustment(_ b: SettingsPageBuilder, _ id: String, _ value: CellHeight) -> SettingControl {
        let (amount, percent): (Double, Bool)
        switch value {
        case .natural: (amount, percent) = (0, false)
        case .pixels(let pixels): (amount, percent) = (Double(pixels), false)
        case .percent(let share): (amount, percent) = (share, true)
        }
        let suffix = percent ? "%" : ""
        let slider = b.slider(id, value: amount, range: percent ? Self.percentRange : Self.pixelRange, step: 1, suffix: suffix) { [store] in
            store.previewTerminal(id, SliderSpec.format($0, step: 1) + suffix)
        } commit: { [store] in
            store.setTerminal(id, SliderSpec.format($0, step: 1) + suffix)
        }
        let unit = b.popUp(id, [.init(id: "pixels", title: "Pixels"), .init(id: "percent", title: "Percent")], selected: percent ? "percent" : "pixels", label: "Unit") { [store] unit in
            let range = unit == "percent" ? Self.percentRange : Self.pixelRange
            let clamped = min(max(amount.rounded(), range.lowerBound), range.upperBound)
            store.setTerminal(id, SliderSpec.format(clamped, step: 1) + (unit == "percent" ? "%" : ""))
        }
        return .row([slider, unit])
    }

    private func fontPopUp(
        _ b: SettingsPageBuilder, _ id: String, families: [String], selected: String, allowDefault: Bool,
        placeholder: String? = nil, label: String? = nil, _ change: @escaping (String) -> Void
    ) -> SettingControl {
        var items = families.map { Choice(id: $0, title: $0) }
        if !selected.isEmpty && !families.contains(selected) { items.insert(.init(id: selected, title: selected), at: 0) }
        if allowDefault { items.insert(.init(id: "", title: "Default"), at: 0) }
        return b.popUp(id, items, selected: selected, placeholder: placeholder, label: label, change)
    }

    private func fallbackList(_ b: SettingsPageBuilder) -> SettingControl {
        let fallbacks = Array(store.terminal.fontFamilies.dropFirst())
        var rows: [SettingControl] = fallbacks.enumerated().map { index, name in
            .row([
                .label(name),
                b.button("Remove \(name)", symbol: "minus.circle") { [store] in
                    var names = fallbacks
                    names.remove(at: index)
                    store.editTerminal("font-fallbacks", .fallbacks(names))
                },
            ])
        }
        let choices = FontCatalog.all.filter { !fallbacks.contains($0) }.map { Choice(id: $0, title: $0) }
        rows.append(b.popUp("font-fallbacks", choices, selected: "", placeholder: "Add Font…", label: "Add fallback font") { [store] name in
            store.editTerminal("font-fallbacks", .fallbacks(fallbacks + [name]))
        })
        return .column(rows)
    }

    private func codepointList(_ b: SettingsPageBuilder) -> SettingControl {
        let maps = store.terminal.font.codepoints
        var rows: [SettingControl] = []
        for map in maps where codepointDraft?.previous != map {
            let range = map.start == map.end ? String(format: "U+%04X", map.start) : String(format: "U+%04X-U+%04X", map.start, map.end)
            let edit = b.button("Edit") { [weak self] in
                self?.codepointDraft = CodepointDraft(previous: map, range: range, family: map.family)
                self?.reload()
            }
            let delete = b.button("Delete", style: .destructive) { [store] in
                store.editTerminal("font-codepoint-map", .codepointMap(previous: map, range: nil, family: nil))
            }
            rows.append(.row([.label("\(range) → \(map.family)", .monospaced), edit, delete]))
        }
        if let draft = codepointDraft {
            let range = b.field("font-codepoint-map", draft.range, placeholder: "U+E000-U+F8FF", width: 180, label: "Unicode range", monospaced: true) { [weak self] in
                self?.codepointDraft?.range = $0
            } commit: { [weak self] in
                self?.codepointDraft?.range = $0
            }
            let family = fontPopUp(b, "font-codepoint-map", families: FontCatalog.all, selected: draft.family, allowDefault: false,
                                   placeholder: "Choose Font…", label: "Font") { [weak self] in
                self?.codepointDraft?.family = $0
                self?.reload()
            }
            let save = b.button("Save", style: .primary) { [weak self] in
                guard let self, let draft = codepointDraft else { return }
                guard !draft.family.isEmpty else { return store.setError("font-codepoint-map", "Choose a font first.") }
                store.editTerminal("font-codepoint-map", .codepointMap(previous: draft.previous, range: draft.range, family: draft.family))
                if store.errors["font-codepoint-map"] == nil { codepointDraft = nil }
                reload()
            }
            let cancel = b.button("Cancel") { [weak self] in
                self?.codepointDraft = nil
                self?.store.setError("font-codepoint-map", nil)
            }
            rows.append(.row([range, family]))
            rows.append(.row([cancel, save]))
        } else {
            rows.append(b.button("Add Map") { [weak self] in
                self?.codepointDraft = CodepointDraft(previous: nil, range: "", family: "")
                self?.reload()
            })
        }
        return .column(rows)
    }

    private func colorControl(_ b: SettingsPageBuilder, _ id: String, _ color: CellColor?) -> SettingControl {
        let rgb = color.flatMap { if case .rgb(let rgb) = $0 { return rgb } else { return nil } }
        let label = SettingsCatalog.item(id)?.label ?? id
        let well = SettingControl.color(ColorSpec(color: rgb, label: label) { [store] in store.setTerminal(id, $0.hex) })
        let field = b.field(id, color?.description ?? "", placeholder: "Theme", width: 110, monospaced: true) { [store] in
            store.setTerminal(id, $0)
        }
        let useTheme = b.button("Use Theme", enabled: color != nil) { [store] in store.setTerminal(id, "") }
        return .row([well, field, useTheme])
    }

    private func paletteGrid(_ b: SettingsPageBuilder) -> SettingControl {
        let palette = store.terminal.options.palette
        var lines: [SettingControl] = []
        for row in 0..<4 {
            var cells: [SettingControl] = []
            for column in 0..<4 {
                let index = row * 4 + column
                let id = "palette-\(index)"
                let well = SettingControl.color(ColorSpec(color: palette[index], label: "ANSI color \(index)") { [store] in
                    store.setTerminal(id, $0.hex)
                })
                let field = b.field(id, palette[index]?.hex ?? "", placeholder: "\(index)", width: 72,
                                    label: "ANSI color \(index)", monospaced: true) { [store] in
                    store.setTerminal(id, $0)
                }
                cells.append(.row([well, field]))
            }
            lines.append(.row(cells))
        }
        for index in 0..<16 {
            if let error = store.errors["palette-\(index)"] { lines.append(.label(error, .error)) }
        }
        return .column(lines)
    }

    private func bindingList(_ b: SettingsPageBuilder) -> SettingControl {
        let bindings = store.terminal.keybindings.bindings.sorted { $0.key < $1.key }
        var rows: [SettingControl] = []
        if bindings.isEmpty && bindingDraft == nil {
            rows.append(.label("No custom key bindings yet.", .note))
        }
        for (chord, action) in bindings where bindingDraft?.previous != chord {
            let edit = b.button("Edit") { [weak self] in
                let (name, parameter) = BindingActions.split(action)
                self?.bindingDraft = BindingDraft(previous: chord, chord: chord, action: name, parameter: parameter)
                self?.reload()
            }
            let delete = b.button("Delete", style: .destructive) { [store] in
                store.editTerminal("terminal-keybindings", .binding(previous: chord, chord: nil, action: nil))
            }
            rows.append(.row([.keys(chord), .label(BindingActions.title(action)), edit, delete]))
        }
        if let draft = bindingDraft {
            rows.append(bindingEditor(b, draft))
        } else {
            rows.append(b.button("Add Binding") { [weak self] in
                self?.bindingDraft = BindingDraft(previous: nil, chord: nil, action: "text", parameter: "")
                self?.reload()
            })
        }
        return .column(rows)
    }

    private func bindingEditor(_ b: SettingsPageBuilder, _ draft: BindingDraft) -> SettingControl {
        let recorder = SettingControl.shortcut(ShortcutSpec(chord: draft.chord, placeholder: "Record Key", label: "Key") { [weak self] chord in
            self?.bindingDraft?.chord = chord
            return nil
        } error: { _ in })
        let action = b.popUp("terminal-keybindings", BindingActions.all.map { Choice(id: $0.id, title: $0.title) }, selected: draft.action, label: "Action") { [weak self] in
            self?.bindingDraft?.action = $0
            self?.reload()
        }
        var lines: [SettingControl] = [.row([.label("Key", .secondary), recorder, .label("Action", .secondary), action])]
        if BindingActions.parameterized.contains(draft.action) {
            let font = draft.action.hasSuffix("font_size")
            let value = b.field("terminal-keybindings", draft.parameter, placeholder: font ? "1" : "\\e[A", width: 240, label: "Value", monospaced: true) { [weak self] in
                self?.bindingDraft?.parameter = $0
            } commit: { [weak self] in
                self?.bindingDraft?.parameter = $0
            }
            lines.append(.row([.label("Value", .secondary), value]))
            lines.append(.label(font ? "Points to change the font size by, such as 1." : "Text to send. Write special keys as escapes, such as \\e for Escape or \\x01 for Control-A.", .note))
        }
        let save = b.button("Save", style: .primary) { [weak self] in self?.saveBinding() }
        let cancel = b.button("Cancel") { [weak self] in
            self?.bindingDraft = nil
            self?.store.setError("terminal-keybindings", nil)
        }
        lines.append(.row([cancel, save]))
        return .column(lines)
    }

    func saveBinding() {
        guard let draft = bindingDraft else { return }
        guard let chord = draft.chord else { return store.setError("terminal-keybindings", "Record a key first.") }
        let action = BindingActions.parameterized.contains(draft.action) ? "\(draft.action):\(draft.parameter)" : draft.action
        store.editTerminal("terminal-keybindings", .binding(previous: draft.previous, chord: chord, action: action))
        if store.errors["terminal-keybindings"] == nil { bindingDraft = nil }
        reload()
    }
}
