/// Usage text of the `tab` command line tool.
public enum CLIHelp {
    public static let root = """
    Tab - terminal workspace command line tool

    Usage: tab [--host DESTINATION] [COMMAND]

      <folder>      Open a folder as a project in the Tab app
      server        Start, inspect or stop the server
      project       List, add, rename or delete server projects
      session       Create terminals, send input, read output and end sessions
      worktree      List, create, register or remove Git worktree projects
      settings      Read or update server settings
      activity      Read or acknowledge agent activity
      git           Run a server Git action using JSON
      files         Run a server file action using JSON
      exec          Execute a program in a server project
      mobile        Enable access, pair phones and revoke devices
      browser       Drive browser tabs in the Tab app on this computer
      install-skills
                    Install the tab-cli skill for AI coding agents
      stdio         Connect stdin/stdout to the server; used over SSH
      --help | --version | --build-info

    Run tab <command> --help or tab help <command> for usage. Management
    commands accept --json.
    Commands connect directly to the server, starting it if needed, except server
    status/stop, which never start it. --host uses the server on another computer
    over SSH (user@host, an ssh_config alias or ssh://user@host:port); Tab must be
    installed there, and directories are absolute paths on that computer.
    TAB_DIR selects the local profile folder. No app is required, except by
    browser commands and tab <folder>, which start it.
    Project selectors accept an exact ID, unique name or directory path.
    Inside a Tab terminal, session commands default to that terminal.
    Use ./NAME to open a folder named like a command.
    Use -- before literal arguments that start with a dash, or before the command
    of session create.
    """

    public static let server = """
    Usage: tab server start|status|stop [--json]
      stop [--force]  Stop only if idle; --force ends all running terminals.
    """

    public static let project = """
    Usage: tab project <action> [--json]
      list
      add <directory> [--name NAME] [--create] [--reuse]
      rename <project> <name>
      delete <project> --yes          Ends its terminals and deletes child projects;
                                     files and worktree folders stay on disk

    Add creates a distinct project even when its directory is already registered;
    --reuse prints the existing one instead. --create makes the directory first.
    Text list columns: id, name, directory (tab-separated).
    """

    public static let session = """
    Usage: tab session <action> [--json]
      list [--project PROJECT] [--all]  Live sessions; --all includes saved/ended ones
      create [project] [--directory PATH] [--cols N] [--rows N] [-- COMMAND...]
      send [id] <text>                 Send literal text without pressing Return
      send-keys [id] <key>             Enter, Tab, Escape, Backspace, Ctrl+C/D/Z
      read-screen [id] [--lines N] [--saved]
      history [id] [--before CURSOR] [--limit N] [--saved]
      search [id] <text> [--ignore-case] [--before CURSOR] [--limit N] [--saved]
      wait [id] --text TEXT [--ignore-case] | --exit
           [--timeout SECONDS | --timeout-ms N]
      end [id] --yes                   End the process, keeping saved output
      discard [id] --yes               End the process and delete saved output

    Create prints the new session ID and types COMMAND into it, then Return.
    COMMAND words are joined with spaces without shell quoting; quote the whole
    command to preserve its quotes and shell syntax.
    Sessions outlive this command; the app lists them under Existing Terminals.
    Session IDs are UUIDs; a unique start of one, of at least 4 characters, works.
    Inside a Tab terminal, the ID defaults to that terminal and the project to its
    project. Wait prints the first visible line containing TEXT, or how the session
    ended; it fails after the timeout (default 30 seconds, maximum 3600).
    Use exec in COMMAND when --exit should wait for that program to finish.
    Read-screen and wait briefly attach to a live terminal; --saved reads its last
    checkpoint instead and also works after it ends. They never close app panes.
    Ended sessions and their saved output are automatically removed after 7 days.
    Read-screen returns the last N visible rows (default 50), not scrollback.
    History/search return one page as JSON, with next for --before; 0 starts paging.
    Text list columns: id, project-id, status, attached, directory.
    """

    public static let worktree = """
    Usage: tab worktree <action> [--json]
      list <project>
      create <project> <name> [--branch NAME] [--base REF | --existing]
             [--directory PATH] [--hooks]
      checkout-pr <project> <number> [--name NAME] [--directory PATH] [--hooks]
      register <project> <directory>
      remove <worktree-project> --yes [--force] [--hooks]

    Create makes a new branch named after the worktree from HEAD; --existing checks
    out a branch that exists. The directory defaults to ~/.tab/worktrees/<project>/
    <name>. --hooks runs the setup or teardown commands from .tab/worktree.json
    and ~/.config/tab/worktree.json, printing each one; without it none run.
    Remove deletes the worktree directory and its project, ending its terminals,
    and refuses uncommitted changes unless --force is given.
    Text list columns: project-id, branch, directory (tab-separated).
    """

    public static let settings = """
    Usage: tab settings get [--json]
           tab settings set <key> <value> [--json]
    Keys: default-shell (absolute path or 'default'), history-budget-bytes (integer),
          shell-integration (true/false). Get returns JSON.
    """

    public static let activity = """
    Usage: tab activity list [--json]
           tab activity ack <event-id>... [--json]
    Text list columns: session-id, project-id, provider, state, event-id, event
    (tab-separated), one row per session. JSON returns the server's activity
    snapshot.
    """

    public static let git = """
    Usage: tab git <project> <action-json> [--json]
    Examples: tab git Home '{"type":"summary"}'
              tab git MyProject '{"type":"log","maxCount":20,"skip":0}'
    Uses the protocol's GitAction JSON shape and prints the GitReply JSON.
    Actions can modify the repository. Watch is unavailable on a one-shot client.
    """

    public static let files = """
    Usage: tab files <project> <action-json> [--json]
    Examples: tab files MyProject '{"type":"list","path":""}'
              tab files MyProject '{"type":"read","path":"README.md"}'
    Uses the protocol's FilesAction JSON shape and prints the FilesReply JSON.
    Paths are relative to the project. Actions can write or delete files.
    Watch/unwatch are unavailable on a one-shot client.
    """

    public static let exec = """
    Usage: tab exec <project> [--json] [--timeout-ms N] -- <program> [args...]
    Runs through the server in the project's directory, without a shell.
    For shell syntax, explicitly use /bin/sh -c '...'. Timeout defaults to 30000ms
    (maximum 300000ms). Text mode forwards stdout/stderr. JSON mode prints the
    complete result. A failed, timed-out, cancelled or truncated run exits nonzero.
    """

    public static let mobile = """
    Usage: tab mobile [action]
      (no action)               Mobile access status and paired devices
      enable [--port N]         Let phones connect; --port changes the port (7419)
      disable                   Turn mobile access off
      pair [--address HOST]...  Show a pairing code and wait for the phone
      revoke <device>           Revoke a device by the start of its ID

    Pairing codes list the server's own addresses. --address puts a DNS name or
    IPv4 address first, for a server that phones reach by another name, such as a
    cloud server's public name. Repeat it for more, up to 8 addresses in all.
    """

    public static let browser = """
    Usage: tab browser <action>
      open [url] [--split] [--project PROJECT] [--worktree WORKTREE]
           [--profile PROFILE]          Open a tab and print its ID
      list [--project PROJECT] [--worktree WORKTREE] [--json]
      navigate <tab-id> <url>
      read <tab-id> [--json]            Title, URL and page text
      close <tab-id>
      reload|back|forward <tab-id>
      screenshot <tab-id>               Print the page as a base64 PNG
      evaluate <tab-id> <javascript>    Print the result as JSON (also: eval)
      click|hover|scroll-into-view|check|uncheck <tab-id> <selector>
      fill <tab-id> <selector> <text>
      type <tab-id> <selector> <text> [--submit]
      press <tab-id> <key> [selector]
      select <tab-id> <selector> <value>
      is <tab-id> visible|hidden|enabled|disabled|checked <selector>
      get-text|get-value|get-count <tab-id> <selector>
      get-attribute <tab-id> <selector> <attribute>
      get-html <tab-id> [selector]
      find <tab-id> role|text|label|placeholder|testid <value>
      snapshot <tab-id> [selector]      Interactive elements, each with a selector
      wait <tab-id> [--selector SELECTOR] [--text TEXT] [--url-contains TEXT]
           [--function JAVASCRIPT] [--timeout-ms N]
      wait-for <tab-id> <selector> [ms]
      wait-for-navigation <tab-id> [ms | --timeout-ms N]
      storage get <tab-id> <key> [local|session]
      storage set <tab-id> <key> <value> [local|session]
      storage clear <tab-id> [local|session]
      cookies get <tab-id> [url]
      cookies set <tab-id> <name> <value> <domain> [--path PATH] [--secure]
                  [--http-only] [--expires UNIX-SECONDS]
      cookies delete <tab-id> <name> [domain]
      cookies clear <tab-id>

    Browser commands talk to the Tab app on this computer, not to the server, so
    they don't take --host. Open starts the app if it isn't running.
    Tabs open in the current project, or the one named by --project and
    --worktree; --split opens the tab beside the current pane instead.
    Use the tab ID that open or list prints. Page actions print their result as
    JSON. Waits give up after --timeout-ms or ms (default 5000, 10000 for
    wait-for-navigation; maximum 60000).
    TAB_CLI_TIMEOUT sets how many seconds the app has to answer (default 10).
    Text list columns: tab-id, title, url, profile, active (tab-separated).
    """

    public static let installSkills = """
    Usage: tab install-skills [--dir DIR]...
    Installs the tab-cli skill, which teaches AI coding agents to use this command,
    into each agent folder that exists: ~/.claude/skills, ~/.codex/skills and
    ~/.agents/skills. --dir adds another skills folder; repeat it for more.
    An installed copy is replaced.
    """

    public static let stdio = """
    Usage: tab stdio [--no-start]
    Joins stdin and stdout to this computer's server, for Tab on another computer,
    which runs it over SSH. --no-start uses only a running server.
    """

    /// The usage of a command group, for `tab help <group>`.
    public static func topic(_ group: String) -> String? {
        switch group {
        case "server": server
        case "project": project
        case "session": session
        case "worktree": worktree
        case "settings": settings
        case "activity": activity
        case "git": git
        case "files": files
        case "exec": exec
        case "mobile": mobile
        case "browser": browser
        case "install-skills": installSkills
        case "stdio": stdio
        default: nil
        }
    }
}
