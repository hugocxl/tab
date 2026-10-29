import Foundation

/// A cell size adjustment: none, a number of pixels, or a percentage. Written
/// `0`, `2` or `10%`.
public enum CellHeight: Hashable, Codable, Sendable, CustomStringConvertible {
    case natural
    case pixels(Int)
    case percent(Double)

    public init(_ text: String) throws {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value == "0" {
            self = .natural
            return
        }
        if value.hasSuffix("%") {
            guard let amount = Double(value.dropLast()), amount.isFinite else {
                throw SettingsError("adjust-cell-height", "invalid percentage \"\(value)\"")
            }
            guard (-99...1000).contains(amount) else {
                throw SettingsError("adjust-cell-height", "percentage is outside the supported range")
            }
            self = .percent(amount)
            return
        }
        guard let amount = Int(value) else {
            throw SettingsError("adjust-cell-height", "invalid number \"\(value)\"")
        }
        guard (-4096...4096).contains(amount) else {
            throw SettingsError("adjust-cell-height", "adjustment is outside the supported range")
        }
        self = .pixels(amount)
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

/// Which Option keys type Alt (Meta) in a terminal instead of characters.
public enum OptionAsAlt: String, Codable, Sendable, CaseIterable {
    case both, none, left, right

    public init(_ value: String) throws {
        switch value {
        case "", "true", "both": self = .both
        case "false", "none": self = .none
        case "left": self = .left
        case "right": self = .right
        default: throw SettingsError("optionAsAlt", "expected both, none, left, or right")
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(error)")
        }
    }

    public func enabled(left: Bool, right: Bool) -> Bool {
        switch self {
        case .both: return true
        case .none: return false
        case .left: return left
        case .right: return right
        }
    }
}

public enum CursorStyle: String, Codable, Sendable, CaseIterable {
    case block, bar, underline, blockHollow
}

/// What the padding around a terminal's cells shows.
public enum PaddingColor: String, Codable, Sendable, CaseIterable {
    case background
    case extend
    case extendAlways
}

/// An OpenType feature setting, such as `calt` = 0 to turn ligatures off.
public struct FontFeature: Codable, Hashable, Sendable {
    public var tag: String
    public var value: Int

    public init(_ tag: String, _ value: Int) {
        self.tag = tag
        self.value = value
    }
}

/// A font for a Unicode range, such as Nerd Font symbols.
public struct FontMap: Codable, Hashable, Sendable {
    public var start: UInt32
    public var end: UInt32
    public var family: String

    public init(start: UInt32, end: UInt32, family: String) {
        self.start = start
        self.end = end
        self.family = family
    }
}

public struct FontOptions: Codable, Equatable, Sendable {
    public var bold: [String]
    public var italic: [String]
    public var boldItalic: [String]
    public var features: [FontFeature]
    public var codepoints: [FontMap]
    public var cellWidth: CellHeight
    /// Draws glyphs with thicker strokes.
    public var thicken: Bool
    public var thickenStrength: Int

    public init() {
        bold = []
        italic = []
        boldItalic = []
        features = []
        codepoints = []
        cellWidth = .natural
        thicken = false
        thickenStrength = 255
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = FontOptions()
        bold = try container.value(.bold, d.bold)
        italic = try container.value(.italic, d.italic)
        boldItalic = try container.value(.boldItalic, d.boldItalic)
        features = try container.value(.features, d.features)
        codepoints = try container.value(.codepoints, d.codepoints)
        cellWidth = try container.value(.cellWidth, d.cellWidth)
        thicken = try container.value(.thicken, d.thicken)
        thickenStrength = try container.value(.thickenStrength, d.thickenStrength)
    }

    /// The features as Ghostty writes them: `-calt, ss01, cv01=2`.
    public var featureList: String {
        features.map { feature in
            switch feature.value {
            case 0: return "-\(feature.tag)"
            case 1: return feature.tag
            default: return "\(feature.tag)=\(feature.value)"
            }
        }.joined(separator: ", ")
    }

    /// Reads features in Ghostty's syntax, replacing earlier settings of the
    /// same tag.
    mutating func readFeatures(_ value: String) throws {
        for raw in value.split(separator: ",") {
            let feature = raw.trimmingCharacters(in: .whitespaces)
            guard !feature.isEmpty else { continue }
            var name: Substring
            var number = 1
            if feature.hasPrefix("-") {
                name = feature.dropFirst()
                number = 0
            } else if let equals = feature.firstIndex(of: "=") {
                name = Substring(feature[..<equals].trimmingCharacters(in: .whitespaces))
                guard let parsed = Int(feature[feature.index(after: equals)...].trimmingCharacters(in: .whitespaces)) else {
                    throw SettingsError("font-feature", "invalid value in \"\(feature)\"")
                }
                number = parsed
            } else if let space = feature.firstIndex(where: \.isWhitespace) {
                name = feature[..<space]
                guard let parsed = Int(feature[space...].trimmingCharacters(in: .whitespaces)) else {
                    throw SettingsError("font-feature", "invalid value in \"\(feature)\"")
                }
                number = parsed
            } else {
                name = Substring(feature)
                while name.hasPrefix("+") { name = name.dropFirst() }
            }
            let tag = name.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard Self.validTag(tag) else {
                throw SettingsError("font-feature", "expected a four-character OpenType tag")
            }
            features.removeAll { $0.tag == tag }
            features.append(FontFeature(tag, number))
        }
    }

    /// Reads `U+E000-U+F8FF,U+F0000=Family` maps.
    static func codepointMaps(_ value: String) throws -> [FontMap] {
        guard let equals = value.firstIndex(of: "=") else {
            throw SettingsError("font-codepoint-map", "expected U+start-U+end=family")
        }
        var family = value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if family.count >= 2, family.hasPrefix("\""), family.hasSuffix("\"") {
            family = String(family.dropFirst().dropLast())
        }
        var maps: [FontMap] = []
        for range in value[..<equals].split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = range.trimmingCharacters(in: .whitespaces)
            let bounds = trimmed.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            func code(_ text: Substring) throws -> UInt32 {
                var text = text.trimmingCharacters(in: .whitespaces)
                while text.hasPrefix("U+") { text = String(text.dropFirst(2)) }
                guard let value = UInt32(text, radix: 16) else {
                    throw SettingsError("font-codepoint-map", "invalid code point \"\(text)\"")
                }
                return value
            }
            let start = try code(bounds[0])
            let end = try code(bounds.count > 1 ? bounds[1] : bounds[0])
            guard start <= end, end <= 0x10_FFFF else {
                throw SettingsError("font-codepoint-map", "invalid Unicode range")
            }
            maps.append(FontMap(start: start, end: end, family: family))
        }
        return maps
    }

    static func validTag(_ tag: String) -> Bool {
        tag.utf8.count == 4 && tag.unicodeScalars.allSatisfy { $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) }
    }
}

/// Ghostty-style terminal options: colors over the theme, cursor, selection,
/// transparency, mouse, scrolling and padding.
public struct TerminalOptions: Codable, Equatable, Sendable {
    public var background: RGBColor?
    public var foreground: RGBColor?
    /// Overrides of the theme's palette by index.
    public var palette: [Int: RGBColor]
    public var cursorColor: CellColor?
    public var cursorText: CellColor?
    public var cursorOpacity: Double
    /// `nil` lets programs choose.
    public var cursorStyle: CursorStyle?
    public var cursorBlink: Bool?
    public var cursorThickness: CellHeight
    public var selectionForeground: CellColor?
    public var selectionBackground: CellColor?
    public var selectionClearOnTyping: Bool
    public var selectionClearOnCopy: Bool
    /// `nil` is opaque.
    public var backgroundOpacity: Double?
    /// Cell backgrounds are transparent too, not just the padding.
    public var backgroundOpacityCells: Bool
    /// Blur behind a transparent terminal, from 0 to 100.
    public var backgroundVibrancy: Int
    public var boldIsBright: Bool
    /// `nil` follows the app's Copy on Select.
    public var copyOnSelect: Bool?
    public var mouseReporting: Bool
    /// Scroll speed for trackpads.
    public var scrollPrecision: Double
    /// Scroll speed for mouse wheels.
    public var scrollDiscrete: Double
    public var scrollOnKeystroke: Bool
    public var scrollOnOutput: Bool
    /// Left and right padding in points.
    public var paddingX: [Double]
    /// Top and bottom padding in points.
    public var paddingY: [Double]
    /// Spreads leftover space evenly around the cells.
    public var paddingBalance: Bool
    public var paddingColor: PaddingColor

    public init() {
        background = nil
        foreground = nil
        palette = [:]
        cursorColor = nil
        cursorText = nil
        cursorOpacity = 1
        cursorStyle = nil
        cursorBlink = nil
        cursorThickness = .natural
        selectionForeground = nil
        selectionBackground = nil
        selectionClearOnTyping = false
        selectionClearOnCopy = false
        backgroundOpacity = nil
        backgroundOpacityCells = false
        backgroundVibrancy = 0
        boldIsBright = false
        copyOnSelect = nil
        mouseReporting = true
        scrollPrecision = 1
        scrollDiscrete = 1
        scrollOnKeystroke = true
        scrollOnOutput = false
        paddingX = [2, 2]
        paddingY = [2, 2]
        paddingBalance = false
        paddingColor = .extend
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalOptions()
        background = try c.decodeIfPresent(RGBColor.self, forKey: .background)
        foreground = try c.decodeIfPresent(RGBColor.self, forKey: .foreground)
        palette = try c.value(.palette, d.palette)
        cursorColor = try c.decodeIfPresent(CellColor.self, forKey: .cursorColor)
        cursorText = try c.decodeIfPresent(CellColor.self, forKey: .cursorText)
        cursorOpacity = try c.value(.cursorOpacity, d.cursorOpacity)
        cursorStyle = try c.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle)
        cursorBlink = try c.decodeIfPresent(Bool.self, forKey: .cursorBlink)
        cursorThickness = try c.value(.cursorThickness, d.cursorThickness)
        selectionForeground = try c.decodeIfPresent(CellColor.self, forKey: .selectionForeground)
        selectionBackground = try c.decodeIfPresent(CellColor.self, forKey: .selectionBackground)
        selectionClearOnTyping = try c.value(.selectionClearOnTyping, d.selectionClearOnTyping)
        selectionClearOnCopy = try c.value(.selectionClearOnCopy, d.selectionClearOnCopy)
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
        backgroundOpacityCells = try c.value(.backgroundOpacityCells, d.backgroundOpacityCells)
        backgroundVibrancy = try c.value(.backgroundVibrancy, d.backgroundVibrancy)
        boldIsBright = try c.value(.boldIsBright, d.boldIsBright)
        copyOnSelect = try c.decodeIfPresent(Bool.self, forKey: .copyOnSelect)
        mouseReporting = try c.value(.mouseReporting, d.mouseReporting)
        scrollPrecision = try c.value(.scrollPrecision, d.scrollPrecision)
        scrollDiscrete = try c.value(.scrollDiscrete, d.scrollDiscrete)
        scrollOnKeystroke = try c.value(.scrollOnKeystroke, d.scrollOnKeystroke)
        scrollOnOutput = try c.value(.scrollOnOutput, d.scrollOnOutput)
        paddingX = try c.value(.paddingX, d.paddingX)
        paddingY = try c.value(.paddingY, d.paddingY)
        paddingBalance = try c.value(.paddingBalance, d.paddingBalance)
        paddingColor = try c.value(.paddingColor, d.paddingColor)
    }

    /// Reads one Ghostty option as Settings edits it by key.
    mutating func read(_ key: String, _ value: String) throws {
        func optional<T>(_ parse: (String) throws -> T) rethrows -> T? {
            value.isEmpty ? nil : try parse(value)
        }
        func color(_ text: String) throws -> RGBColor {
            guard let color = RGBColor(terminalValue: text) else {
                throw SettingsError(key, "expected RRGGBB, #RRGGBB, or a supported color name")
            }
            return color
        }
        func cellColor(_ text: String) throws -> CellColor {
            guard let color = CellColor(text) else {
                throw SettingsError(key, "expected RRGGBB, #RRGGBB, cell-foreground or cell-background")
            }
            return color
        }
        switch key {
        case "background": background = try optional(color)
        case "foreground": foreground = try optional(color)
        case "cursor-color": cursorColor = try optional(cellColor)
        case "cursor-text": cursorText = try optional(cellColor)
        case "selection-foreground": selectionForeground = try optional(cellColor)
        case "selection-background": selectionBackground = try optional(cellColor)
        case "cursor-style":
            cursorStyle = try optional { text in
                switch text {
                case "block": return .block
                case "bar": return .bar
                case "underline": return .underline
                case "block_hollow": return .blockHollow
                default: throw SettingsError(key, "expected block, bar, underline, or block_hollow")
                }
            }
        case "cursor-style-blink":
            cursorBlink = try optional { text in
                guard let flag = Bool(text) else { throw SettingsError(key, "expected true or false") }
                return flag
            }
        case "window-padding-x": paddingX = try Self.padding(value)
        case "window-padding-y": paddingY = try Self.padding(value)
        case "window-padding-color":
            switch value {
            case "background": paddingColor = .background
            case "", "extend": paddingColor = .extend
            case "extend-always": paddingColor = .extendAlways
            default: throw SettingsError(key, "expected background, extend, or extend-always")
            }
        default:
            throw SettingsError(key, "unknown terminal setting")
        }
    }

    private static func padding(_ value: String) throws -> [Double] {
        if value.isEmpty { return [2, 2] }
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = Double(parts[0]), let second = Double(parts.count > 1 ? parts[1] : parts[0]),
              first.isFinite, second.isFinite
        else { throw SettingsError("padding", "invalid number") }
        guard (0...4096).contains(first), (0...4096).contains(second) else {
            throw SettingsError("padding", "must be between 0 and 4096 points")
        }
        return [first, second]
    }
}

/// A change Settings makes to a list in the terminal settings.
public enum TerminalEdit: Equatable, Sendable {
    /// Replaces the fallback fonts after the main family.
    case fallbacks([String])
    /// Adds, replaces or removes a Unicode range font: `map` is a range such
    /// as `U+E000-U+F8FF` and a family.
    case codepointMap(previous: FontMap?, range: String?, family: String?)
    /// Adds, replaces or removes a key binding: `action` in Ghostty syntax.
    case binding(previous: KeyChord?, chord: KeyChord?, action: String?)
}

/// Terminal preferences, stored in `terminal.json`: fonts, cell size, Option
/// as Alt, Ghostty-style options and key bindings.
public struct TerminalSettings: Codable, Equatable, Sendable {
    /// The main font first, then fallbacks.
    public var fontFamilies: [String]
    public var fontSize: Double
    public var cellHeight: CellHeight
    public var font: FontOptions
    public var optionAsAlt: OptionAsAlt
    public var options: TerminalOptions
    public var keybindings: TerminalBindings
    /// Notes about settings that could not be applied, shown until dismissed.
    public var diagnostics: [String]

    public static let defaultFontSize = 13.0

    public init() {
        fontFamilies = ["Menlo"]
        fontSize = Self.defaultFontSize
        cellHeight = .natural
        font = FontOptions()
        optionAsAlt = .both
        options = TerminalOptions()
        keybindings = TerminalBindings()
        diagnostics = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = TerminalSettings()
        fontFamilies = try container.value(.fontFamilies, d.fontFamilies)
        fontSize = try container.value(.fontSize, d.fontSize)
        cellHeight = try container.value(.cellHeight, d.cellHeight)
        font = try container.value(.font, d.font)
        optionAsAlt = try container.value(.optionAsAlt, d.optionAsAlt)
        options = try container.value(.options, d.options)
        keybindings = try container.value(.keybindings, d.keybindings)
        diagnostics = try container.value(.diagnostics, d.diagnostics)
    }

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
        try Self.bounded("font size", fontSize, 1, 256)
        guard !fontFamilies.isEmpty else { throw SettingsError("font family", "at least one font is required") }
        let names = fontFamilies + font.bold + font.italic + font.boldItalic + font.codepoints.map(\.family)
        for name in names where name.trimmingCharacters(in: .whitespaces).isEmpty || name.hasControlCharacter || name.contains("\"") {
            throw SettingsError("font family", "enter a font name without quotes or control characters")
        }
        if font.features.contains(where: { !FontOptions.validTag($0.tag) })
            || font.codepoints.contains(where: { $0.start > $0.end || $0.end > 0x10_FFFF })
        {
            throw SettingsError("font", "invalid font feature or Unicode range")
        }
        guard (0...255).contains(font.thickenStrength) else {
            throw SettingsError("font thicken strength", "enter a number between 0 and 255")
        }
        try Self.bounded("background vibrancy", Double(options.backgroundVibrancy), 0, 100)
        try Self.bounded("cursor opacity", options.cursorOpacity, 0, 1)
        if let opacity = options.backgroundOpacity { try Self.bounded("background opacity", opacity, 0, 1) }
        guard options.paddingX.count == 2, options.paddingY.count == 2 else {
            throw SettingsError("padding", "expected two values per axis")
        }
        for amount in options.paddingX + options.paddingY { try Self.bounded("padding", amount, 0, 4096) }
        for amount in [options.scrollPrecision, options.scrollDiscrete] {
            try Self.bounded("scroll speed", amount, 0.01, 10_000)
        }
        if options.palette.keys.contains(where: { !(0...255).contains($0) }) {
            throw SettingsError("terminal", "palette indexes go from 0 to 255")
        }
    }

    private static func bounded(_ name: String, _ value: Double, _ minimum: Double, _ maximum: Double) throws {
        guard value.isFinite, (minimum...maximum).contains(value) else {
            throw SettingsError(name, "enter a number between \(format(minimum)) and \(format(maximum))")
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// Changes one preference by its Settings id. Nothing changes when the
    /// value is invalid.
    public mutating func setPreference(_ id: String, _ value: String) throws {
        var next = self
        let value = value.trimmingCharacters(in: .whitespaces)
        func flag() throws -> Bool {
            guard let flag = Bool(value) else { throw SettingsError(id, "expected true or false") }
            return flag
        }
        func number() throws -> Double {
            guard let number = Double(value) else { throw SettingsError(id, "expected a number") }
            return number
        }
        func integer() throws -> Int {
            guard let number = Int(value) else { throw SettingsError(id, "expected a whole number") }
            return number
        }
        switch id {
        case "font-family": Self.replaceFirst(&next.fontFamilies, value)
        case "font-family-bold": Self.replaceFirstOrClear(&next.font.bold, value)
        case "font-family-italic": Self.replaceFirstOrClear(&next.font.italic, value)
        case "font-family-bold-italic": Self.replaceFirstOrClear(&next.font.boldItalic, value)
        case "font-feature":
            next.font.features = []
            try next.font.readFeatures(value)
        case "font-thicken-strength": next.font.thickenStrength = try integer()
        case "font-size": next.fontSize = try number()
        case "adjust-cell-height": next.cellHeight = try CellHeight(value)
        case "adjust-cell-width": next.font.cellWidth = try CellHeight(value)
        case "font-thicken": next.font.thicken = try flag()
        case "font-ligatures":
            let enabled = try flag()
            next.font.features.removeAll { ["calt", "liga", "dlig"].contains($0.tag) }
            if !enabled { next.font.features += ["calt", "liga", "dlig"].map { FontFeature($0, 0) } }
        case "background-transparency":
            let percent = try number()
            try Self.bounded(id, percent, 0, 100)
            next.options.backgroundOpacity = 1 - percent / 100
        case "background-opacity":
            let percent = try number()
            try Self.bounded(id, percent, 0, 100)
            next.options.backgroundOpacity = percent / 100
        case "background-vibrancy": next.options.backgroundVibrancy = try integer()
        case "padding-left": next.options.paddingX[0] = try number()
        case "padding-right": next.options.paddingX[1] = try number()
        case "padding-top": next.options.paddingY[0] = try number()
        case "padding-bottom": next.options.paddingY[1] = try number()
        case "background-opacity-cells": next.options.backgroundOpacityCells = try flag()
        case "cursor-style", "cursor-style-blink", "window-padding-x", "window-padding-y", "window-padding-color",
             "background", "foreground", "cursor-color", "cursor-text", "selection-foreground", "selection-background":
            try next.options.read(id, value)
        case let palette where palette.hasPrefix("palette-"):
            guard let index = Int(palette.dropFirst("palette-".count)), (0...255).contains(index) else {
                throw SettingsError(id, "unknown palette entry")
            }
            if value.isEmpty {
                next.options.palette[index] = nil
            } else {
                guard let color = RGBColor(terminalValue: value) else {
                    throw SettingsError(id, "expected RRGGBB, #RRGGBB, or a supported color name")
                }
                next.options.palette[index] = color
            }
        case "cursor-opacity":
            let percent = try number()
            try Self.bounded(id, percent, 0, 100)
            next.options.cursorOpacity = percent / 100
        case "keybind-clear-defaults": next.keybindings.clearDefaults = try flag()
        case "dismiss-import-notes": next.diagnostics = []
        case "adjust-cursor-thickness": next.options.cursorThickness = try CellHeight(value)
        case "window-padding-balance": next.options.paddingBalance = try flag()
        case "copy-on-select": next.options.copyOnSelect = try flag()
        case "selection-clear-on-typing": next.options.selectionClearOnTyping = try flag()
        case "selection-clear-on-copy": next.options.selectionClearOnCopy = try flag()
        case "bold-is-bright": next.options.boldIsBright = try flag()
        case "mouse-reporting": next.options.mouseReporting = try flag()
        case "scroll-on-keystroke": next.options.scrollOnKeystroke = try flag()
        case "scroll-on-output": next.options.scrollOnOutput = try flag()
        case "scroll-precision": next.options.scrollPrecision = try number()
        case "scroll-discrete": next.options.scrollDiscrete = try number()
        case "macos-option-as-alt", "option-as-alt": next.optionAsAlt = try OptionAsAlt(value)
        default: throw SettingsError(id, "unknown terminal setting")
        }
        try next.validate()
        self = next
    }

    /// Applies a list edit from Settings. Nothing changes when it is invalid.
    public mutating func edit(_ edit: TerminalEdit) throws {
        var next = self
        switch edit {
        case .fallbacks(let names):
            next.fontFamilies = Array(next.fontFamilies.prefix(1)) + names
        case let .codepointMap(previous, range, family):
            var maps: [FontMap] = []
            if let range, let family {
                maps = try FontOptions.codepointMaps(
                    "\(range.trimmingCharacters(in: .whitespaces))=\(family.trimmingCharacters(in: .whitespaces))"
                )
            }
            if let previous {
                guard let index = next.font.codepoints.firstIndex(of: previous) else {
                    throw SettingsError("font-codepoint-map", "this map was changed elsewhere")
                }
                next.font.codepoints.replaceSubrange(index...index, with: maps)
            } else {
                next.font.codepoints += maps
            }
        case let .binding(previous, chord, action):
            if let previous { next.keybindings.bindings[previous] = nil }
            if let chord, let action {
                if next.keybindings.bindings[chord] != nil {
                    throw SettingsError("keybind", "\(chord) already has a terminal binding")
                }
                next.keybindings.bindings[chord] = try TerminalAction(action)
            }
        }
        try next.validate()
        self = next
    }

    /// Whether ligature features are left on.
    public var ligaturesEnabled: Bool {
        !font.features.contains { ["calt", "liga", "dlig"].contains($0.tag) && $0.value == 0 }
    }

    /// Changes the font size by `delta` points, within 1 to 256.
    public mutating func zoom(_ delta: Double) {
        fontSize = min(max(fontSize + delta, 1), 256)
    }

    private static func replaceFirst(_ families: inout [String], _ name: String) {
        if families.isEmpty { families.append(name) } else { families[0] = name }
    }

    private static func replaceFirstOrClear(_ families: inout [String], _ name: String) {
        if name.isEmpty { families.removeAll() } else { replaceFirst(&families, name) }
    }
}
