import Foundation

/// Terminal titles without spinners, emoji and icon glyphs, which agents and
/// prompts put in titles but which make sidebars jitter.
public enum TerminalTitle {
    /// The title with decorations removed and trimmed.
    public static func sanitize(_ title: String) -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.allSatisfy(\.isASCII) { return title }
        return String(title.filter { !isDecoration($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sanitize`, or `Terminal` when nothing is left.
    public static func sanitizeOrDefault(_ title: String) -> String {
        let title = sanitize(title)
        return title.isEmpty ? "Terminal" : title
    }

    /// What a terminal pane is called: the title the program set, else the
    /// running program (unless it is the shell), else the folder.
    public static func derive(
        _ title: String,
        processName: String? = nil,
        processIsShell: Bool = true,
        directory: String
    ) -> String {
        var title = Substring(title)
        if let processName, ["omp", "oh-my-pi"].contains(processName), title.hasPrefix("π "),
           !title.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty
        {
            title = title.dropFirst(2)
        }
        let sanitized = sanitize(String(title))
        if !sanitized.isEmpty { return sanitized }
        if let processName, !processIsShell {
            let name = sanitize(processName)
            if !name.isEmpty { return name }
        }
        let basename = directory.split(separator: "/").last.map(String.init) ?? directory
        return sanitizeOrDefault(basename)
    }

    private static let joiners: Set<UInt32> = [0x200D, 0xFE0E, 0xFE0F]

    /// Symbols, private-use icons, emoji, keycaps and stray joiners.
    static func isDecoration(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        if scalars.allSatisfy({ joiners.contains($0.value) || (0xE0020...0xE007F).contains($0.value) }) {
            return true
        }
        for (index, scalar) in scalars.enumerated() {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .otherSymbol, .privateUse: return true
            default: break
            }
            if properties.isEmojiPresentation || scalar.value == 0x20E3 { return true }
            if properties.isEmoji, index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F {
                return true
            }
        }
        return false
    }
}
