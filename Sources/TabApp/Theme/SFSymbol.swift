import AppKit

/// Loads SF Symbols, the source of every UI glyph in Tab.
enum SFSymbol {
    /// The named symbol rendered at `pointSize`. Nil only for a name SF Symbols lacks.
    static func image(_ name: String, pointSize: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(pointSize, 1), weight: .regular))
    }
}
