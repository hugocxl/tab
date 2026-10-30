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
        XCTAssertEqual(try command(["help", "session"]), .help(CLIHelp.session))
        XCTAssertEqual(try command(["help", "browser"]), .help(CLIHelp.browser))
        XCTAssertEqual(try command(["--version"]), .version)
        XCTAssertEqual(try command(["--build-info"]), .buildInfo)
        XCTAssertEqual(try command(["stdio"]), .stdio(.ifNeeded))
        XCTAssertEqual(try command(["stdio", "--no-start"]), .stdio(.never))
        XCTAssertEqual(try command(["~/code/app"]), .open("~/code/app"))
        XCTAssertEqual(try command(["./server"]), .open("./server"))
        XCTAssertEqual(try command(["--askpass", "dev@box's", "password:"]), .askpass("dev@box's password:"))
        for words in [["help", "nothing"], ["stdio", "--start"], ["--version", "extra"], ["-x"]] {
            assertRefused(words)
        }
    }

    func testEveryCommandHasHelp() throws {
        for (group, text) in [("server", CLIHelp.server), ("project", CLIHelp.project), ("session", CLIHelp.session),
                              ("worktree", CLIHelp.worktree), ("settings", CLIHelp.settings),
                              ("activity", CLIHelp.activity), ("git", CLIHelp.git), ("files", CLIHelp.files),
                              ("exec", CLIHelp.exec), ("mobile", CLIHelp.mobile), ("browser", CLIHelp.browser),
                              ("install-skills", CLIHelp.installSkills), ("stdio", CLIHelp.stdio)] {
            XCTAssertEqual(try command([group, "--help"]), .help(text), group)
            XCTAssertEqual(try command(["help", group]), .help(text), group)
        }
        XCTAssertEqual(try command(["session", "create", "--help"]), .help(CLIHelp.session))
        XCTAssertEqual(try command(["browser", "click", "-h"]), .help(CLIHelp.browser))
        XCTAssertEqual(try command(["mobile", "pair", "--help"]), .help(CLIHelp.mobile))
    }

    func testHostComesFirstAndOnlyWithServerCommands() throws {
        let invocation = try parse(["--host", "dev@box", "session", "list"])
        XCTAssertEqual(invocation.host?.destination, "dev@box")
        XCTAssertEqual(invocation.command, .manage(ManageInvocation(json: false, action: .session(.list(project: nil,
                                                                                                         all: false)))))
        XCTAssertEqual(try parse(["--host", "ssh://dev@box:2222", "mobile"]).command, .mobile(.status))
        XCTAssertEqual(try parse(["--host", "box", "server", "status"]).host?.destination, "box")
        for words in [
            ["--host"], ["--host", "box", "--host", "other", "project", "list"], ["--host", "box", "browser", "list"],
            ["--host", "box", "install-skills"], ["--host", "box", "stdio"], ["--host", "box", "--help"],
            ["--host", "box", "/tmp"], ["--host", "-oProxyCommand=evil", "project", "list"],
            ["--host", "my box", "project", "list"], ["project", "list", "--host", "box"],
        ] {
            assertRefused(words)
        }
    }

    func testJSONAndYesAreAcceptedAnywhere() throws {
        XCTAssertEqual(try manage(["project", "list", "--json"]), ManageInvocation(json: true, action: .project(.list)))
        assertRefused(["project", "--json", "list"])
        XCTAssertEqual(try manage(["project", "delete", "--yes", "App", "--json"]),
                       ManageInvocation(json: true, action: .project(.delete("App"))))
        XCTAssertEqual(try action(["session", "end", "--yes"]), .session(.end(nil)))
        assertRefused(["project", "list", "--json", "--json"])
        assertRefused(["project", "delete", "App"])
        assertRefused(["session", "end", SessionId().description])
        assertRefused(["worktree", "remove", "feature"])
        assertRefused(["session", "discard"])
    }

    func testServerProjectSettingsActivityGitFilesExec() throws {
        XCTAssertEqual(try action(["server", "start"]), .server(.start))
        XCTAssertEqual(try action(["server", "status"]), .server(.status))
        XCTAssertEqual(try action(["server", "stop"]), .server(.stop(force: false)))
        XCTAssertEqual(try action(["server", "stop", "--force"]), .server(.stop(force: true)))
        XCTAssertEqual(try action(["project", "add", ".", "--create", "--reuse"]),
                       .project(.add(directory: ".", name: nil, create: true, reuse: true)))
        XCTAssertEqual(try action(["project", "add", "/srv/app", "--name", "App"]),
                       .project(.add(directory: "/srv/app", name: "App", create: false, reuse: false)))
        XCTAssertEqual(try action(["project", "rename", "App", "Web"]), .project(.rename(project: "App", name: "Web")))
        XCTAssertEqual(try action(["settings", "get"]), .settingsGet)
        XCTAssertEqual(try action(["settings", "set", "shell-integration", "false"]),
                       .settingsSet(key: "shell-integration", value: "false"))
        XCTAssertEqual(try action(["activity", "list"]), .activityList)
        XCTAssertEqual(try action(["activity", "ack", "3", "18446744073709551614"]),
                       .activityAck([3, 18_446_744_073_709_551_614]))
        XCTAssertEqual(try action(["git", "Home", ##"{"type":"summary"}"##]),
                       .git(project: "Home", action: ##"{"type":"summary"}"##))
        XCTAssertEqual(try action(["files", "App", ##"{"type":"list","path":""}"##, "--json"]),
                       .files(project: "App", action: ##"{"type":"list","path":""}"##))
        XCTAssertEqual(try action(["exec", "App", "--timeout-ms", "500", "--", "ls", "-la"]),
                       .exec(project: "App", argv: ["ls", "-la"], timeoutMs: 500))
        XCTAssertEqual(try action(["exec", "App", "--", "true"]), .exec(project: "App", argv: ["true"], timeoutMs: 30000))
        for words in [
            ["server", "restart"], ["server", "stop", "now"], ["project"], ["project", "add"], ["project", "add", "a", "b"],
            ["project", "add", ".", "--name"], ["project", "add", ".", "--name", "--reuse"], ["settings", "set", "x"],
            ["activity", "ack"], ["activity", "ack", "one"], ["git", "Home"], ["git", "--json", "{}"],
            ["exec", "App"],
            ["exec", "App", "--timeout-ms", "300001", "--", "ls"], ["frobnicate", "it"], ["project", "list", "-v"],
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
        XCTAssertEqual(try action(["session", "send-keys", "Ctrl+C"]), .session(.keys(session: nil, bytes: Data([3]))))
        XCTAssertEqual(try action(["session", "send-keys", id, "enter"]), .session(.keys(session: id, bytes: Data([13]))))
        XCTAssertEqual(try action(["session", "read-screen", "--lines", "10", "--saved"]),
                       .session(.readScreen(session: nil, lines: 10, saved: true)))
        XCTAssertEqual(try action(["session", "read-screen", id]), .session(.readScreen(session: id, lines: 50,
                                                                                        saved: false)))
        XCTAssertEqual(try action(["session", "history", id, "--before", "18446744073709551615", "--limit", "500"]),
                       .session(.history(session: id, before: .max, limit: 500, saved: false)))
        XCTAssertEqual(try action(["session", "search", id, "error"]),
                       try action(["session", "search", id, "error", "--limit", "100"]))
        XCTAssertEqual(try action(["session", "search", "error", "--ignore-case", "--saved"]),
                       .session(.search(session: nil, query: "error", before: 0, limit: 100, ignoreCase: true,
                                        saved: true)))
        XCTAssertEqual(try action(["session", "wait", id, "--text", "ready", "--ignore-case"]),
                       .session(.wait(session: id, until: .text("ready", ignoreCase: true), timeoutMs: 30000)))
        XCTAssertEqual(try action(["session", "wait", "--exit", "--timeout-ms", "500"]),
                       .session(.wait(session: nil, until: .exit, timeoutMs: 500)))
        XCTAssertEqual(try action(["session", "wait", "--exit", "--timeout", "2.5"]),
                       .session(.wait(session: nil, until: .exit, timeoutMs: 2500)))
        XCTAssertEqual(try action(["session", "list", "--all", "--project", "App"]),
                       .session(.list(project: "App", all: true)))
        XCTAssertEqual(try action(["session", "discard", id, "--yes"]), .session(.discard(id)))
    }

    func testSessionCreateTypesTheWordsAfterTheSeparator() throws {
        XCTAssertEqual(try action(["session", "create", "--rows", "30", "--", "npm", "run", "dev --watch"]),
                       .session(.create(project: nil, directory: nil, size: Size(cols: 80, rows: 30),
                                        command: "npm run dev --watch")))
        XCTAssertEqual(try action(["session", "create", "Home"]),
                       .session(.create(project: "Home", directory: nil, size: Size(cols: 80, rows: 24), command: nil)))
        XCTAssertEqual(try action(["session", "create", "App", "--directory", "./api", "--cols", "120"]),
                       .session(.create(project: "App", directory: "./api", size: Size(cols: 120, rows: 24),
                                        command: nil)))
        for words in [
            ["session", "create", "Home", "Other"], ["session", "create", "Home", "--"],
            ["session", "create", "--cols", "0"], ["session", "create", "--rows", "1025"],
        ] {
            assertRefused(words)
        }
    }

    func testInvalidSessionArgumentsAreRefused() {
        for words in [
            ["session", "send", "0", "text"], ["session", "send", "1", "two", "three"], ["session", "send"],
            ["session", "read-screen", "abcd", "--lines", "no"], ["session", "read-screen", "--lines", "0"],
            ["session", "send-keys", "abcd", "F99"], ["session", "history", "abcd", "--limit", "501"],
            ["session", "wait", "abcd"], ["session", "wait", "--text", "a", "--exit"],
            ["session", "wait", "--exit", "--ignore-case"], ["session", "wait", "--exit", "--timeout-ms", "3600001"],
            ["session", "wait", "--exit", "--timeout", "3601"], ["session", "wait", "--exit", "--timeout", "0"],
            ["session", "wait", "--exit", "--timeout", "1", "--timeout-ms", "5"],
            ["session", "search", "abcd", String(repeating: "x", count: 257)], ["session", "search", "abcd", ""],
            ["session", "attach"], ["session", "send", "not-hex!", "x"],
        ] {
            assertRefused(words)
        }
    }

    func testWorktreeCommands() throws {
        XCTAssertEqual(try action(["worktree", "create", "App", "login"]),
                       .worktree(.create(project: "App", name: "login", branch: "login", base: "HEAD", directory: nil,
                                         hooks: false)))
        XCTAssertEqual(try action(["worktree", "create", "App", "fix", "--branch", "fix/x", "--existing",
                                   "--directory", "/tmp/fix", "--hooks"]),
                       .worktree(.create(project: "App", name: "fix", branch: "fix/x", base: nil,
                                         directory: "/tmp/fix", hooks: true)))
        XCTAssertEqual(try action(["worktree", "checkout-pr", "App", "#12"]),
                       .worktree(.checkoutPullRequest(project: "App", number: 12, name: nil, directory: nil,
                                                      hooks: false)))
        XCTAssertEqual(try action(["worktree", "remove", "login", "--yes", "--force", "--hooks"]),
                       .worktree(.remove(worktree: "login", force: true, hooks: true)))
        XCTAssertEqual(try action(["worktree", "list", "App"]), .worktree(.list("App")))
        XCTAssertEqual(try action(["worktree", "register", "App", "/srv/w"]),
                       .worktree(.register(project: "App", directory: "/srv/w")))
        for words in [
            ["worktree", "create", "Home", "/tmp/w", "--branch", "x", "--base", "main", "--existing"],
            ["worktree", "create", "Home", " "], ["worktree", "checkout-pr", "Home", "0"],
            ["worktree", "checkout-pr", "Home", "twelve"], ["worktree", "list"],
        ] {
            assertRefused(words)
        }
    }

    func testMobileCommands() throws {
        XCTAssertEqual(try command(["mobile"]), .mobile(.status))
        XCTAssertEqual(try command(["mobile", "enable"]), .mobile(.enable(port: nil)))
        XCTAssertEqual(try command(["mobile", "enable", "--port", "8000"]), .mobile(.enable(port: 8000)))
        XCTAssertEqual(try command(["mobile", "disable"]), .mobile(.disable))
        XCTAssertEqual(try command(["mobile", "pair"]), .mobile(.pair(addresses: [])))
        XCTAssertEqual(try command(["mobile", "pair", "--address", "box.example.com", "--address", "10.0.0.4"]),
                       .mobile(.pair(addresses: ["box.example.com", "10.0.0.4"])))
        XCTAssertEqual(try command(["mobile", "revoke", "1a2b"]), .mobile(.revoke(device: "1a2b")))
        var tooMany = ["mobile", "pair"]
        for index in 0 ... Limits.maxPairingHosts { tooMany += ["--address", "h\(index).example"] }
        for words in [
            ["mobile", "enable", "--port", "80"], ["mobile", "enable", "--port", "x"], ["mobile", "pair", "--address"],
            ["mobile", "pair", "--address", "box:22"], ["mobile", "revoke"], ["mobile", "sleep"], tooMany,
        ] {
            assertRefused(words)
        }
    }

    func testInstallSkillsTakesFoldersButNoHost() throws {
        XCTAssertEqual(try command(["install-skills"]), .installSkills([]))
        XCTAssertEqual(try command(["install-skills", "--dir", "a", "--dir", "b"]), .installSkills(["a", "b"]))
        assertRefused(["install-skills", "--dir"])
        assertRefused(["install-skills", "a"])
    }

    // MARK: Browser

    /// Every action as a command line split at spaces, with the request it sends.
    private let browserActions: [(String, BrowserCommand, String)] = [
        ("open", .open, ##"{"split":false}"##),
        ("open a.test --split --project App --worktree fix --profile Work", .open,
         ##"{"url":"a.test","split":true,"project":"App","worktree":"fix","profile":"Work"}"##),
        ("navigate T a.test", .navigate, ##"{"tabId":"T","url":"a.test"}"##),
        ("list", .list, "{}"),
        ("list --project App --worktree fix --json", .list, ##"{"project":"App","worktree":"fix"}"##),
        ("read T", .read, ##"{"tabId":"T"}"##),
        ("close T", .close, ##"{"tabId":"T"}"##),
        ("eval T 1+1", .evaluate, ##"{"tabId":"T","script":"1+1"}"##),
        ("evaluate T 1+1", .evaluate, ##"{"tabId":"T","script":"1+1"}"##),
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
        ("wait T --selector #a --text Done --url-contains /done --function ready --timeout-ms 250", .wait,
         ##"{"tabId":"T","selector":"#a","text":"Done","urlContains":"/done","function":"ready","timeoutMs":250}"##),
        ("wait-for T #a", .waitFor, ##"{"tabId":"T","selector":"#a"}"##),
        ("wait-for T #a 800", .waitFor, ##"{"tabId":"T","selector":"#a","timeoutMs":800}"##),
        ("wait-for-navigation T", .waitForNavigation, ##"{"tabId":"T"}"##),
        ("wait-for-navigation T 900", .waitForNavigation, ##"{"tabId":"T","timeoutMs":900}"##),
        ("wait-for-navigation T --timeout-ms 700", .waitForNavigation, ##"{"tabId":"T","timeoutMs":700}"##),
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
        XCTAssertEqual(Set(browserActions.map(\.1)), Set(BrowserCommand.allCases), "every command is reachable")
    }

    func testBrowserRepliesPrintByActionAndWaitsGetTheirTime() throws {
        for (words, output) in [(["open"], BrowserOutput.text), (["list"], .tabs), (["list", "--json"], .json),
                                (["read", "T"], .page), (["read", "T", "--json"], .json), (["navigate", "T", "a"], .ok),
                                (["close", "T"], .ok), (["eval", "T", "1"], .json), (["screenshot", "T"], .screenshot)] {
            XCTAssertEqual(try browser(words).output, output, "\(words)")
        }
        for (words, time) in [(["click", "T", "#a"], 0.0), (["screenshot", "T"], 20), (["wait", "T"], 5),
                              (["wait", "T", "--timeout-ms", "100"], 0.1), (["wait-for", "T", "#a"], 5),
                              (["wait-for", "T", "#a", "90000"], 60), (["wait-for-navigation", "T"], 10)] {
            XCTAssertEqual(try browser(words).extraTime, time, accuracy: 0.0001, "\(words)")
        }
    }

    func testBrowserOptionsGoAnywhereAndOnlyKnownOnesCount() throws {
        XCTAssertEqual(try browser(["wait", "--timeout-ms", "100", "T", "--selector", "#a"]),
                       try browser(["wait", "T", "--selector", "#a", "--timeout-ms", "100"]))
        XCTAssertEqual(try browser(["type", "--submit", "T", "#q", "rust"]),
                       try browser(["type", "T", "#q", "rust", "--submit"]))
        XCTAssertEqual(try browser(["eval", "T", "-1"]).args, ["tabId": .string("T"), "script": .string("-1")])
        XCTAssertEqual(try browser(["eval", "T", "--", "--help"]).args,
                       ["tabId": .string("T"), "script": .string("--help")])
        XCTAssertEqual(try browser(["wait", "T", "--text", "--selector"]).args,
                       ["tabId": .string("T"), "text": .string("--selector")])
        XCTAssertEqual(try command(["browser"]), .help(CLIHelp.browser))
        XCTAssertEqual(try command(["browser", "storage", "get", "-h"]), .help(CLIHelp.browser))
    }

    func testBrowserUnsignedNumbersKeepTheirExactWireValue() throws {
        let maximum = "18446744073709551615"
        let wait = try browser(["wait", "T", "--timeout-ms", maximum])
        XCTAssertEqual(wait.args["timeoutMs"], .uint(UInt64.max))
        XCTAssertEqual(wait.extraTime, 60)
        let data = try AppSocket.encode(wait.request)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(maximum))
        XCTAssertEqual(try JSONDecoder().decode(AppRequest.self, from: data), wait.request)
        let cookie = try browser(["cookies", "set", "T", "id", "1", "a.test", "--expires", maximum])
        XCTAssertEqual(cookie.args["expires"], .uint(UInt64.max))
    }

    func testWrongBrowserArgumentsNameTheUsage() {
        XCTAssertThrowsError(try command(["browser", "click", "T"])) { error in
            XCTAssertEqual((error as? CLIError)?.message, "usage: tab browser click <tab-id> <selector>")
        }
        for words in [
            ["frobnicate", "T"], ["storage"], ["cookies", "eat", "T"], ["open", "a.test", "b.test"], ["open", "--project"],
            ["navigate", "T"], ["list", "T"], ["read"], ["navigate", "T", "a.test", "--json"], ["is", "T", "shiny", "#a"],
            ["find", "T", "css", "#a"], ["storage", "get", "T", "k", "disk"], ["wait-for", "T", "#a", "soon"],
            ["wait", "T", "--timeout-ms", "-5"], ["wait", "T", "--text", "a", "--text", "b"],
            ["wait-for-navigation", "T", "100", "--timeout-ms", "200"], ["type", "T", "#q", "a", "--submit", "--submit"],
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

    func testSkillInstallsIntoAgentFoldersThatExistAndChosenFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        XCTAssertThrowsError(try AgentSkill.install(home: home.path, directories: []))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"),
                                                withIntermediateDirectories: true)
        let written = try AgentSkill.install(home: home.path, directories: ["chosen"], currentDirectory: home.path)
        XCTAssertEqual(written.map(\.path), [
            home.appendingPathComponent(".claude/skills/tab-cli/SKILL.md").path,
            home.appendingPathComponent("chosen/tab-cli/SKILL.md").path,
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path))
        XCTAssertEqual(try String(contentsOf: written[0], encoding: .utf8), AgentSkill.text)
        XCTAssertEqual(try AgentSkill.install(home: nil, directories: [home.appendingPathComponent("only").path]).count, 1)
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
