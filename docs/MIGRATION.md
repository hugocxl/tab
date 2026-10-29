# Migration inventory

Every Codesh feature, and its state in Tab. This is the definition of done: a
feature is `[x]` only when it is implemented, covered by tests where a test is
meaningful, and verified in the running app. Keep this file current.

Reference: `~/repos/codesh/docs` (product, features, user-guide) and the Rust
crates. Behavior is 1:1 unless listed under "Intentionally changed".

## Server (`tabd`)

- [x] Starts from the app or CLI when not running; Unix socket in the profile folder; single instance per profile (lock file)
- [ ] Projects: create, rename, delete, list; Home project (always first, can't be deleted); failed status when the folder is gone — server side implemented with tests (catalog in `sessions/catalog.json`, retry-safe receipts, paging, deletes end the project's sessions); the failed status is the app's (the protocol carries no project status)
- [ ] Worktree projects: parent/child, branch name, parent color, auto-discovery of worktrees made outside Tab, show/hide per project, prune when deleted outside Tab (no panes, no history) — server side implemented (`WorktreeCatalog`, `setWorktreesVisible`, `pruneWorktree` refuses worktrees with sessions or saved output); discovery is app-driven as in Codesh (`git worktrees` + `worktree register` + `pruneWorktree`)
- [ ] Sessions: create in a project (optional directory and command), attach/detach, shared size, ownership (first attached client), end, discard, exit reasons — server implemented with end-to-end tests; needs app verification
- [x] Session persistence: screen and history saved in the background; survives program exit and server restart; ended sessions removed after 7 days
- [x] History: byte budget per session (default 16 MiB), paging, search (plain text, case-insensitive, optional case-sensitive)
- [x] Screen frames: changed rows only, merged, one in flight per client, acks; full screen on resize
- [ ] Terminal colors set by the app (theme, overrides, cursor style/blink) — server implemented (`setTerminalColors`, applied to attached and new sessions); needs app verification
- [ ] Clear screen (Cmd+K) through the engine, form feed at a semantic prompt — server implemented (`clearScreen` request and session `clear`); needs app verification
- [ ] Kitty graphics placements sent to clients — server sends changed graphics in frames and snapshots; needs app verification
- [ ] Metadata events: title, directory, bell, clipboard write (OSC 52), input modes, cursor blinking, progress (OSC 9;4), foreground process name — server implemented (foreground process via `tcgetpgrp` + `proc_name`); needs app verification
- [ ] Shell integration (zsh, fish automatic; bash opt-in): prompts marks, cwd, command exit; prompt jumping and command output selection — server installs the scripts into the profile and sets `ZDOTDIR`/`XDG_DATA_DIRS`/`TAB_SHELL_INTEGRATION_DIR`; prompt jumping is the app's
- [x] Environment: TERM, COLORTERM, TERM_PROGRAM, TAB_SERVER_ID, TAB_SESSION_ID, LANG fallback; login shells; default shell setting
- [x] Server settings: default shell, history budget, shell integration; `server.json`; `settings get|set`
- [x] Stop / stop-if-idle / restart; stop refuses while terminals run unless forced
- [ ] Git: summary, branches, remote branches, changes (conflicts, staged, unstaged, untracked), stage/unstage/discard, commit/amend, diff, raw diff, log, status, repo info, init, pull/push/fetch, checkout, cherry-pick, revert, delete branch (local, remote), watch working tree — `GitService` implemented with tests; wired into `tabd`; waiting for app verification
- [ ] Worktrees: list, create (new or existing branch, default/template/folder location), register existing, remove (with files), checkout PR, inspect removal (uncommitted changes), setup/teardown hooks from `.tab/worktree.json` and `~/.config/tab/worktree.json` with env vars and 5-minute limit — implemented in `GitService` + `Hooks/` with tests (catalog side through `WorktreeCatalog`); location choice is the app's; receipts are in memory, not durable across server restarts
- [ ] Pull requests via `gh`: number for a branch, info, list — implemented (also create, merge, close, checkout, update branch, diff) with a fake `gh` in tests
- [ ] Files: list, read, read bytes, write, stat, mkdir, rename, delete, watch (FSEvents), folders listing for remote project pickers — `FilesService` implemented with tests; folders listing is the core's `listFolders`
- [ ] Search: file list (`rg --files` or `git ls-files`), content search (`rg`, case and regex toggles, 200 matches per file) — implemented in `Search/` with tests
- [x] Exec: run a program in a project folder without a shell, cancellable
- [x] Uploads: chunked file upload into a temp folder (remote drops and pastes)
- [ ] AI agent detection: 12 providers from JSON manifests; working/blocked/idle; one unread event per session; read/ack/claim; works with no app attached — `AgentDetector` + `AgentStateTracker` implemented with the Rust fixtures; events, read/ack/claim implemented in the core (one unread event per session, first desktop app claims); detection runs on the session queue
- [ ] Mobile access: opt-in TLS listener (port 7419), self-signed cert, one-time 5-minute pairing code with QR payload and addresses, per-device tokens stored hashed, revoke, disable disconnects; phones can't manage access, settings, stop, or exec — `RemoteAccess` implemented with TLS pairing tests; the core serves `.mobile` streams as already authenticated and refuses phone-forbidden requests (tested)
- [x] Logging to `server.log`; `TAB_DIR` profile override

## Client library and CLI (`tab`)

- [ ] Local connection, starting `tabd` from beside the executable; handshake with version negotiation; reconnect with replay of pending closes — implemented (`LocalServer`, `ServerClient`, `Reconnector`, `PendingCloses`, `ServerHost` for app-hosted starts); unit-tested against a fake server; end-to-end test waits for a working `tabd`
- [ ] Remote connection over SSH: `ssh <dest> tab stdio`, custom SSH command prefix, identity file, port, user, password login (askpass kept in memory), host-key and auth failures reported, exponential reconnect that stops when it needs the user — implemented (`SSHTarget`, `RemoteServer`, `Bridge`, `AskpassServer`, `RemoteInstall`); failures tested with fake ssh programs; bridge tested end to end through `tab stdio` with a stand-in server
- [ ] Requests with replies, events, per-session grid cache (rows, cursor, history pages) — implemented (`ServerClient`, `RunGrid`), unit-tested
- [x] `tab` (no args): opens the folder-less terminal UI → NOT PORTED (see below); prints help instead
- [ ] `tab <folder>`: opens the folder in the app (selecting or adding its project), starting the app if needed — implemented (`{"type":"open","path":…}` over `app.sock`, `open -a`, server fallback); needs the app side
- [ ] `tab server start|status|stop [--force]` — implemented
- [ ] `tab project list|add|rename|delete [--json] [--yes]` — implemented
- [ ] `tab session list [--all]|create [--directory] [-- cmd]|send|send-keys|read-screen [--lines] [--saved]|history|search|wait --text/--exit [--timeout]|end|discard`; inside a Tab terminal, session commands default to that terminal and `create` to its project — implemented (UUID session IDs or unique prefixes; `TAB_SESSION_ID`/`TAB_SERVER_ID`)
- [ ] `tab worktree list|create|checkout-pr|register|remove [--hooks]` — implemented; default folder is `~/.tab/worktrees/<project>/<name>` (the app's per-project location setting isn't read yet)
- [ ] `tab settings get|set` — implemented
- [ ] `tab activity list [--json]|ack <event-id>` — implemented
- [ ] `tab git ...`, `tab files ...` raw JSON actions — implemented (protocol `{"type":…}` JSON)
- [ ] `tab exec <project> -- <program> [args]` — implemented
- [ ] `tab mobile [enable [--port]|disable|pair [--address]|revoke <id>]` — implemented; QR encoder (byte mode, level M, versions 1–10) matches Core Image module for module
- [ ] `tab browser open|list|read|click|fill|type|wait|wait-for-navigation|snapshot|screenshot|close|...` through `app.sock` — CLI side implemented with every Codesh action (`BrowserCommand` lists the app commands and arguments); needs the app side
- [x] `tab install-skills [--dir]`
- [ ] `tab stdio` — implemented, ready line `TAB-STDIO/1`; verified with a stand-in server
- [x] `--host <dest>` first; `--json`; `--yes`; exit codes and `tab: <message>` errors; `TAB_DIR`

## App: window, sidebar, projects

- [ ] One main window; restores projects, panes, window frame and state on launch; never opens a terminal by itself — implemented (`AppModel`, `MainWindowController`; restore tested with a fake server; launched with a real `tabd`: a restored Home pane attached and ran)
- [ ] Sidebar: Home terminals as cards above projects; projects with worktrees always expanded beneath; activity cards (name, agent glyph and state, relative age; running agent title / latest session / open PR / last commit; branch, PRIMARY badge, PR number); drag to reorder; Ctrl+1–9 jump with modifier hints; Cmd+B toggle; collapsed mode — implemented (`SidebarViewController`, `SidebarListing`, `ActivityCardData`; ordering/filter tests; offscreen render compared with `sidebar.png`); collapsed mode is a 44pt icon column
- [ ] Sidebar footer: host selector (All, Local, server), name filter (Escape clears, keeps parents of matching worktrees), Add Project, New Browser — implemented; host button opens the Remote Servers host menu, right click has host/workspace filters and Filter by Name
- [ ] Sidebar top row: sidebar toggle, Files and Source Control toggles tinted when open — implemented; window buttons placed at (16, 19) on that row
- [ ] Workspaces: create, rename, delete; project in any number of workspaces; filter the sidebar; Remote Servers fixed workspace listing remote Homes — implemented (sidebar host button menu, project menu, palette Switch Workspace)
- [ ] Projects: add via Add Project / Cmd+O / palette Open Project page (search folders by name, type a path to browse, Tab completes, Return opens, Cmd+Return adds, Cmd+K actions, Choose in Finder…, Change Search Location…), Add Project on <server>…; rename; project menu (rename, workspaces, show worktrees, copy path, remove); project icon from `.icns`/`.ico`/`icon|logo` PNG in root or assets/resources/public/packaging, skipping git-ignored (`ProjectIconCache`/`ProjectIconFinder` implemented with tests); missing folder shows failed and can only be removed; remove ends terminals — app side implemented (sidebar menus, palette Open Project page, `TextPrompt` rename)
- [ ] Home: always first, Cmd+N opens a terminal there, standalone terminal tabs with their own splits — implemented
- [ ] Project order shared by every filter; local before remote; next/previous project (Ctrl+] / Ctrl+[); back/forward navigation (Cmd+Ctrl+Left/Right) — implemented (`NavigationHistory` tested)
- [ ] New Terminal in Project… (Cmd+Shift+N): local and remote projects, switches workspace, connects a remote server and opens its Home — implemented (palette page)
- [ ] Switch Worktree… (Cmd+Opt+W): current first then recent (or sidebar order per setting), filter, rename/remove per row, New Worktree… at the bottom — implemented (palette page)
- [ ] New Worktree… (Cmd+Opt+N): name, new branch from base or existing branch, Default/Template/Folder location, per-project remembered choice, hooks review and enable, failure semantics — implemented (`NewWorktreeDialog`)
- [ ] Remove Worktree and Files…: warns about uncommitted changes, runs teardown, ends terminals — implemented (`confirmRemoveWorktree`)
- [ ] Window title, full screen (Cmd+Ctrl+F), default window size setting — implemented

## App: panes and splits

- [ ] Single split layout per project (zero when empty); Home tabs exempt; new panes split right of the focused pane and splits equalize; close moves focus to a neighbor; background opens never steal focus — implemented (`SplitContainerView`)
- [ ] Pane cards: 8px gutter, 10px radius, 1px border, 36px header with title and actions shown on the active or hovered card; terminals draw no inner focus border — implemented (`PaneCardView`; gutter math tested; render compared with `window-panes.png`)
- [ ] Split right/down (Cmd+D / Cmd+Shift+D), close (Cmd+W), close all of the project's panes (Cmd+Shift+W), focus by direction (Cmd+Opt+Arrows), zoom (Cmd+Shift+Return), equalize (Cmd+Ctrl+=), drag the gutter to resize, Cmd-drag a pane to swap or dock on an edge — implemented (`SplitGeometry`, `DropTargets` tested)
- [ ] New terminal pane (Cmd+T) in the project folder or the focused pane's folder (setting) — implemented
- [ ] Closing a terminal: ends it unless another pane in any app shows it; confirm when a program other than the shell runs (setting); Detach Terminal; close-as-detach setting; offline close waits for reconnect — implemented (`TerminalPane.willClose`, pending discards replayed on reconnect)
- [ ] Existing Terminals (Cmd+Opt+T): project's sessions this app isn't showing, owner app, open in a new pane — implemented (palette page)
- [ ] End All Sessions and Quit; quitting never ends terminals; "server offline" keeps last screens and replays edits and closes on reconnect — implemented; offline tested with a fake server
- [ ] Pane kinds: terminal, editor, diff, browser, Remote Servers, with per-kind titles; editor/diff/servers panes reuse an existing pane for the same target — implemented through `PaneRegistry` factories

## App: terminal view

- [ ] Core Text renderer of style runs: fonts (family, fallbacks, bold/italic, size, features, Unicode range fonts, thicker strokes, bright bold), cell size, line and character spacing, padding per edge with balanced leftover space and padding color, transparency and vibrancy, cursor shapes/blink/opacity/thickness, selection colors, 16 ANSI colors and overrides
- [ ] Redraw only changed rows; cached lines; one rectangle per background run; underline styles, strikethrough, inverse, faint, blink, hyperlinks
- [ ] Kitty graphics images
- [ ] Keyboard: full key encoding through the engine (kitty keyboard protocol, application cursor keys), Option as Alt (none/left/right/both), IME composition and marked text, line feed on Shift+Return, built-in terminal bindings (clear screen, delete line, start/end of line, scroll to top/bottom, prompt jumps) and user key bindings from `terminal.json` that win over app shortcuts; option to disable built-ins
- [ ] Mouse: selection (click, drag, double word, triple line), copy on select, clear selection when typing or copying, mouse reporting to programs with Shift to override, right-click menu, scroll with separate trackpad and wheel speeds, alternate scroll, scroll to live output on input
- [ ] Copy/paste: Cmd+C/Cmd+V, bracketed paste, image paste sends Ctrl+V, drop files pastes paths; remote: upload then paste the remote path
- [ ] Find (Cmd+F) across history with next/previous and case toggle, match highlighting
- [ ] Links: Cmd-click URLs (system browser or built-in per setting) and file paths with `:line:column` (Tab editor or chosen app); remote files offer a read-only copy or the path
- [ ] Prompt jumping (Cmd+Up/Down), Select Command Output
- [ ] Font size per pane (Cmd+= / Cmd+- / Cmd+0)
- [ ] Title: program-set title, else running program, else folder; agent glyph; proxy icon
- [ ] Bell, progress indicator, OSC 52 clipboard writes (size limit), focus events, synchronized output
- [ ] Hidden panes keep last screen and scroll position, re-attach when shown

## App: command palette

- [ ] Cmd+Shift+P: root search across commands, files (2+ chars, See all), branches, worktrees, projects, terminals; recent commands; keycaps; Return, Cmd+Return secondary, Cmd+K actions, Escape back/close, Backspace back when empty; 740pt wide, 480pt tall, 72pt from top layout — implemented (`PaletteController`, `PaletteSource`; ranking and page tests; render compared with `palette.png`)
- [ ] Pages: Go to File (Cmd+P), Find in Files (Cmd+Shift+F, Aa and .* toggles, grouped results), Open Project (Cmd+O), New Terminal in Project (Cmd+Shift+N), Switch Worktree (Cmd+Opt+W), Existing Terminals (Cmd+Opt+T), Switch Branch…, New Branch…, Changes… (Return opens diff, Cmd+K stage/unstage/discard), Change Theme (Cmd+Shift+K), custom Commands — implemented; plus Commit/Create Pull Request with AI and Check for Updates on the root page

## App: native panels

- [ ] Files panel (Cmd+E): tree pinned right, New File/Folder, Collapse All, Refresh, context menu (open, rename, delete, copy absolute/relative path, reveal in Finder), follows disk changes, shares the right spot with Source Control — `FilesPanelController` + `FilesTree` (Codesh tree tests ported) implemented with inline naming, keyboard navigation and `reveal(path:)`; `ProjectPanelContent.files` adapts it to `RightPanelContent`; needs shell wiring (hosts, `watch`, `filesChanged` routing) and app verification
- [ ] Editor pane: syntax highlighting for common languages, unsaved marker, save prompts on close/quit, reload on disk change or offer to keep yours, refuses binary and very large files, open at line:column — `EditorPaneController` (NSTextView, line numbers, incremental highlighting, Cmd+S/Cmd+F, wrap toggle, `go(line:column:)`, `confirmClose` for quit) and `EditorPaneContent` implemented with tests; needs shell wiring and app verification
- [ ] Source Control panel (Cmd+Y): branch header with Refresh, Conflicts/Staged/Changes/Untracked groups, stage/unstage/discard per file, Stage All/Unstage All, commit message with Cmd+Return, Amend, refresh on changes — `SourceControlController` + `SourceControlModel` implemented with tests (commit errors as toasts, AI message hook via the host); `ProjectPanelContent.sourceControl` adapts it; needs shell wiring and app verification
- [ ] Diff pane: working tree or staged diff for a file, refreshes on changes, long diffs cut short — `DiffPaneController` (unified/split, drawn rows only, horizontal scroll) + `DiffDocument` implemented with tests; `DiffPaneContent` adapts it; needs shell wiring and app verification
- [ ] Agents panel (Cmd+Opt+A): rows grouped by state or by project with counts (setting), Return opens pane; docked at sidebar bottom (resizable), popup when collapsed, Move to Right (resizable, remembered), Detach (floating, remembered frame), reattach — `AgentsPanelController` + `AgentsPanelModel` implemented with tests; needs shell wiring and app verification
- [ ] Agent Sessions panel: titlebar history button and View menu toggle, per local project directory, search titles/IDs/providers, provider multi-select filter with counts, grouped by recency, Up/Down/Return resume in a new terminal with the provider's resume command, Tab to filters, Escape semantics, resize, batched background loading, Refresh; providers Claude Code, Codex, Copilot, Droid, Pi, Oh My Pi, Xal with their JSONL locations and `CLAUDE_CONFIG_DIR` / `CODEX_HOME` — `AgentSessionsController` + `AgentSessionCatalog` (port of `files.rs`/`parse.rs` with the Rust tests) implemented; titlebar button and View menu are the shell's; needs app verification
- [ ] Notifications: macOS notification when an agent needs attention or finishes, not for the visible pane or detached terminals, click jumps to the pane, looking clears everywhere, only one app notifies (claim)

## App: browser

- [ ] Browser panes with WKWebView: New Browser Tab (Cmd+Opt+B), sidebar button, palette, `tab browser open`, Cmd-click terminal links (setting), popups open as new panes — `BrowserPaneController` implemented (popups through `BrowserHost.openBrowserPane`); entry points are the shell's; needs app verification
- [ ] Address bar with search engine and history suggestions, Cmd+L, reload, back/forward (Cmd+[ / Cmd+]), find on page, zoom, copy address, Web Inspector, open in another browser, switch profile, external schemes open in their apps — implemented in `BrowserToolbar`/`BrowserPaneController`; Web Inspector uses WebKit's private `_inspector` when present, else points to Safari's Develop menu (pages are inspectable); needs app verification
- [ ] Profiles: separate cookies, data, history, logins; default profile setting; manage in Settings → Browser; import history, bookmarks and cookies from another browser (Safari, Chrome, Firefox) — `BrowserProfiles` (per-profile `WKWebsiteDataStore`, `browser-history.json`) and `BrowserImport` (Safari, Chromium family with Keychain decryption, Firefox) implemented; parsing and decryption tested, real browser data not tried; Settings forwarding is the shell's
- [ ] Remembers address and profile across restarts; Enable built-in browser setting; home page setting — pane reports `BrowserPane` state through the host and honors `BrowserSettings`; persistence is the shell's
- [ ] Browser automation over `app.sock`: open, list, read, click, fill, type, wait, wait-for-navigation, snapshot (interactive elements with selectors), screenshot, close, navigate, evaluate — `BrowserAutomation.handle(command:args:)` implements every `BrowserCommand`, tested against a real `WKWebView`; the shell's placeholder `BrowserAutomation` in `Model/AppSocketHandler.swift` must go

## App: remote servers

- [ ] Host menu in the sidebar footer with per-server state; popover: Add Server… (host, user, port, identity file, password login, custom SSH command, group), Test Connection, install Tab there when missing (same version into `~/.local/bin`), version mismatch explanation, edit, connect/disconnect/reconnect, restart or stop its server, forget (removes its projects here), groups — implemented in `TabApp/Remote` (`RemoteServersController.toggleHostMenu`, `ServerFormSheet`, `RemoteServersModel`, server/group/move menus, `hostFilterMenu`) with tests; checked in offscreen renders; needs wiring into the sidebar footer and app verification
- [ ] Manage Remote Servers… pane: servers by group, checkboxes with Shift-range, Select all, bulk connect/disconnect/regroup/forget, group headings connect/rename/delete — implemented (`RemoteServersPaneController`, `ServerSelection`) with tests; needs registering as the `.servers` pane kind
- [ ] Add Project → Remote browses the server's folders — `RemoteFolderBrowser` implemented (lists through the server's `listFolders`); needs the shell to show it
- [ ] Remote projects marked with server and path; remote Home per server; offline servers never show projects as failed; auto-reconnect with backoff that stops when a login or host key needs you; password prompt kept in memory — `RemoteServerConnector` (proxy, askpass, `passwordNeeded` stops the shell's backoff, refused passwords forgotten) and `PasswordSheet` implemented with tests; the shell's `connectorFactory` must use `RemoteServersModel.connector(for:)`
- [ ] Remote terminals: drops and pastes upload first; Cmd-click remote file offers read-only copy; Git and files run on the server

## App: settings window

- [ ] Separate window like System Settings: sidebar with search across labels, grouped inset cards; works offline; changes apply immediately; Edit in… opens the section's JSON file; hand edits to `terminal.json` reload when the app activates, errors shown and last good values kept
- [ ] General: closing behavior (end or detach), confirm when a program runs, open files with (Tab editor or another app), default window size, worktree default location (default/template/folder), voice (language, offline model, send after recording)
- [ ] Appearance: light and dark theme pickers following macOS appearance, ~490 bundled themes plus custom `themes/`, sidebar width, order worktree switcher by recent use, agents panel rows grouping
- [ ] Keyboard: every shortcut with key glyphs, record a new one, Reset when changed, conflicts refused, saved under `keymap`
- [ ] Commands: custom commands (name, command, optional shortcut) run in a new pane
- [ ] Terminal: everything in the terminal view list above, with sliders previewing while dragging, pixel/percent units, key bindings recorder with actions (send text, …), disable built-ins, Reset terminal settings with confirmation
- [ ] Browser: enable, open terminal links in browser, default profile, search engine, home page, profiles, import
- [ ] Server: default shell, history budget, shell integration, stop and restart with confirmation
- [ ] Mobile: allow mobile devices, port, Show Pairing Code (QR), paired phones with Revoke
- [ ] AI: command-line tools per provider, prompts for commit and PR text, per-project PR prompts, commit choices (include unstaged, push)
- [ ] Backup & Restore: Export… `.tab` file (settings, terminal, themes, server settings, remote server list, local projects with layouts); Choose file… restores on next launch with a recovery copy in `Backups/`; existing projects kept and matched layouts applied; excludes live sessions, paired devices, remote projects, project files, proxy
- [ ] Proxy: Set Up Proxy… from a terminal's menu (HTTP or SOCKS5, login, bypass list), Use for the whole app (new terminals, downloads, SSH), Apply Proxy per terminal (restart in same folder, proxy icon), env vars http_proxy/https_proxy/all_proxy/no_proxy; stored in `proxy.json`, never backed up — implemented in `TabApp/Proxy` (`ProxyModel`, `ProxyController`, sheet, `ProxyEnvironment`, `ProxyTunnel` as ssh's ProxyCommand) with tests; `main` must call `ProxyTunnel.runIfRequested()`; needs app verification

## App: other

- [ ] Menu bar built from the shortcut catalog: Tab (About, Settings, Install Command Line Tool…, End All Sessions and Quit), File, Edit (Select Command Output), View (Toggle Agent Sessions, Toggle Voice Recording), Window, Help — implemented (`MenuBarBuilder`)
- [ ] Install Command Line Tool… links `~/.local/bin/tab` to the bundle's copy — implemented (`CommandLineInstaller.installAndReport`) with tests; menu item and palette command wired
- [ ] `tab://pair` URL scheme and `tab <folder>` single-instance handoff over `app.sock` — implemented (`AppDelegate`, `AppSocketHandler`, `SingleInstance`; handoff tested)
- [ ] Dictation (Cmd+Shift+I): on-device SFSpeechRecognizer into the active live terminal, Finish/Cancel, pause releases the mic, 10-minute cap, one session at a time, language setting, send after recording — implemented in `TabApp/Voice` (`DictationController`, indicator, `SpeechRecorder`) with state-machine tests; wired to Cmd+Shift+I in the shell; needs Info.plist usage strings and app verification
- [ ] AI actions: generate commit message and PR text with the configured CLI tool and prompts (runs locally; needs the folder locally) — implemented in `TabApp/AI` (`AIActionsController`, 12 providers, bounded process) with tests; prompt is passed as an argument like Codesh; wired: Source Control's commit message and palette commands
- [ ] Updates from GitHub Releases `update.json`: install now when the new version speaks the running server's protocol (server replaced once idle, or now with "Also restart the server"), otherwise wait for terminals to end or confirm ending them; verified download; old bundle kept until its server exits — implemented in `TabApp/Updater` (`UpdaterController`, manifest, decision table, verified download, ditto + atomic swap, sheet, 6-hour checks, team-ID check) with tests; not tried with a signed release
- [ ] Themes: app chrome and terminal colored by the chosen theme; dark `#111111` / warm `#d5cec7` default; vibrancy material for the terminal when enabled
- [ ] Accessibility: labels on controls; Reduce Transparency and Increase Contrast disable vibrancy
- [ ] Diagnostics and profiler hooks removed unless needed for the renderer

## Intentionally changed or dropped

- Linux desktop, Linux CLI/server builds, Intel builds: dropped (macOS 14+, Apple silicon only).
- Terminal UI (`codesh` with no arguments, Ratatui): not ported. `tab` with no arguments prints help; `tab <folder>` opens the app.
- Phone SDK (`codesh-mobile`, Swift/Kotlin bindings): not ported. The server's mobile access is ported, so existing phone clients need a Tab-speaking SDK later.
- Config files: `settings.json`, `terminal.json`, `server.json`, `state.json` instead of TOML. Themes keep Ghostty's format.
- Dead settings removed: app layout mode, sidebar vibrancy and level, sidebar collapsed style, status bar visibility, tips visibility, tab-focused expansion. The sidebar is always opaque; there is no status bar.
- Protocol: new JSON + binary protocol; not wire-compatible with Codesh servers.
