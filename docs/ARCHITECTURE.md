# Architecture

Tab is a macOS terminal workspace for running agents and shells: projects and
Git worktrees, each with one workspace of split panes (terminals, editors,
diffs, browsers, agent chats), with terminals that keep running in a background server after
the app quits. Its application and server are a Swift rewrite of Codesh, with
the active bundled source web renderer for agent conversation bodies. The product behavior is the
one documented in `~/repos/codesh/docs` (product, features, user guide); this
document is how Tab is built.

## Processes

```
Tab.app ──Unix socket──▶ tabd (terminals, agent chats, projects, history, git, files)
Tab.app ──ssh host tab stdio──▶ tabd on another Mac
tab CLI ──Unix socket / ssh──▶ tabd
phone  ──TLS (paired)──▶ tabd (opt-in network listener)
tab browser ──app.sock──▶ Tab.app (browser automation)
```

- `Tab.app/Contents/MacOS/` holds `TabDesktop` (the app), `tabd` and `tab`. The app and the CLI
  start `tabd` from beside themselves when it isn't running (detached session,
  `setsid`, stdio to `server.log`).
- The server owns projects and sessions. Apps own layouts, panes, workspaces
  and project order. Terminals outlive apps; closing the last pane that shows a
  session ends it.
- The desktop app keeps one connection per server plus a second "side"
  connection per server for Git, files, search and uploads, so they never wait
  behind terminal traffic.

## Modules

| Module | Role | Depends on |
| --- | --- | --- |
| `GhosttyVT` | Binary xcframework of libghostty-vt (C). Built by `scripts/build-ghostty.sh`. | |
| `TabCore` | Ids, profile folders, shortcut catalog, settings model, themes, split-layout model, workspaces, fuzzy matching, binary codec helpers, logging, time. No UI, no sockets. | |
| `TabProtocol` | Messages, framing, screen rows and their binary codec, errors, version. | TabCore |
| `TabTerminal` | Ghostty engine wrapper and the PTY: feed, resize, rows as style runs, cursor, modes, key and mouse encoding, selection, search, history capture, kitty graphics, links, progress. | GhosttyVT, TabProtocol |
| `TabServer` | Catalog (projects, worktrees, Home), session threads, connections and outboxes, history persistence, server settings, Git, files, search, exec, uploads, agent detection, shell integration, mobile access listener, archive cleanup. | TabCore, TabProtocol, TabTerminal |
| `tabd` | Server executable: args, logging, run loop. | TabServer |
| `TabClient` | Connect to a server: local socket (starting tabd), SSH remote (`tab stdio`), handshake, requests with replies, events, per-session grid cache, reconnect. | TabCore, TabProtocol |
| `tab` | The CLI: server, project, session, worktree, settings, activity, git, files, exec, mobile, browser, install-skills, stdio, `tab <folder>`. | TabClient |
| `TabApp` | The AppKit app: window, sidebar, splits, terminal view, panels, palette, settings window, browser, dialogs, notifications, updater, dictation. | TabClient |
| `TabDesktop` | App executable main; keeps that name in the bundle because `Tab` and `tab` collide on a case-insensitive disk. | TabApp |

Rules: a module never imports one to its right in the table except as listed.
Apps never include server code; they only speak the protocol.

## Protocol

A reliable byte stream (Unix socket, SSH stdio, or TLS) carries frames:

```
u32 big-endian payload length
u8  kind        0 = JSON message · 1 = screen frame (binary) · 2 = raw session input
u32 channel     0 = control · n = an attached session
payload
```

- JSON messages are `Codable` enums with a `type` discriminator and optional
  fields, so builds can add fields and cases without breaking each other.
  Unknown request types get an `unsupported` error reply; unknown fields are
  ignored. `ProtocolVersion` bumps only for breaking changes.
- The control channel carries `request(id, body)`, `reply(id, body)` and
  `event(body)`. Every request gets exactly one reply. Shared state (catalog,
  sessions, activity, remote access) changes are announced with a short
  `changed(topic)` event and re-read.
- An attached session gets its own channel: screen frames and metadata events
  down; raw input, encoded keys, mouse events, resize, acks and scroll requests
  up.
- Screen rows travel as style runs (text, style, cell widths) in a compact
  little-endian binary format defined in `TabProtocol/ScreenCodec.swift`,
  versioned, with round-trip tests. Frames carry only the rows that changed, the
  cursor, and the scroll position; a resize sends the whole screen.
- Flow control: at most one frame in flight per session per client. Newer
  output merges into the waiting frame; it is sent once the client acks.
  Control messages are written before screen data.
- History is never pushed: clients page through it and search it on request.

The complete request list to support, grouped (names are the Swift cases):

- Sessions: `listSessions`, `createSession`, `attach`, `attachWithoutResize`,
  `detach`, `endSession`, `discardSession`, `readSavedScreen`, `historyPage`,
  `searchHistory`, `clearScreen`, `setTerminalColors`, `syncSessionReferences`
  (which sessions this client shows), `identifyClient`, `cancelCreation`,
  `writeInput` (for CLI send), `ping`.
- Catalog: `readCatalog`, `mutateProject(create | rename | delete |
  pruneWorktree)`, `listProjectSessions`, `listFolders`.
- Server: `readServerSettings`, `writeServerSettings`, `stopServer`,
  `stopServerIfIdle`, `restartServer`.
- Agent chats: `agentChat(create | read | send | approve | setAccess | interrupt | close)`;
  `agentChatChanged(session, revision)` tells clients when to reread a snapshot.
- Git: `summary`, `branches`, `remoteBranches`, `changes`, `switchBranch`,
  `createBranch`, `deleteBranch`, `deleteRemoteBranch`, `stage`, `unstage`,
  `discard`, `commit(message, amend)`, `diff`, `rawDiff`, `log`, `status`,
  `repoInfo`, `init`, `pull`, `push`, `fetch`, `checkout`, `cherryPick`,
  `revert`, `worktrees`, `worktree(create | register | remove | checkoutPR)`,
  `inspectRemoval`, `worktreeHooks`, `pullRequest(number | info | list)`,
  `watch`, `unwatch`, `switchToBase`, `pullRequestPreview`.
- Files: `list`, `read`, `readBytes`, `readRange`, `write`, `stat`, `mkdir`, `rename`,
  `delete`, `watch`, `unwatch`; `search(files | content)` using `rg`, falling
  back to `git ls-files` for file lists.
- Exec: `exec(project, program, args, env)`, `cancelExec`.
- Uploads: `upload(chunk)` for dropped and pasted files on remote servers.
- Activity: `readActivity`, `acknowledgeActivity`, `claimActivity` (one app
  delivers notifications).
- Mobile: `authenticate`, `pair`, `readRemoteAccess`, `writeRemoteAccess`,
  `startPairing(hosts)`, `cancelPairing`, `revokeDevice`.

## Inside the server

- One serial `DispatchQueue` per session owns its Ghostty terminal for its
  whole life (the engine is not thread-safe). A dedicated `Thread` only blocks
  on `read(2)` of the PTY and forwards bytes to the session queue.
- Every tick (about 16 ms) a session that changed sends changed rows and the
  cursor to each attached client's outbox. Quiet sessions send nothing. After a
  burst, history is compressed.
- A background writer saves each session's screen and history to
  `sessions/<id>/`, so they survive the program and the server. Ended sessions
  and their saved output are removed after 7 days.
- Each connection has a reader (input, acks and pings handled at once; the
  rest on an ordered worker queue) and a writer fed by an outbox: control first,
  then one merged frame per session.
- Agent detection runs on the session queue after output settles, against
  the JSON rule manifests in `Resources/Detection` (regions, priorities,
  contains / regex / line_regex / all / any / not gates). Providers: Claude
  Code, Codex, OpenCode, Cursor, Copilot, Droid, Pi, Grok, Kiro, Xal,
  Antigravity, Oh My Pi. States: working, blocked (waiting for you), idle,
  unknown. At most one unread event per session, in memory.
- Agent chats are separate from terminal detection and PTYs. `AgentSessions`
  owns their normalized transcripts and `AgentRuntime` drives installed Claude
  Code and Codex processes over JSONL pipes. Claude uses stream-json control
  messages; Codex uses `app-server` threads and turns. The adapters follow source
  Code's provider behavior (see [Agent Tabs](AGENT_TABS.md) and the bundled
  third-party notice). Agent requests and coalesced revision notifications
  travel over the existing control channel. App disconnects do not end agents;
  daemon restart requires resuming the provider conversation. Per-turn Git
  checkpoints use isolated indexes and private refs; capture runs on blocking
  workers and serializes across follow-up turns. Bounded summaries travel with
  the transcript. `agentCheckpoint` retrieves paged file lists and immutable
  per-file diffs over the same control channel, scoped to the owning session.
  Full checkpoint records are persisted separately from transcript previews.
- Shell integration scripts live in `Resources/Shell`; zsh and fish load
  automatically through `ZDOTDIR` / `XDG_DATA_DIRS`, bash is opt-in with
  `TAB_SHELL_INTEGRATION=1`.
- Terminals get `TERM=xterm-256color`, `COLORTERM=truecolor`,
  `TERM_PROGRAM=tab`, `TAB_SERVER_ID`, `TAB_SESSION_ID`, and a UTF-8 `LANG`
  when none is set.

## Inside the app

- Agent conversation bodies use the pinned upstream components in an isolated,
  nonpersistent `WKWebView`. `vendor/ConversationRenderer` extracts the actual source
  components and bundles their styles, syntax engines, math and lazy assets
  locally. Swift owns the composer, pane, providers, persistence and filesystem
  services; a scoped snapshot/action bridge adapts those services without a source
  server or authentication. Renderer failure restores the native transcript.
  Normal text and code use native macOS font stacks; only specialized KaTeX
  WOFF2 equation fonts are bundled. Existing `AppTheme` is the color authority:
  semantic colors, `SyntaxColors` and `TerminalPalette` flow through snapshots,
  including live palette changes within the same light/dark mode. There is no
  separate conversation theme catalog. The native fallback reuses these colors.
  See [the port acceptance ledger](CONVERSATION_RENDERER.md) for source/native
  evidence and service boundaries. The final unfiltered `scripts/validate.sh`
  gate passed on October 31, 2026, including live palette propagation tests.
- AppKit for the window, sidebar, split container, pane cards, terminal view,
  panels, palette and menus. SwiftUI (in `NSHostingView`) is allowed for the
  Settings window forms and for static dialogs. Never put SwiftUI on the
  terminal rendering path.
- Application-shell controls are native: the `Components` buttons, switches, pop-ups,
  segmented controls, text and search fields and spinners subclass their
  AppKit controls (`NSButton`, `NSSwitch`, `NSPopUpButton`, …) and only add
  closures. They follow the window's appearance, which tracks the theme.
  Glass surfaces are a `GlassView` behind the host's content: Liquid Glass
  on macOS 26 and later, a frosted `NSVisualEffectView` before, configured
  by a named `GlassView.Style` such as `.card` for the selected sidebar card.
  Settings pages describe rows as `SettingControl` data rendered by a SwiftUI
  grouped `Form`. The Changelog page is the exception: it renders the
  `CHANGELOG.md` that `scripts/bundle.sh` copies into the app's resources.
- `TerminalView` is an `NSView` that draws rows of style runs with Core Text
  into its backing layer, invalidating only changed rows, with a per-row line
  cache keyed by content hash and a glyph run cache. One rectangle per
  background color run. Kitty images draw as `CGImage` placements. The
  renderer is behind a `TerminalRenderer` protocol so a Metal renderer can
  replace it later without touching the model.
- Hidden terminal panes detach but keep their last screen and scroll position,
  and still count as showing their session; they attach again when shown.
- State: `AppModel` (main actor) owns the `AppState` (projects, workspaces,
  layouts, panes, window state) persisted as `state.json`, and a
  `ServerConnection` per server. Views observe through Combine or direct
  callbacks; no per-frame polling.
- Every shortcut comes from the `ShortcutCatalog` in TabCore, resolved through
  the keymap in settings; menus are built from the catalog. Terminal key
  bindings from `terminal.json` win while a terminal is focused.
- Browser panes are `WKWebView`s with one `WKWebsiteDataStore` per profile and
  the app's own history. `tab browser` reaches the app over `app.sock`.
- Agent tool snapshots retain optional inspector identity separately from semantic
  category, plus whether an output string encodes a structured provider result.
  Claude uses the source renderer’s normalized native-tool whitelist; semantic aliases and unknown
  MCP names remain generic inspectors. Codex selects its inspector from native item type,
  retains namespace-qualified tool names and contentItems, and preserves MCP structured
  output precedence plus error/result context without flattening mixed content blocks.
  This keeps read/search shell commands in the command inspector and distinguishes
  text such as `null` from a JSON null. Optional search patterns and typed web-result
  titles, URLs and snippets survive persistence for native search inspectors.
  File-change metadata retains the provider patch, optional counts and move/type
  operations. Native file inspectors open immutable tool snapshots in the diff
  window; this action never diffs the current worktree. Claude structured patches
  and Codex native changes normalize on the server. Older snapshots decode without
  these fields. Dynamic tool raster images use an internal item-plus-payload event;
  the session owner stages up to eight images before publishing descriptors. Tool
  blobs never enter transcript JSON. Retrieval accepts provider item IDs, verifies
  message ownership, and hashes non-UUID IDs into storage directory names. Single
  retrieved payloads support 10 MiB; user-send aggregate limits remain unchanged.
  Provider NDJSON accepts bounded 128 MiB lines for eight encoded images and scans
  only newly received bytes while waiting for a newline. Original Claude/Codex
  argument subtrees are selected from the validated wire JSON before dictionary
  serialization can reorder keys. The byte scanner skips unrelated image strings
  without decoding them again; persisted activity input keeps that original JSON.
  Unmodified structured outputs reuse original subtrees as well, including MCP
  error/result wrappers. Image-rewritten output uses a batch of exact byte-range
  replacements, preserving surrounding order without copying removed blobs into
  output strings. Shadowed duplicate values are cleared, including ignored image
  payloads; failed path matching falls back to the sanitized projection. Structured scalar results serialize as JSON
  fragments instead of disappearing through object/array-only serialization.
  Explicit file-search records carry a pattern and typed file/position/preview
  results; provider Grep and Glob calls remain generic inspectors, matching the source renderer.
- Agent panes keep a native fixed bottom composer, model, effort and access
  pickers. Their conversation body uses the bundled source renderer described
  above, with an AppKit Markdown transcript as its failure fallback. Both use
  the same card background as terminal panes. Fallback response blocks retain
  selectable text, highlighted code, copy actions and project-aware file navigation.
  In the native fallback, transcript geometry is separate from row views: only the viewport and an
  overscan buffer are mounted, with a bounded detached-view cache. Cached heights
  avoid remeasuring unchanged history during streaming. Lightweight disclosure and
  code-wrap state survives view eviction; scrolling is anchored by row identity.
  Expanded completed-work entries share the main timeline geometry and viewport;
  folding retains child state without retaining their native views. Consecutive
  tool calls are separate main-timeline entries, with selection pinned during
  scrolling. Only individual expanded output details use bounded scroll surfaces.
  Their persisted pane state identifies the server-owned session and initial provider;
  the server snapshot owns the current provider, model and reasoning effort. One connection event
  consumer routes conversation revisions to matching panes; panes reread state
  when notified or reconnected rather than polling.
- Native panels (Files, Source Control) are tabs of the right sidebar
  of the current project; editor and diff panes are text views with a
  lightweight tokenizer-based highlighter for common languages.
- Notifications use `UNUserNotificationCenter`; dictation uses
  `SFSpeechRecognizer` and `AVAudioEngine`; updates download from GitHub
  Releases and replace the bundle once no terminals need the old server.

## Files

Everything lives in one profile folder: `~/Library/Application Support/Tab`
(release) or `Tab Dev` (debug builds), overridable with `TAB_DIR`.

| File | Holds |
| --- | --- |
| `server.json` | Server settings: shell, history budget, shell integration |
| `server.log`, `server.sock`, `server.pid` | Server log, socket, lock |
| `sessions/` | Projects, sessions, saved screens and history |
| `agents/` | Bounded agent transcript snapshots and provider conversation IDs |
| `remote.json` | Mobile access settings and paired phones (token hashes) |
| `settings.json` | App preferences, `keymap`, remote servers |
| `terminal.json` | Terminal preferences and key bindings |
| `themes/` | Custom themes in Ghostty's theme format (`key = value`) |
| `state.json` | Projects, layouts, workspaces, window state |
| `proxy.json` | Proxy settings, excluded from backups |
| `Backups/` | Recovery copies made by restore |
| `app.sock` | The app's socket for `tab browser` and `tab <folder>` |

Identity: bundle id `com.hugocorta.tab` (`com.hugocorta.tab-dev` for debug
builds), URL scheme `tab://`, environment prefix `TAB_`, executables `TabDesktop`,
`tabd`, `tab`.

## Decisions

| | Decision | Why |
| --- | --- | --- |
| D1 | Ghostty is the terminal engine, through its C library | Least memory, fastest parsing, already proven in Codesh |
| D2 | A separate `tabd` process owns terminals | Terminals survive the app; several apps show one terminal |
| D3 | JSON control messages, binary screen rows | JSON through Codable is native and additive; rows are the volume |
| D4 | One merged frame in flight per session per client | A slow client never piles up |
| D5 | AppKit + Core Text renderer, redraw on change only | Native, predictable, no GPU framework to debug first; Metal can come behind the same protocol |
| D6 | No third-party Swift packages; pinned Tab conversation assets are bundled separately | Preserve native application services while using the actual source conversation renderer; asset and dependency licenses are recorded in its manifest |
| D7 | Config files are JSON | Codable is built in; TOML is not |
| D8 | Only macOS, only Apple silicon | Removes every Linux and Intel branch |
| D9 | The terminal UI (Ratatui) and the phone SDK are not ported | Neither is a native macOS app; the server keeps serving phones |
