import XCTest
import TabProtocol
@testable import TabApp

final class TerminalCommandIconTests: XCTestCase {
    func testCommandFamilies() {
        let families: [(AppIcon, String)] = [
            (.node, "node nodemon tsx ts-node"), (.npm, "npm npx"), (.pnpm, "pnpm pnpx"),
            (.yarn, "yarn"), (.bun, "bun bunx"), (.deno, "deno"),
            (.python, "python python3 pip pip3 uv poetry pytest"),
            (.ruby, "ruby bundle rake gem rails"), (.rust, "cargo rustc rustup"), (.go, "go gopls"),
            (.swift, "swift swiftc xcodebuild xcrun"), (.docker, "docker docker-compose podman"),
            (.git, "git gh lazygit tig"), (.vim, "vim nvim vi"), (.pencil, "nano micro emacs hx"),
            (.ssh, "ssh mosh scp sftp"), (.wrench, "make cmake ninja bazel just"),
            (.java, "java gradle gradlew mvn kotlin kotlinc"), (.php, "php composer artisan"),
            (.monitor, "htop top btop glances"), (.logs, "tail less more man bat journalctl"),
            (.download, "curl wget aria2c"), (.database, "psql mysql sqlite3 redis-cli mongosh duckdb"),
            (.kubernetes, "kubectl helm k9s minikube"), (.terraform, "terraform tofu"),
            (.homebrew, "brew"), (.multiplexer, "tmux screen zellij"), (.search, "rg grep fzf fd"),
            (.bash, "zsh bash fish sh dash nu pwsh login"),
        ]
        for (expected, names) in families {
            for name in names.split(separator: " ") {
                XCTAssertEqual(icon(String(name)), expected, String(name))
            }
        }
    }

    func testExecutablePathsCaseAndNumericVersions() {
        let examples: [(String, AppIcon)] = [
            ("/opt/homebrew/bin/NODE", .node), ("/usr/bin/PYTHON3.12", .python),
            ("pip3.12", .python), ("ruby3.3", .ruby), ("node22", .node),
            ("java-21", .java), ("/opt/bin/php8.4", .php), ("sqlite3.45", .database),
            ("ts-node", .node), ("/bin/-ZSH", .bash), ("-bash", .bash),
        ]
        for (name, expected) in examples {
            XCTAssertEqual(icon(name), expected, name)
        }
    }

    func testShellMetadataAndUnknownCommands() {
        XCTAssertEqual(TerminalCommandIcon.icon(for: nil), .bash)
        XCTAssertEqual(TerminalCommandIcon.icon(for: ForegroundProcess(name: "custom-shell", isShell: true)), .bash)
        XCTAssertEqual(TerminalCommandIcon.icon(for: ForegroundProcess(name: "node", isShell: true)), .bash)
        for name in ["", "custom-program", "node-server", "pythonista", "python3.12rc1", "python3..12", "npm run dev", "claude", "codex"] {
            XCTAssertEqual(icon(name), .terminal, name)
        }
    }

    @MainActor
    func testSubtaskCommandLineIcons() {
        // Direct tools and runtimes
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "swift test --filter TabCoreTests", title: "Run tests"), .command(.swift))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "npm run dev", title: "Dev server"), .command(.npm))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "python3 train.py", title: "Train"), .command(.python))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "cargo build --release", title: "Build"), .command(.rust))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "docker compose up", title: "Services"), .command(.docker))

        // Scripts by file extension
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "scripts/validate.sh", title: "Run full validation"), .file("validate.sh"))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "./deploy.py --dry-run", title: "Deploy"), .file("deploy.py"))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "./tools/check.ts", title: "Check"), .file("check.ts"))

        // Chained commands, env assignments, wrappers, and `sh -c`
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "cd website && npm run build:site", title: "Build site"), .command(.npm))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "NODE_ENV=production node server.js", title: "Server"), .command(.node))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "nohup env FOO=1 swift test &", title: "Tests"), .command(.swift))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: #"bash -c "cd macos && scripts/validate.sh""#, title: "Validate"), .file("validate.sh"))

        // Agent CLIs invoked in a shell
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "claude -p 'audit'", title: "Audit"), .agent(.claude))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "codex exec 'fix'", title: "Fix"), .agent(.codex))

        // Fallback to title when server omits command, else generic green terminal
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: nil, title: "npm run dev"), .command(.npm))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: nil, title: "Run full validation for shared"), .kind(.terminal))
        XCTAssertEqual(TerminalCommandIcon.subtaskIcon(command: "./custom-binary --flag", title: "Run binary"), .kind(.terminal))
    }

    private func icon(_ name: String) -> AppIcon {
        TerminalCommandIcon.icon(for: ForegroundProcess(name: name, isShell: false))
    }
}
