import TabProtocol

/// Sidebar icons for foreground executables, independent of terminal titles.
enum TerminalCommandIcon {
    static func icon(for process: ForegroundProcess?) -> AppIcon {
        guard let process, !process.isShell else { return .bash }
        var name = String(process.name.split(separator: "/").last ?? "").lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        if let icon = byProcessName[name] { return icon }

        // Match only numeric version suffixes, keeping command names exact.
        for index in name.indices.reversed() where name[index].isASCII && name[index].isNumber {
            let version = name[index...].split(separator: ".", omittingEmptySubsequences: false)
            guard version.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { continue }
            var base = name[..<index]
            if base.last == "-" || base.last == "." { base = base.dropLast() }
            if let icon = byProcessName[String(base)] { return icon }
        }
        return .terminal
    }

    private static let byProcessName: [String: AppIcon] = [
        "node": .node, "nodemon": .node, "tsx": .node, "ts-node": .node,
        "npm": .npm, "npx": .npm,
        "pnpm": .pnpm, "pnpx": .pnpm,
        "yarn": .yarn,
        "bun": .bun, "bunx": .bun,
        "deno": .deno,
        "python": .python, "python3": .python, "pip": .python, "pip3": .python,
        "uv": .python, "poetry": .python, "pytest": .python,
        "ruby": .ruby, "bundle": .ruby, "rake": .ruby, "gem": .ruby, "rails": .ruby,
        "cargo": .rust, "rustc": .rust, "rustup": .rust,
        "go": .go, "gopls": .go,
        "swift": .swift, "swiftc": .swift, "xcodebuild": .swift, "xcrun": .swift,
        "docker": .docker, "docker-compose": .docker, "podman": .docker,
        "git": .git, "gh": .git, "lazygit": .git, "tig": .git,
        "vim": .vim, "nvim": .vim, "vi": .vim,
        "nano": .pencil, "micro": .pencil, "emacs": .pencil, "hx": .pencil,
        "ssh": .ssh, "mosh": .ssh, "scp": .ssh, "sftp": .ssh,
        "make": .wrench, "cmake": .wrench, "ninja": .wrench, "bazel": .wrench, "just": .wrench,
        "java": .java, "gradle": .java, "gradlew": .java, "mvn": .java, "kotlin": .java, "kotlinc": .java,
        "php": .php, "composer": .php, "artisan": .php,
        "htop": .monitor, "top": .monitor, "btop": .monitor, "glances": .monitor,
        "tail": .logs, "less": .logs, "more": .logs, "man": .logs, "bat": .logs, "journalctl": .logs,
        "curl": .download, "wget": .download, "aria2c": .download,
        "psql": .database, "mysql": .database, "sqlite3": .database, "redis-cli": .database,
        "mongosh": .database, "duckdb": .database,
        "kubectl": .kubernetes, "helm": .kubernetes, "k9s": .kubernetes, "minikube": .kubernetes,
        "terraform": .terraform, "tofu": .terraform,
        "brew": .homebrew,
        "tmux": .multiplexer, "screen": .multiplexer, "zellij": .multiplexer,
        "rg": .search, "grep": .search, "fzf": .search, "fd": .search,
        "zsh": .bash, "bash": .bash, "fish": .bash, "sh": .bash,
        "dash": .bash, "nu": .bash, "pwsh": .bash, "login": .bash,
    ]

    /// Resolves a colored sidebar icon for a background shell subtask from its
    /// command line (falling back to its title when an older server omits the
    /// command). Recognizes agent CLIs, known tools, and script files.
    @MainActor
    static func subtaskIcon(command: String?, title: String) -> ActivityCardData.PaneRow.Icon {
        if let command, let resolved = commandLineIcon(for: command) { return resolved }
        if command == nil, let resolved = commandLineIcon(for: title) { return resolved }
        return .kind(.terminal)
    }

    @MainActor
    static func commandLineIcon(for commandLine: String) -> ActivityCardData.PaneRow.Icon? {
        guard let executable = primaryExecutable(in: commandLine) else { return nil }
        var name = String(executable.split(separator: "/").last ?? "").lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        if let provider = agentProviders[name] { return .agent(provider) }
        let matched = icon(for: ForegroundProcess(name: executable, isShell: false))
        if matched != .terminal { return .command(matched) }
        let basename = String(executable.split(separator: "/").last ?? "")
        if !basename.isEmpty, FileIcon.hasSpecificIcon(for: basename) { return .file(basename) }
        return nil
    }

    /// Extracts the main executable from a shell command line, skipping
    /// setup segments (`cd`, `export`, `set`, `unset`), env assignments,
    /// common wrappers (`env`, `nohup`, `time`, `exec`, `sudo`, `timeout`),
    /// and unwrapping `sh -c "..."`.
    static func primaryExecutable(in commandLine: String, depth: Int = 0) -> String? {
        guard depth < 3 else { return nil }
        for segment in splitSegments(commandLine) {
            let tokens = tokenize(segment)
            guard !tokens.isEmpty else { continue }
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if isEnvAssignment(token) { index += 1; continue }
                let lower = basenameLower(token)
                if lower == "env" {
                    index += 1
                    while index < tokens.count, tokens[index].hasPrefix("-") || isEnvAssignment(tokens[index]) {
                        index += 1
                    }
                    continue
                }
                if ["nohup", "time", "exec", "command", "nice", "caffeinate"].contains(lower) {
                    index += 1
                    while index < tokens.count, tokens[index].hasPrefix("-") { index += 1 }
                    continue
                }
                if lower == "sudo" {
                    index += 1
                    while index < tokens.count, tokens[index].hasPrefix("-") {
                        let flag = tokens[index]
                        index += 1
                        if ["-u", "-g", "-C", "-h", "-p"].contains(flag), index < tokens.count { index += 1 }
                    }
                    continue
                }
                if lower == "timeout" {
                    index += 1
                    while index < tokens.count, tokens[index].hasPrefix("-") { index += 1 }
                    if index < tokens.count { index += 1 } // duration argument
                    continue
                }
                if ["cd", "pushd", "export", "set", "unset"].contains(lower) {
                    index = tokens.count
                    break
                }
                // Unwrap `sh -c "<inner>"` / `bash -lc "<inner>"` to inspect the real command.
                if ["sh", "bash", "zsh", "fish", "dash"].contains(lower),
                   index + 2 < tokens.count,
                   tokens[index + 1].hasPrefix("-"), tokens[index + 1].contains("c"),
                   let inner = primaryExecutable(in: tokens[index + 2], depth: depth + 1) {
                    return inner
                }
                return token
            }
        }
        return nil
    }

    private static let agentProviders: [String: AgentProvider] = [
        "claude": .claude,
        "codex": .codex,
        "opencode": .openCode,
        "cursor-agent": .cursor,
        "copilot": .copilot,
        "droid": .droid,
        "pi": .pi,
        "grok": .grok,
        "kiro": .kiro, "kiro-cli": .kiro,
        "gemini": .gemini,
        "omp": .ohMyPi,
    ]

    private static func basenameLower(_ token: String) -> String {
        var name = String(token.split(separator: "/").last ?? "").lowercased()
        if name.hasPrefix("-") { name.removeFirst() }
        return name
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq > token.startIndex else { return false }
        let name = token[..<eq]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? true)
    }

    /// Splits a command line on top-level `&&`, `||`, `;`, `|` outside quotes.
    private static func splitSegments(_ input: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if escaped {
                current.append(ch)
                escaped = false
                i = input.index(after: i)
                continue
            }
            if ch == "\\", quote != "'" {
                current.append(ch)
                escaped = true
                i = input.index(after: i)
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                i = input.index(after: i)
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                i = input.index(after: i)
                continue
            }
            let next = input.index(after: i)
            if ch == ";" {
                segments.append(current)
                current = ""
                i = next
                continue
            }
            if (ch == "&" || ch == "|"), next < input.endIndex, input[next] == ch {
                segments.append(current)
                current = ""
                i = input.index(after: next)
                continue
            }
            if ch == "|" {
                segments.append(current)
                current = ""
                i = next
                continue
            }
            current.append(ch)
            i = next
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Splits a segment into shell tokens, unquoting single/double quotes.
    private static func tokenize(_ segment: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in segment {
            if escaped {
                current.append(ch)
                inToken = true
                escaped = false
                continue
            }
            if ch == "\\", quote != "'" {
                escaped = true
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                inToken = true
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                inToken = true
                continue
            }
            if ch.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
                continue
            }
            current.append(ch)
            inToken = true
        }
        if inToken { tokens.append(current) }
        return tokens
    }
}
