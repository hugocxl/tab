import CoreGraphics
import TabCore
import TabProtocol

/// The colors a terminal draws with: the theme's scheme with the user's
/// `terminal.json` overrides on top, resolved to `0xRRGGBB` values.
public struct TerminalPalette: Equatable, Sendable {
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
    public var cursorStyle: CursorShape?
    public var cursorBlink: Bool?
    public var cursorOpacity: Double
    public var boldIsBright: Bool
    /// 1 is opaque; lower lets the window's material show through.
    public var backgroundOpacity: Double
    /// Whether cells with their own background color also become translucent.
    public var backgroundOpacityCells: Bool

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
        cursorOpacity = 1
        boldIsBright = false
        backgroundOpacity = 1
        backgroundOpacityCells = false
    }

    /// The palette of a theme with `terminal.json` overrides. `background` is
    /// the pane card color the host wants under the terminal, when it differs
    /// from the theme's.
    public init(scheme: ColorScheme, options: TerminalOptions, dark: Bool, background: RGBColor? = nil) {
        self.init(dark: dark)
        if let color = background ?? scheme.background { self.background = color.value }
        if let color = scheme.foreground { foreground = color.value }
        for (index, color) in scheme.palette where (0..<256).contains(index) {
            colors[index] = color.value
        }
        cursorColor = scheme.cursorColor
        cursorText = scheme.cursorText
        selectionForeground = scheme.selectionForeground
        selectionBackground = scheme.selectionBackground
        apply(options)
    }

    /// Applies the user's overrides from `terminal.json`.
    public mutating func apply(_ options: TerminalOptions) {
        if let color = options.background { background = color.value }
        if let color = options.foreground { foreground = color.value }
        for (index, color) in options.palette where (0..<256).contains(index) {
            colors[index] = color.value
        }
        cursorColor = options.cursorColor ?? cursorColor
        cursorText = options.cursorText ?? cursorText
        selectionForeground = options.selectionForeground ?? selectionForeground
        selectionBackground = options.selectionBackground ?? selectionBackground
        cursorStyle = options.cursorStyle.map(Self.shape)
        cursorBlink = options.cursorBlink
        cursorOpacity = options.cursorOpacity
        boldIsBright = options.boldIsBright
        backgroundOpacity = options.backgroundOpacity ?? 1
        backgroundOpacityCells = options.backgroundOpacityCells
        cursor = cursorColor.map { resolveCell($0, foreground: foreground, background: self.background) } ?? foreground
    }

    /// Whether the terminal covers what is behind it.
    public var isOpaque: Bool { backgroundOpacity >= 1 }

    public func indexed(_ index: UInt8) -> UInt32 { colors[Int(index)] }

    public func resolve(_ color: Color, default fallback: UInt32) -> UInt32 {
        switch color {
        case .default: return fallback
        case .indexed(let index): return colors[Int(index)]
        case .rgb(let red, let green, let blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        }
    }

    /// The foreground and background a style draws with, after bright bold
    /// and inverse.
    public func style(_ style: Style) -> (foreground: UInt32, background: UInt32) {
        var fg = style.fg
        if style.bold, boldIsBright, case .indexed(let index) = fg, index < 8 {
            fg = .indexed(index + 8)
        }
        let foreground = resolve(fg, default: self.foreground)
        let background = resolve(style.bg, default: self.background)
        return style.inverse ? (background, foreground) : (foreground, background)
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

    static func shape(_ style: CursorStyle) -> CursorShape {
        switch style {
        case .block: return .block
        case .bar: return .bar
        case .underline: return .underline
        case .blockHollow: return .hollow
        }
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

extension CGColor {
    static func terminal(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}
