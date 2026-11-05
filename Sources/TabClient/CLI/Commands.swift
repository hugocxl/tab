import Foundation
import TabProtocol

/// One `tab` command: its words, what it accepts, its help, and what it
/// parses to. The parser, the usage errors and the help all come from these.
struct CLICommandSpec: Sendable {
    enum Place: Sendable {
        /// Uses a server, this computer's or the one `--host` names.
        case server
        /// Uses the app on this computer.
        case app
        /// Works on this computer only.
        case local

        func refusesHost(_ name: String) -> String {
            switch self {
            case .server: ""
            case .app: "tab \(name) works in the app on this Mac, so it can't take --host"
            case .local: "tab \(name) works on this Mac only, so it can't take --host"
            }
        }
    }

    /// The words that name it, such as `session new` or `browser storage get`.
    var path: [String]
    /// What follows the name; several forms are shown as separate lines.
    var usage: [String]
    var summary: String
    /// How many words, other than options, it takes.
    var words: ClosedRange<Int>
    /// Options that take a value.
    var values: [String]
    /// Options that take a value and may be repeated.
    var lists: [String]
    var flags: [String]
    /// It prints data and takes `--json`.
    var json: Bool
    /// Words after `--` are kept apart, as a command to run.
    var literal: Bool
    var place: Place
    var build: @Sendable (CLIArguments) throws -> CLICommand

    var name: String { path.joined(separator: " ") }

    init(_ path: String, _ usage: [String], _ summary: String, words: ClosedRange<Int> = 0 ... 0,
         values: [String] = [], lists: [String] = [], flags: [String] = [], json: Bool = false,
         literal: Bool = false, place: Place = .server, build: @escaping @Sendable (CLIArguments) throws -> CLICommand) {
        self.path = path.split(separator: " ").map(String.init)
        self.usage = usage
        self.summary = summary
        self.words = words
        self.values = values
        self.lists = lists
        self.flags = flags
        self.json = json
        self.literal = literal
        self.place = place
        self.build = build
    }
}

/// The commands under one name, such as `session`, and what they share.
struct CLIGroup: Sendable {
    enum Section: Sendable {
        case server, app, local
    }

    var name: String
    var summary: String
    var section: Section
    var commands: [CLICommandSpec]
    /// What every command of the group shares, printed after their list.
    var notes: String
    /// Run by Tab itself, not people; left out of `tab --help`.
    var hidden = false

    /// The command `words` start with, and how many words name it; else the
    /// most words that start some command's name.
    func command(for words: [String]) -> (CLICommandSpec?, Int) {
        var best = 0
        var found: CLICommandSpec?
        for spec in commands {
            let tail = Array(spec.path.dropFirst())
            if Array(words.prefix(tail.count)) == tail, found.map({ $0.path.count < spec.path.count }) ?? true {
                found = spec
            }
            let common = zip(tail, words).prefix { $0 == $1 }.count
            best = max(best, common)
        }
        if let found { return (found, found.path.count - 1) }
        return (nil, best)
    }
}

enum CLICommands {
    static func group(_ name: String) -> CLIGroup? {
        groups.first { $0.name == name }
    }

    static let groups: [CLIGroup] = [
        session, project, worktree, exec, git, files, activity, settings, mobile, server, device, forward,
        pane, tab, browser, integrations, stdio,
    ]

    private static func manage(_ arguments: CLIArguments, _ action: ManageAction) -> CLICommand {
        .manage(ManageInvocation(json: arguments.json, action: action))
    }

    // MARK: Server

    static let session = CLIGroup(
        name: "session", summary: "Terminals that keep running, with or without the app", section: .server,
        commands: [
            CLICommandSpec("session new", ["[--project PROJECT] [--directory DIR] [--cols N] [--rows N] [-- COMMAND...]"],
                           "Start a terminal and print its ID; COMMAND is typed into it, then Return",
                           values: ["--project", "--directory", "--cols", "--rows"], json: true, literal: true) { a in
                let command = a.literal?.joined(separator: " ")
                if let command, command.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw CLIError("missing command after --")
                }
                let size = Size(cols: try a.number("--cols", default: 80, 1 ... Limits.maxCols),
                                rows: try a.number("--rows", default: 24, 1 ... Limits.maxRows))
                return manage(a, .session(.new(project: a.value("--project"), directory: a.value("--directory"),
                                               size: size, command: command)))
            },
            CLICommandSpec("session list", ["[--project PROJECT] [--all]"],
                           "Running terminals; --all adds ended ones", values: ["--project"], flags: ["--all"],
                           json: true) { a in
                manage(a, .session(.list(project: a.value("--project"), all: a.flag("--all"))))
            },
            CLICommandSpec("session send", ["[SESSION] TEXT"], "Type text, without pressing Return",
                           words: 1 ... 2) { a in
                manage(a, .session(.send(session: try a.session(before: 1), text: a.trailing(0, after: 1))))
            },
            CLICommandSpec("session press", ["[SESSION] KEY"],
                           "Press Enter, Tab, Escape, Backspace, Ctrl+C, Ctrl+D or Ctrl+Z", words: 1 ... 2) { a in
                manage(a, .session(.press(session: try a.session(before: 1), bytes: try key(a.trailing(0, after: 1)))))
            },
            CLICommandSpec("session read", ["[SESSION] [--lines N] [--saved]"],
                           "Print the last N visible rows (50 by default)", words: 0 ... 1, values: ["--lines"],
                           flags: ["--saved"], json: true) { a in
                manage(a, .session(.read(session: try a.session(before: 0),
                                         lines: try a.number("--lines", default: 50, 1 ... Int(Limits.maxRows)),
                                         saved: a.flag("--saved"))))
            },
            CLICommandSpec("session history", ["[SESSION] [--before CURSOR] [--limit N] [--saved]"],
                           "Print a page of scrollback as JSON", words: 0 ... 1, values: ["--before", "--limit"],
                           flags: ["--saved"]) { a in
                manage(a, .session(.history(session: try a.session(before: 0),
                                            before: try a.number("--before", default: 0, 0 ... UInt64.max),
                                            limit: try a.number("--limit", default: 200, 1 ... 500),
                                            saved: a.flag("--saved"))))
            },
            CLICommandSpec("session search", ["[SESSION] TEXT [--ignore-case] [--before CURSOR] [--limit N] [--saved]"],
                           "Find text in the scrollback; prints a page of matches as JSON", words: 1 ... 2,
                           values: ["--before", "--limit"], flags: ["--ignore-case", "--saved"]) { a in
                let query = a.trailing(0, after: 1)
                let limit: UInt16 = try a.number("--limit", default: 100, 1 ... 500)
                do {
                    try Validation.search(query: query, maxResults: limit)
                } catch {
                    throw CLIError("the text to search for must have 1 to \(Limits.maxSearchQuery) bytes")
                }
                return manage(a, .session(.search(session: try a.session(before: 1), query: query,
                                                  before: try a.number("--before", default: 0, 0 ... UInt64.max),
                                                  limit: limit, ignoreCase: a.flag("--ignore-case"),
                                                  saved: a.flag("--saved"))))
            },
            CLICommandSpec("session wait", ["[SESSION] --text TEXT [--ignore-case] [--timeout SECONDS]",
                                            "[SESSION] --exit [--timeout SECONDS]"],
                           "Wait until TEXT shows on screen, printing its line, or until the terminal ends",
                           words: 0 ... 1, values: ["--text", "--timeout"], flags: ["--exit", "--ignore-case"],
                           json: true) { a in
                let until: CLIWaitUntil
                switch (a.value("--text"), a.flag("--exit")) {
                case (let text?, false): until = .text(text, ignoreCase: a.flag("--ignore-case"))
                case (nil, true) where !a.flag("--ignore-case"): until = .exit
                default: throw a.usage
                }
                return manage(a, .session(.wait(session: try a.session(before: 0), until: until,
                                                timeoutMs: try a.timeout(default: 30, maximum: 3600))))
            },
            CLICommandSpec("session events", ["[SESSION]"],
                           "Print what happens to terminals and agents, one line each, until interrupted",
                           words: 0 ... 1, json: true) { a in
                manage(a, .session(.events(session: try a.session(before: 0))))
            },
            CLICommandSpec("session stop", ["[SESSION] --yes"], "End the terminal; --saved still reads its output",
                           words: 0 ... 1, flags: ["--yes"]) { a in
                try a.confirm()
                return manage(a, .session(.stop(session: try a.session(before: 0))))
            },
            CLICommandSpec("session remove", ["[SESSION] --yes"], "End the terminal and delete its saved output",
                           words: 0 ... 1, flags: ["--yes"]) { a in
                try a.confirm()
                return manage(a, .session(.remove(session: try a.session(before: 0))))
            },
        ],
        notes: """
        A session is a terminal on the server. It keeps running after this command
        returns, whether or not the app is open, and the app lists it under Detached
        Terminals. To show one in the app, run tab pane new terminal SESSION.

        SESSION is an ID, a unique start of one (at least 4 characters), or a name
        such as wispy-cedar. Inside a Tab terminal it defaults to that terminal, and
        PROJECT to its project; elsewhere PROJECT defaults to Home.

        The words of COMMAND are joined with spaces, without shell quoting; quote the
        whole command to keep its quotes and pipes. Start it with exec when wait --exit
        should wait for that program rather than the shell.

        read and wait look at the visible screen, not the scrollback. --saved reads
        the last saved screen instead, which also works after the terminal ended.
        history and search print one page; pass its next as --before for the next.
        wait gives up after --timeout seconds: 30 by default, at most 3600.
        events prints started, ended, agent (working, blocked or idle), attention,
        completed and notification.
        Ended terminals and their output are removed after 7 days.
        list prints the columns id, projectId, status, attached, directory and name.
        """)

    static let project = CLIGroup(
        name: "project", summary: "The folders Tab works in", section: .server,
        commands: [
            CLICommandSpec("project list", [""], "Home first, then each project followed by its worktrees",
                           json: true) { a in
                manage(a, .project(.list))
            },
            CLICommandSpec("project new", ["DIRECTORY [--name NAME] [--create] [--reuse]"],
                           "Add a folder as a project and print its ID", words: 1 ... 1, values: ["--name"],
                           flags: ["--create", "--reuse"], json: true) { a in
                let name = try a.value("--name").map(projectName)
                return manage(a, .project(.new(directory: a.word(0), name: name, create: a.flag("--create"),
                                               reuse: a.flag("--reuse"))))
            },
            CLICommandSpec("project rename", ["PROJECT NAME"], "Rename a project", words: 2 ... 2) { a in
                manage(a, .project(.rename(project: a.word(0), name: try projectName(a.word(1)))))
            },
            CLICommandSpec("project remove", ["PROJECT --yes"],
                           "Remove a project and its worktree projects, ending their terminals", words: 1 ... 1,
                           flags: ["--yes"]) { a in
                try a.confirm()
                return manage(a, .project(.remove(project: a.word(0))))
            },
        ],
        notes: """
        A project is named by its ID, its name (ignoring case) when no other has it,
        or its folder.
        new adds a second project even when the folder already is one; --reuse prints
        the existing one instead, and --create makes the folder first.
        remove leaves the files and worktree folders on disk.
        list prints the columns id, name and directory.
        """)

    static let worktree = CLIGroup(
        name: "worktree", summary: "Git worktrees, each a project of its own", section: .server,
        commands: [
            CLICommandSpec("worktree list", ["PROJECT"], "The project's Git worktrees", words: 1 ... 1,
                           json: true) { a in
                manage(a, .worktree(.list(project: a.word(0))))
            },
            CLICommandSpec("worktree new", ["PROJECT NAME [--branch NAME] [--base REF | --existing] [--directory DIR] [--hooks]",
                                            "PROJECT --pr NUMBER [NAME] [--directory DIR] [--hooks]"],
                           "Create a worktree and its project, on a new branch or a pull request's",
                           words: 1 ... 2, values: ["--branch", "--base", "--directory", "--pr"],
                           flags: ["--existing", "--hooks"], json: true) { a in
                let name = try a.optional(1).map(projectName)
                guard let number = a.value("--pr") else {
                    guard let name else { throw a.usage }
                    if a.flag("--existing"), a.value("--base") != nil {
                        throw CLIError("--base and --existing can't be combined")
                    }
                    return manage(a, .worktree(.new(project: a.word(0), name: name,
                                                    branch: a.value("--branch") ?? name,
                                                    base: a.flag("--existing") ? nil : a.value("--base") ?? "HEAD",
                                                    directory: a.value("--directory"), hooks: a.flag("--hooks"))))
                }
                guard a.value("--branch") == nil, a.value("--base") == nil, !a.flag("--existing") else {
                    throw CLIError("--pr checks out the pull request's branch; leave out --branch, --base and --existing")
                }
                var digits = Substring(number)
                while digits.first == "#" { digits = digits.dropFirst() }
                guard let parsed = UInt64(digits), parsed > 0 else {
                    throw CLIError("--pr must be a pull request number")
                }
                return manage(a, .worktree(.pullRequest(project: a.word(0), number: parsed, name: name,
                                                        directory: a.value("--directory"), hooks: a.flag("--hooks"))))
            },
            CLICommandSpec("worktree register", ["PROJECT DIRECTORY"],
                           "Add a worktree that already exists on disk as a project", words: 2 ... 2,
                           json: true) { a in
                manage(a, .worktree(.register(project: a.word(0), directory: a.word(1))))
            },
            CLICommandSpec("worktree remove", ["WORKTREE --yes [--force] [--hooks]"],
                           "Delete the worktree's folder and project, ending its terminals", words: 1 ... 1,
                           flags: ["--yes", "--force", "--hooks"]) { a in
                try a.confirm()
                return manage(a, .worktree(.remove(worktree: a.word(0), force: a.flag("--force"),
                                                   hooks: a.flag("--hooks"))))
            },
        ],
        notes: """
        new branches from HEAD, or --base, under the worktree's name or --branch;
        --existing checks out a branch that exists instead. --pr checks out a pull
        request, named pr-NUMBER unless a name is given. The folder defaults to
        ~/.tab/worktrees/PROJECT/NAME.
        --hooks runs the setup or teardown commands of .tab/worktree.json and
        ~/.config/tab/worktree.json, printing each one; without it none run.
        remove refuses uncommitted changes unless --force is given.
        list prints the columns projectId, branch and directory.
        """)

    static let exec = CLIGroup(
        name: "exec", summary: "Run a program in a project's folder", section: .server,
        commands: [
            CLICommandSpec("exec", ["PROJECT [--timeout SECONDS] -- PROGRAM [ARG...]"],
                           "Run a program, without a shell, and print what it prints", words: 1 ... 1,
                           values: ["--timeout"], json: true, literal: true) { a in
                guard let argv = a.literal, !argv.isEmpty else { throw a.usage }
                return manage(a, .exec(project: a.word(0), argv: argv,
                                       timeoutMs: try a.timeout(default: 30, maximum: 300)))
            },
        ],
        notes: """
        For shell syntax, run /bin/sh -c '...'. The program gets --timeout seconds:
        30 by default, at most 300. A program that fails, times out or prints too
        much makes exec fail. --json prints the whole result.
        """)

    static let git = CLIGroup(
        name: "git", summary: "Run a Git action, given as JSON", section: .server,
        commands: [
            CLICommandSpec("git", ["PROJECT ACTION-JSON"], "Run the action and print the reply as JSON",
                           words: 2 ... 2) { a in
                manage(a, .git(project: a.word(0), action: a.word(1)))
            },
        ],
        notes: """
        The action is the protocol's GitAction, such as '{"type":"summary"}' or
        '{"type":"log","maxCount":20,"skip":0}'. Actions can change the repository.
        """)

    static let files = CLIGroup(
        name: "files", summary: "Run a file action, given as JSON", section: .server,
        commands: [
            CLICommandSpec("files", ["PROJECT ACTION-JSON"], "Run the action and print the reply as JSON",
                           words: 2 ... 2) { a in
                manage(a, .files(project: a.word(0), action: a.word(1)))
            },
        ],
        notes: """
        The action is the protocol's FilesAction, such as '{"type":"list","path":""}'
        or '{"type":"read","path":"README.md"}'. Paths are relative to the project.
        Actions can write and delete files.
        """)

    static let activity = CLIGroup(
        name: "activity", summary: "Agent states and unread events", section: .server,
        commands: [
            CLICommandSpec("activity list", [""], "One line per terminal with an agent or an unread event",
                           json: true) { a in
                manage(a, .activityList)
            },
            CLICommandSpec("activity ack", ["EVENT..."], "Mark events as read", words: 1 ... 1000) { a in
                manage(a, .activityAck(try a.words.map { word in
                    guard let id = UInt64(word) else { throw CLIError("event IDs are whole numbers") }
                    return id
                }))
            },
        ],
        notes: """
        list prints the columns session, project, provider, state, event and kind;
        --json prints the server's whole activity.
        """)

    static let settings = CLIGroup(
        name: "settings", summary: "Server settings", section: .server,
        commands: [
            CLICommandSpec("settings get", [""], "Print the settings as JSON") { a in
                manage(a, .settingsGet)
            },
            CLICommandSpec("settings set", ["KEY VALUE"], "Change a setting", words: 2 ... 2) { a in
                manage(a, .settingsSet(key: a.word(0), value: a.word(1)))
            },
        ],
        notes: """
        Keys: startup-command (a command line, or default), history-budget-bytes
        (a whole number) and shell-integration (true or false).
        """)

    static let mobile = CLIGroup(
        name: "mobile", summary: "Let phones connect, and pair them", section: .server,
        commands: [
            CLICommandSpec("mobile status", [""], "Whether phones can connect, and the paired ones") { a in
                manage(a, .mobile(.status))
            },
            CLICommandSpec("mobile enable", ["[--port N]"], "Let phones connect, on port 7419 or N",
                           values: ["--port"]) { a in
                let port: UInt16? = a.value("--port") == nil ? nil : try a.number("--port", default: 0, 1024 ... .max)
                return manage(a, .mobile(.enable(port: port)))
            },
            CLICommandSpec("mobile disable", [""], "Stop phones from connecting") { a in
                manage(a, .mobile(.disable))
            },
            CLICommandSpec("mobile pair", ["[--address HOST]..."], "Show a pairing code and wait for the phone",
                           lists: ["--address"]) { a in
                let addresses = a.list("--address")
                for address in addresses {
                    do {
                        try Validation.pairingHosts([address])
                    } catch {
                        throw CLIError("--address \(address): use a DNS name or an IPv4 address, without a port")
                    }
                }
                guard addresses.count <= Limits.maxPairingHosts else {
                    throw CLIError("a pairing code holds at most \(Limits.maxPairingHosts) addresses")
                }
                return manage(a, .mobile(.pair(addresses: addresses)))
            },
            CLICommandSpec("mobile revoke", ["DEVICE"], "Unpair a device by the start of its ID",
                           words: 1 ... 1) { a in
                manage(a, .mobile(.revoke(device: a.word(0))))
            },
        ],
        notes: """
        A pairing code lists the server's own addresses. --address puts a DNS name or
        IPv4 address first, for a server phones reach by another name, such as a
        cloud server's public one; repeat it for more, up to 8 in all.
        """)

    static let server = CLIGroup(
        name: "server", summary: "Start, check or stop the server", section: .server,
        commands: [
            CLICommandSpec("server start", [""], "Start the server unless it runs, and print its version as JSON") { a in
                manage(a, .server(.start))
            },
            CLICommandSpec("server status", [""], "Print the running server's version as JSON") { a in
                manage(a, .server(.status))
            },
            CLICommandSpec("server stop", ["[--force --yes]"],
                           "Stop the server when no terminal runs; --force ends them", flags: ["--force", "--yes"]) { a in
                if a.flag("--force") { try a.confirm() }
                return manage(a, .server(.stop(force: a.flag("--force"))))
            },
        ],
        notes: """
        Every other command starts the server when it isn't running; status and stop
        never do.
        """)

    static let device = CLIGroup(
        name: "device", summary: "The server's iOS simulators and Android emulators", section: .server,
        commands: [
            CLICommandSpec("device list", [""], "One line per device: its ID, platform, name, OS and state", json: true) { a in
                manage(a, .device(.list))
            },
            CLICommandSpec("device boot", ["DEVICE"], "Start a device", words: 1 ... 1) { a in
                manage(a, .device(.boot(device: a.word(0))))
            },
            CLICommandSpec("device shutdown", ["[--device DEVICE]"], "Shut a device down", values: ["--device"]) { a in
                manage(a, .device(.shutDown(device: a.value("--device"))))
            },
            CLICommandSpec("device screenshot", ["[--device DEVICE] [--output FILE]"],
                           "Save the screen as a PNG, or write it to stdout", values: ["--device", "--output"]) { a in
                manage(a, .device(.screenshot(device: a.value("--device"), output: a.value("--output"))))
            },
            CLICommandSpec("device tap", ["[--device DEVICE] X Y"], "Tap a point, in the screenshot's pixels",
                           words: 2 ... 2, values: ["--device"]) { a in
                guard let x = Double(a.word(0)), let y = Double(a.word(1)), x >= 0, y >= 0 else {
                    throw CLIError("X and Y are pixels of the screenshot, from its top left")
                }
                return manage(a, .device(.tap(device: a.value("--device"), x: x, y: y)))
            },
            CLICommandSpec("device type", ["[--device DEVICE] TEXT"], "Type text on the device's keyboard",
                           words: 1 ... 1, values: ["--device"]) { a in
                manage(a, .device(.type(device: a.value("--device"), text: a.word(0))))
            },
            CLICommandSpec("device press", ["[--device DEVICE] home|back|recents|lock"], "Press a button",
                           words: 1 ... 1, values: ["--device"]) { a in
                guard let button = DeviceButton(rawValue: a.word(0)) else {
                    throw CLIError("buttons are home, back, recents and lock")
                }
                return manage(a, .device(.press(device: a.value("--device"), button: button)))
            },
            CLICommandSpec("device open", ["[--device DEVICE] URL"], "Open a URL, such as an app's deep link",
                           words: 1 ... 1, values: ["--device"]) { a in
                manage(a, .device(.open(device: a.value("--device"), url: a.word(0))))
            },
        ],
        notes: """
        Devices belong to the server, so an agent in a remote terminal sees the
        devices of the computer its app runs on. DEVICE is an ID or a name from list;
        without --device, commands use the only running device.
        """)

    static let forward = CLIGroup(
        name: "forward", summary: "Reach a server's port from this computer", section: .server,
        commands: [
            CLICommandSpec("forward", ["PORT [--local-port N]"],
                           "Forward 127.0.0.1:PORT here to the server's localhost:PORT until interrupted",
                           words: 1 ... 1, values: ["--local-port"]) { a in
                guard let remote = UInt16(a.word(0)), remote > 0 else { throw CLIError("PORT is a TCP port, 1 to 65535") }
                let local: UInt16? = a.value("--local-port") == nil ? nil : try a.number("--local-port", default: 0, 1 ... .max)
                return manage(a, .forward(remote: remote, local: local ?? remote))
            },
        ],
        notes: """
        With --host, a physical phone or a Mac app on this computer reaches a server
        on another one, such as its Metro bundler. Browser and device panes in a
        remote tab use the server's network already.
        """)

    // MARK: App

    static let pane = CLIGroup(
        name: "pane", summary: "Add a terminal, agent or browser pane beside yours", section: .app,
        commands: [
            CLICommandSpec("pane new terminal", ["[SESSION] [--project PROJECT] [--directory DIR] [-- COMMAND...]"],
                           "Show SESSION, or start a terminal, in a new pane; prints the session ID",
                           words: 0 ... 1, values: ["--project", "--directory"], json: true, literal: true,
                           place: .app) { a in
                .pane(CLIPane(placement: .pane, project: a.value("--project"),
                              content: try terminal(a)), json: a.json)
            },
            CLICommandSpec("pane new agent", ["[--project PROJECT] [--provider claude|codex]", "--fork [AGENT]"],
                           "Start an agent conversation in a new pane, or copy one with --fork; prints its ID",
                           words: 0 ... 1, values: ["--project", "--provider"], flags: ["--fork"], json: true,
                           place: .app) { a in
                guard a.flag("--fork") else {
                    guard a.words.isEmpty else { throw a.usage }
                    return .pane(CLIPane(placement: .pane, project: a.value("--project"), content: try agent(a)),
                                 json: a.json)
                }
                guard a.value("--project") == nil, a.value("--provider") == nil else {
                    throw CLIError("a fork keeps its project and provider; leave out --project and --provider")
                }
                if let agent = a.optional(0), SessionId(string: agent) == nil { throw CLIError("an agent is named by its ID") }
                return .pane(CLIPane(placement: .pane, project: nil, content: .fork(agent: a.optional(0))), json: a.json)
            },
            CLICommandSpec("pane new browser", ["[URL] [--project PROJECT] [--profile PROFILE]"],
                           "Open a page in a new pane; prints the browser's ID", words: 0 ... 1,
                           values: ["--project", "--profile"], json: true, place: .app) { a in
                .pane(CLIPane(placement: .pane, project: a.value("--project"),
                              content: .browser(url: a.optional(0), profile: a.value("--profile"))), json: a.json)
            },
        ],
        notes: """
        Panes open in the app on this Mac, which starts if it isn't running. A new
        pane goes beside the Tab terminal or agent this command runs in. Elsewhere it
        goes into the tab of PROJECT, by default Home, where it becomes a new tab.
        To add a tab of its own, use tab tab new.

        SESSION is a terminal started earlier, such as with tab session new. A fork
        keeps the conversation's transcript, provider, model, effort and access, and
        then goes on by itself; AGENT defaults to the agent this command runs in.
        Use the printed browser ID with tab browser.
        """)

    static let tab = CLIGroup(
        name: "tab", summary: "Add a terminal, agent or browser tab to Home", section: .app,
        commands: [
            CLICommandSpec("tab new terminal", ["[--directory DIR] [-- COMMAND...]"],
                           "Start a terminal in a new tab; prints the session ID", values: ["--directory"],
                           json: true, literal: true, place: .app) { a in
                .pane(CLIPane(placement: .tab, project: nil, content: try terminal(a)), json: a.json)
            },
            CLICommandSpec("tab new agent", ["[--provider claude|codex]"],
                           "Start an agent conversation in a new tab; prints its ID", values: ["--provider"],
                           json: true, place: .app) { a in
                .pane(CLIPane(placement: .tab, project: nil, content: try agent(a)), json: a.json)
            },
            CLICommandSpec("tab new browser", ["[URL] [--profile PROFILE]"],
                           "Open a page in a new tab; prints the browser's ID", words: 0 ... 1,
                           values: ["--profile"], json: true, place: .app) { a in
                .pane(CLIPane(placement: .tab, project: nil,
                              content: .browser(url: a.optional(0), profile: a.value("--profile"))), json: a.json)
            },
        ],
        notes: """
        A tab is a card in the sidebar. Tabs open in Home in the app on this Mac,
        which starts if it isn't running. To add a pane to an existing tab, use
        tab pane new.
        """)

    private static func terminal(_ a: CLIArguments) throws -> CLIPane.Content {
        let session = try a.session(before: 0)
        let command = a.literal?.joined(separator: " ")
        if let command, command.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CLIError("missing command after --")
        }
        if session != nil, command != nil || a.value("--directory") != nil || a.value("--project") != nil {
            throw CLIError("SESSION is already running; leave out --project, --directory and the command")
        }
        return .terminal(session: session, directory: a.value("--directory"), command: command)
    }

    private static func agent(_ a: CLIArguments) throws -> CLIPane.Content {
        let name = a.value("--provider") ?? AgentChatProvider.claude.rawValue
        guard let provider = AgentChatProvider(rawValue: name) else {
            throw CLIError("--provider must be \(AgentChatProvider.allCases.map(\.rawValue).joined(separator: " or "))")
        }
        return .agent(provider: provider)
    }

    // MARK: This Mac

    static let integrations = CLIGroup(
        name: "integrations", summary: "Teach coding agents on this Mac to use tab", section: .local,
        commands: [
            CLICommandSpec("integrations status", [""], "What is installed for each coding agent", json: true,
                           place: .local) { a in
                .integrations(.status, json: a.json)
            },
            CLICommandSpec("integrations install", ["[--dir DIR]..."],
                           "Install the tab-cli skill and the hooks; --dir adds a skills folder", lists: ["--dir"],
                           json: true, place: .local) { a in
                .integrations(.install(directories: a.list("--dir")), json: a.json)
            },
            CLICommandSpec("integrations remove", [""], "Take the skill and the hooks out again", json: true,
                           place: .local) { a in
                .integrations(.remove, json: a.json)
            },
            CLICommandSpec("integrations context", [""],
                           "Print what an agent starting in a Tab terminal is told (run by the hooks)",
                           place: .local) { _ in
                .integrations(.context, json: false)
            },
            CLICommandSpec("integrations report", ["AGENT working|blocked|idle|ended"],
                           "Tell Tab what this terminal's agent does (run by the hooks)", words: 2 ... 2,
                           place: .local) { a in
                guard let agent = CodingAgent(rawValue: a.word(0)) else { throw a.usage }
                let state: AgentState? = switch try a.choice(1, ["working", "blocked", "idle", "ended"]) {
                case "working": .working
                case "blocked": .blocked
                case "idle": .idle
                default: nil
                }
                let provider: AgentProvider = switch agent {
                case .claude: .claude
                case .codex: .codex
                case .opencode: .openCode
                case .pi: .pi
                }
                return .integrations(.report(provider: provider, state: state), json: false)
            },
        ],
        notes: """
        Coding agents are Claude Code, Codex, OpenCode and Pi. install writes the
        tab-cli skill into each one found, and into Claude Code and Codex hooks that
        run tab integrations context when a session starts and tab integrations report
        as the agent works. Codex runs a new hook only after you approve it with
        /hooks. remove keeps every other skill, hook and setting. report prints
        nothing and never fails, so a missing server doesn't disturb the agent.
        status prints the columns agent, found, skill and hook.
        """)

    static let stdio = CLIGroup(
        name: "stdio", summary: "Join stdin and stdout to the server", section: .local,
        commands: [
            CLICommandSpec("stdio", ["[--no-start]"], "Run over SSH by Tab on another computer",
                           flags: ["--no-start"], place: .local) { a in
                .stdio(a.flag("--no-start") ? .never : .ifNeeded)
            },
        ],
        notes: "--no-start uses only a running server.",
        hidden: true)

    // MARK: Helpers

    static func key(_ key: String) throws -> Data {
        switch key.lowercased() {
        case "escape", "esc": Data([0x1B])
        case "enter", "return": Data([0x0D])
        case "tab": Data([0x09])
        case "ctrl+c", "ctrl-c": Data([0x03])
        case "ctrl+d", "ctrl-d": Data([0x04])
        case "ctrl+z", "ctrl-z": Data([0x1A])
        case "backspace": Data([0x7F])
        default: throw CLIError("unknown key \(key); use Enter, Tab, Escape, Backspace, Ctrl+C, Ctrl+D or Ctrl+Z")
        }
    }

    static func projectName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw CLIError("a name can't be empty") }
        return trimmed
    }
}
