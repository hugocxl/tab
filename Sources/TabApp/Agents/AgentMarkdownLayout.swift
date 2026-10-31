import Foundation

/// Chromium's positive CSS layout values are stored in 1/64-pixel units.
/// Preserve those fractions between native sections instead of rounding each block.
enum AgentMarkdownLayout {
    static func units(_ value: CGFloat) -> CGFloat { floor(value * 64) / 64 }
    static let blockGap = units(10.4)
    static let compactListGap = units(5.6)
}
