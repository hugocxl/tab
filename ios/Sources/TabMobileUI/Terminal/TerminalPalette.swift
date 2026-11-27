import CoreGraphics
import TabCommon
import TabProtocol
import UIKit

/// A theme's colors as the renderer uses them: 256 indexed colors over the
/// xterm defaults, and cached CGColors for true-color cells.
final class TerminalPalette {
    let background: RGBColor
    let foreground: RGBColor
    let cursor: RGBColor
    let cursorText: RGBColor
    let selection: RGBColor
    let dark: Bool
    private let table: [RGBColor]
    private var cache: [UInt32: CGColor] = [:]

    init(scheme: ColorScheme, dark: Bool) {
        self.dark = dark
        let background = scheme.background ?? RGBColor(dark ? 0x1A1A19 : 0xF7F6F4)
        let foreground = scheme.foreground ?? RGBColor(dark ? 0xCECDC8 : 0x312F27)
        var table = Self.xterm
        for (index, color) in scheme.palette where index >= 0 && index < 256 { table[index] = color }
        self.background = background
        self.foreground = foreground
        self.table = table
        cursor = Self.resolve(scheme.cursorColor, foreground: foreground, background: background) ?? foreground
        cursorText = Self.resolve(scheme.cursorText, foreground: foreground, background: background) ?? background
        selection = Self.resolve(scheme.selectionBackground, foreground: foreground, background: background)
            ?? RGBColor(dark ? 0x53362C : 0xEDD6CD)
    }

    private static func resolve(_ color: CellColor?, foreground: RGBColor, background: RGBColor) -> RGBColor? {
        switch color {
        case .rgb(let value)?: value
        case .cellForeground?: foreground
        case .cellBackground?: background
        case nil: nil
        }
    }

    /// A cell's foreground and background after inverse and faint.
    func colors(_ style: Style) -> (foreground: CGColor, background: CGColor?) {
        var foreground = rgb(style.fg) ?? self.foreground
        var background = rgb(style.bg)
        if style.bold, case .indexed(let index) = style.fg, index < 8 { foreground = table[Int(index) + 8] }
        if style.inverse {
            let swapped = background ?? self.background
            background = foreground
            foreground = swapped
        }
        return (cgColor(foreground, alpha: style.faint ? 0.5 : 1), background.map { cgColor($0) })
    }

    func rgb(_ color: TabProtocol.Color) -> RGBColor? {
        switch color {
        case .default: nil
        case .indexed(let index): table[Int(index)]
        case .rgb(let red, let green, let blue): RGBColor(UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
        }
    }

    func cgColor(_ color: RGBColor, alpha: CGFloat = 1) -> CGColor {
        let key = color.value | (alpha < 1 ? 0x1000000 : 0)
        if let cached = cache[key] { return cached }
        let value = CGColor(srgbRed: CGFloat(color.value >> 16 & 0xFF) / 255, green: CGFloat(color.value >> 8 & 0xFF) / 255,
                            blue: CGFloat(color.value & 0xFF) / 255, alpha: alpha)
        cache[key] = value
        return value
    }

    func uiColor(_ color: RGBColor) -> UIColor { UIColor(cgColor: cgColor(color)) }

    /// The palette as the server reports it to programs that ask (OSC 4/10/11).
    var terminalColors: TerminalColors {
        func rgb(_ color: RGBColor) -> RGB {
            RGB(UInt8(color.value >> 16 & 0xFF), UInt8(color.value >> 8 & 0xFF), UInt8(color.value & 0xFF))
        }
        return TerminalColors(foreground: rgb(foreground), background: rgb(background), cursor: rgb(cursor),
                              ansi: table.prefix(16).map(rgb))
    }

    /// xterm's 16 colors, 6×6×6 cube and gray ramp.
    private static let xterm: [RGBColor] = {
        var colors: [UInt32] = [0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
                                0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]
        let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
        for red in steps { for green in steps { for blue in steps { colors.append(red << 16 | green << 8 | blue) } } }
        for index in 0..<24 {
            let level = UInt32(8 + index * 10)
            colors.append(level << 16 | level << 8 | level)
        }
        return colors.map(RGBColor.init)
    }()
}
