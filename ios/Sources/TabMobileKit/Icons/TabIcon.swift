import TabProtocol

/// Tab icons by their IconsCXL resource names. The two view-mode icons still
/// ship in the app catalog. Mirrors `AppIcon` in Tab: keep cases and hues in step.
public enum TabIcon: String, CaseIterable, Sendable {
    case agents
    case antigravity
    case appWindow = "app-window"
    case arrowDown = "arrow-down"
    case arrowUp = "arrow-up"
    case astro
    case babel
    case ban
    case bash
    case bellUnread = "bell-unread"
    case biome
    case bitbucket
    case bootstrap
    case braces
    case brain
    case browserslist
    case bun
    case c
    case check
    case checkbox
    case checkboxFill = "checkbox-fill"
    case chevronDown = "chevron-down"
    case chevronLeft = "chevron-left"
    case chevronRight = "chevron-right"
    case chevronUp = "chevron-up"
    case chevronsIn = "chevrons-in"
    case chevronsUpDown = "chevrons-up-down"
    case circle
    case circleCheck = "circle-check"
    case circleCheckFill = "circle-check-fill"
    case circleUser = "circle-user"
    case circleXFill = "circle-x-fill"
    case claude
    case close
    case code
    case codeBlock = "code-block"
    case codex
    case columns
    case command
    case commentText = "comment-text"
    case conversation
    case conversationAdd = "conversation-add"
    case copilot
    case copy
    case cpp
    case cpu
    case csharp
    case css
    case cursor
    case dart
    case database
    case deno
    case diff
    case docker
    case dot
    case download
    case downloadCircleFill = "download-circle-fill"
    case droid
    case elixir
    case ellipsis
    case ellipsisCircle = "ellipsis-circle"
    case envelope
    case epub
    case eraser
    case eslint
    case exclamationCircleFill = "exclamation-circle-fill"
    case extensions = "extension"
    case externalLink = "external-link"
    case eye
    case file
    case filePlus = "file-plus"
    case fileSymlink = "file-symlink"
    case fileTable = "file-table"
    case fileText = "file-text"
    case foldVertical = "fold-vertical"
    case folder
    case folderOpen = "folder-open"
    case folderPlus = "folder-plus"
    case folderZip = "folder-zip"
    case folders
    case font
    case forgejo
    case gaugeHigh = "gauge-high"
    case gaugeLow = "gauge-low"
    case gaugeMax = "gauge-max"
    case gaugeMedium = "gauge-medium"
    case git
    case gitBranch = "git-branch"
    case gitcafe
    case github
    case gitlab
    case globe
    case go
    case graphql
    case grok
    case hand
    case hash
    case haskell
    case history
    case homebrew
    case html
    case image
    case info
    case infoFill = "info-fill"
    case java
    case javascript
    case kiro
    case kotlin
    case kubernetes
    case laptop
    case layers
    case lightbulb
    case listTodo = "list-todo"
    case lock
    case lockOpen = "lock-open"
    case logs
    case lua
    case markdown
    case maximize
    case mcp
    case microphone
    case minus
    case minusCircle = "minus-circle"
    case monitor
    case multiplexer
    case network
    case nextjs
    case node
    case npm
    case objc
    case octagonAlert = "octagon-alert"
    case ohMyPi = "oh-my-pi"
    case opencode
    case oxc
    case panelLeft = "panel-left"
    case panelRight = "panel-right"
    case paperclip
    case pauseCircleFill = "pause-circle-fill"
    case pdf
    case pencil
    case phone
    case phoneAndroid = "phone-android"
    case php
    case pi
    case play
    case plus
    case pnpm
    case postcss
    case powershell
    case prettier
    case python
    case quote
    case r
    case react
    case refresh
    case refreshCircleFill = "refresh-circle-fill"
    case reset
    case rows
    case rss
    case ruby
    case rust
    case sass
    case scala
    case search
    case serverRack = "server-rack"
    case settings
    case shield
    case shieldKeyhole = "shield-keyhole"
    case slides
    case sparkles
    case spinner
    case spreadsheet
    case ssh
    case stop
    case stylelint
    case svelte
    case svg
    case svgo
    case swift
    case tablet
    case tailwind
    case terminal
    case terminalStack = "terminal-stack"
    case terraform
    case themes
    case toml
    case trash
    case triangleAlert = "triangle-alert"
    case triangleAlertFill = "triangle-alert-fill"
    case typescript
    case video
    case viewList = "view-list"
    case viewTree = "view-tree"
    case vim
    case vite
    case vscode
    case vue
    case wasm
    case waveform
    case webpack
    case word
    case wrap
    case wrench
    case xal
    case xml
    case yarn
    case yml
    case zig
    case zip
    case zoomIn = "zoom-in"
    /// The browser and simulator pane kinds' two-tone marks, beside `bash`
    /// and `codeBlock` in the sidebar.
    case browser, simulator

    /// Hues for the set's colorful marks, as Tab's themes draw them.
    public enum Hue: String, CaseIterable, Sendable {
        case gray, red, vermilion, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown
    }

    public static let signatureHues: [TabIcon: Hue] = [
        .agents: .orange,
        .browser: .blue,
        .codeBlock: .indigo,
        .simulator: .purple,
        .antigravity: .blue,
        .astro: .purple,
        .babel: .yellow,
        .bash: .green,
        .biome: .blue,
        .bitbucket: .blue,
        .bootstrap: .indigo,
        .braces: .gray,
        .brain: .gray,
        .browserslist: .yellow,
        .bun: .brown,
        .c: .blue,
        .claude: .orange,
        .codex: .gray,
        .copilot: .gray,
        .cpp: .blue,
        .csharp: .purple,
        .css: .indigo,
        .cursor: .gray,
        .dart: .cyan,
        .database: .gray,
        .deno: .gray,
        .diff: .green,
        .docker: .blue,
        .dot: .gray,
        .droid: .orange,
        .elixir: .purple,
        .epub: .orange,
        .eslint: .indigo,
        .file: .gray,
        .fileSymlink: .gray,
        .fileTable: .gray,
        .fileText: .gray,
        .folder: .gray,
        .folderOpen: .gray,
        .font: .gray,
        .forgejo: .orange,
        .git: .vermilion,
        .gitcafe: .brown,
        .github: .gray,
        .gitlab: .orange,
        .go: .cyan,
        .graphql: .pink,
        .grok: .gray,
        .haskell: .indigo,
        .homebrew: .yellow,
        .html: .orange,
        .image: .gray,
        .java: .orange,
        .javascript: .yellow,
        .kiro: .purple,
        .kotlin: .purple,
        .kubernetes: .blue,
        .lock: .gray,
        .lua: .blue,
        .markdown: .gray,
        .mcp: .gray,
        .nextjs: .gray,
        .node: .green,
        .npm: .red,
        .objc: .vermilion,
        .ohMyPi: .purple,
        .opencode: .gray,
        .oxc: .cyan,
        .pdf: .red,
        .php: .indigo,
        .pi: .purple,
        .pnpm: .orange,
        .postcss: .red,
        .powershell: .blue,
        .prettier: .teal,
        .python: .blue,
        .r: .blue,
        .react: .cyan,
        .ruby: .red,
        .rust: .orange,
        .sass: .pink,
        .scala: .red,
        .slides: .orange,
        .spreadsheet: .green,
        .stylelint: .gray,
        .svelte: .red,
        .svg: .orange,
        .svgo: .green,
        .swift: .orange,
        .tailwind: .cyan,
        .terraform: .indigo,
        .toml: .gray,
        .typescript: .blue,
        .video: .pink,
        .vim: .green,
        .vite: .purple,
        .vscode: .blue,
        .vue: .green,
        .wasm: .indigo,
        .webpack: .blue,
        .word: .blue,
        .xal: .blue,
        .xml: .orange,
        .yarn: .blue,
        .yml: .red,
        .zig: .orange,
        .zip: .gray,
    ]

    /// The hue this mark always uses, or nil for a UI glyph its surroundings tint.
    public var signatureHue: Hue? { Self.signatureHues[self] }

    /// The provider's mark, or a generic one for an agent Tab doesn't know.
    public static func agent(_ provider: AgentProvider) -> TabIcon {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        case .openCode: .opencode
        case .cursor: .cursor
        case .copilot: .copilot
        case .droid: .droid
        case .pi: .pi
        case .grok: .grok
        case .kiro: .kiro
        case .xal: .xal
        case .antigravity: .antigravity
        case .ohMyPi: .ohMyPi
        case .unknown: .brain
        }
    }

    /// A terminal's mark for its foreground executable, as Tab's sidebar
    /// shows it: a shell, a known command's brand or tool, else a terminal.
    public static func command(_ process: ForegroundProcess?) -> TabIcon {
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

    /// A file's mark by its name: exact names first, then its longest
    /// extension, with Tab's overrides winning within each.
    public static func file(_ path: String) -> TabIcon {
        let name = String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? "").lowercased()
        if let icon = overrideNames[name] ?? fileNames[name] { return icon }
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        // Each suffix starts one component later, so multi-part extensions win.
        let suffixes = components.indices.dropFirst().map { components[$0...].joined(separator: ".") }
        for suffix in suffixes {
            if let icon = overrideExtensions[suffix] { return icon }
        }
        for suffix in suffixes {
            if let icon = fileExtensions[suffix] { return icon }
        }
        return .file
    }

    private static let byProcessName: [String: TabIcon] = [
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

    private static let fileNames: [String: TabIcon] = [
        ".babelrc": .babel,
        ".babelrc.json": .babel,
        ".bash_profile": .bash,
        ".bashrc": .bash,
        ".browserslistrc": .browserslist,
        ".dockerignore": .docker,
        ".eslintignore": .eslint,
        ".eslintrc": .eslint,
        ".eslintrc.cjs": .eslint,
        ".eslintrc.js": .eslint,
        ".eslintrc.json": .eslint,
        ".eslintrc.yaml": .eslint,
        ".eslintrc.yml": .eslint,
        ".gitattributes": .git,
        ".gitignore": .git,
        ".gitkeep": .git,
        ".gitmodules": .git,
        ".npmignore": .npm,
        ".npmrc": .npm,
        ".oxlintrc.json": .oxc,
        ".postcssrc": .postcss,
        ".postcssrc.json": .postcss,
        ".postcssrc.yaml": .postcss,
        ".postcssrc.yml": .postcss,
        ".prettierignore": .prettier,
        ".prettierrc": .prettier,
        ".prettierrc.cjs": .prettier,
        ".prettierrc.js": .prettier,
        ".prettierrc.json": .prettier,
        ".prettierrc.mjs": .prettier,
        ".prettierrc.toml": .prettier,
        ".prettierrc.yaml": .prettier,
        ".prettierrc.yml": .prettier,
        ".stylelintignore": .stylelint,
        ".stylelintrc": .stylelint,
        ".stylelintrc.cjs": .stylelint,
        ".stylelintrc.js": .stylelint,
        ".stylelintrc.json": .stylelint,
        ".stylelintrc.mjs": .stylelint,
        ".stylelintrc.yaml": .stylelint,
        ".stylelintrc.yml": .stylelint,
        ".terraform.lock.hcl": .terraform,
        ".yarnrc": .yarn,
        ".yarnrc.yml": .yarn,
        ".zprofile": .bash,
        ".zshenv": .bash,
        ".zshrc": .bash,
        "agents.md": .agents,
        "babel.config.cjs": .babel,
        "babel.config.js": .babel,
        "babel.config.json": .babel,
        "babel.config.mjs": .babel,
        "biome.json": .biome,
        "biome.jsonc": .biome,
        "bootstrap.bundle.js": .bootstrap,
        "bootstrap.bundle.min.js": .bootstrap,
        "bootstrap.css": .bootstrap,
        "bootstrap.js": .bootstrap,
        "bootstrap.min.css": .bootstrap,
        "bootstrap.min.js": .bootstrap,
        "bun.lock": .bun,
        "bun.lockb": .bun,
        "bunfig.toml": .bun,
        "claude.md": .claude,
        "compose.yaml": .docker,
        "compose.yml": .docker,
        "docker-compose.override.yml": .docker,
        "docker-compose.yaml": .docker,
        "docker-compose.yml": .docker,
        "dockerfile": .docker,
        "eslint.config.cjs": .eslint,
        "eslint.config.js": .eslint,
        "eslint.config.mjs": .eslint,
        "eslint.config.mts": .eslint,
        "eslint.config.ts": .eslint,
        "gemfile": .ruby,
        "next.config.js": .nextjs,
        "next.config.mjs": .nextjs,
        "next.config.mts": .nextjs,
        "next.config.ts": .nextjs,
        "package-lock.json": .npm,
        "package.json": .npm,
        "pnpm-lock.yaml": .pnpm,
        "pnpm-workspace.yaml": .pnpm,
        "postcss.config.cjs": .postcss,
        "postcss.config.js": .postcss,
        "postcss.config.mjs": .postcss,
        "postcss.config.ts": .postcss,
        "prettier.config.cjs": .prettier,
        "prettier.config.js": .prettier,
        "prettier.config.mjs": .prettier,
        "rakefile": .ruby,
        "readme.md": .markdown,
        "stylelint.config.cjs": .stylelint,
        "stylelint.config.js": .stylelint,
        "stylelint.config.mjs": .stylelint,
        "svgo.config.cjs": .svgo,
        "svgo.config.js": .svgo,
        "svgo.config.mjs": .svgo,
        "svgo.config.ts": .svgo,
        "tailwind.config.cjs": .tailwind,
        "tailwind.config.js": .tailwind,
        "tailwind.config.mjs": .tailwind,
        "tailwind.config.ts": .tailwind,
        "tsconfig.json": .typescript,
        "vite.config.js": .vite,
        "vite.config.mjs": .vite,
        "vite.config.mts": .vite,
        "vite.config.ts": .vite,
        "webpack.config.babel.js": .webpack,
        "webpack.config.cjs": .webpack,
        "webpack.config.js": .webpack,
        "webpack.config.mjs": .webpack,
        "webpack.config.ts": .webpack,
        "yarn.lock": .yarn,
    ]

    private static let fileExtensions: [String: TabIcon] = [
        "7z": .zip,
        "astro": .astro,
        "authors": .fileText,
        "avi": .video,
        "avif": .image,
        "bash": .bash,
        "bmp": .image,
        "bz2": .zip,
        "c": .c,
        "cc": .cpp,
        "cfg": .fileText,
        "changelog": .fileText,
        "cjs": .javascript,
        "code-workspace": .vscode,
        "conf": .fileText,
        "contributors": .fileText,
        "cpp": .cpp,
        "cs": .csharp,
        "csh": .bash,
        "css": .css,
        "csv": .fileTable,
        "csx": .csharp,
        "cts": .typescript,
        "cxx": .cpp,
        "dart": .dart,
        "db": .database,
        "diff": .diff,
        "doc": .word,
        "docx": .word,
        "editorconfig": .fileText,
        "env": .fileText,
        "env.development": .fileText,
        "env.local": .fileText,
        "env.production": .fileText,
        "eot": .font,
        "epub": .epub,
        "erb": .ruby,
        "ex": .elixir,
        "exs": .elixir,
        "fish": .bash,
        "gemspec": .ruby,
        "gif": .image,
        "go": .go,
        "gql": .graphql,
        "graphql": .graphql,
        "gz": .zip,
        "h": .c,
        "heic": .image,
        "heif": .image,
        "hh": .cpp,
        "hpp": .cpp,
        "hs": .haskell,
        "htm": .html,
        "html": .html,
        "hxx": .cpp,
        "icns": .image,
        "ico": .image,
        "ini": .fileText,
        "inl": .cpp,
        "jar": .zip,
        "java": .java,
        "jpeg": .image,
        "jpg": .image,
        "js": .javascript,
        "json": .braces,
        "json5": .braces,
        "jsonc": .braces,
        "jsonl": .braces,
        "jsx": .react,
        "ksh": .bash,
        "kt": .kotlin,
        "kts": .kotlin,
        "less": .css,
        "lhs": .haskell,
        "license": .fileText,
        "log": .fileText,
        "lua": .lua,
        "luau": .lua,
        "m": .objc,
        "m4v": .video,
        "markdown": .markdown,
        "mcp": .mcp,
        "md": .markdown,
        "mdx": .markdown,
        "mdx.tsx": .markdown,
        "mjs": .javascript,
        "mkv": .video,
        "mm": .objc,
        "mov": .video,
        "mp4": .video,
        "mts": .typescript,
        "odp": .slides,
        "ods": .fileTable,
        "odt": .word,
        "ogv": .video,
        "otf": .font,
        "patch": .diff,
        "pdf": .pdf,
        "php": .php,
        "png": .image,
        "postcss": .css,
        "ppt": .slides,
        "pptx": .slides,
        "ps1": .powershell,
        "psd1": .powershell,
        "psm1": .powershell,
        "py": .python,
        "pyi": .python,
        "pyw": .python,
        "pyx": .python,
        "r": .r,
        "rake": .ruby,
        "rar": .zip,
        "rb": .ruby,
        "rs": .rust,
        "rst": .fileText,
        "rtf": .fileText,
        "sass": .sass,
        "scala": .scala,
        "scss": .sass,
        "sh": .bash,
        "sql": .database,
        "sqlite": .database,
        "sqlite3": .database,
        "styl": .css,
        "svelte": .svelte,
        "svg": .svg,
        "swift": .swift,
        "tar": .zip,
        "tf": .terraform,
        "tfstate": .terraform,
        "tfvars": .terraform,
        "tgz": .zip,
        "tif": .image,
        "tiff": .image,
        "toml": .toml,
        "ts": .typescript,
        "tsv": .fileTable,
        "tsx": .react,
        "ttf": .font,
        "txt": .fileText,
        "vue": .vue,
        "war": .zip,
        "wasm": .wasm,
        "wast": .wasm,
        "wat": .wasm,
        "webm": .video,
        "webp": .image,
        "woff": .font,
        "woff2": .font,
        "xhtml": .html,
        "xls": .fileTable,
        "xlsx": .fileTable,
        "xml": .xml,
        "xsd": .xml,
        "xsl": .xml,
        "xslt": .xml,
        "xz": .zip,
        "yaml": .yml,
        "yml": .yml,
        "zig": .zig,
        "zip": .zip,
        "zsh": .bash,
    ]

    private static let overrideNames: [String: TabIcon] = [
        "agents.md": .agents,
        "package.json": .npm,
        "pnpm-lock.yaml": .pnpm,
        "pnpm-workspace.yaml": .pnpm,
        "tsconfig.json": .typescript,
    ]

    private static let overrideExtensions: [String: TabIcon] = [
        "avi": .video,
        "cs": .csharp,
        "csx": .csharp,
        "dart": .dart,
        "diff": .diff,
        "doc": .word,
        "docx": .word,
        "epub": .epub,
        "ex": .elixir,
        "exs": .elixir,
        "heic": .image,
        "heif": .image,
        "hs": .haskell,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "lhs": .haskell,
        "lua": .lua,
        "luau": .lua,
        "m4v": .video,
        "mkv": .video,
        "mov": .video,
        "mp4": .video,
        "odp": .slides,
        "odt": .word,
        "ogv": .video,
        "patch": .diff,
        "pdf": .pdf,
        "php": .php,
        "ppt": .slides,
        "pptx": .slides,
        "ps1": .powershell,
        "psd1": .powershell,
        "psm1": .powershell,
        "r": .r,
        "scala": .scala,
        "toml": .toml,
        "webm": .video,
        "xml": .xml,
        "xsd": .xml,
        "xsl": .xml,
        "xslt": .xml,
    ]
}
