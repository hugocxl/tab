import AppKit
import TabCore

/// Who handles a key press in the main window.
enum KeyResolution: Equatable {
    /// The focused pane's content takes it: a terminal key binding or one of
    /// its own shortcuts.
    case pane
    /// The app runs a shortcut's action.
    case action(ShortcutId)
    /// A custom command's shortcut.
    case command(String)
    /// Normal handling: the focused view, then the menu bar.
    case pass
}

/// Decides every key press of the main window: the focused terminal's own
/// bindings first, then the keymap's actions, then normal handling.
@MainActor
final class KeyDispatcher {
    /// Actions the menu bar's standard items run, so their keys go there.
    static let menuActions: Set<ShortcutId> = [.quit, .hideApp, .hideOthers, .minimize, .showAll, .zoom]

    /// Keys a text field keeps for editing while it has the keyboard.
    static func isTextEditing(_ chord: KeyChord) -> Bool {
        let modifiers = chord.modifiers
        if modifiers.isDisjoint(with: [.command, .control]) { return true }
        let editing: Set<String> = [
            "cmd-a", "cmd-c", "cmd-v", "cmd-x", "cmd-z", "cmd-shift-z", "cmd-left", "cmd-right", "cmd-up", "cmd-down",
            "cmd-backspace", "cmd-shift-left", "cmd-shift-right", "ctrl-a", "ctrl-e", "ctrl-k", "ctrl-d", "ctrl-h",
            "ctrl-f", "ctrl-b", "ctrl-n", "ctrl-p",
        ]
        return editing.contains(chord.rawValue)
    }

    static func resolve(chord: KeyChord?, paneTakes: Bool, editingText: Bool, keymap: Keymap,
                        commands: [CustomCommand]) -> KeyResolution {
        if paneTakes { return .pane }
        guard let chord else { return .pass }
        if editingText && isTextEditing(chord) { return .pass }
        if let command = commands.first(where: { keymap.binding($0.shortcutId) == chord }) { return .command(command.id) }
        if let action = keymap.action(for: chord) ?? Self.alternate(chord, keymap: keymap), !menuActions.contains(action) {
            return .action(action)
        }
        return .pass
    }

    /// Secondary default keys, such as Ctrl+Tab for Next Tab.
    static func alternate(_ chord: KeyChord, keymap: Keymap) -> ShortcutId? {
        ShortcutCatalog.keymapActions.first { id in
            let context = id.definition.contexts.first ?? nil
            return keymap.keys(id.rawValue, context: context).contains(chord.rawValue)
        }
    }

    unowned let model: AppModel
    let actions: Actions
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var hintWork: DispatchWorkItem?
    weak var window: NSWindow?
    /// Command-clicks may drag panes.
    var commandMouseDown: ((NSEvent) -> Bool)?
    private var mouseMonitor: Any?

    init(model: AppModel, actions: Actions) {
        self.model = model
        self.actions = actions
    }

    func install() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let box = EventBox(event)
            return MainActor.assumeIsolated { self.handle(box.event) } ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChanged(event.modifierFlags) }
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.window, event.modifierFlags.contains(.command) else { return event }
            let box = EventBox(event)
            return MainActor.assumeIsolated { self.commandMouseDown?(box.event) ?? false } ? nil : event
        }
    }

    /// Handles a key press in the main window; false lets it through.
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, let window else { return false }
        let pane = model.activePane.flatMap { model.panes.controller(for: $0) }
        let editingText = window.firstResponder is NSTextView && !(pane?.hasFocus ?? false)
        let paneTakes = !editingText && (pane?.handleKeyFirst(event) ?? false)
        let resolution = Self.resolve(chord: KeyChord(event: event), paneTakes: paneTakes, editingText: editingText,
                                      keymap: model.settings.keymap, commands: model.settings.commands)
        switch resolution {
        case .pane:
            return true
        case .action(let id):
            return actions.perform(id)
        case .command(let id):
            guard let command = model.settings.commands.first(where: { $0.id == id }) else { return false }
            model.newTerminal(in: model.currentProject.id, command: command.command)
            return true
        case .pass:
            if event.keyCode == 53, !editingText, !model.nameFilter.isEmpty {
                actions.clearSidebarFilter()
                return true
            }
            return false
        }
    }

    // MARK: Shortcut hints

    /// Holding modifiers for half a second shows the sidebar's numbers.
    private func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        let held = Self.chordModifiers(flags)
        hintWork?.cancel()
        guard !held.isEmpty else {
            model.shortcutHints = nil
            return
        }
        if model.shortcutHints != nil {
            model.shortcutHints = held
            scheduleRecheck()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.chordModifiers(NSEvent.modifierFlags)
                self.model.shortcutHints = current.isEmpty ? nil : current
                if !current.isEmpty { self.scheduleRecheck() }
            }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The system can swallow a modifier's release; check while hints show.
    private func scheduleRecheck() {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.shortcutHints != nil else { return }
                self.modifiersChanged(NSEvent.modifierFlags)
            }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    static func chordModifiers(_ flags: NSEvent.ModifierFlags) -> ChordModifiers {
        var modifiers = ChordModifiers()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}

/// Carries an event into main-actor code run synchronously on the main thread.
private struct EventBox: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}
