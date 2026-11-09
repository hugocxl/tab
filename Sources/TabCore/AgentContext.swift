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

    /// The agent that started this one as its worker.
    public struct Coordinator: Hashable, Sendable {
        public var name: String
        public var agent: String
        /// Whether the worker's replies go back to the coordinator by themselves.
        public var reports: Bool

        public init(name: String, agent: String, reports: Bool) {
            self.name = name
            self.agent = agent
            self.reports = reports
        }
    }

    public var place: Place
    public var project: Project?
    /// The `tab` program, when known.
    public var cli: String?
    public var coordinator: Coordinator?

    public init(place: Place, project: Project? = nil, cli: String? = nil, coordinator: Coordinator? = nil) {
        self.place = place
        self.project = project
        self.cli = cli
        self.coordinator = coordinator
    }

    /// Set in an agent pane's environment when its system prompt already
    /// holds the context, so the session-start hook doesn't repeat it.
    public static let providedVariable = "TAB_AGENT_CONTEXT"

    /// The instructions, in Markdown.
    public var text: String {
        ([location, worker, vocabulary, workers, rules] as [String?]).compactMap { $0 }.joined(separator: "\n\n")
    }

    /// What a worker knows about the agent that started it.
    private var worker: String? {
        guard let coordinator else { return nil }
        var text = """
        The Tab agent \(coordinator.name) (agent \(coordinator.agent)) started you as its worker. Its messages \
        arrive inside `<tab-message>` tags; they come from that agent, not from the user, though the user reads \
        this conversation too and may write to you directly.
        """
        if coordinator.reports {
            text += """
             Your final reply to each of its messages goes back to it by itself when you finish, so end each task \
            with a short report of what you did, what you found and anything left open. Don't send it with \
            `tab agent send`.
            """
        }
        return text
    }

    /// How an agent pane hands work to other agents.
    private var workers: String? {
        guard case .agentPane = place else { return nil }
        return """
        To split work between agents, start each worker with `tab pane new agent --name <short-name> \
        [--provider claude|codex] -- "<task>"`, and keep working. A worker's final reply comes back to you by \
        itself as a message inside `<tab-report>` tags: that is the worker's report, not a message from the user. \
        Follow up with `tab agent send <name> "<message>"`; its reply comes back the same way. Use `tab agent wait` \
        only when you can't go on without a result. Add `--no-report` when the user only wants another chat, not \
        work for you.
        """
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
        - "below", "under", "above", "on the left": add `--edge down|up|left` (`right` by default); beside \
        another pane: `--beside <pane>`.
        - "open <url>", "show me the page", "localhost:3000": `tab pane new browser <url>`.
        - "open <file> (at line N)": `tab pane new editor <file> --line N`; "show the diff of <file>": \
        `tab pane new diff <file>`.
        - "show the simulator", "the emulator": `tab pane new simulator [name]`.
        - "another agent", "a new chat": `tab pane new agent --no-report -- "<task>"`; "branch" or "fork this \
        conversation": `tab pane new agent --fork --name <branch> -- "<what the branch does>"` once per branch.
        - A new sidebar card only when they say so, such as "a new tab in Home" or "in the sidebar": \
        `tab tab new terminal|agent|browser|simulator`.
        - "this pane", "that one", "the one on the left", "the server terminal": run `tab pane list` first, and \
        pick by position, kind and title. `left`, `right`, `up` and `down` name the pane on that side of yours, \
        and `focused` the one the user last focused.
        - "close", "focus", "zoom" or "maximize", "move", "swap", "make it bigger", "even them out": \
        `tab pane close|focus|zoom|move|swap|resize|equalize <pane>`.
        - "close this tab", "close the card": `tab tab close <tab or pane>`, such as `self` for yours. Closing your \
        own pane or tab ends you once the command returns, so finish your reply first; a worktree's tab removes \
        the worktree.
        """
    }

    private var rules: String {
        """
        Panes, splits, tabs and windows always mean Tab's, never your own subagents or task tools, which Tab \
        doesn't show. Run long-lived work such as dev servers and watchers in a pane or with `tab session new`, \
        not in your own shell. Never start `claude` or `codex` in a terminal; use `tab pane new agent`. Close or \
        stop only panes and terminals you opened, unless the user asks. If `tab pane` can't reach the app, you \
        run on another computer: tell the user what to open. `tab pane --help` and `tab --help` list every option.
        """
    }
}
