import Foundation
import TabCore

/// A command-line AI tool that writes commit and pull request text. It runs
/// headless in the project folder with its tools turned off; callers own the
/// prompt and whatever happens with the answer.
public struct AIProvider: Hashable, Sendable, Identifiable {
    /// The id saved in `AISettings.providers`, such as `claude`.
    public let id: String
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    /// Every supported tool, in the order the first installed one is chosen.
    public static let all: [AIProvider] = [
        AIProvider(id: "claude", name: "Claude Code", executable: "claude", arguments: [
            "--print", "--output-format", "text", "--permission-mode", "dontAsk",
            "--no-session-persistence", "--tools=",
        ]),
        AIProvider(id: "codex", name: "Codex", executable: "codex", arguments: [
            "exec", "--ephemeral", "--sandbox", "read-only", "--color", "never",
        ]),
        AIProvider(id: "opencode", name: "OpenCode", executable: "opencode", arguments: ["run"],
                   environment: ["OPENCODE_PERMISSION": #"{"*":"deny"}"#]),
        AIProvider(id: "copilot", name: "GitHub Copilot", executable: "copilot", arguments: [
            "--silent", "--no-ask-user", "--available-tools=", "-p",
        ]),
        AIProvider(id: "cursor", name: "Cursor", executable: "cursor-agent", arguments: [
            "--print", "--output-format", "text",
        ]),
        AIProvider(id: "droid", name: "Droid", executable: "droid", arguments: ["exec", "--output-format", "text"]),
        AIProvider(id: "grok", name: "Grok", executable: "grok", arguments: [
            "--no-auto-update", "--sandbox", "workspace", "--permission-mode", "dontAsk", "--no-subagents",
            "--disable-web-search", "--output-format", "plain", "-p",
        ]),
        AIProvider(id: "kiro", name: "Kiro CLI", executable: "kiro-cli", arguments: [
            "chat", "--no-interactive", "--trust-tools=",
        ]),
        AIProvider(id: "pi", name: "Pi", executable: "pi", arguments: ["--print", "--no-session", "--no-tools"]),
        AIProvider(id: "xal", name: "Xal", executable: "xal", arguments: ["run", "--format", "text"]),
        AIProvider(id: "antigravity", name: "Antigravity", executable: "agy", arguments: [
            "--print", "--output-format", "text", "--mode=plan",
        ]),
        AIProvider(id: "omp", name: "Oh My Pi", executable: "omp", arguments: ["--print", "--no-session", "--no-tools"]),
    ]

    /// The most a prompt may be.
    public static let promptLimit = 256 * 1024
    /// The most a tool may print on each of stdout and stderr.
    public static let outputLimit = 256 * 1024
    /// How long a tool gets to answer.
    public static let timeout: TimeInterval = 300

    init(id: String, name: String, executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public static func provider(id: String) -> AIProvider? {
        all.first { $0.id == id }
    }

    /// The configured tool when it is installed, else the first installed one
    /// when nothing is configured.
    public static func selected(installed: [AIProvider], configured: String?) -> AIProvider? {
        guard let configured, !configured.isEmpty else { return installed.first }
        return installed.first { $0.id == configured }
    }

    /// The tool for `action` as settings choose it, or why there is none.
    public static func resolve(_ action: RepositoryAction, settings: AISettings,
                               installed: [AIProvider]) -> Result<AIProvider, AIActionError> {
        guard let id = settings.providers[action.key], !id.isEmpty else {
            guard let first = installed.first else {
                return .failure(AIActionError("Install a supported AI provider CLI or choose one in Settings → AI."))
            }
            return .success(first)
        }
        guard let provider = provider(id: id) else {
            return .failure(AIActionError(
                "The selected AI provider \"\(id)\" is no longer supported. Choose another one in Settings → AI."
            ))
        }
        guard installed.contains(provider) else {
            return .failure(AIActionError("\(provider.name) CLI is not installed. Choose another provider or install its CLI."))
        }
        return .success(provider)
    }

    // MARK: Finding the tools

    /// The tools found on the search path.
    public static func installed(search: [URL] = AIProviderSearch.paths()) -> [AIProvider] {
        all.filter { $0.executableURL(in: search) != nil }
    }

    /// Like `installed`, after reading the login shell's `PATH` once, so
    /// tools installed by version managers are found from a Finder launch.
    public static func discover() async -> [AIProvider] {
        await AIProviderSearch.loadLoginPath()
        return installed()
    }

    func executableURL(in search: [URL]) -> URL? {
        search.map { $0.appendingPathComponent(executable) }.first(where: Executable.isExecutableFile)
    }

    // MARK: Running

    /// Runs the tool in `directory` with `prompt` as its last argument and
    /// returns what it printed.
    public func generate(prompt: String, in directory: URL, cancellation: AICancellation = AICancellation()) throws -> String {
        guard prompt.utf8.count <= Self.promptLimit else {
            throw AIActionError("AI prompt exceeds the 256 KB limit")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AIActionError("The project directory isn't available on this Mac")
        }
        let search = AIProviderSearch.paths()
        guard let program = executableURL(in: search) else {
            throw AIActionError("\(name) CLI is not installed")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TAB_PANE_ID"] = nil
        environment["TAB_SESSION_ID"] = nil
        environment["PWD"] = directory.path
        environment["PATH"] = search.map(\.path).joined(separator: ":")
        environment.merge(self.environment) { _, new in new }
        let argument = prompt.hasPrefix("-") ? " \(prompt)" : prompt
        let output: BoundedProcess.Output
        do {
            output = try BoundedProcess.run(
                program: program.path, arguments: arguments + [argument], environment: environment,
                directory: directory.path, timeout: Self.timeout, limit: Self.outputLimit, cancellation: cancellation
            )
        } catch let failure as BoundedProcess.Failure {
            throw AIActionError(failure.describe(provider: name))
        }
        guard let text = String(data: output.stdout, encoding: .utf8) else {
            throw AIActionError("\(name) returned invalid UTF-8")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let detail = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AIActionError("\(name) returned an empty response: \(detail)")
        }
        return text
    }
}

/// Where AI tools are looked for: `PATH`, the usual per-user install
/// folders, Homebrew, and the login shell's `PATH`.
public enum AIProviderSearch {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginPath: [String]?

    public static func paths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = environment["HOME"], !home.isEmpty {
            for relative in [".local/bin", ".npm-global/bin", ".opencode/bin", ".factory/bin", ".cargo/bin", ".bun/bin"] {
                directories.append((home as NSString).appendingPathComponent(relative))
            }
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        directories += lock.withLock { loginPath } ?? []
        var seen = Set<String>()
        return directories.filter { $0.hasPrefix("/") && seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }

    /// Reads the login shell's `PATH` once; later calls return at once.
    static func loadLoginPath() async {
        if lock.withLock({ loginPath != nil }) { return }
        let path = await Task.detached(priority: .utility) { readLoginPath() }.value
        lock.withLock { if loginPath == nil { loginPath = path } }
    }

    private static func readLoginPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let start = "__TAB_PATH_START__"
        let end = "__TAB_PATH_END__"
        guard let output = try? BoundedProcess.run(
            program: shell, arguments: ["-l", "-i", "-c", "printf '\(start)%s\(end)' \"$PATH\""],
            environment: ProcessInfo.processInfo.environment, directory: NSHomeDirectory(),
            timeout: 5, limit: AIProvider.outputLimit, cancellation: AICancellation()
        ) else { return [] }
        let text = String(decoding: output.stdout, as: UTF8.self)
        guard let startRange = text.range(of: start, options: .backwards),
              let endRange = text.range(of: end, range: startRange.upperBound..<text.endIndex)
        else { return [] }
        return text[startRange.upperBound..<endRange.lowerBound].split(separator: ":").map(String.init)
    }
}

/// Stops a running tool from another thread.
public final class AICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }

    public var isCancelled: Bool { lock.withLock { cancelled } }
}

/// Why an AI action couldn't run, in words for the user.
public struct AIActionError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    public var message: String

    public init(_ message: String) { self.message = message }

    public var description: String { message }
    public var errorDescription: String? { message }
}
