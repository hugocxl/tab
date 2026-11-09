import AppKit
import TabCore

extension SettingsModel {
    func buildTerminal(_ b: SettingsPageBuilder) {
        let terminal = store.terminal
        let palette = TerminalPalette(scheme: store.theme.scheme, settings: terminal, dark: !store.theme.palette.isLight,
                                      background: RGBColor(store.theme.card))
        func preview(_ id: String, _ preview: TerminalPreview) {
            b.row(id, .preview(PreviewSpec(preview: preview, settings: terminal, palette: palette)))
        }
        func toggle(_ id: String, _ value: Bool, _ set: @escaping (inout TerminalSettings, Bool) -> Void) {
            b.row(id, b.toggle(id, value) { [store] on in store.updateTerminal(id) { set(&$0, on) } })
        }
        func choice<T: RawRepresentable>(_ id: String, _ value: T, _ titles: KeyValuePairs<T, String>,
                                         _ set: @escaping (inout TerminalSettings, T) -> Void) where T.RawValue == String {
            let choices = titles.map { Choice(id: $0.key.rawValue, title: $0.value) }
            b.row(id, b.popUp(id, choices, selected: value.rawValue) { [store] raw in
                guard let picked = T(rawValue: raw) else { return }
                store.updateTerminal(id) { set(&$0, picked) }
            })
        }

        // Typography
        preview("typography-preview", .typography)
        b.row("font-family", .row([
            .fontName(family: terminal.fontFamily, style: terminal.fontStyle),
            b.button("Choose…") { [store] in
                TerminalFontPanel.shared.show(store.terminal) { family, style, size in
                    store.updateTerminal("font-family") {
                        $0.fontFamily = family
                        $0.fontStyle = style
                        $0.fontSize = size
                    }
                }
            },
        ]))
        b.row("font-size", b.stepper("font-size", terminal.fontSize, range: TerminalSettings.fontSizeRange, unit: "pt") { [store] size in
            store.updateTerminal("font-size") { $0.fontSize = size }
        })
        var styles = TerminalFontPanel.styles(of: terminal.fontFamily)
        if !styles.contains(terminal.fontStyle) { styles.insert(terminal.fontStyle, at: 0) }
        b.row("font-style", b.popUp("font-style", styles.map { Choice(id: $0, title: $0) }, selected: terminal.fontStyle) { [store] style in
            store.updateTerminal("font-style") { $0.fontStyle = style }
        })
        b.row("font-advanced", .disclosure { [weak self] in self?.open(.advancedFont) })

        // Advanced Font Settings
        preview("advanced-preview", .typography)
        b.row("character-spacing", characterSpacing(b, terminal.characterSpacing))
        b.row("line-height", b.stepper("line-height", terminal.lineHeight, range: TerminalSettings.lineHeightRange, unit: "%") { [store] percent in
            store.updateTerminal("line-height") { $0.lineHeight = percent }
        })
        toggle("ligatures", terminal.ligatures) { $0.ligatures = $1 }
        toggle("font-smoothing", terminal.fontSmoothing) { $0.fontSmoothing = $1 }
        b.row("fallback-fonts", fallbackFonts(b, terminal.fallbackFonts))

        // Colors
        toggle("improve-contrast", terminal.improveContrast) { $0.improveContrast = $1 }
        toggle("force-theme-palette", terminal.forceThemePalette) { $0.forceThemePalette = $1 }
        toggle("display-p3", terminal.displayP3) { $0.displayP3 = $1 }

        // Cursor
        preview("cursor-preview", .cursor)
        choice("cursor-style", terminal.cursorStyle, [.block: "Block", .bar: "Bar", .underline: "Underline", .outline: "Outline"]) {
            $0.cursorStyle = $1
        }
        choice("cursor-blink", terminal.cursorBlink, [.off: "Off", .slow: "Slow", .normal: "Normal", .fast: "Fast"]) {
            $0.cursorBlink = $1
        }
        toggle("force-cursor-style", terminal.forceCursorStyle) { $0.forceCursorStyle = $1 }

        // Keyboard
        choice("option-key", terminal.optionKey, [
            .automatic: "Automatic (by keyboard layout)", .alt: "Alt (Meta)", .characters: "Special Characters",
            .leftAlt: "Left Option Is Alt", .rightAlt: "Right Option Is Alt",
        ]) { $0.optionKey = $1 }
        b.note("option-key", "Automatic sends Alt on U.S. layouts and types special keys elsewhere. Applies to all terminals on this Mac, including remote hosts.")

        // Scrolling
        toggle("smooth-scrolling", terminal.smoothScrolling) { $0.smoothScrolling = $1 }
        b.note("smooth-scrolling", "Move through terminal history smoothly with a trackpad or Magic Mouse. Programs that handle scrolling themselves, and scrolling while Find is open, still move by whole lines.")

        // Selection
        preview("selection-preview", .selection)
        toggle("copy-on-select", terminal.copyOnSelect) { $0.copyOnSelect = $1 }
        toggle("copy-animation", terminal.copyAnimation) { $0.copyAnimation = $1 }
        let colors: KeyValuePairs<SelectionColor, String> = [.theme: "Theme", .text: "Text Color", .background: "Background Color"]
        choice("selection-foreground", terminal.selectionForeground, colors) { $0.selectionForeground = $1 }
        choice("selection-background", terminal.selectionBackground, colors) { $0.selectionBackground = $1 }
        toggle("rounded-selection", terminal.roundedSelection) { $0.roundedSelection = $1 }

        // Links
        choice("app-links", terminal.appLinks, [.ask: "Ask First", .always: "Always Open", .never: "Never Open"]) {
            $0.appLinks = $1
        }
        b.note("app-links", "Web, mail, and file links open directly. Other links, such as ssh://, launch the app registered for them, and any program in a terminal can print one.")

        // Titles
        toggle("generated-titles", terminal.preferGeneratedTitles) { $0.preferGeneratedTitles = $1 }
        b.note("generated-titles", "Show the running program and its directory instead of titles that shells set. Titles that programs set for themselves, and names you give tabs, still appear.")

        // Shell
        let server = store.serverSettings
        b.row("startup-command", b.field("startup-command", server.map { Executable.commandLine($0.startupCommand) } ?? "",
                                         placeholder: "Default login shell", width: nil, monospaced: true,
                                         enabled: server != nil) { [store] in
            store.setServer("startup-command", $0)
        })
        if server == nil {
            b.note("startup-command", store.errors["server"] ?? (store.serverState == .running ? "Loading the server’s settings…" : "Connect to the local server to change the startup command."),
                   error: store.errors["server"] != nil)
        }
        b.note("startup-command", "Executable and arguments. Use quotes to group arguments. Applies to new terminals on this Mac. Remote hosts use their own default shell. New tabs and splits use the source terminal’s working directory when available. Otherwise, they use the server’s default directory.")
    }

    /// Character spacing: a reset button, the amount, and its unit.
    private func characterSpacing(_ b: SettingsPageBuilder, _ spacing: CellAdjustment) -> SettingControl {
        let percent: Bool
        let amount: Double
        switch spacing {
        case .natural: (amount, percent) = (0, false)
        case .pixels(let pixels): (amount, percent) = (Double(pixels), false)
        case .percent(let share): (amount, percent) = (share, true)
        }
        let id = "character-spacing"
        let range = percent ? CellAdjustment.percentRange
            : Double(CellAdjustment.pixelRange.lowerBound)...Double(CellAdjustment.pixelRange.upperBound)
        func adjustment(_ value: Double, percent: Bool) -> CellAdjustment {
            percent ? .percent(value) : value == 0 ? .natural : .pixels(Int(value))
        }
        let reset = b.button("Reset Character Spacing", enabled: spacing != .natural, icon: .reset) { [store] in
            store.updateTerminal(id) { $0.characterSpacing = .natural }
        }
        let stepper = b.stepper(id, amount, range: range) { [store] value in
            store.updateTerminal(id) { $0.characterSpacing = adjustment(value, percent: percent) }
        }
        let unit = b.popUp(id, [Choice(id: "px", title: "px"), Choice(id: "%", title: "%")], selected: percent ? "%" : "px",
                           label: "Unit") { [store] unit in
            let toPercent = unit == "%"
            guard toPercent != percent else { return }
            let bounds = toPercent ? CellAdjustment.percentRange
                : Double(CellAdjustment.pixelRange.lowerBound)...Double(CellAdjustment.pixelRange.upperBound)
            let clamped = min(max(amount.rounded(), bounds.lowerBound), bounds.upperBound)
            store.updateTerminal(id) { $0.characterSpacing = adjustment(clamped, percent: toPercent) }
        }
        return .row([reset, stepper, unit])
    }

    /// The fallback fonts in order, each removable, and a menu adding one.
    private func fallbackFonts(_ b: SettingsPageBuilder, _ fonts: [String]) -> SettingControl {
        let id = "fallback-fonts"
        var rows: [SettingControl] = fonts.enumerated().map { index, name in
            .row([
                .fontName(family: name, style: "Regular"),
                b.button("Remove \(name)", icon: .minusCircle) { [store] in
                    store.updateTerminal(id) { $0.fallbackFonts.remove(at: index) }
                },
            ])
        }
        let choices = TerminalFontPanel.families.filter { !fonts.contains($0) }.map { Choice(id: $0, title: $0) }
        rows.append(b.menu(id, "Add…", choices) { [store] name in
            store.updateTerminal(id) { $0.fallbackFonts.append(name) }
        })
        return .column(rows, trailing: true)
    }
}
