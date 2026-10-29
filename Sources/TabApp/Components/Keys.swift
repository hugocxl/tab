import AppKit
import TabCore

/// One key of a shortcut, drawn as in the command palette: a 20pt rounded
/// cap on the surface color.
public final class KeyCap: ThemedView {
    public let symbol: String
    private let label: NSTextField

    public init(_ symbol: String) {
        self.symbol = symbol
        label = makeLabel(symbol, font: AppFont.small)
        label.alignment = .center
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.keycap),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.keycap),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func themeDidChange() {
        label.textColor = theme.fgMuted
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        theme.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Metrics.radiusSmall, yRadius: Metrics.radiusSmall).fill()
    }

    /// The caps of a chord in display order: `⇧`, `⌘`, `N`.
    public static func symbols(for chord: KeyChord) -> [String] {
        var symbols: [String] = []
        let modifiers = chord.modifiers
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        if modifiers.contains(.function) { symbols.append("fn") }
        symbols.append(ShortcutCatalog.displayChord(chord.key))
        return symbols
    }
}

/// The caps of one chord side by side.
public final class KeyCapRow: NSStackView {
    public init(_ chord: KeyChord) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        for symbol in KeyCap.symbols(for: chord) { addArrangedSubview(KeyCap(symbol)) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(chord.display)
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

extension KeyChord {
    /// The chord a key press makes, or `nil` for a lone modifier.
    public init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let key = Self.keyName(event) else { return nil }
        var parts: [String] = []
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("alt") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.function) && !Self.functionImplied(event.keyCode) { parts.append("fn") }
        guard let chord = try? KeyChord((parts + [key]).joined(separator: "-")) else { return nil }
        self = chord
    }

    /// Arrow and navigation keys report Function on their own.
    private static func functionImplied(_ keyCode: UInt16) -> Bool {
        (115...126).contains(keyCode) || keyCode == 117 || (96...111).contains(keyCode)
    }

    private static let namedKeyCodes: [UInt16: String] = [
        36: "enter", 76: "enter", 48: "tab", 49: "space", 51: "backspace", 53: "escape", 117: "delete",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown", 123: "left", 124: "right", 125: "down", 126: "up",
        114: "insert",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
        109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17",
        79: "f18", 80: "f19", 90: "f20",
    ]

    private static func keyName(_ event: NSEvent) -> String? {
        if let name = namedKeyCodes[event.keyCode] { return name }
        guard let characters = event.charactersIgnoringModifiers?.lowercased(), characters.count == 1,
              let character = characters.first, !character.isWhitespace,
              !character.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        // Shift changes the character on symbol keys; record the base key.
        if event.modifierFlags.contains(.shift),
           let base = event.characters(byApplyingModifiers: [])?.lowercased(), base.count == 1
        {
            return base
        }
        return String(character)
    }
}

/// A button that records a shortcut: it shows the chord's glyphs, and
/// after a click "Press a shortcut…" until a key is pressed. Escape cancels.
/// `onRecord` returns an error to show, such as a conflict, or `nil` when
/// the chord was taken.
public final class ShortcutRecorder: HoverView {
    public private(set) var chord: KeyChord?
    public var placeholder: String
    public var onRecord: ((KeyChord) -> String?)?
    public var onError: ((String?) -> Void)?
    public private(set) var isRecording = false {
        didSet { updateTitle() }
    }
    private let label: NSTextField

    public init(chord: KeyChord?, placeholder: String = "Not assigned", label accessibilityName: String) {
        self.chord = chord
        self.placeholder = placeholder
        label = makeLabel("", font: AppFont.small)
        label.alignment = .center
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityName)
        updateTitle()
    }

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public var title: String { label.stringValue }

    public func setChord(_ chord: KeyChord?) {
        self.chord = chord
        updateTitle()
    }

    private func updateTitle() {
        label.stringValue = isRecording ? "Press a shortcut…" : (chord?.display ?? placeholder)
        setAccessibilityValue(label.stringValue)
        themeDidChange()
    }

    public override func themeDidChange() {
        label.textColor = isRecording ? theme.accent : (chord == nil ? theme.fgMuted : theme.fg)
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.radiusMedium, yRadius: Metrics.radiusMedium)
        theme.button.setFill()
        path.fill()
        if isHovered {
            theme.hover.setFill()
            path.fill()
        }
        (isRecording ? theme.accent : theme.border).setStroke()
        path.lineWidth = isRecording ? 1.5 : Metrics.border
        path.stroke()
    }

    public override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        beginRecording()
    }

    public override func accessibilityPerformPress() -> Bool {
        beginRecording()
        return true
    }

    public func beginRecording() {
        isRecording = true
        onError?(nil)
        window?.makeFirstResponder(self)
    }

    public override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        record(event)
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
                beginRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        record(event)
    }

    /// Records the chord of a key press; Escape without modifiers cancels.
    public func record(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        isRecording = false
        if event.keyCode == 53 && flags.isEmpty { return }
        guard let chord = KeyChord(event: event) else {
            onError?("That key can't be used for a shortcut.")
            return
        }
        record(chord)
    }

    /// Offers `chord` as if it had been pressed.
    public func record(_ chord: KeyChord) {
        isRecording = false
        if let error = onRecord?(chord) {
            onError?(error)
            return
        }
        onError?(nil)
        setChord(chord)
    }
}
