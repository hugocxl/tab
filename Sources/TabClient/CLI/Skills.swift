import Foundation

/// The tab-cli skill, which teaches AI coding agents to use `tab`, and
/// installing it into skills folders.
public enum AgentSkill {
    public static let folderName = "tab-cli"

    /// Writes the skill into each of `directories`, replacing an older copy,
    /// and returns the files written.
    public static func install(directories: [String],
                               currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> [URL] {
        try directories.map { directory in
            let root = URL(fileURLWithPath: directory, relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true))
                .standardizedFileURL
            let folder = root.appendingPathComponent(folderName, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        }
    }

    public static let text = #"""
    ---
    name: tab-cli
    description: How to drive Tab from a shell with the `tab` command — start terminals that keep running, type into them, read and wait on their output, open terminal, agent and browser panes in the app, fork your own conversation into a new agent pane, and manage projects and Git worktrees. Use this when you are an agent running inside a Tab terminal or Tab agent pane (or any script on the same computer) and want work to run in its own terminal instead of blocking yours, the user asks for a new terminal, agent or browser pane or tab, asks to branch or fork the conversation or split work into panes, or to drive the Tab app's built-in browser.
    ---

    # Tab CLI

    Tab keeps terminals in a background server. `tab` has two kinds of commands:

    - **On the server**: `session`, `project`, `worktree` and the like. A
      session is a terminal that keeps running after your command returns,
      whether or not the app shows it. These never open anything in the app.
    - **In the app**: `pane new` adds a pane beside yours, `tab new` adds a tab
      (a card in the sidebar) to Home, and `browser` drives a browser pane.

    Run `tab --help` and `tab <command> --help` for every option. Commands that
    print data take `--json`.

    ## When to use it

    - Start a long-running process (a dev server, a test watcher, a log tail) in its
      own terminal, then check on it later.
    - Wait until that process prints something, or exits, before going on.
    - Show the user a terminal, agent or browser in a pane.
    - Create a Git worktree for a task.

    Don't use it for work a plain command can do in your own terminal.

    ## Inside Tab

    Tab sets `TAB_SESSION_ID` and `TAB_SERVER_ID` in every terminal, and
    `TAB_AGENT_ID` in its own agent panes, which also have `tab` on `PATH`.
    Session commands then default to your own terminal, a missing project to
    your project, and new panes open beside yours, so most commands need no IDs.

    ## Start a terminal and capture its ID

    `session new` starts a terminal that runs unseen and prints its ID. Everything
    after `--` is typed into it, followed by Return. Capture the ID; never guess one.

    ```bash
    WEB=$(tab session new -- npm run dev)
    TESTS=$(tab session new --project MyProject --directory ./packages/api -- exec npm test)
    ```

    Outside Tab the project defaults to Home; name another with `--project`: an
    ID, a unique name, or its folder.

    Every session also has a name, such as `wispy-cedar`, shown by `session list`.
    It works wherever an ID does while no other session has it.

    The words after `--` are joined with spaces, so quote the whole command to keep
    its own quotes, pipes, or `;`:

    ```bash
    tab session new -- 'grep -rn "TODO list" src | wc -l'
    ```

    ## Show things in the app

    When the user asks for a terminal, agent or browser "pane", add one with
    `pane new`; a terminal from `session new` runs unseen.

    ```bash
    tab pane new terminal                     # a new terminal pane beside yours
    tab pane new terminal -- npm run dev      # the same, running a command
    tab pane new terminal "$WEB"              # show a terminal you started earlier
    tab pane new agent                        # a new agent pane, a fresh conversation
    tab pane new agent -- "Review the open PR"   # the same, starting on that message
    tab pane new agent --fork                 # a new agent pane continuing this conversation
    tab pane new browser http://localhost:3000   # prints the browser's ID
    tab tab new terminal                      # a new tab in Home instead
    ```

    `pane new agent --fork` copies your transcript, model, effort and access mode,
    so the user can carry on in parallel. Never start `claude` or `codex` in a
    terminal for that: it is a separate program that asks its own questions, such
    as whether to trust the folder, regardless of the access mode chosen in Tab.

    ## Branch the conversation

    When the user asks to branch or fork this conversation, or to split work
    into panes, fork once per branch and give each its part after `--`:

    ```bash
    tab pane new agent --fork -- "Show the first draft and edit it with me"
    tab pane new agent --fork -- "Show the second draft and edit it with me"
    ```

    Each branch knows everything said up to the fork, starts on its message, and
    the user talks to it in its pane. Your own subagent or task tools are not
    panes: Tab doesn't show them. You can't see a branch's replies, so don't
    report what it found; tell the user the branches are open.

    ## Wait instead of polling

    ```bash
    tab session wait "$WEB" --text "ready" --timeout 120   # prints the matching line
    tab session wait "$TESTS" --exit                        # prints how it ended
    ```

    `wait` fails with a nonzero exit if the timeout passes (default 30 seconds)
    or, for `--text`, if the terminal ends without showing the text. It looks at
    the visible screen, not scrollback. Don't wait on your own terminal: it is
    busy running `tab`.

    `--exit` waits for the terminal's shell to end. Use `exec` for a one-shot command,
    as in the test example, so the program replaces the shell and its exit ends the
    session. Without `exec`, the shell stays open after the program finishes.

    ## Follow what happens

    `tab session events` prints one line per event until stopped: terminals
    starting and ending, agents changing state (`working`, `blocked`, `idle`),
    and notifications programs send. Give a session to follow only that one.

    ```bash
    tab session events "$TESTS" --json          # one JSON object per line
    ```

    ## Read output

    ```bash
    tab session read "$WEB" --lines 40          # last visible rows, not scrollback
    tab session search "$WEB" "error" --ignore-case
    tab session history "$WEB" --limit 200      # JSON, paged with --before
    ```

    After a terminal ends, add `--saved` to read its last saved output.

    ## Send input deliberately

    `send` types text without pressing Return; `press` presses one key
    (Enter, Tab, Escape, Backspace, Ctrl+C, Ctrl+D, Ctrl+Z).

    ```bash
    tab session press "$WEB" Ctrl+C
    tab session read "$WEB"
    tab session send "$WEB" "npm run dev"
    tab session press "$WEB" Enter
    ```

    You are typing into a live terminal. Read the screen first if you are unsure
    what is running.

    ## Stop terminals you started

    ```bash
    tab session list --project MyProject     # id, projectId, status, attached, directory, name
    tab session stop "$WEB" --yes
    ```

    Only stop terminals you started. A terminal the user is looking at closes in
    their app too.

    ## Projects and worktrees

    ```bash
    tab project list
    tab project new ~/code/app --reuse               # prints the existing project if there is one
    tab worktree new MyProject login                 # branch "login" from HEAD, default location
    tab worktree new MyProject fix --branch fix/x --base main --hooks
    tab worktree new MyProject --pr 42               # check out pull request 42
    tab worktree list MyProject
    tab worktree remove login --yes
    ```

    `--hooks` runs the setup or teardown commands from `.tab/worktree.json`; ask
    the user before using it. `worktree remove` refuses uncommitted changes unless
    `--force` is given; never pass `--force` without the user's consent.

    ## Browser

    `tab browser` drives the browser panes of the Tab app on this Mac: read a
    page, click and type, take screenshots. Open one with `pane new browser` or
    `tab new browser`, which print its ID.

    ```bash
    PAGE=$(tab pane new browser http://localhost:3000)
    tab browser wait-for-navigation "$PAGE"
    tab browser snapshot "$PAGE"                       # interactive elements, each with a selector
    tab browser fill "$PAGE" "#email" "me@example.com"
    tab browser click "$PAGE" "button[type=submit]"
    tab browser wait "$PAGE" --text "Welcome" --timeout 10
    tab browser read "$PAGE"                           # title, URL and page text
    ```

    - Capture the ID that `pane new browser` prints, or find it with
      `tab browser list`; never guess one.
    - Wait after anything that loads a page (opening, `navigate`, a submitting
      `click`, `back`): `wait-for-navigation`, `wait-for <selector>`, or `wait`.
    - `snapshot` lists the interactive elements, each with a `selector` you can
      pass to `click`, `fill`, `type`, and the other element commands. They print
      `false` when nothing matches.
    - `eval` runs JavaScript in the page and prints the result as JSON.
    - Screenshots work on background browsers:
      `tab browser screenshot "$PAGE" | base64 -D > page.png`.
    - Close only browsers you opened.

    ## Simulators and emulators

    `tab device` drives the iOS simulators and Android emulators of the server
    your terminal runs on, so you can check UI work where the app builds.

    ```bash
    tab device list                                    # id, platform, name, runtime, state
    tab device boot "iPhone 17"
    tab device screenshot --output screen.png          # look at it before tapping
    tab device tap 200 640                             # pixels of that screenshot
    tab device type "hello"
    tab device press home
    tab device open "myapp://settings"
    ```

    - Without `--device`, commands use the only running device.
    - Take a new screenshot after each action to see its effect.
    - Shut down only devices you started.

    ## Other computers

    Put `--host user@computer` before a server command, such as `session`,
    `project`, or `worktree`, to use another computer's server over SSH.
    Folders are then absolute paths on that computer. `pane`, `tab`, `browser`
    and `integrations` work on this Mac only and don't take `--host`.
    `tab --host user@computer forward 8081` makes that computer's port 8081
    reachable on this Mac's localhost until stopped.

    """#
}
