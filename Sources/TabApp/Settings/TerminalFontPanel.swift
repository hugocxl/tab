import AppKit
import TabCore

/// The system Fonts panel, choosing the terminal font's family, style and
/// size together.
@MainActor
final class TerminalFontPanel: NSObject, NSFontChanging {
    static let shared = TerminalFontPanel()

    private var font: NSFont?
    private var choose: ((_ family: String, _ style: String, _ size: Double) -> Void)?

    /// Opens the panel on `settings`' font; `choose` gets each pick.
    func show(_ settings: TerminalSettings, choose: @escaping (_ family: String, _ style: String, _ size: Double) -> Void) {
        let descriptor = NSFontDescriptor(fontAttributes: [.family: settings.fontFamily, .face: settings.fontStyle])
        let font = NSFont(descriptor: descriptor, size: settings.fontSize)
            ?? .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        self.font = font
        self.choose = choose
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(font, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let current = font, let manager = sender else { return }
        let picked = manager.convert(current)
        font = picked
        let family = picked.familyName ?? current.familyName ?? TerminalSettings.defaultFontFamily
        let style = (CTFontCopyName(picked, kCTFontStyleNameKey) as String?) ?? TerminalSettings.defaultFontStyle
        let size = min(max(Double(picked.pointSize).rounded(), TerminalSettings.fontSizeRange.lowerBound),
                       TerminalSettings.fontSizeRange.upperBound)
        choose?(family, style, size)
    }

    nonisolated func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection, .face, .size]
    }

    /// The styles of `family` without italics, such as Regular and Bold.
    static func styles(of family: String) -> [String] {
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        return members.compactMap { member in
            guard member.count > 3, let name = member[1] as? String, let traits = member[3] as? UInt else { return nil }
            return NSFontTraitMask(rawValue: traits).contains(.italicFontMask) ? nil : name
        }
    }

    /// Every font family, for fallbacks.
    static let families: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
}
