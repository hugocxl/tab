import TabProtocol
import XCTest
@testable import TabClient

final class ArgumentTests: XCTestCase {
    private func parse(_ words: [String]) throws -> CLIInvocation {
        try CLIParser.parse(words)
    }

    private func command(_ words: [String]) throws -> CLICommand {
        try parse(words).command
    }

    private func manage(_ words: [String]) throws -> ManageInvocation {
        guard case .manage(let invocation) = try command(words) else {
            throw XCTSkip("\(words) is not a management command")
        }
        return invocation
    }

    private func action(_ words: [String]) throws -> ManageAction {
        try manage(words).action
    }

    private func assertRefused(_ words: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(words), "\(words)", file: file, line: line) { error in
            XCTAssertTrue(error is CLIError, "\(words): \(error)", file: file, line: line)
        }
    }

    func testTopLevelCommands() throws {
        XCTAssertEqual(try command([]), .help(CLIHelp.root))
        XCTAssertEqual(try command(["--help"]), .help(CLIHelp.root))
        XCTAssertEqual(try command(["-h"]), .help(CLIHelp.root))
        XCTAssertEqual(try command(["help"]), .help(CLIHelp.root))
        XCTAssertEqual(try command(["help", "session"]), .help(CLIHelp.group(CLICommands.session)))
        XCTAssertEqual(try command(["--version"]), .version)
        XCTAssertEqual(try command(["--build-info"]), .buildInfo)
        XCTAssertEqual(try command(["stdio"]), .stdio(.ifNeeded))
        XCTAssertEqual(try command(["stdio", "--no-start"]), .stdio(.never))
        XCTAssertEqual(try command(["~/code/app"]), .open("~/code/app"))
        XCTAssertEqual(try command(["./server"]), .open("./server"))
        XCTAssertEqual(try command(["--askpass", "dev@box's", "password:"]), .askpass("dev@box's password:"))
        for words in [["help", "nothing"], ["help", "session", "attach"], ["stdio", "--start"], ["--version", "extra"],
                      ["-x"], ["frobnicate", "it"]] {
            assertRefused(words)
        }
    }

    func testHelpComesFromEveryCommandAndGroup() throws {
        for group in CLICommands.groups {
            let help = CLIHelp.group(group)
            XCTAssertEqual(try command([group.name, "--help"]), .help(help), group.name)
            XCTAssertEqual(try command(["help", group.name]), .help(help), group.name)
            for spec in group.commands {
                let text = CLIHelp.command(spec, in: group)
                XCTAssertEqual(try command(spec.path + ["--help"]), .help(text), spec.name)
                XCTAssertEqual(try command(spec.path + ["-h", "--yes"]), .help(text), spec.name)
                XCTAssertEqual(try command(["help"] + spec.path), .help(text), spec.name)
                XCTAssertTrue(help.contains("  \(spec.name)"), spec.name)
            }
            if !group.hidden { XCTAssertTrue(CLIHelp.root.contains("  \(group.name) "), group.name) }
        }
        // A group, or a command missing its words, prints help rather than failing.
        XCTAssertEqual(try command(["session"]), .help(CLIHelp.group(CLICommands.session)))
        XCTAssertEqual(try command(["pane", "new"]), .help(CLIHelp.group(CLICommands.pane)))
        XCTAssertEqual(try command(["git"]), .help(CLIHelp.command(CLICommands.git.commands[0], in: CLICommands.git)))
        XCTAssertFalse(CLIHelp.root.contains("stdio"))
    }

    func testErrorsNameTheCommand() {
        for (words, message) in [
            (["session", "frob"], "unknown command tab session frob; run tab session --help"),
            (["pane", "new", "editor"], "unknown command tab pane new editor; run tab pane --help"),
            (["session", "send", "1a2b", "two", "three"], "usage: tab session send [SESSION] TEXT"),
            (["session", "list", "--json", "--json"], "--json given twice"),
            (["session", "list", "--verbose"],
             "unknown option --verbose for tab session list; put -- before words that start with a dash"),
            (["session", "send", "--json", "hi"],
             "unknown option --json for tab session send; put -- before words that start with a dash"),
            (["project", "remove", "App"], "tab project remove ends terminals or deletes data; pass --yes to confirm"),
        ] {
            XCTAssertThrowsError(try parse(words), "\(words)") { error in
                XCTAssertEqual((error as? CLIError)?.message, message)
            }
        }
    }

    func testHostComesFirstAndOnlyWithServerCommands() throws {
        let invocation = try parse(["--host", "dev@box", "session", "list"])
        XCTAssertEqual(invocation.host?.destination, "dev@box")
        XCTAssertEqual(invocation.command, .manage(ManageInvocation(json: false, action: .session(.list(project: nil,
                                                                                                         all: false)))))
        XCTAssertEqual(try parse(["--host", "ssh://dev@box:2222", "mobile", "status"]).command,
                       .manage(ManageInvocation(json: false, action: .mobile(.status))))
        XCTAssertEqual(try parse(["--host", "box", "server", "status"]).host?.destination, "box")
        for words in [
            ["--host"], ["--host", "box"], ["--host", "box", "--host", "other", "project", "list"],
            ["--host", "box", "browser", "list"], ["--host", "box", "pane", "new", "terminal"],
            ["--host", "box", "tab", "new", "agent"], ["--host", "box", "integrations", "install"],
            ["--host", "box", "stdio"], ["--host", "box", "--help"], ["--host", "box", "/tmp"],
            ["--host", "-oProxyCommand=evil", "project", "list"], ["--host", "my box", "project", "list"],
            ["project", "list", "--host", "box"],
        ] {
            assertRefused(words)
        }
        XCTAssertThrowsError(try parse(["--host", "box", "pane", "new", "agent"])) { error in
            XCTAssertEqual((error as? CLIError)?.message, "tab pane new agent works in the app on this Mac, so it can't take --host")
        }
    }

    func testOptionsGoAnywhereAndJSONOnlyWherePrinted() throws {
        XCTAssertEqual(try manage(["project", "list", "--json"]), ManageInvocation(json: true, action: .project(.list)))
        XCTAssertEqual(try manage(["project", "remove", "--yes", "App"]),
                       ManageInvocation(json: false, action: .project(.remove(project: "App"))))
        XCTAssertEqual(try manage(["exec", "--json", "App", "--timeout", "1", "--", "ls", "--all"]),
                       ManageInvocation(json: true, action: .exec(project: "App", argv: ["ls", "--all"], timeoutMs: 1000)))
        XCTAssertEqual(try action(["session", "stop", "--yes"]), .session(.stop(session: nil)))
        for words in [
            ["project", "rename", "App", "Web", "--json"], ["session", "remove"], ["worktree", "remove", "feature"],
            ["server", "stop", "--force"], ["settings", "get", "--json", "--json"],
        ] {
            assertRefused(words)
        }
    }

    func testServerProjectSettingsActivityGitFilesExec() throws {
        XCTAssertEqual(try action(["server", "start"]), .server(.start))
        XCTAssertEqual(try action(["server", "status"]), .server(.status))
        XCTAssertEqual(try action(["server", "stop"]), .server(.stop(force: false)))
        XCTAssertEqual(try action(["server", "stop", "--force", "--yes"]), .server(.stop(force: true)))
        XCTAssertEqual(try action(["project", "new", ".", "--create", "--reuse"]),
                       .project(.new(directory: ".", name: nil, create: true, reuse: true)))
        XCTAssertEqual(try action(["project", "new", "/srv/app", "--name", " App "]),
                       .project(.new(directory: "/srv/app", name: "App", create: false, reuse: false)))
        XCTAssertEqual(try action(["project", "rename", "App", "Web"]), .project(.rename(project: "App", name: "Web")))
        XCTAssertEqual(try action(["settings", "get"]), .settingsGet)
        XCTAssertEqual(try action(["settings", "set", "shell-integration", "false"]),
                       .settingsSet(key: "shell-integration", value: "false"))
        XCTAssertEqual(try action(["activity", "list"]), .activityList)
        XCTAssertEqual(try action(["activity", "ack", "3", "18446744073709551614"]),
                       .activityAck([3, 18_446_744_073_709_551_614]))
        XCTAssertEqual(try action(["git", "Home", ##"{"type":"summary"}"##]),
                       .git(project: "Home", action: ##"{"type":"summary"}"##))
        XCTAssertEqual(try action(["files", "App", ##"{"type":"list","path":""}"##]),
                       .files(project: "App", action: ##"{"type":"list","path":""}"##))
        XCTAssertEqual(try action(["exec", "App", "--timeout", "0.5", "--", "ls", "-la"]),
                       .exec(project: "App", argv: ["ls", "-la"], timeoutMs: 500))
        XCTAssertEqual(try action(["exec", "App", "--", "true"]), .exec(project: "App", argv: ["true"], timeoutMs: 30000))
        for words in [
            ["server", "restart"], ["server", "stop", "now"], ["project", "new", "a", "b"], ["project", "new", ".", "--name"],
            ["project", "rename", "App", " "], ["settings", "set", "x"], ["activity", "ack", "one"], ["git", "Home"],
            ["exec", "App", "ls"], ["exec", "App", "--"], ["exec", "App", "--timeout", "301", "--", "ls"],
        ] {
            assertRefused(words)
        }
    }

    func testSessionCommandsDefaultToTheCallingTerminal() throws {
        let id = SessionId().description
        XCTAssertEqual(try action(["session", "send", "hello"]), .session(.send(session: nil, text: "hello")))
        XCTAssertEqual(try action(["session", "send", id, "hello"]), .session(.send(session: id, text: "hello")))
        XCTAssertEqual(try action(["session", "send", "1a2b", "--", "--literal"]),
                       .session(.send(session: "1a2b", text: "--literal")))
        XCTAssertEqual(try action(["session", "press", "Ctrl+C"]), .session(.press(session: nil, bytes: Data([3]))))
        XCTAssertEqual(try action(["session", "press", id, "enter"]), .session(.press(session: id, bytes: Data([13]))))
        XCTAssertEqual(try action(["session", "read", "--lines", "10", "--saved"]),
                       .session(.read(session: nil, lines: 10, saved: true)))
        XCTAssertEqual(try action(["session", "read", id]), .session(.read(session: id, lines: 50, saved: false)))
        XCTAssertEqual(try action(["session", "history", id, "--before", "18446744073709551615", "--limit", "500"]),
                       .session(.history(session: id, before: .max, limit: 500, saved: false)))
        XCTAssertEqual(try action(["session", "search", id, "error"]),
                       try action(["session", "search", id, "error", "--limit", "100"]))
        XCTAssertEqual(try action(["session", "search", "error", "--ignore-case", "--saved"]),
                       .session(.search(session: nil, query: "error", before: 0, limit: 100, ignoreCase: true,
                                        saved: true)))
        XCTAssertEqual(try action(["session", "wait", id, "--text", "ready", "--ignore-case"]),
                       .session(.wait(session: id, until: .text("ready", ignoreCase: true), timeoutMs: 30000)))
        XCTAssertEqual(try action(["session", "wait", "--text", "--done"]),
                       .session(.wait(session: nil, until: .text("--done", ignoreCase: false), timeoutMs: 30000)))
        XCTAssertEqual(try action(["session", "wait", "--exit", "--timeout", "2.5"]),
                       .session(.wait(session: nil, until: .exit, timeoutMs: 2500)))
        XCTAssertEqual(try action(["session", "list", "--all", "--project", "App"]),
                       .session(.list(project: "App", all: true)))
        XCTAssertEqual(try action(["session", "events", "wispy-cedar"]), .session(.events(session: "wispy-cedar")))
        XCTAssertEqual(try action(["session", "remove", id, "--yes"]), .session(.remove(session: id)))
    }

    func testSessionNewTypesTheWordsAfterTheSeparator() throws {
        XCTAssertEqual(try action(["session", "new", "--rows", "30", "--", "npm", "run", "dev --watch"]),
                       .session(.new(project: nil, directory: nil, size: Size(cols: 80, rows: 30),
                                     command: "npm run dev --watch")))
        XCTAssertEqual(try action(["session", "new", "--project", "Home"]),
                       .session(.new(project: "Home", directory: nil, size: Size(cols: 80, rows: 24), command: nil)))
        XCTAssertEqual(try action(["session", "new", "--project", "App", "--directory", "./api", "--cols", "120"]),
                       .session(.new(project: "App", directory: "./api", size: Size(cols: 120, rows: 24), command: nil)))
        for words in [
            ["session", "new", "Home"], ["session", "new", "--"], ["session", "new", "--cols", "0"],
            ["session", "new", "--rows", "1025"],
        ] {
            assertRefused(words)
        }
    }

    func testInvalidSessionArgumentsAreRefused() {
        for words in [
            ["session", "send", "0", "text"], ["session", "send", "1", "two", "three"],
            ["session", "read", "abcd", "--lines", "no"], ["session", "read", "--lines", "0"],
            ["session", "press", "abcd", "F99"], ["session", "history", "abcd", "--limit", "501"],
            ["session", "wait", "abcd"], ["session", "wait", "--text", "a", "--exit"],
            ["session", "wait", "--exit", "--ignore-case"], ["session", "wait", "--exit", "--timeout", "3601"],
            ["session", "wait", "--exit", "--timeout", "0"], ["session", "wait", "--exit", "--timeout-ms", "5"],
            ["session", "search", "abcd", String(repeating: "x", count: 257)], ["session", "search", "abcd", ""],
            ["session", "attach"], ["session", "send", "not-hex!", "x"], ["session", "events", "a", "b"],
        ] {
            assertRefused(words)
        }
    }

    func testPanesAndTabsShowWhatTheyStart() throws {
        let id = SessionId().description
        func pane(_ words: [String]) throws -> CLIPane {
            guard case .pane(let pane, _) = try command(words) else { throw CLIError("\(words) is not a pane") }
            return pane
        }
        XCTAssertEqual(try pane(["pane", "new", "terminal", "--", "npm", "run", "dev"]),
                       CLIPane(placement: .pane, project: nil,
                               content: .terminal(session: nil, directory: nil, command: "npm run dev")))
        XCTAssertEqual(try pane(["pane", "new", "terminal", "wispy-cedar"]),
                       CLIPane(placement: .pane, project: nil,
                               content: .terminal(session: "wispy-cedar", directory: nil, command: nil)))
        XCTAssertEqual(try pane(["pane", "new", "terminal", "--project", "App", "--directory", "api"]),
                       CLIPane(placement: .pane, project: "App",
                               content: .terminal(session: nil, directory: "api", command: nil)))
        XCTAssertEqual(try pane(["pane", "new", "agent"]),
                       CLIPane(placement: .pane, project: nil, content: .agent(provider: .claude)))
        XCTAssertEqual(try pane(["pane", "new", "agent", "--project", "App", "--provider", "codex"]),
                       CLIPane(placement: .pane, project: "App", content: .agent(provider: .codex)))
        XCTAssertEqual(try pane(["pane", "new", "agent", "--fork"]),
                       CLIPane(placement: .pane, project: nil, content: .fork(agent: nil)))
        XCTAssertEqual(try pane(["pane", "new", "agent", "--fork", id]),
                       CLIPane(placement: .pane, project: nil, content: .fork(agent: id)))
        XCTAssertEqual(try pane(["pane", "new", "browser", "a.test", "--project", "App", "--profile", "Work"]),
                       CLIPane(placement: .pane, project: "App", content: .browser(url: "a.test", profile: "Work")))
        XCTAssertEqual(try pane(["tab", "new", "terminal", "--directory", "/tmp"]),
                       CLIPane(placement: .tab, project: nil, content: .terminal(session: nil, directory: "/tmp",
                                                                                 command: nil)))
        XCTAssertEqual(try pane(["tab", "new", "agent", "--provider", "codex"]),
                       CLIPane(placement: .tab, project: nil, content: .agent(provider: .codex)))
        XCTAssertEqual(try pane(["tab", "new", "browser"]),
                       CLIPane(placement: .tab, project: nil, content: .browser(url: nil, profile: nil)))
        XCTAssertEqual(try command(["pane", "new", "agent", "--json"]),
                       .pane(CLIPane(placement: .pane, project: nil, content: .agent(provider: .claude)), json: true))
        for words in [
            ["pane", "new", "agent", "--provider", "gemini"], ["pane", "new", "agent", "App"],
            ["pane", "new", "agent", "--fork", "wispy-cedar"], ["pane", "new", "agent", "--fork", "--provider", "codex"],
            ["pane", "new", "terminal", "a", "b"], ["pane", "new", "terminal", id, "--", "ls"],
            ["pane", "new", "browser", "a.test", "b.test"], ["tab", "new", "terminal", id],
            ["tab", "new", "agent", "--fork"], ["tab", "new", "browser", "--project", "App"],
        ] {
            assertRefused(words)
        }
    }

    func testWorktreeCommands() throws {
        XCTAssertEqual(try action(["worktree", "new", "App", "login"]),
                       .worktree(.new(project: "App", name: "login", branch: "login", base: "HEAD", directory: nil,
                                      hooks: false)))
        XCTAssertEqual(try action(["worktree", "new", "App", "fix", "--branch", "fix/x", "--existing",
                                   "--directory", "/tmp/fix", "--hooks"]),
                       .worktree(.new(project: "App", name: "fix", branch: "fix/x", base: nil, directory: "/tmp/fix",
                                      hooks: true)))
        XCTAssertEqual(try action(["worktree", "new", "App", "--pr", "#12"]),
                       .worktree(.pullRequest(project: "App", number: 12, name: nil, directory: nil, hooks: false)))
        XCTAssertEqual(try action(["worktree", "new", "App", "review", "--pr", "12", "--hooks"]),
                       .worktree(.pullRequest(project: "App", number: 12, name: "review", directory: nil, hooks: true)))
        XCTAssertEqual(try action(["worktree", "remove", "login", "--yes", "--force", "--hooks"]),
                       .worktree(.remove(worktree: "login", force: true, hooks: true)))
        XCTAssertEqual(try action(["worktree", "list", "App"]), .worktree(.list(project: "App")))
        XCTAssertEqual(try action(["worktree", "register", "App", "/srv/w"]),
                       .worktree(.register(project: "App", directory: "/srv/w")))
        for words in [
            ["worktree", "new", "Home", "w", "--branch", "x", "--base", "main", "--existing"],
            ["worktree", "new", "Home", " "], ["worktree", "new", "Home"], ["worktree", "new", "Home", "--pr", "0"],
            ["worktree", "new", "Home", "--pr", "twelve"], ["worktree", "new", "Home", "--pr", "1", "--base", "main"],
        ] {
            assertRefused(words)
        }
    }

    func testMobileCommands() throws {
        XCTAssertEqual(try action(["mobile", "status"]), .mobile(.status))
        XCTAssertEqual(try action(["mobile", "enable"]), .mobile(.enable(port: nil)))
        XCTAssertEqual(try action(["mobile", "enable", "--port", "8000"]), .mobile(.enable(port: 8000)))
        XCTAssertEqual(try action(["mobile", "disable"]), .mobile(.disable))
        XCTAssertEqual(try action(["mobile", "pair"]), .mobile(.pair(addresses: [])))
        XCTAssertEqual(try action(["mobile", "pair", "--address", "box.example.com", "--address", "10.0.0.4"]),
                       .mobile(.pair(addresses: ["box.example.com", "10.0.0.4"])))
        XCTAssertEqual(try action(["mobile", "revoke", "1a2b"]), .mobile(.revoke(device: "1a2b")))
        var tooMany = ["mobile", "pair"]
        for index in 0 ... Limits.maxPairingHosts { tooMany += ["--address", "h\(index).example"] }
        for words in [
            ["mobile", "enable", "--port", "80"], ["mobile", "enable", "--port", "x"], ["mobile", "pair", "--address"],
            ["mobile", "pair", "--address", "box:22"], ["mobile", "sleep"], tooMany,
        ] {
            assertRefused(words)
        }
    }

    func testIntegrationsCommands() throws {
        XCTAssertEqual(try command(["integrations", "status"]), .integrations(.status, json: false))
        XCTAssertEqual(try command(["integrations", "install", "--json"]), .integrations(.install(directories: []), json: true))
        XCTAssertEqual(try command(["integrations", "install", "--dir", "a", "--dir", "b"]),
                       .integrations(.install(directories: ["a", "b"]), json: false))
        XCTAssertEqual(try command(["integrations", "context"]), .integrations(.context, json: false))
        XCTAssertEqual(try command(["integrations", "report", "claude", "blocked"]),
                       .integrations(.report(provider: .claude, state: .blocked), json: false))
        XCTAssertEqual(try command(["integrations", "report", "opencode", "ended"]),
                       .integrations(.report(provider: .openCode, state: nil), json: false))
        for words in [["integrations", "install", "--dir"], ["integrations", "report", "claude", "sleeping"],
                      ["integrations", "report", "gemini", "idle"], ["integrations", "context", "--json"]] {
            assertRefused(words)
        }
    }

    // MARK: Browser

    /// Every action as a command line split at spaces, with the request it sends.
    private let browserActions: [(String, BrowserCommand, String)] = [
        ("navigate T a.test", .navigate, ##"{"tabId":"T","url":"a.test"}"##),
        ("list", .list, "{}"),
        ("list --project App --json", .list, ##"{"project":"App"}"##),
        ("read T", .read, ##"{"tabId":"T"}"##),
        ("close T", .close, ##"{"tabId":"T"}"##),
        ("eval T 1+1", .evaluate, ##"{"tabId":"T","script":"1+1"}"##),
        ("click T #go", .click, ##"{"tabId":"T","selector":"#go"}"##),
        ("type T #q rust", .type, ##"{"tabId":"T","selector":"#q","text":"rust","submit":false}"##),
        ("type T #q rust --submit", .type, ##"{"tabId":"T","selector":"#q","text":"rust","submit":true}"##),
        ("fill T #q rust", .fill, ##"{"tabId":"T","selector":"#q","text":"rust"}"##),
        ("press T Enter", .press, ##"{"tabId":"T","key":"Enter"}"##),
        ("press T Enter #q", .press, ##"{"tabId":"T","key":"Enter","selector":"#q"}"##),
        ("select T #s L", .select, ##"{"tabId":"T","selector":"#s","value":"L"}"##),
        ("hover T #m", .hover, ##"{"tabId":"T","selector":"#m"}"##),
        ("scroll-into-view T #m", .scrollIntoView, ##"{"tabId":"T","selector":"#m"}"##),
        ("check T #ok", .setChecked, ##"{"tabId":"T","selector":"#ok","checked":true}"##),
        ("uncheck T #ok", .setChecked, ##"{"tabId":"T","selector":"#ok","checked":false}"##),
        ("is T visible #ok", .is, ##"{"tabId":"T","property":"visible","selector":"#ok"}"##),
        ("wait T", .wait, ##"{"tabId":"T"}"##),
        ("wait T --selector #a --text Done --url-contains /done --function ready --timeout 0.25", .wait,
         ##"{"tabId":"T","selector":"#a","text":"Done","urlContains":"/done","function":"ready","timeoutMs":250}"##),
        ("wait-for T #a", .waitFor, ##"{"tabId":"T","selector":"#a"}"##),
        ("wait-for T #a --timeout 0.8", .waitFor, ##"{"tabId":"T","selector":"#a","timeoutMs":800}"##),
        ("wait-for-navigation T", .waitForNavigation, ##"{"tabId":"T"}"##),
        ("wait-for-navigation T --timeout 0.7", .waitForNavigation, ##"{"tabId":"T","timeoutMs":700}"##),
        ("get-text T h1", .getText, ##"{"tabId":"T","selector":"h1"}"##),
        ("get-html T", .getHTML, ##"{"tabId":"T"}"##),
        ("get-html T main", .getHTML, ##"{"tabId":"T","selector":"main"}"##),
        ("get-value T #q", .getValue, ##"{"tabId":"T","selector":"#q"}"##),
        ("get-attribute T a href", .getAttribute, ##"{"tabId":"T","selector":"a","attribute":"href"}"##),
        ("get-count T li", .getCount, ##"{"tabId":"T","selector":"li"}"##),
        ("find T role button", .find, ##"{"tabId":"T","kind":"role","value":"button"}"##),
        ("snapshot T", .snapshot, ##"{"tabId":"T"}"##),
        ("snapshot T form", .snapshot, ##"{"tabId":"T","selector":"form"}"##),
        ("reload T", .reload, ##"{"tabId":"T"}"##),
        ("back T", .back, ##"{"tabId":"T"}"##),
        ("forward T", .forward, ##"{"tabId":"T"}"##),
        ("screenshot T", .screenshot, ##"{"tabId":"T"}"##),
        ("storage get T k", .storageGet, ##"{"tabId":"T","key":"k","kind":"local"}"##),
        ("storage set T k v session", .storageSet, ##"{"tabId":"T","key":"k","value":"v","kind":"session"}"##),
        ("storage clear T", .storageClear, ##"{"tabId":"T","kind":"local"}"##),
        ("cookies get T", .cookiesGet, ##"{"tabId":"T"}"##),
        ("cookies get T a.test", .cookiesGet, ##"{"tabId":"T","url":"a.test"}"##),
        ("cookies set T id 1 a.test", .cookiesSet, ##"{"tabId":"T","name":"id","value":"1","domain":"a.test"}"##),
        ("cookies set T id 1 a.test --path /app --secure --http-only --expires 1767225600", .cookiesSet,
         ##"{"tabId":"T","name":"id","value":"1","domain":"a.test","path":"/app","secure":true,"httpOnly":true,"expires":1767225600}"##),
        ("cookies delete T id", .cookiesDelete, ##"{"tabId":"T","name":"id"}"##),
        ("cookies delete T id a.test", .cookiesDelete, ##"{"tabId":"T","name":"id","domain":"a.test"}"##),
        ("cookies clear T", .cookiesClear, ##"{"tabId":"T"}"##),
    ]

    private func browser(_ words: [String]) throws -> BrowserInvocation {
        guard case .browser(let invocation) = try command(["browser"] + words) else {
            throw CLIError("\(words) is not a browser request")
        }
        return invocation
    }

    func testEveryBrowserActionSendsItsCommandAndArguments() throws {
        for (line, expected, json) in browserActions {
            let invocation = try browser(line.split(separator: " ").map(String.init))
            XCTAssertEqual(invocation.command, expected, line)
            let args = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
            XCTAssertEqual(invocation.args, args, line)
            XCTAssertEqual(invocation.request, .browser(command: expected.rawValue, args: args), line)
        }
        XCTAssertEqual(Set(browserActions.map(\.1)).union([.open]), Set(BrowserCommand.allCases), "every command is reachable")
        let beside = SessionId()
        XCTAssertEqual(BrowserInvocation.open(url: "a.test", profile: "Work", project: "App", beside: beside,
                                              placement: .pane).args,
                       ["url": .string("a.test"), "profile": .string("Work"), "project": .string("App"),
                        "beside": .string(beside.description), "tab": .bool(false)])
        XCTAssertEqual(BrowserInvocation.open(url: nil, profile: nil, project: nil, beside: nil, placement: .tab).args,
                       ["tab": .bool(true)])
    }

    func testBrowserRepliesPrintByActionAndWaitsGetTheirTime() throws {
        for (words, output) in [(["list"], BrowserOutput.list), (["list", "--json"], .json), (["read", "T"], .page),
                                (["read", "T", "--json"], .json), (["navigate", "T", "a"], .ok), (["close", "T"], .ok),
                                (["reload", "T"], .ok), (["cookies", "clear", "T"], .ok), (["eval", "T", "1"], .json),
                                (["screenshot", "T"], .screenshot)] {
            XCTAssertEqual(try browser(words).output, output, "\(words)")
        }
        for (words, time) in [(["click", "T", "#a"], 0.0), (["screenshot", "T"], 20), (["wait", "T"], 5),
                              (["wait", "T", "--timeout", "0.1"], 0.1), (["wait-for", "T", "#a"], 5),
                              (["wait-for", "T", "#a", "--timeout", "60"], 60), (["wait-for-navigation", "T"], 10)] {
            XCTAssertEqual(try browser(words).extraTime, time, accuracy: 0.0001, "\(words)")
        }
    }

    func testBrowserOptionsGoAnywhereAndOnlyKnownOnesCount() throws {
        XCTAssertEqual(try browser(["wait", "--timeout", "1", "T", "--selector", "#a"]),
                       try browser(["wait", "T", "--selector", "#a", "--timeout", "1"]))
        XCTAssertEqual(try browser(["type", "--submit", "T", "#q", "rust"]),
                       try browser(["type", "T", "#q", "rust", "--submit"]))
        XCTAssertEqual(try browser(["eval", "T", "-1"]).args, ["tabId": .string("T"), "script": .string("-1")])
        XCTAssertEqual(try browser(["eval", "T", "--", "--help"]).args,
                       ["tabId": .string("T"), "script": .string("--help")])
        XCTAssertEqual(try browser(["wait", "T", "--text", "--selector"]).args,
                       ["tabId": .string("T"), "text": .string("--selector")])
        XCTAssertEqual(try command(["browser"]), .help(CLIHelp.group(CLICommands.browser)))
        XCTAssertEqual(try command(["browser", "storage"]), .help(CLIHelp.group(CLICommands.browser)))
    }

    func testBrowserUnsignedNumbersKeepTheirExactWireValue() throws {
        let maximum = "18446744073709551615"
        let cookie = try browser(["cookies", "set", "T", "id", "1", "a.test", "--expires", maximum])
        XCTAssertEqual(cookie.args["expires"], .uint(UInt64.max))
        let data = try AppSocket.encode(cookie.request)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(maximum))
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: data), cookie.request)
    }

    func testWrongBrowserArgumentsNameTheUsage() {
        XCTAssertThrowsError(try command(["browser", "click", "T"])) { error in
            XCTAssertEqual((error as? CLIError)?.message, "usage: tab browser click BROWSER SELECTOR")
        }
        for words in [
            ["frobnicate", "T"], ["cookies", "eat", "T"], ["open", "a.test"], ["evaluate", "T", "1"], ["navigate", "T"],
            ["list", "T"], ["navigate", "T", "a.test", "--json"], ["is", "T", "shiny", "#a"], ["find", "T", "css", "#a"],
            ["storage", "get", "T", "k", "disk"], ["wait-for", "T", "#a", "800"], ["wait", "T", "--timeout", "-5"],
            ["wait", "T", "--timeout", "61"], ["wait", "T", "--text", "a", "--text", "b"],
            ["wait-for-navigation", "T", "100"], ["type", "T", "#q", "a", "--submit", "--submit"],
            ["cookies", "set", "T", "id", "1"], ["cookies", "set", "T", "id", "1", "a.test", "--expires", "soon"],
        ] {
            assertRefused(["browser"] + words)
        }
    }

    // MARK: Skill

    /// Splits a shell line into words, keeping quoted text together and
    /// standing in a session ID for each `$VARIABLE`.
    private func words(_ line: String) -> [String] {
        var words: [String] = []
        var word = ""
        var quoted = false
        for character in line {
            switch character {
            case "\"": quoted.toggle()
            case " " where !quoted:
                if !word.isEmpty { words.append(word) }
                word = ""
            default: word.append(character)
            }
        }
        words.append(word)
        return words.filter { !$0.isEmpty }.map { $0.hasPrefix("$") ? "1a2b3c4d" : $0 }
    }

    func testEveryCommandInTheSkillParses() throws {
        XCTAssertTrue(AgentSkill.text.hasPrefix("---\nname: tab-cli\n"))
        let commands = AgentSkill.text.split(separator: "\n").compactMap { line -> String? in
            guard let range = line.range(of: "tab ") else { return nil }
            let command = line[range.upperBound...]
            guard !command.hasPrefix("<command>"), !command.hasPrefix("--help"), !command.contains("`") else {
                return nil
            }
            let trimmed = command.components(separatedBy: "  #")[0].trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix(")") ? String(trimmed.dropLast()) : trimmed
        }
        XCTAssertGreaterThan(commands.count, 15, "\(commands)")
        for command in commands {
            XCTAssertNoThrow(try parse(words(command)), "tab \(command)")
        }
    }

    func testSkillInstallsIntoChosenFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let written = try AgentSkill.install(directories: ["chosen", home.appendingPathComponent("only").path],
                                             currentDirectory: home.path)
        XCTAssertEqual(written.map(\.path), [
            home.appendingPathComponent("chosen/tab-cli/SKILL.md").path,
            home.appendingPathComponent("only/tab-cli/SKILL.md").path,
        ])
        XCTAssertEqual(try String(contentsOf: written[0], encoding: .utf8), AgentSkill.text)
    }

    func testSessionSelectorsResolveUniquePrefixes() throws {
        let a = try XCTUnwrap(SessionId(string: "1a2b3c4d-0000-4000-8000-000000000001"))
        let b = try XCTUnwrap(SessionId(string: "1a2b9999-0000-4000-8000-000000000002"))
        XCTAssertEqual(try SessionSelector.resolve("1a2b3", among: [a, b]), a)
        XCTAssertEqual(try SessionSelector.resolve("1A2B9", among: [a, b]), b)
        XCTAssertThrowsError(try SessionSelector.resolve("1a2b", among: [a, b]))
        XCTAssertThrowsError(try SessionSelector.resolve("ffff", among: [a, b]))
        XCTAssertEqual(try SessionSelector.resolve(a.description, among: []), a)
    }
}
