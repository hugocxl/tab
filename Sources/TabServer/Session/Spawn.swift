import Foundation
import TabCore
import TabProtocol
import TabTerminal

/// Builds what a new session runs: the user's login shell with Tab's
/// environment.
enum SessionSpawn {
    static let fallbackShell = "/bin/zsh"

    /// The configured shell, else `$SHELL`, else zsh.
    static func shell(settings: ServerSettingsDoc, environment: [String: String]) -> String {
        if let shell = settings.defaultShell?.rawValue, !shell.isEmpty { return shell }
        if let shell = environment["SHELL"], shell.hasPrefix("/") { return shell }
        return fallbackShell
    }

    static func request(
        settings: ServerSettingsDoc, integration: ShellIntegration?, directory: String, size: Size,
        command: String?, extra: [String: String], server: ServerId, session: SessionId,
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> SpawnRequest {
        let shell = shell(settings: settings, environment: inherited)
        var environment = Self.environment(inherited: inherited, extra: extra, server: server, session: session)
        environment["SHELL"] = shell
        integration?.configure(&environment, shell: shell, enabled: settings.shellIntegration)
        var arguments = ["-l"]
        if let command { arguments += ["-c", command] }
        return SpawnRequest(program: shell, arguments: arguments, environment: environment,
                            workingDirectory: directory, size: size)
    }

    /// The server's environment, `extra` (such as a proxy) replacing what it
    /// names, then Tab's own variables, which nothing replaces.
    static func environment(inherited: [String: String], extra: [String: String], server: ServerId,
                            session: SessionId) -> [String: String] {
        var environment = inherited
        for key in ["TAB_SHELL_INTEGRATION", "TAB_SHELL_INTEGRATION_DIR", "TAB_ZDOTDIR_SET", "TAB_ORIGINAL_ZDOTDIR"] {
            environment[key] = nil
        }
        for (key, value) in extra { environment[key] = value }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "tab"
        environment["TERM_PROGRAM_VERSION"] = Release.version
        environment["TAB_SERVER_ID"] = server.description
        environment["TAB_SESSION_ID"] = session.description
        applyUTF8Locale(&environment)
        return environment
    }

    private static let localeKeys = ["LC_ALL", "LC_CTYPE", "LANG"]
    static let fallbackLocale = "C.UTF-8"

    /// Sets a UTF-8 `LANG` when no locale variable is set, from the system's
    /// language and region when that locale is installed.
    static func applyUTF8Locale(_ environment: inout [String: String],
                                system: String? = Locale.current.identifier,
                                installed: (String) -> Bool = localeInstalled) {
        let blank = { (value: String?) in value?.trimmingCharacters(in: .whitespaces).isEmpty ?? true }
        guard localeKeys.allSatisfy({ blank(environment[$0]) }) else { return }
        let candidates = [system.flatMap(languageAndRegion).map { "\($0).UTF-8" }, fallbackLocale].compactMap { $0 }
        guard let locale = candidates.first(where: installed) else { return }
        for key in localeKeys where environment[key] != nil { environment[key] = "" }
        environment["LANG"] = locale
    }

    /// `zh-Hant_CN` is `zh_CN`; `en_US@rg=eszzzz` is `en_US`.
    static func languageAndRegion(_ identifier: String) -> String? {
        let head = identifier.split(whereSeparator: { $0 == "@" || $0 == "." }).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let subtags = head.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = subtags.first,
              let region = subtags.dropFirst().first(where: { !($0.count == 4 && $0.allSatisfy(\.isLetter)) }),
              (2...3).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }),
              (2...3).contains(region.count), region.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return nil }
        return "\(language)_\(region)"
    }

    static func localeInstalled(_ name: String) -> Bool {
        guard !name.contains("/"), !name.contains("\0") else { return false }
        return FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)")
    }
}
