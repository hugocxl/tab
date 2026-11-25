import Foundation

/// What Tab tells a coding agent about where it runs and how to drive the app,
/// so that a request such as "open a terminal here" works without the user
/// naming commands. Tab's agent panes get it as part of their system prompt;
/// an agent started in a Tab terminal gets it from the session-start hook.
public struct AgentContext: Hashable, Sendable {
    public enum Place: Hashable, Sendable {
        /// A Tab agent pane, which shows the conversation itself.
        case agentPane(agent: String)
        /// A Tab terminal, such as one running Claude Code.
        case terminal(session: String, name: String?)
    }

    /// The project the agent works in.
    public struct Project: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            /// The user's Home, where every card is a tab of its own.
            case home
            case project
            /// A Git worktree of the named project.
            case worktree(of: String?)
        }

        public var name: String
        public var directory: String
        public var kind: Kind

        public init(name: String, directory: String, kind: Kind) {
            self.name = name
            self.directory = directory
            self.kind = kind
        }
    }

    public var place: Place
    public var project: Project?
    /// The `tab` program, when known.
    public var cli: String?
    /// The user's computers, as their app last described them to this server.
    public var infrastructure: Infrastructure?
    /// The computer the agent runs on.
    public var machine: MachineInfo?

    public init(place: Place, project: Project? = nil, cli: String? = nil,
                infrastructure: Infrastructure? = nil, machine: MachineInfo? = nil) {
        self.place = place
        self.project = project
        self.cli = cli
        self.infrastructure = infrastructure
        self.machine = machine
    }

    /// Set in an agent pane's environment when its system prompt already
    /// holds the context, so the session-start hook doesn't repeat it.
    public static let providedVariable = "TAB_AGENT_CONTEXT"

    /// The instructions, in Markdown.
    public var text: String {
        [location, vocabulary, computers, rules].compactMap { $0 }.joined(separator: "\n\n")
    }

    private var command: String {
        cli.map { "`tab` (\($0))" } ?? "`tab`"
    }

    private var location: String {
        let opening: String
        switch place {
        case .agentPane(let agent):
            opening = """
            You are running inside Tab, a macOS terminal workspace app, in an agent pane (agent \(agent)). The \
            user reads this conversation in a pane of Tab's window, and \(command) drives the app from your shell.
            """
        case let .terminal(session, name):
            let named = name.map { ", \($0)" } ?? ""
            opening = """
            You are running inside Tab, a macOS terminal workspace app, in one of its terminals (session \
            \(session)\(named)). The user sees this terminal as a pane of Tab's window, and \(command) drives the \
            app from your shell. Session commands default to this terminal, but don't `tab session wait` on it: \
            it is busy running you.
            """
        }
        guard let project else { return "# Tab\n\n" + opening }
        let folder = "\(project.name) (\(project.directory))"
        let belongs = switch project.kind {
        case .home: "You work in Home, the user's home folder (\(project.directory)), where every sidebar card is a tab of its own."
        case .project: "You work in the project \(folder); it is one tab in the sidebar."
        case .worktree(let parent):
            "You work in \(folder), a Git worktree\(parent.map { " of \($0)" } ?? ""); it is one tab in the sidebar."
        }
        return "# Tab\n\n" + opening + " " + belongs
    }

    private var vocabulary: String {
        """
        When the user asks for something in the app, run the `tab` command yourself instead of explaining it. \
        In Tab a tab is a card in the sidebar, and a pane is one terminal, agent, browser, simulator, editor or \
        diff in a tab's split layout. Users say these loosely, so act on what they mean:

        - "open a terminal", "new tab", "split", "another shell (here)": `tab pane new terminal`, a pane beside \
        yours in this tab. Add `-- <command>` to run something in it, such as a dev server.
        - New panes open on the right of yours, side by side. Add `--edge down|up|left` only when the user \
        says "below", "under", "above" or "on the left"; beside another pane: `--beside <pane>`.
        - "open <url>", "show me the page", "localhost:3000": `tab pane new browser <url>`.
        - "open <file> (at line N)": `tab pane new editor <file> --line N`; "show the diff of <file>": \
        `tab pane new diff <file>`.
        - "show the simulator", "the emulator": `tab pane new simulator [name]`.
        - To check UI work yourself, read pages and screens as text and act on refs: `tab browser snapshot` and \
        `tab simulator snapshot -i` print elements such as `@e3 [button] "Sign in"`; `tab browser click @e3` and \
        `tab simulator tap @e3 --settle` act on them. Take screenshots only to see pixels. `tab browser --help` and \
        `tab simulator --help` list the rest.
        - "another agent", "a new chat": `tab pane new agent -- "<task>"`; "branch" or "fork this \
        conversation": `tab pane new agent --fork -- "<what the branch does>"` once per branch.
        - A new sidebar card only when they say so, such as "a new tab in Home" or "in the sidebar": \
        `tab tab new terminal|agent|browser|simulator`.
        - "this pane", "that one", "the one on the left", "the server terminal": run `tab pane list` first, and \
        pick by position, kind and title. `left`, `right`, `up` and `down` name the pane on that side of yours, \
        and `focused` the one the user last focused.
        - "close", "focus", "zoom" or "maximize", "move", "swap", "make it bigger", "even them out": \
        `tab pane close|focus|zoom|move|swap|resize|equalize <pane>`.
        - "close this tab", "close the card": `tab tab close <tab or pane>`, such as `self` for yours. Closing your \
        own pane or tab ends you once the command returns, so finish your reply first; a worktree's tab removes \
        the worktree. If that would lose anything, the command fails and says what: ask the user, and with their \
        yes add `--force`.
        """
    }

    /// Where the agent runs among the user's computers, and how to reach the
    /// others. Left out for someone with one computer, where it says nothing.
    private var computers: String? {
        guard let infrastructure, infrastructure.computers.count > 1 else { return nil }
        let here = infrastructure.receiver.flatMap { id in infrastructure.computers.first { $0.id == id } }
        let seat = infrastructure.seat
        let atSeat = here.map { $0.role == .seat } ?? false
        let hereName = here?.name ?? machine?.name
        let hardware = (machine ?? here?.machine).map(\.summary).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""

        var opening: String
        switch (hereName, atSeat) {
        case (let name?, true):
            opening = "You run on **\(name)**\(hardware), the Mac the user sits at, so its files, processes and " +
                "`localhost` are the ones the user works with."
        case (let name?, false):
            let seatName = seat.map { "**\($0.name)**" } ?? "another Mac"
            opening = "You run on **\(name)**\(hardware), a Tab server. The user sits at \(seatName) and sees you " +
                "through Tab there: files, processes and `localhost` here are \(name)'s, not \(seat?.name ?? "theirs"). " +
                "Tab's browser panes reach this computer's `localhost` through a tunnel."
        case (nil, _):
            opening = "You run on one of the user's computers below."
        }

        let lines = infrastructure.computers.map { computer -> String in
            let you = computer.id == here?.id ? " (you)" : ""
            let specs = computer.machine.map(\.summary).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
            let group = computer.group.map { ", group \($0)" } ?? ""
            let what: String
            switch computer.role {
            case .seat: what = "where the user sits, running the Tab app"
            case .tabServer: what = "Tab server" + reach(computer, fromSeat: atSeat)
            case .sshHost: what = "SSH only, no Tab" + reach(computer, fromSeat: atSeat)
            case .unknown: what = "another computer" + reach(computer, fromSeat: atSeat)
            }
            return "- **\(computer.name)**\(you): \(what)\(group)\(specs)"
        }

        let dest = atSeat ? "the host in its `ssh` command, such as an SSH config alias" : "the address after `ssh`"
        return """
        ## The user's computers

        \(opening) When the user names one of these computers, they mean it; don't search for it.

        \(lines.joined(separator: "\n"))

        To send work to a Tab server, run it there so it keeps running and shows in Tab: \
        `tab --host DEST session new --project PROJECT -- COMMAND` starts a terminal (follow it with \
        `tab --host DEST session read` or `session wait`), and `tab --host DEST exec PROJECT -- PROGRAM` runs a \
        short program; `tab --host DEST project list` names its projects. On an SSH-only computer, run \
        `ssh DEST 'COMMAND'`, or open a shell the user can watch with `tab pane new terminal -- ssh DEST`. \
        DEST is \(dest). Pick a computer that fits the work: its chip, architecture and memory are listed.
        """
    }

    /// How this agent's computer reaches `computer`: the seat's own SSH
    /// settings there, the resolved address anywhere else.
    private func reach(_ computer: Infrastructure.Computer, fromSeat: Bool) -> String {
        if fromSeat {
            if let command = computer.sshCommand { return ", reached with `\(command)`" }
            guard let ssh = computer.ssh else { return "" }
            let resolved = computer.address.map { " (\($0))" } ?? ""
            return ", `\(ssh)`\(resolved)"
        }
        if let address = computer.address { return ", `ssh \(address)`" }
        if computer.sshCommand != nil { return ", reachable only from the user's Mac" }
        return computer.ssh.map { ", `\($0)` on the user's Mac" } ?? ""
    }

    private var rules: String {
        let general = """
        Panes, splits, tabs and windows always mean Tab's, never your own subagents or task tools, which Tab \
        doesn't show. Run long-lived work such as dev servers and watchers in a pane or with `tab session new`, \
        not in your own shell. Never start `claude` or `codex` in a terminal; use `tab pane new agent`. Close or \
        stop only panes and terminals you opened, unless the user asks. If `tab pane` can't reach the app, you \
        run on another computer: tell the user what to open. `tab pane --help` and `tab --help` list every option.
        """
        guard case .agentPane = place else { return general }
        return general + "\n\n" + """
        Agents you start with `tab pane new agent` are yours. A new one sees only its message, so make it \
        self-contained; give each one that changes files its own worktree with `--worktree <name>`. When work \
        you sent one ends, fails or waits for the user, Tab sends you its report as your next message, so end \
        your turn instead of waiting on it. They get at most your access, and only the user approves their \
        requests. `tab agent list --children` lists them, and `tab agent stop <agent>` stops one and those it \
        started.
        """
    }
}
