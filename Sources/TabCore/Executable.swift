import Foundation

/// Finds Tab's executables: `Tab`, `tabd` and `tab` live together in
/// `Tab.app/Contents/MacOS`, and beside each other in a build folder.
public enum Executable {
    public static let server = "tabd"
    public static let cli = "tab"
    public static let app = "Tab"

    /// The running executable with symbolic links resolved, so a CLI started
    /// through `~/.local/bin/tab` finds the bundle it points into.
    public static func currentURL() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            return Bundle.main.executableURL?.resolvingSymlinksInPath()
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    }

    /// The app bundle whose `Contents/MacOS` holds `executable`.
    public static func containingBundle(of executable: URL) -> URL? {
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return bundle.pathExtension == "app" ? bundle : nil
    }

    /// The executable named `name` beside the running one, else in the app
    /// bundle that holds it.
    public static func sibling(_ name: String, of executable: URL? = currentURL()) -> URL? {
        guard let executable else { return nil }
        var candidates = [executable.deletingLastPathComponent().appendingPathComponent(name)]
        if let bundle = containingBundle(of: executable) {
            candidates.append(bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(name))
        }
        return candidates.first { isExecutableFile($0) }
    }

    /// The server to start: `TAB_SERVER_BIN`, else `tabd` beside this program.
    public static func serverURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment["TAB_SERVER_BIN"] {
            guard !override.isEmpty else {
                throw ExecutableError.invalid("TAB_SERVER_BIN must not be empty")
            }
            return URL(fileURLWithPath: override)
        }
        guard let url = sibling(server) else {
            throw ExecutableError.notFound(server)
        }
        return url
    }

    /// Whether `url` is a regular file with an execute bit set.
    public static func isExecutableFile(_ url: URL) -> Bool {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && (info.st_mode & 0o111) != 0
    }

    /// Splits a command line the way a POSIX shell splits words, with single
    /// and double quotes and backslash escapes, without running anything.
    public static func commandArguments(_ source: String) throws -> [String] {
        if source.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw ExecutableError.invalid("Commands must not contain control characters")
        }
        var arguments: [String] = []
        var word = ""
        var started = false
        var quote: Character?
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            switch (quote, character) {
            case ("'", "'"), ("\"", "\""):
                quote = nil
            case (nil, "'"), (nil, "\""):
                quote = character
                started = true
            case (nil, "\\"), ("\"", "\\"):
                guard let escaped = iterator.next() else {
                    throw ExecutableError.invalid("Commands must not end with an unescaped backslash")
                }
                if quote == "\"" && !["\"", "\\", "$", "`"].contains(escaped) {
                    word.append("\\")
                }
                word.append(escaped)
                started = true
            case (nil, _) where character.isWhitespace:
                if started {
                    arguments.append(word)
                    word = ""
                    started = false
                }
            default:
                word.append(character)
                started = true
            }
        }
        if quote != nil { throw ExecutableError.invalid("Close the quote in the command") }
        if started { arguments.append(word) }
        guard let first = arguments.first, !first.isEmpty else {
            throw ExecutableError.invalid("Enter a command with a non-empty program name")
        }
        return arguments
    }
}

public enum ExecutableError: Error, Equatable, CustomStringConvertible {
    case invalid(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalid(let message): return message
        case .notFound(let name): return "\(name) was not found beside this program"
        }
    }
}
