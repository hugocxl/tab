import AppKit

/// Loads SF Symbols, the only icon source in Tab.
enum SFSymbol {
    /// The named symbol rendered at `pointSize`, or its `.fill` variant when
    /// `filled` and SF Symbols has one. Nil only for a name SF Symbols lacks.
    static func image(_ name: String, filled: Bool = false, pointSize: CGFloat) -> NSImage? {
        let base = filled && !name.hasSuffix(".fill")
            ? NSImage(systemSymbolName: name + ".fill", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
            : NSImage(systemSymbolName: name, accessibilityDescription: nil)
        return base?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: max(pointSize, 1), weight: .regular))
    }
}
