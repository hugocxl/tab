import CoreGraphics
import Foundation
import TabCore
import TabProtocol

/// The colors a terminal draws with: the theme's scheme with the terminal
/// settings' color and cursor choices, resolved to `0xRRGGBB` values.
public struct TerminalPalette: Hashable, Sendable {
    public var transparentBackground = false
    public var background: UInt32
    public var foreground: UInt32
    /// The cursor color when no cell-relative cursor color is set.
    public var cursor: UInt32
    /// The 256-color palette: 16 ANSI colors, the 6×6×6 cube, the gray ramp.
    public var colors: [UInt32]
    public var cursorColor: CellColor?
    public var cursorText: CellColor?
    public var selectionForeground: CellColor?
    public var selectionBackground: CellColor?
    public var cursorStyle: CursorShape
    public var cursorBlink: Bool
    /// The least contrast text keeps against its background; 1 leaves colors as they are.
    public var minimumContrast: Double
    /// Text colors snap to the nearest of the theme's 16 colors and foreground.
    public var forceThemePalette: Bool
    /// Colors are Display P3 values rather than sRGB.
    public var displayP3: Bool

    /// The contrast "Improve text contrast" keeps, WCAG's minimum for large text.
    public static let improvedContrast = 3.0

    /// Tab's built-in colors, used where a theme sets nothing.
    public init(dark: Bool = true) {
        let ansi: [UInt32] = dark
            ? [0x46_40_56, 0xEC_48_99, 0x34_D3_99, 0xE0_AF_68, 0xC3_70_D3, 0x63_66_F1, 0x22_D3_EE, 0xA9_B1_D6,
               0x7C_73_93, 0xF4_72_B6, 0x6E_E7_B7, 0xFB_BF_24, 0xD9_9B_E5, 0x81_8C_F8, 0x67_E8_F9, 0xC9_C2_D9]
            : [0xD5_D6_DB, 0xA3_2D_68, 0x1A_7A_4E, 0x9A_70_24, 0x47_96_F0, 0x7C_3A_ED, 0x0B_71_89, 0x3B_3F_5C,
               0x7A_7E_94, 0xEC_48_99, 0x34_D3_99, 0xE0_AF_68, 0x6B_AB_F5, 0xA7_8B_FA, 0x22_D3_EE, 0x1E_1E_2E]
        background = dark ? 0x19_17_1F : 0xF0_F0_F5
        foreground = dark ? 0xC9_C2_D9 : 0x1E_1E_2E
        cursor = foreground
        colors = Self.defaultColors(ansi)
        cursorStyle = .block
        cursorBlink = true
        minimumContrast = 1
        forceThemePalette = false
        displayP3 = false
    }

    /// The palette of a theme with the terminal settings' choices. `background`
    /// is the pane card color the host wants under the terminal, when it
    /// differs from the theme's.
    public init(scheme: ColorScheme, settings: TerminalSettings = TerminalSettings(), dark: Bool,
                background: RGBColor? = nil) {
        self.init(dark: dark)
        if let color = background ?? scheme.background { self.background = color.value }
        if let color = scheme.foreground { foreground = color.value }
        for (index, color) in scheme.palette where (0..<256).contains(index) {
            colors[index] = color.value
        }
        cursorColor = scheme.cursorColor
        cursorText = scheme.cursorText
        selectionForeground = settings.selectionForeground.cellColor ?? scheme.selectionForeground
        selectionBackground = settings.selectionBackground.cellColor ?? scheme.selectionBackground
        cursorStyle = Self.shape(settings.cursorStyle)
        cursorBlink = settings.cursorBlink != .off
        minimumContrast = settings.improveContrast ? Self.improvedContrast : 1
        forceThemePalette = settings.forceThemePalette
        displayP3 = settings.displayP3
        cursor = cursorColor.map { resolveCell($0, foreground: foreground, background: self.background) } ?? foreground
    }

    public func indexed(_ index: UInt8) -> UInt32 { colors[Int(index)] }

    public func resolve(_ color: Color, default fallback: UInt32) -> UInt32 {
        switch color {
        case .default: return fallback
        case .indexed(let index): return colors[Int(index)]
        case .rgb(let red, let green, let blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        }
    }

    /// The foreground and background a style draws with, after inverse, the
    /// theme palette and the contrast adjustment.
    public func style(_ style: Style) -> (foreground: UInt32, background: UInt32) {
        var foreground = resolve(style.fg, default: self.foreground)
        if forceThemePalette, Self.isProgramColor(style.fg) { foreground = nearestThemeColor(foreground) }
        let background = resolve(style.bg, default: self.background)
        var colors: (foreground: UInt32, background: UInt32) = style.inverse ? (background, foreground) : (foreground, background)
        if minimumContrast > 1 { colors.foreground = Self.contrasting(colors.foreground, on: colors.background, minimumContrast) }
        return colors
    }

    func resolveCell(_ color: CellColor, foreground: UInt32, background: UInt32) -> UInt32 {
        color.resolve(foreground: RGBColor(foreground), background: RGBColor(background)).value
    }

    /// What the server's engine needs to answer color queries and draw
    /// defaults the same way.
    public var terminalColors: TerminalColors {
        func rgb(_ value: UInt32) -> RGB {
            RGB(UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
        }
        var palette: [Int: RGB] = [:]
        for index in 16..<256 { palette[index] = rgb(colors[index]) }
        return TerminalColors(
            foreground: rgb(foreground), background: rgb(background), cursor: rgb(cursor),
            ansi: colors.prefix(16).map(rgb), palette: palette, cursorStyle: cursorStyle, cursorBlink: cursorBlink)
    }

    /// A color as Core Graphics draws it, in sRGB or Display P3.
    public func cgColor(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        let red = CGFloat(value >> 16 & 0xFF) / 255
        let green = CGFloat(value >> 8 & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        if displayP3, let space = CGColorSpace(name: CGColorSpace.displayP3),
           let color = CGColor(colorSpace: space, components: [red, green, blue, alpha]) {
            return color
        }
        return CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func shape(_ style: CursorStyle) -> CursorShape {
        switch style {
        case .block: return .block
        case .bar: return .bar
        case .underline: return .underline
        case .outline: return .hollow
        }
    }

    // MARK: Text colors

    /// Colors a program picked itself: true color and the 256-color cube and
    /// ramp, not the theme's own 16.
    static func isProgramColor(_ color: Color) -> Bool {
        switch color {
        case .default: return false
        case .indexed(let index): return index >= 16
        case .rgb: return true
        }
    }

    /// The theme color (16 ANSI colors or foreground) closest to `value`.
    func nearestThemeColor(_ value: UInt32) -> UInt32 {
        var best = foreground
        var bestDistance = Self.distance(value, foreground)
        for candidate in colors.prefix(16) {
            let distance = Self.distance(value, candidate)
            if distance < bestDistance {
                best = candidate
                bestDistance = distance
            }
        }
        return best
    }

    /// The "redmean" approximation of perceived color distance.
    static func distance(_ a: UInt32, _ b: UInt32) -> Double {
        let (r1, g1, b1) = components(a)
        let (r2, g2, b2) = components(b)
        let mean = (r1 + r2) / 2
        let dr = r1 - r2, dg = g1 - g2, db = b1 - b2
        return (2 + mean / 256) * dr * dr + 4 * dg * dg + (2 + (255 - mean) / 256) * db * db
    }

    /// `foreground` moved toward black or white just enough to reach
    /// `minimum` contrast against `background`, keeping its hue.
    static func contrasting(_ foreground: UInt32, on background: UInt32, _ minimum: Double) -> UInt32 {
        let backgroundLuminance = luminance(background)
        guard contrast(luminance(foreground), backgroundLuminance) < minimum else { return foreground }
        let target: UInt32 = contrast(1, backgroundLuminance) >= contrast(0, backgroundLuminance) ? 0xFF_FF_FF : 0
        var low = 0.0
        var high = 1.0
        for _ in 0..<12 {
            let middle = (low + high) / 2
            if contrast(luminance(blend(foreground, target, middle)), backgroundLuminance) >= minimum {
                high = middle
            } else {
                low = middle
            }
        }
        return blend(foreground, target, high)
    }

    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// WCAG relative luminance.
    static func luminance(_ value: UInt32) -> Double {
        func linear(_ channel: Double) -> Double {
            let c = channel / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = components(value)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    static func blend(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let (r1, g1, b1) = components(a)
        let (r2, g2, b2) = components(b)
        func mix(_ x: Double, _ y: Double) -> UInt32 { UInt32((x + (y - x) * amount).rounded()) }
        return mix(r1, r2) << 16 | mix(g1, g2) << 8 | mix(b1, b2)
    }

    private static func components(_ value: UInt32) -> (Double, Double, Double) {
        (Double(value >> 16 & 0xFF), Double(value >> 8 & 0xFF), Double(value & 0xFF))
    }

    static func defaultColors(_ ansi: [UInt32]) -> [UInt32] {
        var colors = ansi
        for cube in 0..<216 {
            let level = { (value: Int) -> UInt32 in value == 0 ? 0 : UInt32(55 + 40 * value) }
            colors.append(level(cube / 36) << 16 | level(cube / 6 % 6) << 8 | level(cube % 6))
        }
        for step in 0..<24 {
            let level = UInt32(8 + 10 * step)
            colors.append(level << 16 | level << 8 | level)
        }
        return colors
    }
}
