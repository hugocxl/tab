# tabios

Tab for iPhone and iPad: the tabs, terminals and agents of a Mac running Tab,
on the go. Native Swift and UIKit, iOS 27 and later only, built around Liquid
Glass. A private, commercial App Store app; the Mac app lives in the public
`hugocxl/tab` repository.

## Commands

```sh
scripts/sync-tab.sh ../tab       # copy the shared Tab code into Vendor/
scripts/validate.sh              # tests on a simulator + app build, warnings are errors
scripts/run-sim.sh [iphone|ipad] # build, install and launch on a simulator
scripts/test-live.sh ../tab      # pair with a real tabd and drive a terminal
```

A change is finished only when `scripts/validate.sh` passes and every screen it
touches was checked on iPhone and iPad simulators against a real `tabd`
(`scripts/test-live.sh` starts one with its own `TAB_DIR`, on port 7431).

## Architecture

- The phone is a client of the Mac's `tabd`, like the desktop app: the server
  runs terminals (libghostty) and agents, and keeps tabs in `sessions/tabs.json`.
  The phone renders screen frames and transcripts and sends input and intents.
  There is no terminal emulator and no SSH on the phone.
- Phones connect over the server's TLS listener (Tab Settings → Mobile, port
  7419). Pairing scans `tab://pair?…`; the certificate is pinned by its SHA-256
  and the device token lives in the Keychain. Admission is `hello`, then
  `authenticate` (or `pair`), then the ordinary protocol.
- `Vendor/` is synced from Tab by `scripts/sync-tab.sh` and never edited here:
  - `TabProtocol`: messages, framing, the screen codec. Verbatim.
  - `TabShared`: `TabReducer`, themes, `ServerClient`, `RunGrid`, reconnect and
    tunnel code from TabCore and TabClient, plus `Shims/` for the two TabCore
    symbols they use.
  Change shared code in Tab, then sync. `Vendor/TAB_REVISION` records the source.
- Modules:
  - `TabMobileKit` (TabProtocol, TabShared): connections, pairing, tabs with
    optimistic intents, terminal and agent controllers, the sidebar's cards. No UIKit.
  - `TabMobileUI` (TabMobileKit): the UIKit app.
  - `App/Tab.xcodeproj`: the app target, a scene delegate over `TabMobileUI`.
- Tabs change through `TabIntent`s applied with the same `TabReducer` as the
  server, shown at once and confirmed by the server, exactly as the desktop does.
- The home screen is the desktop sidebar's Open Tabs layout (`TabCard`,
  `TabCardCell`): keep it in step with `ActivityCardData` and `SidebarRows` in Tab.
- Tabs and panes keep Tab's words: a **tab** is a card in the list; a **pane**
  is a terminal or agent inside it. Browser, simulator, editor and diff panes
  show a placeholder; they open on the Mac.

## Performance

- The terminal draws each row into its own layer and redraws only rows a frame
  changed; the cursor is a separate layer that blinks on the render server.
  Frames are acknowledged in the layout pass that draws them, so the server
  never sends faster than the phone shows.
- No polling timers. Timers only for what is visibly changing (elapsed time,
  key repeat), scheduled for when the text next changes.
- Agent Markdown renders once per item text; snapshots reconfigure only rows
  that changed, and reload rows whose cell kind changed.

## Code standards

- Swift 6 toolchain, Swift 5 language mode. UIKit throughout; SwiftUI only for
  Settings forms. Observation (`@Observable`) with `updateProperties()`.
- Liquid Glass through the system: bars, menus, `UIButton.Configuration.glass()`
  and `.prominentGlass()`, `UIGlassEffect` for custom surfaces. Glass is for
  controls and navigation, not content.
- No force unwraps or `try!` outside tests. Prefer early returns.
- No third-party packages. Code from other apps is never copied; Blink and
  VVTerm are GPL and rootshell is only a reference.
- Persistent files are `Codable` JSON that tolerates unknown and missing keys.

## Commits

- Commit only when asked. Each commit adds a `## X.Y.Z - YYYY-MM-DD` section to
  `CHANGELOG.md`, newest first.
