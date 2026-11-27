# Tab for iPhone and iPad

Native iOS/iPadOS client for Tab (UIKit, iOS 27+, Liquid Glass), published on the App Store. The Mac app and its server live in `../macos`. Paths and commands below are relative to `ios/`; read the root `AGENTS.md` first.

## Commands

```sh
scripts/validate.sh               # simulator tests, iOS app build (warnings as errors)
scripts/run-sim.sh [iphone|ipad]  # build, install, and launch this checkout's app on a simulator
scripts/stop.sh [iphone|ipad]     # terminate this checkout's app on the simulator
scripts/test-live.sh              # pair with a real tabd (built in ../macos) on port 7431 and drive a terminal
scripts/release.sh                # archive and upload to TestFlight (only when asked)
```

A change is finished only when the root `scripts/validate.sh ios` passes and any touched screen is verified on iPhone and iPad simulators against a real `tabd`. If a task launched a simulator app, run `scripts/stop.sh` before finishing.

## Why & Invariants

- **Thin client of `tabd`:** there is no terminal emulator and no SSH on the phone — the Mac's `tabd` runs terminals/agents and owns `sessions/tabs.json`. Connections use TLS with SHA-256 certificate pinning (port 7419); device tokens live only in the Keychain, never in `servers.json`.
- **Shared code:** the protocol (`TabProtocol`), releases, loggers, themes and the tab reducer (`TabCommon`) and the `tabd` client (`TabConnection`) come from `../shared`, which the Mac app builds on too. Change them there, never by copying them here; protocol changes are strictly append-only. Code that needs UIKit, sockets or the Keychain stays in this package.
- **UI & performance:** UIKit throughout (SwiftUI only for Settings forms), `@Observable` with `updateProperties()`, system Liquid Glass for controls/navigation only (not content). Keep Tab's exact **tab** vs **pane** terminology, iPad shortcuts from `ShortcutCatalog`, and icons from `@hugocxl/icons` (via `TabIcon`). No polling timers; acknowledge terminal frames in the layout pass that draws them.
- **Dependencies & licensing:** no third-party packages beyond Apple frameworks, `@hugocxl/icons`, and `../shared`. Never copy code from Blink or VVTerm (GPL). Keep the root `THIRD_PARTY_NOTICES.md` current.
- **Version:** the app shares the root `CHANGELOG.md` version with the Mac app. Scripts pass it and the commit-count build number to `xcodebuild` via `scripts/version.sh`; the project's own `MARKETING_VERSION` stays `0.0.0`.
- **Worktrees:** linked worktrees build and install with `com.hugocorta.tabios-dev.<hash>` and checkout-local DerivedData via the root `scripts/worktree.sh`, so multiple worktrees run side-by-side on the same simulator. Never use bare `git stash`.
- **Tests:** never touch the real Keychain or app state in tests (use temporary dirs, throwaway `UserDefaults`, in-memory token vault). `LiveServerTests` run only via `scripts/test-live.sh`.
