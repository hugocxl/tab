import AppKit

/// Native adaptation of source SGR attributes using the existing app terminal palette.
@MainActor
struct AgentTerminalStyle {
    var bold = false, dim = false, italic = false, underline = false, strike = false, inverse = false
    var foreground: UInt32?, background: UInt32?
    private var foregroundCode = "", backgroundCode = ""
    var pen: String {
        var parts: [String] = []
        if bold { parts.append("1") }; if dim { parts.append("2") }; if italic { parts.append("3") }
        if underline { parts.append("4") }; if inverse { parts.append("7") }; if strike { parts.append("9") }
        if !foregroundCode.isEmpty { parts.append(foregroundCode) }
        if !backgroundCode.isEmpty { parts.append(backgroundCode) }
        return parts.joined(separator: ";")
    }

    static func parameters(_ source: String) -> [Int] {
        source.components(separatedBy: ";").flatMap { part -> [Int] in
            var values = part.components(separatedBy: ":").map { Int($0) ?? 0 }
            if values.count >= 6, [38, 48].contains(values[0]), values[1] == 2 { values.remove(at: 2) }
            return values
        }
    }

    mutating func apply(_ source: String, palette: [UInt32]) {
        let values = Self.parameters(source)
        var index = 0
        while index < values.count {
            let code = values[index]
            switch code {
            case 0: self = Self()
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 7: inverse = true
            case 9: strike = true
            case 22: bold = false; dim = false
            case 23: italic = false
            case 24: underline = false
            case 27: inverse = false
            case 29: strike = false
            case 30...37: foreground = palette[code - 30]; foregroundCode = String(code)
            case 90...97: foreground = palette[code - 82]; foregroundCode = String(code)
            case 40...47: background = palette[code - 40]; backgroundCode = String(code)
            case 100...107: background = palette[code - 92]; backgroundCode = String(code)
            case 39: foreground = nil; foregroundCode = ""
            case 49: background = nil; backgroundCode = ""
            case 38, 48:
                var color: UInt32?
                var colorCode = ""
                let mode = index + 1 < values.count ? values[index + 1] : 0
                if mode == 5 {
                    if index + 2 < values.count, (0...255).contains(values[index + 2]) {
                        color = Self.indexed(values[index + 2], palette: palette)
                        colorCode = "\(code);5;\(values[index + 2])"
                    }
                    index += 3
                } else if mode == 2 {
                    if index + 4 < values.count {
                        color = UInt32(values[index + 2] & 255) << 16 | UInt32(values[index + 3] & 255) << 8 | UInt32(values[index + 4] & 255)
                    }
                    if let color { colorCode = "\(code);2;\((color >> 16) & 255);\((color >> 8) & 255);\(color & 255)" }
                    index += 5
                } else { index += 2 }
                if let color {
                    if code == 38 { foreground = color; foregroundCode = colorCode } else { background = color; backgroundCode = colorCode }
                }
                continue
            default: break
            }
            index += 1
        }
    }

    static func indexed(_ index: Int, palette: [UInt32]) -> UInt32 {
        palette[index]
    }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    private static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ shift: UInt32) -> Double {
            let value = Double((rgb >> shift) & 255) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }

    func attributes(palette: TerminalPalette, baseColor: NSColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var fg = foreground, bg = background
        if inverse { (fg, bg) = (bg, fg ?? palette.foreground) }
        if let background = bg {
            let back = Self.luminance(background)
            let ratio = fg.map { (max(Self.luminance($0), back) + 0.05) / (min(Self.luminance($0), back) + 0.05) }
            if (ratio ?? 0) < 3 {
                func contrast(_ color: UInt32) -> Double {
                    (max(Self.luminance(color), back) + 0.05) / (min(Self.luminance(color), back) + 0.05)
                }
                fg = contrast(palette.foreground) >= contrast(palette.background) ? palette.foreground : palette.background
            }
        }
        var font = AppFont.mono(fontSize, weight: bold ? .semibold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: (fg.map(Self.color) ?? baseColor).withAlphaComponent(dim ? 0.65 : 1)]
        if let bg { attributes[.backgroundColor] = Self.color(bg).withAlphaComponent(dim ? 0.65 : 1) }
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }
}
