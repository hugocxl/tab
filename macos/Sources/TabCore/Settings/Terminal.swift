import Foundation

/// A character spacing adjustment: none, a number of pixels, or a percentage.
/// Written `0`, `2` or `10%`.
public enum CellAdjustment: Hashable, Codable, Sendable, CustomStringConvertible {
    case natural
    case pixels(Int)
    case percent(Double)

    public static let pixelRange = -5...20
    public static let percentRange = -50.0...200.0

    public init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "0" {
            self = .natural
            return
        }
        if value.hasSuffix("%") {
            guard let amount = Double(value.dropLast()), amount.isFinite else {
                throw SettingsError("character spacing", "invalid percentage \"\(value)\"")
            }
            self = .percent(amount)
            return
        }
        guard let amount = Int(value) else {
            throw SettingsError("character spacing", "invalid number \"\(value)\"")
        }
        self = .pixels(amount)
    }

    /// Whether the amount is within the range Settings offers.
    public var isValid: Bool {
        switch self {
        case .natural: return true
        case .pixels(let amount): return Self.pixelRange.contains(amount)
        case .percent(let amount): return amount.isFinite && Self.percentRange.contains(amount)
        }
    }

    /// The adjusted size in points of a `natural` size at `scale` pixels per
    /// point, whole pixels and at least one.
    public func apply(natural: Double, scale: Double) -> Double {
        let physical = natural * scale
        let adjusted: Double
        switch self {
        case .natural: adjusted = physical
        case .pixels(let amount): adjusted = physical.rounded() + Double(amount)
        case .percent(let amount): adjusted = physical * (1 + amount / 100)
        }
        return max(adjusted.rounded(), 1) / scale
    }

    public var description: String {
        switch self {
        case .natural: return "0"
        case .pixels(let value): return String(value)
        case .percent(let value):
            return (value == value.rounded() ? String(Int(value)) : String(value)) + "%"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text: String
        if let number = try? container.decode(Int.self) {
            text = String(number)
        } else {
            text = try container.decode(String.self)
        }
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What the Option keys do in a terminal: send Alt (Meta), or type the
/// special characters of the keyboard layout.
public enum OptionKey: String, Codable, Sendable, CaseIterable {
    /// Alt on U.S. layouts, special characters on the others.
    case automatic
    case alt
    case characters
    case leftAlt
    case rightAlt

    /// Whether Option sends Alt with this key down, on a U.S. layout or not.
    public func sendsAlt(left: Bool, right: Bool, usLayout: Bool) -> Bool {
        switch self {
        case .automatic: return usLayout
        case .alt: return true
        case .characters: return false
        case .leftAlt: return left
        case .rightAlt: return right
        }
    }
}

public enum CursorStyle: String, Codable, Sendable, CaseIterable {
    case block, bar, underline, outline
}

/// How fast the cursor blinks, or not at all.
public enum CursorBlink: String, Codable, Sendable, CaseIterable {
    case off, slow, normal, fast

    /// Seconds between blink phases, `nil` when off.
    public var interval: TimeInterval? {
        switch self {
        case .off: return nil
        case .slow: return 0.8
        case .normal: return 0.53
        case .fast: return 0.3
        }
    }
}

/// A selection color: the theme's, or the selected cell's own text or
/// background color.
public enum SelectionColor: String, Codable, Sendable, CaseIterable {
    case theme, text, background

    /// The color over the theme, `nil` for the theme's own.
    public var cellColor: CellColor? {
        switch self {
        case .theme: return nil
        case .text: return .cellForeground
        case .background: return .cellBackground
        }
    }
}

/// What a terminal link that launches another app does when clicked.
public enum AppLinkPolicy: String, Codable, Sendable, CaseIterable {
    case ask, always, never
}

/// Terminal preferences, stored in `terminal.json`.
public struct TerminalSettings: Codable, Hashable, Sendable {
    // Typography
    public var fontFamily: String
    /// The face within the family, such as Regular or Medium.
    public var fontStyle: String
    public var fontSize: Double
    public var characterSpacing: CellAdjustment
    /// Extra line height, in percent of the font's.
    public var lineHeight: Double
    public var ligatures: Bool
    public var fontSmoothing: Bool
    /// Fonts for characters the terminal font lacks, in order.
    public var fallbackFonts: [String]
    // Colors
    public var improveContrast: Bool
    public var forceThemePalette: Bool
    public var displayP3: Bool
    // Cursor
    public var cursorStyle: CursorStyle
    public var cursorBlink: CursorBlink
    /// Ignores programs' requests to change the cursor's shape.
    public var forceCursorStyle: Bool
    // Keyboard
    public var optionKey: OptionKey
    // Scrolling
    public var smoothScrolling: Bool
    // Selection
    public var copyOnSelect: Bool
    public var copyAnimation: Bool
    public var selectionForeground: SelectionColor
    public var selectionBackground: SelectionColor
    public var roundedSelection: Bool
    // Links
    public var appLinks: AppLinkPolicy
    // Titles
    public var preferGeneratedTitles: Bool

    public static let defaultFontFamily = "SF Mono"
    public static let defaultFontStyle = "Regular"
    public static let defaultFontSize = 13.0
    public static let fontSizeRange = 6.0...72.0
    public static let lineHeightRange = -50.0...200.0

    public init() {
        fontFamily = Self.defaultFontFamily
        fontStyle = Self.defaultFontStyle
        fontSize = Self.defaultFontSize
        characterSpacing = .natural
        lineHeight = 0
        ligatures = true
        fontSmoothing = false
        fallbackFonts = []
        improveContrast = true
        forceThemePalette = false
        displayP3 = false
        cursorStyle = .block
        cursorBlink = .normal
        forceCursorStyle = false
        optionKey = .automatic
        smoothScrolling = false
        copyOnSelect = false
        copyAnimation = true
        selectionForeground = .theme
        selectionBackground = .theme
        roundedSelection = true
        appLinks = .ask
        preferGeneratedTitles = true
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalSettings()
        fontFamily = try c.value(.fontFamily, d.fontFamily)
        fontStyle = try c.value(.fontStyle, d.fontStyle)
        fontSize = try c.value(.fontSize, d.fontSize)
        characterSpacing = try c.value(.characterSpacing, d.characterSpacing)
        lineHeight = try c.value(.lineHeight, d.lineHeight)
        ligatures = try c.value(.ligatures, d.ligatures)
        fontSmoothing = try c.value(.fontSmoothing, d.fontSmoothing)
        fallbackFonts = try c.value(.fallbackFonts, d.fallbackFonts)
        improveContrast = try c.value(.improveContrast, d.improveContrast)
        forceThemePalette = try c.value(.forceThemePalette, d.forceThemePalette)
        displayP3 = try c.value(.displayP3, d.displayP3)
        cursorStyle = try c.value(.cursorStyle, d.cursorStyle)
        cursorBlink = try c.value(.cursorBlink, d.cursorBlink)
        forceCursorStyle = try c.value(.forceCursorStyle, d.forceCursorStyle)
        optionKey = try c.value(.optionKey, d.optionKey)
        smoothScrolling = try c.value(.smoothScrolling, d.smoothScrolling)
        copyOnSelect = try c.value(.copyOnSelect, d.copyOnSelect)
        copyAnimation = try c.value(.copyAnimation, d.copyAnimation)
        selectionForeground = try c.value(.selectionForeground, d.selectionForeground)
        selectionBackground = try c.value(.selectionBackground, d.selectionBackground)
        roundedSelection = try c.value(.roundedSelection, d.roundedSelection)
        appLinks = try c.value(.appLinks, d.appLinks)
        preferGeneratedTitles = try c.value(.preferGeneratedTitles, d.preferGeneratedTitles)
    }

    /// The terminal font, then its fallbacks.
    public var fontFamilies: [String] { [fontFamily] + fallbackFonts }

    /// Reads `url`, creating it with the defaults when missing.
    public static func load(_ url: URL) throws -> TerminalSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let settings = TerminalSettings()
            try settings.save(to: url)
            return settings
        }
        do {
            return try decode(Data(contentsOf: url), path: url.path)
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
    }

    /// Terminal settings from JSON, checked.
    public static func decode(_ data: Data, path: String = "terminal.json") throws -> TerminalSettings {
        let settings: TerminalSettings
        do {
            settings = try JSONDecoder().decode(TerminalSettings.self, from: data)
        } catch {
            throw SettingsError(path, SettingsJSON.describe(error))
        }
        try settings.validate()
        return settings
    }

    /// Writes the settings. A file that no longer reads, such as one broken
    /// by a hand edit, is never overwritten, so the edit can be fixed.
    public func save(to url: URL) throws {
        try validate()
        let data = try SettingsJSON.encode(self)
        if let previous = try? Data(contentsOf: url) {
            _ = try Self.decode(previous, path: url.path)
        }
        do {
            try AtomicFile.write(data, to: url)
        } catch {
            throw SettingsError(url.path, error.localizedDescription)
        }
    }

    public func validate() throws {
        guard fontSize.isFinite, Self.fontSizeRange.contains(fontSize) else {
            throw SettingsError("font size", "enter a size from 6 to 72 points")
        }
        guard lineHeight.isFinite, Self.lineHeightRange.contains(lineHeight) else {
            throw SettingsError("line height", "enter a percentage from -50 to 200")
        }
        guard characterSpacing.isValid else {
            throw SettingsError("character spacing", "enter -5 to 20 pixels, or -50% to 200%")
        }
        for name in [fontFamily, fontStyle] + fallbackFonts
            where name.trimmingCharacters(in: .whitespaces).isEmpty || name.hasControlCharacter {
            throw SettingsError("font", "enter a font name without control characters")
        }
    }
}
