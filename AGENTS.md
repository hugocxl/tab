# Tab

Monorepo for Tab: a native terminal workspace for the Mac and its iPhone and iPad client.

| Project    | What                                                                  | Instructions       |
| ---------- | --------------------------------------------------------------------- | ------------------ |
| `shared/`  | Protocol and `tabd` client both apps build on (Swift package, macOS + iOS) | `shared/AGENTS.md` |
| `macos/`   | Mac app, `tabd` server and `tab` CLI (Swift package, AppKit, macOS 14+) | `macos/AGENTS.md`  |
| `ios/`     | iPhone and iPad client of `tabd` (UIKit, iOS 27+, App Store)          | `ios/AGENTS.md`    |
| `website/` | Website and docs at hugocxl.github.io/tab (static, GitHub Pages)      | —                  |

Read the project's `AGENTS.md` before changing it. Both apps depend on `shared/` by path, so they always build against the same protocol and client; protocol changes there are append-only. Root `scripts/` holds only repo-wide tooling.

## Commands

```sh
scripts/validate.sh                  # changelog check + every project (shared, macos, ios, website)
scripts/validate.sh macos ios        # only the named projects
macos/scripts/run-dev.sh             # build and launch this checkout's Mac dev app
ios/scripts/run-sim.sh [iphone|ipad] # build and launch the iOS app on a simulator
cd website && npm ci && npm run build:site && npm run check:site
```

A change is finished only when `scripts/validate.sh` passes for the projects it touches (`shared macos ios` when touching `shared/`; all of them when touching root tooling). Stop apps you launched: `macos/scripts/stop.sh`, `ios/scripts/stop.sh`.

## Worktrees

Each linked worktree builds its own Mac dev app and installs its own iOS app (`<bundle-id>-dev.<hash>`), so parallel worktrees never collide. Never use bare `git stash`.

## Commits & Releases

- Commit and push only when asked. Pull with `git pull --rebase --autostash origin main` before committing.
- Commit messages must use `<Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence.>` (enforced by `.githooks/commit-msg`, which automatically prepends the single root `CHANGELOG.md` and triggers `.githooks/post-commit` to tag `vX.Y.Z`). One changelog and version line covers both apps.
- Every push to `main` runs the Release workflow (validate, sign, notarize, publish the Mac DMG and `update.json`). Do not tag stable versions by hand; publish betas only when asked via `scripts/tag-beta.sh`. TestFlight uploads go through `ios/scripts/release.sh` only when asked.
