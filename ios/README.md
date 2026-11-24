# Tab for iPhone and iPad

### Your Mac's tabs, terminals, and agents — on the go.

**A native UIKit client for [Tab](https://github.com/hugocxl/tab) on iPhone and iPad.** Pair with Tab on your Mac (Settings → Mobile → Show Pairing Code) to access the same sidebar tabs, live terminals, and coding agents from anywhere.

[Tab for macOS](https://github.com/hugocxl/tab) · [Changelog](CHANGELOG.md)

<!-- Add .github/preview.png screenshot here -->

## Highlights

- **Live Mac sessions.** Connects directly to your Mac's `tabd` over certificate-pinned TLS — no terminal emulator or SSH setup on the phone.
- **Shared workspace state.** Uses the exact same `TabIntent` / `TabReducer` protocol as desktop Tab so tabs stay in sync.
- **Native UIKit & Liquid Glass.** Built for iOS 27+ with iPad keyboard shortcuts, row-level terminal rendering, and Keychain-backed pairing tokens.

## Development

Requires iOS 27 SDK, Xcode 27, and `../tab` checked out beside this repository for shared code sync and live tests.

```sh
scripts/sync-tab.sh ../tab        # sync shared Tab protocol/core code into Vendor/
scripts/validate.sh               # version check, simulator tests, iOS app build
scripts/run-sim.sh [iphone|ipad]  # build, install, and launch on a simulator
scripts/stop.sh [iphone|ipad]     # terminate this checkout's app on the simulator
scripts/test-live.sh ../tab       # live integration test against a real tabd
```

Linked Git worktrees install with a checkout-unique bundle ID (`com.hugocorta.tabios-dev.<hash>`) so parallel worktrees never overwrite each other on the simulator.

## Releases

Commits follow `<Added|Changed|Removed|Improved|Fixed>: <One user-facing sentence.>` — `.githooks/` automatically updates `CHANGELOG.md` and creates the matching `vX.Y.Z` tag. Pushing to `main` verifies `MARKETING_VERSION` parity and publishes GitHub Releases; TestFlight uploads run locally via `scripts/release.sh`.

## License

Private commercial App Store app by [Hugo](https://github.com/hugocxl). Third-party attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
