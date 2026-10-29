import Foundation

/// The app's shortcuts: each command's primary key, the catalog's defaults
/// with the user's changes from `settings.json` → `keymap` applied. Custom
/// commands bind as `command.<id>`.
public struct Keymap: Equatable, Sendable, Codable {
    /// The effective primary key of each bound action.
    public private(set) var bindings: [String: KeyChord]
    /// The user's changes as written, by action id.
    public private(set) var overrides: [String: String]

    /// The catalog's defaults.
    public init() {
        bindings = Self.defaultBindings
        overrides = [:]
    }

    static let defaultBindings: [String: KeyChord] = {
        var bindings: [String: KeyChord] = [:]
        for shortcut in ShortcutCatalog.all {
            if let chord = shortcut.defaultChord { bindings[shortcut.name] = chord }
        }
        return bindings
    }()

    /// Actions that no longer exist; older files that bind them still load.
    static let retired: Set<String> = [
        "toggle_composer", "composer.submit", "composer.insert", "composer.close", "composer.voice",
        "project_colors.previous_color", "project_colors.next_color",
        "project_colors.choose_color", "project_colors.dismiss_colors",
    ]

    public func chord(_ action: ShortcutId) -> KeyChord? { bindings[action.rawValue] }

    /// The rebindable action `chord` runs.
    public func action(for chord: KeyChord) -> ShortcutId? {
        ShortcutCatalog.keymapActions.first { self.chord($0) == chord }
    }

    public func binding(_ id: String) -> KeyChord? { bindings[id] }

    /// Whether the effective binding equals the built-in default, including
    /// unbound actions.
    public func isDefault(_ id: String) -> Bool {
        binding(id) == ShortcutCatalog.find(id)?.defaultChord
    }

    /// The keymap with `id` bound to `chord`, or reset to its default when
    /// `chord` is `nil`. A command can't take a key a built-in action uses
    /// now; one that had its key before a built-in default claimed it keeps
    /// it, and that default yields.
    public func withBinding(_ id: String, _ chord: KeyChord?) throws -> Keymap {
        let isCommand = Self.isCommandAction(id)
        guard ShortcutCatalog.find(id) != nil || isCommand else {
            throw SettingsError("keymap", "unknown action")
        }
        if isCommand, let chord, let other = builtinKeys()[chord.rawValue] {
            throw SettingsError("keymap.\(id)", "\(chord) is also bound to keymap.\(other)")
        }
        var overrides = self.overrides
        overrides[id] = chord?.rawValue
        let resolved = try Self.fromOverrides(overrides)
        if chord == nil && resolved.binding(id) != Keymap().binding(id) {
            throw SettingsError(
                "keymap.\(id)",
                "the default shortcut is assigned to another action; reset that action first"
            )
        }
        return resolved
    }

    /// Writes the user's changes as the `keymap` section of `url`, keeping the
    /// file's other sections.
    public func save(to url: URL) throws {
        var document = try SettingsDocument.read(url)
        try document.replace("keymap", overrides)
        try document.write(to: url)
    }

    /// The keymap for a user's changes, refusing unknown actions, invalid keys
    /// and keys bound twice where both apply.
    public static func fromOverrides(_ overrides: [String: String]) throws -> Keymap {
        let overrides = overrides.filter { !retired.contains($0.key) && !$0.key.hasPrefix("extension.") }
        var keymap = Keymap()
        keymap.overrides = overrides
        var explicit: [String: KeyChord] = [:]
        for (name, value) in overrides {
            let key = "keymap.\(name)"
            let isCommand = isCommandAction(name)
            guard ShortcutCatalog.find(name) != nil || isCommand else {
                throw SettingsError(key, "unknown action")
            }
            let chord: KeyChord
            do {
                chord = try KeyChord(value)
            } catch {
                throw SettingsError(key, "\(error)")
            }
            if isCommand && !["cmd-", "ctrl-", "alt-"].contains(where: chord.rawValue.hasPrefix) {
                throw SettingsError(key, "command shortcuts must include Command, Control, or Option")
            }
            explicit[name] = chord
        }
        for action in ShortcutCatalog.yielding where explicit[action.rawValue] == nil {
            let taken = explicit.contains { id, chord in
                chord == keymap.chord(action) && sameScope(id, action.rawValue)
            }
            if taken { keymap.bindings[action.rawValue] = nil }
        }
        keymap.bindings.merge(explicit) { _, new in new }
        let sorted = keymap.bindings.sorted { $0.key < $1.key }
        for (index, (id, chord)) in sorted.enumerated() {
            for (other, otherChord) in sorted[..<index] where chord == otherChord && sameScope(id, other) {
                throw SettingsError("keymap.\(id)", "\(chord) is also bound to keymap.\(other)")
            }
        }
        try keymap.validateCommandAliases()
        let defaults = defaultBindings
        keymap.overrides = keymap.overrides.filter { id, chord in
            chord.isEmpty || (try? KeyChord(chord)) != defaults[id]
        }
        return keymap
    }

    private func validateCommandAliases() throws {
        guard bindings.keys.contains(where: Self.isCommandAction) else { return }
        let builtins = builtinKeys()
        for (id, chord) in bindings.sorted(by: { $0.key < $1.key }) where Self.isCommandAction(id) {
            if let other = builtins[chord.rawValue] {
                throw SettingsError("keymap.\(id)", "\(chord) is also bound to keymap.\(other)")
            }
        }
    }

    /// Each key a built-in action uses in some context, and that action.
    private func builtinKeys() -> [String: String] {
        var builtins: [String: String] = [:]
        for shortcut in ShortcutCatalog.all {
            for context in shortcut.contexts {
                for key in keys(shortcut.name, context: context) {
                    builtins[key] = shortcut.name
                }
            }
        }
        return builtins
    }

    /// The keys that run `id` in `context`: a rebound action's one key, or the
    /// defaults that apply there and that no other binding has taken.
    public func keys(_ id: String, context: String?) -> [String] {
        guard let primary = bindings[id] else { return [] }
        guard let shortcut = ShortcutCatalog.find(id) else {
            return Self.isCommandAction(id) ? [primary.rawValue] : []
        }
        guard shortcut.defaultChord == primary else { return [primary.rawValue] }
        return zip(shortcut.keys, shortcut.keyContexts)
            .filter { $0.1.contains(context) }
            .compactMap { try? KeyChord($0.0) }
            .filter { key in
                !bindings.contains { other, chord in
                    other != id && chord == key && Self.primaryApplies(other, chord, context)
                }
            }
            .map(\.rawValue)
    }

    /// The other action that already uses `chord` where `id` would, if any.
    public func conflict(for id: String, chord: KeyChord) -> String? {
        bindings.sorted { $0.key < $1.key }.first { other, bound in
            other != id && bound == chord && Self.sameScope(id, other)
        }?.key
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let overrides = try container.decode([String: String].self)
        do {
            self = try Self.fromOverrides(overrides)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(overrides)
    }

    /// Whether `id` names a custom command's shortcut, `command.<id>`.
    public static func isCommandAction(_ id: String) -> Bool {
        guard id.hasPrefix("command.") else { return false }
        return CustomCommand.isValidId(String(id.dropFirst("command.".count)))
    }

    static func sameScope(_ left: String, _ right: String) -> Bool {
        if isCommandAction(left) || isCommandAction(right) { return true }
        guard let left = ShortcutCatalog.find(left), let right = ShortcutCatalog.find(right) else { return false }
        return left.overlaps(right)
    }

    private static func primaryApplies(_ id: String, _ chord: KeyChord, _ context: String?) -> Bool {
        guard let shortcut = ShortcutCatalog.find(id) else { return false }
        let contexts = shortcut.defaultChord == chord ? shortcut.keyContexts.first ?? [] : shortcut.contexts
        return contexts.contains { ShortcutContext.overlap(context, $0) }
    }
}
