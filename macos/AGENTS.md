# Tab for Mac

Native macOS terminal workspace written only in Swift for macOS 14+ on Apple silicon. No Linux or Intel paths, no no-op settings. Paths and commands below are relative to `macos/`; read the root `AGENTS.md` first.

## Commands

```sh
scripts/build-ghostty.sh          # once: builds vendor/GhosttyVT.xcframework (needs Zig 0.17)
swift build
swift test --filter TabCoreTests  # one module; plain `swift test` runs all
scripts/run-dev.sh                # bundle and relaunch this checkout's isolated dev app
scripts/stop.sh                   # quit this checkout's dev app and stop its tabd
scripts/validate.sh               # warnings-as-errors build, tests, debug bundle
```

A change is finished only when the root `scripts/validate.sh macos` passes (add `ios` when touching `TabProtocol` or code the iOS app syncs). If a task opened a dev app, run `scripts/stop.sh` before finishing so it and its `tabd` do not stay running.

## Why & Invariants

- **Executable naming:** the AppKit app is `TabDesktop` (not `Tab`) because `Tab` and the `tab` CLI collide on case-insensitive APFS.
- **Process ownership:** `tabd` owns terminals, agents, projects, tabs, Git, and files and outlives the app; `TabApp` never links `TabServer`. Right-sidebar plugins build as lazy `.bundle`s via `scripts/build-plugins.sh` and are never linked into `TabDesktop`.
- **Protocol & state compatibility:** old and new builds talk to each other, so the protocol and JSON `Codable` files only grow (ignore unknown keys, reply `unsupported` to unknown requests; bump `ProtocolVersion` only for breaking changes).
- **Backpressure & threading:** one screen frame in flight per client (newer output merges into the waiting frame; terminals/control beat video/tunnels). `libghostty-vt` is not thread-safe — one serial queue owns each session's terminal. `tabd` serves its main queue because CoreSimulator delivers callbacks there.
- **UI & tokens:** AppKit throughout (SwiftUI only for Settings forms and static dialogs, never on the terminal path). Hot paths (renderer, split layout, sidebar) do no per-frame allocations and use no polling timers. Shortcuts come only from `ShortcutCatalog`, colors from `AppTheme`, glass from `GlassView.Style`, and icons through `AppIcon`/`ChromeIcon`: SF Symbols outlines for every UI glyph, `@hugocxl/icons` only for AI provider logos (`AgentLogo`) and file-type icons (`FileIcon`; stroke set, two-tone set in the Explorer file tree). No other icon packages or local SVGs.
- **Terminology:** a **tab** is a sidebar card holding a split layout; a **pane** is one terminal/agent/browser/simulator/editor/diff inside a tab. Keep these words exact in code, docs, and UI.
- **Worktrees:** each linked worktree builds its own `Tab Dev (<worktree>)` with its own bundle ID, profile folder, and `tabd`. Launch only via `scripts/run-dev.sh` (shells inside Tab export `TAB_DIR`, which would attach a bare `open` to another profile). Never use bare `git stash`.
- **Dependencies:** no third-party packages beyond Apple frameworks, `@hugocxl/icons`, and vendored `libghostty-vt` without maintainer approval. Keep the root `THIRD_PARTY_NOTICES.md` updated for adapted code/artwork.
- **Tests:** test real risks (data loss, protocol compatibility, concurrency, regressions), not defaults. Keep temporary `TAB_DIR` socket paths short (`SUN_LEN`).
