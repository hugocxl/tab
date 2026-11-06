import Observation
import TabShared
import UIKit

/// The person's terminal settings, kept in user defaults.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var fontSize: CGFloat {
        didSet { defaults.set(Double(fontSize), forKey: "terminal.fontSize") }
    }

    var darkTheme: String {
        didSet { defaults.set(darkTheme, forKey: "terminal.darkTheme"); schemes = [:] }
    }

    var lightTheme: String {
        didSet { defaults.set(lightTheme, forKey: "terminal.lightTheme"); schemes = [:] }
    }

    @ObservationIgnored private var schemes: [String: ColorScheme] = [:]

    private init() {
        let stored = defaults.double(forKey: "terminal.fontSize")
        fontSize = stored > 0 ? CGFloat(stored) : (UIDevice.current.userInterfaceIdiom == .pad ? 14 : 12)
        darkTheme = defaults.string(forKey: "terminal.darkTheme") ?? ThemeCatalog.defaultDark
        lightTheme = defaults.string(forKey: "terminal.lightTheme") ?? ThemeCatalog.defaultLight
    }

    /// The terminal colors for the appearance, read from the bundled theme file.
    func scheme(dark: Bool) -> ColorScheme {
        let name = dark ? darkTheme : lightTheme
        if let cached = schemes[name] { return cached }
        let fallback = dark ? ThemeCatalog.defaultDark : ThemeCatalog.defaultLight
        let scheme = [name, fallback].lazy.compactMap(Self.read).first ?? ColorScheme()
        schemes[name] = scheme
        return scheme
    }

    private static func read(_ name: String) -> ColorScheme? {
        guard let directory = ThemeCatalog.bundledDirectory,
              let source = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
            return nil
        }
        return ColorScheme.parse(source)
    }

    /// Every bundled theme name, for Settings.
    static let themeNames: [String] = {
        guard let directory = ThemeCatalog.bundledDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let own = [ThemeCatalog.defaultDark, ThemeCatalog.defaultLight]
        return own + names.filter { !$0.hasPrefix(".") && !own.contains($0) }.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }()
}
