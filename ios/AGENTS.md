# tabios

Native iOS/iPadOS client for Tab (UIKit, iOS 27+, Liquid Glass). Private commercial App Store app; the Mac server lives in `../tab` (`hugocxl/tab`).

## Commands

```sh
scripts/sync-tab.sh ../tab        # sync shared Tab protocol/core code into Vendor/
scripts/validate.sh               # version parity, simulator tests, iOS app build (warnings as errors)
scripts/run-sim.sh [iphone|ipad]  # build, install, and launch this checkout's app on a simulator
scripts/stop.sh [iphone|ipad]     # terminate this checkout's app on the simulator
scripts/test-live.sh ../tab       # pair with a real tabd on port 7431 and drive a terminal
```

A change is finished only when `scripts/validate.sh` passes and any touched screen is verified on iPhone and iPad simulators against a real `tabd`. If a task launched a simulator app, run `scripts/stop.sh` before finishing.

## Why & Invariants

- **Thin client of `tabd`:** there is no terminal emulator and no SSH on the phone — the Mac's `tabd` runs terminals/agents and owns `sessions/tabs.json`. Connections use TLS with SHA-256 certificate pinning (port 7419); device tokens live only in the Keychain, never in `servers.json`.
- **Vendored Tab code:** never edit `Vendor/TabProtocol` or `Vendor/TabShared/Tab` here — change shared code in `../tab` and run `scripts/sync-tab.sh ../tab` (only `Vendor/TabShared/Shims` is maintained here). Protocol changes start in Tab and are strictly append-only.
- **UI & performance:** UIKit throughout (SwiftUI only for Settings forms), `@Observable` with `updateProperties()`, system Liquid Glass for controls/navigation only (not content). Keep Tab's exact **tab** vs **pane** terminology, iPad shortcuts from `ShortcutCatalog`, and icons from `@hugocxl/icons` (via `TabIcon`). No polling timers; acknowledge terminal frames in the layout pass that draws them.
- **Dependencies & licensing:** no third-party packages beyond Apple frameworks, `@hugocxl/icons`, and vendored Tab code. Never copy code from Blink or VVTerm (GPL). Keep `THIRD_PARTY_NOTICES.md` current.
- **Version parity:** `MARKETING_VERSION` in `App/Tab.xcodeproj` (Debug & Release) must match `CHANGELOG.md` because the app sends it in `hello`.
- **Worktrees:** linked worktrees build and install with `com.hugocorta.tabios-dev.<hash>` and checkout-local DerivedData via `scripts/worktree.sh`, so multiple worktrees run side-by-side on the same simulator. Never use bare `git stash`.
- **Tests:** never touch the real Keychain or app state in tests (use temporary dirs, throwaway `UserDefaults`, in-memory token vault). `LiveServerTests` run only via `scripts/test-live.sh`.

## Commits & Releases

- Commit and push only when asked. Pull with `git pull --rebase --autostash origin main` before committing.
- Commit messages must use `<Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence.>` (enforced by `.githooks/commit-msg`, which automatically prepends `CHANGELOG.md` and triggers `.githooks/post-commit` to tag `vX.Y.Z`).
- Every push to `main` publishes GitHub Releases for new versions; TestFlight uploads go through `scripts/release.sh` only when asked.
