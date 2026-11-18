# tabios

Tab for iPhone and iPad: the tabs, terminals and agents of a Mac running Tab, on
the go. It is written only in native Swift and UIKit, for iOS 27 and later, and
built around Liquid Glass. It is a private, commercial App Store app. The Mac app
lives in the public `hugocxl/tab` repository, checked out beside this one as
`../tab`.

## Commands

```sh
scripts/sync-tab.sh ../tab        # copy the shared Tab code into Vendor/
scripts/validate.sh               # tests on an iPhone simulator, then the app build; warnings are errors
scripts/run-sim.sh [iphone|ipad]  # build, install and relaunch on a simulator
scripts/test-live.sh ../tab       # pair with a real tabd and drive a terminal (build tab first)
```

A change is finished only when `scripts/validate.sh` passes, and every screen it
touches was checked on an iPhone and an iPad simulator against a real `tabd`.
`scripts/test-live.sh` starts one with its own `TAB_DIR` in `.build/tabd`, on
port 7431.

## Architecture

- The phone is a client of the Mac's `tabd`, like the desktop app. The server runs
  terminals (libghostty) and agents, and keeps tabs in `sessions/tabs.json`. The
  phone renders screen frames and transcripts, and sends input and intents. There
  is no terminal emulator and no SSH on the phone.
- Phones connect over the server's TLS listener (Tab Settings → Mobile, port
  7419). Pairing scans or opens a `tab://pair?…` link; the certificate is pinned
  by its SHA-256, and the device token lives in the Keychain, never in
  `servers.json`. Admission is `hello`, then `authenticate` (or `pair`), then the
  ordinary protocol.
- `Vendor/` is synced from Tab by `scripts/sync-tab.sh` and never edited here.
  Change shared code in Tab, then sync. `Vendor/TAB_REVISION` records the Tab
  version and commit it came from.
  - `TabProtocol`: messages, framing and the screen codec, verbatim.
  - `TabShared/Tab`: `TabReducer`, themes, `ServerClient`, `RunGrid`, reconnect
    and tunnel code from TabCore and TabClient, with their imports of each other
    removed.
  - `TabShared/Shims`: the two TabCore symbols that code uses (`Release`, `Log`).
    Written here; the sync leaves them alone.
- Modules, with what each may depend on:
  - `TabProtocol` and `TabShared` (TabProtocol): the vendored code above.
  - `TabMobileKit` (TabProtocol, TabShared): connections, pairing, tabs with
    optimistic intents, terminal and agent controllers, the sidebar's cards. No
    UIKit.
  - `TabMobileUI` (TabMobileKit, TabProtocol, TabShared): the UIKit app.
  - `App/Tab.xcodeproj`: the app target, a scene delegate over `TabMobileUI`.
  - Keep `Package.swift` and this list in sync.
- The protocol is Tab's, so it follows Tab's rules: it only grows, unknown fields
  are ignored, and the phone must keep working with older and newer servers. A
  protocol change starts in Tab.
- Tabs change through `TabIntent`s applied with the same `TabReducer` as the
  server, shown at once and confirmed by the server, exactly as the desktop does.
  The phone keeps only its own view: the selected tab and its preferences.
- The home screen is the desktop sidebar's Open Tabs layout (`TabCard`,
  `TabCardCell`). Keep it in step with `ActivityCardData` and `SidebarRows` in
  Tab.
- Tab icons use Icons through `TabIcon`; the two view-mode icons remain local.
- Tabs and panes keep Tab's words in code, docs and UI:
  - A **tab** is one card in the list. It holds a split layout of panes.
  - A **pane** is one terminal or agent inside a tab. Browser, simulator, editor
    and diff panes show a placeholder; they open on the Mac.
  - **New Tab** always adds a card, a tab in Home; **New Pane** adds a pane to
    an existing tab.
- iPad keyboard shortcuts (`RootViewController`) use the desktop's keys from
  `ShortcutCatalog` in Tab.
- Use UIKit throughout. SwiftUI is allowed only for Settings forms.
- Liquid Glass comes from the system: bars, menus, `UIButton.Configuration.glass()`
  and `.prominentGlass()`, and `UIGlassEffect` for custom surfaces. Glass is for
  controls and navigation, not content.
- State lives in Application Support (`servers.json`), Caches and
  `UserDefaults`; secrets only in the Keychain.

## Performance

- The terminal draws each row into its own layer and redraws only rows a frame
  changed. The cursor is a separate layer that blinks on the render server.
- Frames are acknowledged in the layout pass that draws them, so the server never
  sends faster than the phone shows.
- No polling timers. Timers are only for what is visibly changing (elapsed time,
  key repeat), scheduled for when the text next changes.
- Agent Markdown renders once per item text. Snapshots reconfigure only rows that
  changed, and reload rows whose cell kind changed.
- Measure with Instruments on a device when in doubt.

## Code standards

- Swift 6 toolchain, Swift 5 language mode.
- Observation (`@Observable`) with `updateProperties()` for UI updates.
- No force unwraps or `try!` outside tests.
- Log through `os.Logger`, not `print`.
- Prefer early returns over nested conditionals.
- Choose self-explanatory names over comments. Use `///` doc comments on public
  API.
- Persistent files are JSON through `Codable`, and decoders tolerate unknown keys
  and missing optional keys.
- Follow the existing patterns, and fix root causes rather than symptoms.
- Use no third-party packages beyond Apple frameworks, Icons and the vendored Tab code.
  Code from other apps is never copied: Blink and VVTerm are GPL, and rootshell is
  only a reference. Third-party artwork or code goes in `THIRD_PARTY_NOTICES.md`.

## Testing

- Tests use XCTest in `Tests/<Module>Tests` and run on a simulator through the
  `TabKit` scheme.
- Test real risks: protocol compatibility, pairing, intents and transcripts,
  terminal input and regressions. Don't test defaults.
- `LiveServerTests` talk to a real `tabd` and run only from
  `scripts/test-live.sh`; `scripts/validate.sh` skips them.
- Tests use a temporary directory, a throwaway `UserDefaults` suite and an
  in-memory token vault, never the real Keychain or app state.

## Commits and the changelog

- Commit only when asked.
- Don't push, open pull requests or comment on issues unless asked.
- Before committing, run `git pull --rebase --autostash origin main`, so the next
  version comes from the latest `main`.
- Every commit is a version. It adds one `## X.Y.Z - YYYY-MM-DD` section on top of
  `CHANGELOG.md`, dated today and newer than the section below it. The commit
  message starts with the version: `0.3.0: New app icon background`.
  - Set `MARKETING_VERSION` in `App/Tab.xcodeproj` (Debug and Release) to the
    same version. The app sends it to `tabd` in `hello`, and
    `scripts/validate.sh` fails when the two differ.
  - Bump the patch for fixes and invisible changes, and the minor version for new
    features or visible changes.
  - If the rebase conflicts there, renumber your section above theirs. Never add
    to an older section.
- Group entries under `### Added`, `### Changed`, `### Fixed` or `### Removed` as
  `- ` items, with wrapped lines indented two spaces and inline Markdown only.
- Write one sentence per entry for someone using the app. Don't mention file
  names or refactors. A sync of `Vendor/` gets an entry only for what it changes
  on the phone.
