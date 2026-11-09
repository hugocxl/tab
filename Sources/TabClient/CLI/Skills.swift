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
    description: How to drive Tab from a shell with the `tab` command — open terminal, agent, browser, simulator, editor and diff panes in the app, list the panes on screen and focus, close, zoom, move, swap and resize them, start terminals that keep running, type into them, read and wait on their output, branch your own conversation into agent panes and read their replies, check apps on iOS simulators and Android emulators, and manage projects and Git worktrees. Use this when you are an agent running inside a Tab terminal or Tab agent pane (or any script on the same computer) and the user asks for anything in the app, however loosely — "open a terminal here", "new tab", "split this", "show me the page", "close that pane", "make it bigger", "put the tests below" — asks to branch or fork the conversation or split work into panes, wants work to run in its own terminal instead of blocking yours, or to drive the Tab app's built-in browser or a simulator.
    ---

    # Tab CLI

    Tab keeps terminals and agent conversations in a background server. `tab` has
    two kinds of commands:

    - **On the server**: `session`, `agent`, `project`, `worktree`, `simulator` and
      the like. A session is a terminal that keeps running after your command
      returns, whether or not the app shows it. These never open anything in the app.
    - **In the app**: `pane new` adds a pane beside yours, `pane list` shows the
      panes on screen, `pane focus|close|zoom|move|swap|resize|equalize` arrange
      them, `tab new` adds a tab (a card in the sidebar) to Home, and `browser`
      drives a browser pane.

    Run `tab --help` and `tab <command> --help` for every option. Commands that
    print data take `--json`.

    ## What users mean

    When the user asks for something in the app, run the command yourself instead
    of explaining it. In Tab a **tab** is a card in the sidebar and a **pane** is one
    terminal, agent, browser, simulator, editor or diff inside a tab. Users say
    these loosely:

    | The user says | Run |
    | --- | --- |
    | "open a terminal", "new tab", "split", "another shell here" | `tab pane new terminal` |
    | "run the dev server in a new terminal" | `tab pane new terminal -- npm run dev` |
    | "… below", "… on the left", "… above" | add `--edge down`, `--edge left`, `--edge up` |
    | "… next to the browser" | add `--beside <pane>` |
    | "open localhost:3000", "show me the page" | `tab pane new browser http://localhost:3000` |
    | "open App.swift at line 42" | `tab pane new editor App.swift --line 42` |
    | "show me the diff of App.swift" | `tab pane new diff App.swift` |
    | "show the simulator" | `tab pane new simulator` |
    | "start another agent on X" | `tab pane new agent -- "X"` |
    | "branch this", "fork the conversation" | `tab pane new agent --fork -- "<the branch's part>"` |
    | "a new tab in Home", "a new card in the sidebar" | `tab tab new terminal` (or agent, browser, simulator) |
    | "this pane", "that one", "the one on the left" | `tab pane list`, then pick by position, kind and title |
    | "close it", "focus the server", "maximize that" | `tab pane close`, `tab pane focus`, `tab pane zoom` |
    | "close this tab", "close that card" | `tab tab close self`, `tab tab close <tab or pane>` |
    | "move it below", "swap them", "make it bigger", "even them out" | `tab pane move`, `swap`, `resize`, `equalize` |

    Only use `tab tab new` when the user asks for a new card in the sidebar; "a new
    tab" said in passing almost always means a pane beside yours. Panes, splits and
    tabs never mean your own subagents or task tools, which Tab doesn't show.

    ## When to use it

    - Start a long-running process (a dev server, a test watcher, a log tail) in its
      own terminal, then check on it later.
    - Wait until that process prints something, or exits, before going on.
    - Show the user a terminal, agent, browser, simulator, file or diff in a pane.
    - Branch this conversation into agent panes the user can talk to.
    - Create a Git worktree for a task.

    Don't use it for work a plain command can do in your own shell.

    ## Where you run

    - **In a Tab terminal** (`TAB_SESSION_ID` is set): session commands default to
      your terminal, a missing project to its project, and new panes open beside it.
      Don't `wait` on your own terminal: it is busy running `tab`.
    - **In a Tab agent pane** (`TAB_AGENT_ID` is set, and `tab` is on `PATH`): you
      have no terminal of your own, so give session commands a session ID. A
      missing project means your agent's, and new panes open beside yours. Your
      own subagent or task tools are not panes: Tab doesn't show them.
    - **In a tab of another computer**: `tab` uses that computer's server, so
      sessions, projects and simulators are its own, and folders are paths there.
      `pane`, `tab` and `browser` can't reach the app the user is looking at; tell
      the user what to open instead.
    - **Anywhere else**: a missing project means Home.

    ## Start a terminal and capture its ID

    `session new` starts a terminal that runs unseen and prints its ID. Everything
    after `--` is typed into it, followed by Return. Capture the ID; never guess one.

    ```bash
    WEB=$(tab session new -- npm run dev)
    TESTS=$(tab session new --project MyProject --directory ~/code/app/packages/api -- exec npm test)
    ```

    `--project` takes an ID, a unique name, or its folder. `--directory` is
    relative to your current folder, not to the project, so prefer an absolute path.
    New terminals are 80 columns by 24 rows; add `--cols 200 --rows 50` when a
    program's output is wide or you'll wait on lines that would scroll off.

    Every session also has a name, such as `wispy-cedar`, shown by `session list`.
    It, or a unique start of the ID (at least 4 characters), works wherever an ID
    does.

    The words after `--` are joined with spaces, so quote the whole command to keep
    its own quotes, pipes, or `;`:

    ```bash
    tab session new -- 'grep -rn "TODO list" src | wc -l'
    ```

    ## Show things in the app

    When the user asks for a pane, add one with `pane new`; a terminal from
    `session new` runs unseen.

    ```bash
    tab pane new terminal                     # a new terminal pane beside yours
    tab pane new terminal -- npm run dev      # the same, running a command
    tab pane new terminal "$WEB"              # show a terminal you started earlier
    tab pane new agent                        # a new agent pane, a fresh conversation
    tab pane new agent -- "Review the open PR"   # the same, starting on that message
    tab pane new browser http://localhost:3000   # prints the browser's ID
    tab pane new simulator "iPhone 17"        # a simulator or emulator's screen
    tab pane new editor Sources/App.swift --line 42
    tab pane new diff Sources/App.swift       # its uncommitted changes; --staged for staged ones
    tab pane new terminal --edge down -- npm test   # below yours
    tab pane new browser http://localhost:3000 --beside "$EDITOR_PANE" --edge up
    tab tab new terminal                      # a new tab in Home instead
    tab tab new simulator
    ```

    - Inside Tab, a pane opens beside yours, on its right unless `--edge` says
      `left`, `up` or `down`. `--beside PANE` opens it beside another pane of the
      same computer's tabs. With `--project` it works in that project's folder,
      but it still opens beside you.
    - `editor` and `diff` take a file inside the project, absolute or relative to
      your current folder. A pane already showing that file is focused instead.
    - `simulator` without a name shows the only running simulator, else the picker.
    - Never start `claude` or `codex` in a terminal to give the user another agent:
      it is a separate program that asks its own questions, such as whether to trust
      the folder, regardless of the access mode chosen in Tab. Use `pane new agent`.

    ## See and arrange the panes on screen

    `pane list` prints the panes of your tab, one per line: id, kind, position,
    flags, title, session and project. `--all` lists every tab; `--json` adds the
    tab, folders, browser URLs and each pane's share of the tab.

    ```bash
    tab pane list
    # 6f1c…  agent     left         self             Agent           …
    # 9a2e…  terminal  top right    focused          npm run dev     …   wispy-cedar
    # c47b…  browser   bottom right                  localhost:3000
    ```

    - position is `whole`, `left`, `right`, `top`, `bottom`, `top left`, … as the
      user sees it. flags are `self` (the pane you run in), `focused`, `zoomed`
      and `hidden` (not on screen now).
    - Name a pane by its ID or a unique start of one, by its terminal's or
      agent's ID or name (`wispy-cedar`), by its exact title, or with a word:
      `self`, `focused`, or `left`, `right`, `up`, `down` for the pane on that side
      of yours. A browser's ID is its pane's ID.
    - Check `pane list` before acting on "this", "that" or "the other pane"; if
      two panes fit, ask the user which.

    ```bash
    tab pane focus right                      # show it and give it the keyboard
    tab pane zoom 9a2e                        # alone in the tab; --off shows them all
    tab pane move c47b down --beside self     # dock it below yours
    tab pane swap left right
    tab pane resize self --width 60           # 60% of the tab's width
    tab pane resize 9a2e --height 30
    tab pane equalize
    tab pane close c47b
    tab tab close self                        # the whole tab you run in
    ```

    - `close` asks the user first when a program still runs in the pane; closing a
      terminal ends it. Close only panes and tabs you opened unless the user asks.
    - `tab tab close` takes a tab ID from `tab pane list --all --json` or any pane
      in the tab, and closes all its panes. A worktree's card closes by removing
      the worktree, asking the user when anything would be lost.
    - Closing your own pane or card (`self`) ends you just after the command
      returns, without asking: do it last, once your reply is written.
    - `move` and `swap` work within one tab.

    ## Branch the conversation

    When the user asks to branch or fork this conversation, or to split work
    into panes, fork once per branch and give each its part after `--`. Each
    command prints the branch's agent ID:

    ```bash
    FIRST=$(tab pane new agent --fork -- "Show the first draft and edit it with me")
    SECOND=$(tab pane new agent --fork -- "Show the second draft and edit it with me")
    ```

    A branch knows everything said up to the fork, with your model, effort and
    access mode, starts on its message, and the user talks to it in its pane.
    Forking needs a Tab agent pane; from a terminal, start `pane new agent` with a
    message that carries the context instead.

    Branches work in the same folder as you. When they change files, give each a
    worktree, so they don't edit the same ones:

    ```bash
    WT=$(tab worktree new MyProject try-cache | cut -f1)
    tab pane new agent --fork --project "$WT" -- "Fix the slow query with a cache"
    ```

    To follow a branch, wait for its reply, then read it. Don't report what a
    branch said before you've read it.

    ```bash
    tab agent wait "$FIRST" --timeout 600       # prints its latest reply once it's idle
    tab agent read "$FIRST" --all               # the whole conversation
    tab agent send "$FIRST" "Make it shorter"   # a message, as the user would send it
    ```

    `agent wait` fails when the branch needs the user to approve something, fails,
    or the timeout passes.

    ## Wait instead of polling

    ```bash
    tab session wait "$WEB" --text "ready" --timeout 120   # prints the matching line
    tab session wait "$TESTS" --exit                        # prints how it ended
    ```

    `wait` fails with a nonzero exit if the timeout passes (default 30 seconds)
    or, for `--text`, if the terminal ends without showing the text. It looks at
    the visible screen, not scrollback, so text that scrolled off is missed: use
    `session search` for that.

    `--exit` waits for the terminal's shell to end. Use `exec` for a one-shot command,
    as in the test example, so the program replaces the shell and its exit ends the
    session. Without `exec`, the shell stays open after the program finishes.

    ## Follow what happens

    `tab session events` prints one line per event until stopped: terminals
    starting and ending, agents changing state (`working`, `blocked`, `idle`),
    agents needing attention or completing a reply, and notifications programs
    send. Give a session or agent ID to follow only that one. `tab activity list`
    shows what every agent is doing now.

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

    `send` types text without pressing Return; `press` presses one key, such as
    `Enter`, `Escape`, `Up`, `Down`, `Space`, `y`, `Shift+Tab` or `Ctrl+C`. Keys
    reach the program the way the app's keyboard sends them, so arrows move through
    menus and prompts.

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
    their app too. `session remove` also deletes its saved output.

    ## Projects and worktrees

    ```bash
    tab project list
    tab project new ~/code/app --reuse               # prints the existing project if there is one
    tab ~/code/app                                   # open a folder as a project in the app
    tab worktree new MyProject login                 # branch "login" from HEAD, default location
    tab worktree new MyProject fix --branch fix/x --base main --hooks
    tab worktree new MyProject --pr 42               # check out pull request 42
    tab worktree list MyProject
    tab worktree remove login --yes
    ```

    `worktree new` and `project new` print the project's ID, name and folder,
    separated by tabs. `--hooks` runs the setup or teardown commands from
    `.tab/worktree.json` and `~/.config/tab/worktree.json`; ask the user before
    using it. `worktree remove` refuses uncommitted changes unless `--force` is
    given; never pass `--force` without the user's consent.

    `tab exec MyProject -- git status` runs a program in a project's folder on its
    server, without a terminal, and prints what it prints.

    ## Browser

    `tab browser` drives the browser panes of the Tab app on this Mac: read a
    page, click and type, take screenshots. Open one with `pane new browser` or
    `tab tab new browser`, which print its ID.

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
      `false` when nothing matches. `find` looks elements up by role, text, label,
      placeholder or test ID.
    - A browser's profile has its own logins and cookies. For pages the user is
      signed in to, open the browser with their profile:
      `tab pane new browser https://example.com --profile Work`.
    - `eval` runs JavaScript in the page and prints the result as JSON.
    - Screenshots work on background browsers:
      `tab browser screenshot "$PAGE" | base64 -D > page.png`.
    - Close only browsers you opened.

    ## Simulators and emulators

    `tab simulator` drives the iOS simulators and Android emulators of the server
    your terminal runs on, so you can check UI work where the app builds. Show
    one to the user with `pane new simulator`.

    ```bash
    tab simulator list                                 # id, platform, name, runtime, state
    tab simulator boot "iPhone 17"
    tab simulator screenshot --output screen.png       # look at it before tapping
    tab simulator tap 200 640                          # pixels of that screenshot
    tab simulator type "hello"
    tab simulator press home
    tab simulator open "myapp://settings"
    ```

    - Without `--simulator`, commands use the only running simulator.
    - iOS simulators have the `home` and `lock` buttons; Android emulators also
      have `back` and `recents`.
    - Take a new screenshot after each action to see its effect.
    - Shut down only simulators you started.

    ## Other computers

    From this Mac, put `--host user@computer` before a server command, such as
    `session`, `agent`, `project`, or `worktree`, to use another computer's server
    over SSH. Folders are then absolute paths on that computer. `pane`, `tab`,
    `browser` and `integrations` work on this Mac only and don't take `--host`.
    `tab --host user@computer forward 8081` makes that computer's port 8081
    reachable on this Mac's localhost until stopped.

    """#
}
