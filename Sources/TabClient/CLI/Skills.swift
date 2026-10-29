import Foundation

/// The tab-cli skill, which teaches AI coding agents to use `tab`, and
/// installing it where agents look for skills.
public enum AgentSkill {
    public static let folderName = "tab-cli"
    /// Agent folders in the home folder; each keeps its skills in `skills`.
    public static let agents = [".claude", ".codex", ".agents"]

    /// Writes the skill into every agent folder in `home` and into each of
    /// `directories`, replacing an older copy, and returns the files written.
    public static func install(home: String?, directories: [String],
                               currentDirectory: String = FileManager.default.currentDirectoryPath) throws -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []
        if let home {
            for agent in agents {
                let folder = URL(fileURLWithPath: home).appendingPathComponent(agent, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    roots.append(folder.appendingPathComponent("skills", isDirectory: true))
                }
            }
        }
        for directory in directories {
            roots.append(URL(fileURLWithPath: directory, relativeTo: URL(fileURLWithPath: currentDirectory))
                .standardizedFileURL)
        }
        guard !roots.isEmpty else {
            throw CLIError("found no AI agent folder (~/.claude, ~/.codex or ~/.agents); choose one with --dir")
        }
        return try roots.map { root in
            let folder = root.appendingPathComponent(folderName, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("SKILL.md")
            try Data(text.utf8).write(to: file, options: .atomic)
            return file
        }
    }

    public static let text = #"""
    ---
    name: tab-cli
    description: How to drive Tab from a shell with the `tab` command — start terminals that keep running, type into them, read and wait on their output, and manage projects and Git worktrees. Use this when you are an agent running inside a Tab terminal (or any script on the same computer) and want work to run in its own terminal instead of blocking yours, or to drive the Tab app's built-in browser.
    ---

    # Tab CLI

    Tab keeps terminals in a background server. The `tab` command talks to that
    server directly; the app doesn't need to be open. Terminals you start keep
    running after your command returns, and the user can open them in the app from
    **Existing Terminals**.

    Run `tab --help` and `tab <command> --help` for every option. Add `--json`
    to any management command for machine-readable output.

    ## When to use it

    - Start a long-running process (a dev server, a test watcher, a log tail) in its
      own terminal, then check on it later.
    - Wait until that process prints something, or exits, before going on.
    - Create a Git worktree for a task.

    Don't use it for work a plain command can do in your own terminal.

    ## Inside a Tab terminal

    Tab sets `TAB_SESSION_ID` and `TAB_SERVER_ID` in every terminal. Session
    commands then default to your own terminal, and `session create` to your
    project, so most commands need no IDs.

    ## Start a terminal and capture its ID

    `session create` prints the new session ID. Everything after `--` is typed into
    the new terminal, followed by Return. Capture the ID; never guess one.

    ```bash
    WEB=$(tab session create -- npm run dev)
    TESTS=$(tab session create MyProject --directory ./packages/api -- exec npm test)
    ```

    Outside a Tab terminal, name the project: an ID, a unique name, or its folder.

    The words after `--` are joined with spaces, so quote the whole command to keep
    its own quotes, pipes, or `;`:

    ```bash
    tab session create -- 'grep -rn "TODO list" src | wc -l'
    ```

    ## Wait instead of polling

    ```bash
    tab session wait "$WEB" --text "ready" --timeout-ms 120000   # prints the matching line
    tab session wait "$TESTS" --exit                              # prints how it ended
    ```

    `wait` fails with a nonzero exit if the timeout passes (default 30 s) or, for
    `--text`, if the terminal ends without showing the text. It looks at the
    visible screen, not scrollback. Don't wait on your own terminal: it is busy
    running `tab`.

    `--exit` waits for the terminal's shell to end. Use `exec` for a one-shot command,
    as in the test example, so the program replaces the shell and its exit ends the
    session. Without `exec`, the shell stays open after the program finishes.

    ## Read output

    ```bash
    tab session read-screen "$WEB" --lines 40     # last visible rows, not scrollback
    tab session search "$WEB" "error" --ignore-case
    tab session history "$WEB" --limit 200        # JSON, paged with --before
    ```

    After a terminal ends, add `--saved` to read its last saved output.

    ## Send input deliberately

    `send` types text without pressing Return; `send-keys` presses one key
    (Enter, Tab, Escape, Backspace, Ctrl+C, Ctrl+D, Ctrl+Z).

    ```bash
    tab session send-keys "$WEB" Ctrl+C
    tab session read-screen "$WEB"
    tab session send "$WEB" "npm run dev"
    tab session send-keys "$WEB" Enter
    ```

    You are typing into a live terminal. Read the screen first if you are unsure
    what is running.

    ## End terminals you started

    ```bash
    tab session list --project MyProject     # id, project-id, status, attached, directory
    tab session end "$WEB" --yes
    ```

    Only end terminals you created. A terminal the user is looking at closes in
    their app too.

    ## Projects and worktrees

    ```bash
    tab project list
    tab project add ~/code/app --reuse                 # prints the existing project if there is one
    tab worktree create MyProject login                # branch "login" from HEAD, default location
    tab worktree create MyProject fix --branch fix/x --base main --hooks
    tab worktree list MyProject
    tab worktree remove login --yes
    ```

    `--hooks` runs the setup or teardown commands from `.tab/worktree.json`; ask
    the user before using it. `worktree remove` refuses uncommitted changes unless
    `--force` is given; never pass `--force` without the user's consent.

    ## Browser

    `tab browser` drives tabs in the Tab app's built-in browser: open a page,
    read it, click and type, take screenshots. It talks to the app on this Mac,
    so it needs the app (`open` starts it) and never takes `--host`.

    ```bash
    PAGE=$(tab browser open http://localhost:3000)    # prints the new tab's ID
    tab browser wait-for-navigation "$PAGE"
    tab browser snapshot "$PAGE"                       # interactive elements, each with a selector
    tab browser fill "$PAGE" "#email" "me@example.com"
    tab browser click "$PAGE" "button[type=submit]"
    tab browser wait "$PAGE" --text "Welcome" --timeout-ms 10000
    tab browser read "$PAGE"                           # title, URL and page text
    ```

    - Capture the tab ID that `open` prints, or find it with `tab browser list`;
      never guess one.
    - Wait after anything that loads a page (`open`, `navigate`, a submitting
      `click`, `back`): `wait-for-navigation`, `wait-for <selector>`, or `wait`.
    - `snapshot` lists the interactive elements, each with a `selector` you can
      pass to `click`, `fill`, `type`, and the other element commands. They print
      `false` when nothing matches.
    - `evaluate` runs JavaScript in the page and prints the result as JSON.
    - Screenshots work on background tabs:
      `tab browser screenshot "$PAGE" | base64 -D > page.png`.
    - Close only tabs you opened.

    ## Other computers

    Put `--host user@computer` before a server-backed command, such as `project`,
    `session`, or `worktree`, to use another computer's server over SSH. Directories
    are then absolute paths on that computer.

    Folder-opening commands, `browser`, and `install-skills` do not support
    `--host`.
    `install-skills --dir DIR` always installs into a local directory.

    """#
}
