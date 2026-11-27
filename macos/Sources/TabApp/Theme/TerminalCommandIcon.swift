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
}
