# Tab

Tab is a native macOS terminal workspace written only in Swift, for macOS 14+ on
Apple silicon. Write everything natively in Swift: no Linux or Intel paths, no
settings that do nothing.

## Commands

```sh
scripts/build-ghostty.sh          # once: vendor/GhosttyVT.xcframework (needs Zig 0.17)
swift build
swift test --filter TabCoreTests  # one module; plain `swift test` runs all
scripts/bundle.sh debug           # build/debug/Tab Dev.app
scripts/run-dev.sh                # bundle, then quit and relaunch this checkout's dev app
scripts/validate.sh               # build (warnings are errors), tests, debug bundle
```

A change is finished only when `scripts/validate.sh` passes. The release workflow
runs the same script.

## Architecture

- Three executables ship in one bundle:
  - `TabDesktop` is the AppKit app. It isn't named `Tab` because `Tab` and `tab`
    collide on a case-insensitive disk.
  - `tabd` is the server. It owns terminals, agent chats, projects, tabs, history,
    Git and files, and keeps running after the app quits.
  - `tab` is the CLI.
- The app and the CLI start `tabd` when it isn't running and talk to it over a Unix
  socket, or `ssh host tab stdio` for a remote Mac.
- A pane's processes, files and network belong to its tab's server; the app renders
  and sends input. Browser panes render in the app, but a remote tab's pages load
  through the server's tunnels, so `localhost` is the server's. Simulator panes show
  the server's simulators and emulators: this Mac's surfaces directly, another
  computer's as video.
- Modules, with what each may depend on:
  - `TabProtocol`: messages, framing, binary screen codec. Depends on nothing.
  - `TabCore` (TabProtocol): models, settings, shortcut catalog, themes, logging.
    No UI or sockets.
  - `TabTerminal` (GhosttyVT, TabProtocol): the libghostty-vt wrapper and the PTY.
  - `TabSimulators` (TabCore, TabProtocol): simulators, emulators and the screen video
    codec, without AppKit. Simulator code, not server code.
  - `TabServer` (TabCore, TabSimulators, TabProtocol, TabTerminal): everything `tabd`
    does.
  - `TabClient` (TabCore, TabProtocol): connecting, handshake, reconnecting, tunnels.
  - `TabApp` (TabClient, TabCore, TabSimulators, TabProtocol): the UI. Apps never link
    server code.
  - Keep `Package.swift` and this list in sync.
- Each server keeps its projects' tabs and their split layouts in
  `sessions/tabs.json`, so every app connected to it shows the same tabs. Apps
  change them with `TabIntent`s that the server and the app apply through the
  same `TabReducer`; the app shows the server's tabs with its unconfirmed changes
  on top. Each app keeps only its own view: selection, focus, zoom and pane titles.
  The server ends a pane's terminal when the pane closes, and closes a pane when
  its terminal ends.
- Old and new builds talk to each other, so the protocol only grows. JSON messages
  are `Codable` enums with a `type` discriminator. Unknown fields are ignored, and
  unknown requests get an `unsupported` reply. Bump `ProtocolVersion` only for a
  breaking change.
- Each session allows one screen frame in flight per client. Newer output merges
  into the waiting frame, so a slow client never piles up frames. Simulator video uses
  the same credit, encoding only when the channel has it, and tunnels send only
  what their reader granted. Terminals and control messages always go first.
- The Ghostty engine isn't thread-safe. One serial queue owns each session's terminal.
- Simulator code lives in `Sources/TabSimulators`, served by `tabd`'s `SimulatorService` and
  shown by the app's simulator panes. iOS simulators use Xcode's private CoreSimulator
  and SimulatorKit frameworks, loaded at runtime, plus `simctl` and `devicectl`.
  Android emulators use the emulator's gRPC control API and `adb`. `tabd` serves
  its main queue, where CoreSimulator delivers callbacks.
- Tabs and panes are different things; keep the words exact in code, docs and UI:
  - A **tab** is one card in the sidebar. It holds a split layout of panes. A
    project or worktree is a single tab, and Home holds one tab per card.
  - A **pane** is one terminal, agent, browser, simulator, editor or diff inside a
    tab's layout.
  - **New Tab** always adds a card, so it adds a tab to Home (`AppModel.newTab`).
    The sidebar's + button offers Terminal Tab, Agent Tab, Browser Tab and
    Simulator Tab.
  - **New Pane** always adds a pane to an existing tab, beside the pane it shows
    (`AppModel.newPane`). Only a project with no tab yet gets one. The empty-tab
    placeholder and a card's New Pane submenu offer the same four kinds.
  - Cmd-T and New Agent follow the current card: a pane in a project's tab, a
    new tab in Home.
- Use AppKit throughout. SwiftUI is allowed only for Settings forms and static
  dialogs, never on the terminal rendering path.
- Shortcuts come only from `ShortcutCatalog`, and colors only from `AppTheme`.
- Icons come from `AppIcon`, backed by IconsCXL and two local view-mode SVGs in `Resources/TabIcons`
  (one kebab-case file per case; `scripts/icons/STYLE.md` says how to draw one,
  and `scripts/icons/` normalizes and previews them). Only the sidebar's header
  and footer buttons and the pane header draw SF Symbols, through
  `SystemSymbol`. Agent logos, Git host logos, command marks and file types are
  icons too, each with its signature hue.
- Glass surfaces use `GlassView` (Liquid Glass on macOS 26, frosted material
  before). Add a `GlassView.Style` preset for a new use rather than creating effect
  views directly.
- State lives in `~/Library/Application Support/Tab`, or `Tab Dev` for debug
  builds. Override it with `TAB_DIR`.
- A debug build from a linked worktree is its own app, `Tab Dev (<worktree>)`,
  with its own bundle id, profile folder and `tabd`, so several worktrees' builds
  run at once. Launch it with `scripts/run-dev.sh`, never a bare `open`: shells
  inside Tab export `TAB_DIR`, which would attach it to another profile.

## Performance

The terminal renderer, split layout and sidebar are hot paths. They do no allocation
or layout work per frame beyond what changed, use no polling timers, and redraw only
on change. Server threads never block on disk or process launches while handling
input. Measure with Instruments when in doubt.

## Code standards

- Swift 6 toolchain, Swift 5 language mode.
- Prefer value types and `enum` state. Use `actor`s or serial queues for shared
  mutable state.
- No force unwraps or `try!` outside tests.
- Libraries log through the logging helpers, not `print`.
- Prefer early returns over nested conditionals.
- Choose self-explanatory names over comments. Use `///` doc comments on public API.
- Settings and state files only grow, so they are JSON through `Codable`, and
  decoders tolerate unknown keys and missing optional keys.
- Follow the existing patterns, and fix root causes rather than symptoms.
- Use no third-party packages beyond Apple frameworks, IconsCXL and the vendored
  libghostty-vt. Proposing one needs the maintainer's approval, with its GitHub
  URL, star count and maintenance status. Third-party artwork or code you adapt
  goes in `THIRD_PARTY_NOTICES.md`.

## Testing

- Tests use XCTest in `Tests/<Module>Tests`.
- Test real risks: data loss, protocol compatibility, concurrency and regressions.
  Don't test defaults.
- Server and client tests may start a real `tabd` in a temporary `TAB_DIR`. Keep
  socket paths short to stay under the `SUN_LEN` limit.

## Commits and the changelog

- Commit only when asked.
- Don't push, open pull requests or comment on issues unless asked.
- Before committing, run `git pull --rebase --autostash origin main`. Other
  branches push to `main`, so the next version comes from the latest `main`.
- Every commit is a version. It adds one `## X.Y.Z - YYYY-MM-DD` section on top of
  `CHANGELOG.md`, dated today and newer than the section below it.
  - Bump the patch for fixes and invisible changes, and the minor version for new
    features or visible changes.
  - If the rebase conflicts there, renumber your section above theirs. Never add
    to an older section.
- Group entries under `### Added`, `### Changed`, `### Fixed` or `### Removed` as
  `- ` items, with wrapped lines indented two spaces and inline Markdown only.
- Write one sentence per entry for someone using Tab. Don't mention file names or
  refactors.
  - The app shows this file in Settings → Changelog.
  - The release workflow rejects a commit without a newer version, so even a CI fix
    gets a short entry.
  - `ChangelogTests` checks the format.

## Releasing

Every push to `main` runs the Release workflow. It tags each pushed commit with its
changelog version and publishes the newest one. Don't tag stable versions by hand.

- After pushing, don't watch or check the Release workflow unless asked.
- Make a beta with `scripts/tag-beta.sh` only when asked.
- Signing and notarization inputs are documented at the top of `scripts/release.sh`.
- GitHub secrets are set with `scripts/setup-release-secrets.sh`.
