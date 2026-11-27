# Tab shared code

The Swift package both apps build on: the Mac app (`../macos`) and the iPhone and iPad app (`../ios`) depend on it by path, so they always speak the same protocol. Paths and commands below are relative to `shared/`; read the root `AGENTS.md` first.

## Commands

```sh
swift build
swift test --filter TabProtocolTests  # one module; plain `swift test` runs all
scripts/validate.sh                   # warnings-as-errors build and tests on the Mac
```

A change is finished only when the root `scripts/validate.sh shared macos ios` passes: the iOS build of this package runs only in `ios/`.

## Modules

| Module          | What                                                                           | Mac re-export |
| --------------- | ------------------------------------------------------------------------------ | ------------- |
| `TabProtocol`   | Messages, framing, screen rows and their binary codec. No dependencies.        | `TabCore`     |
| `TabCommon`     | Release versions, loggers, terminal themes and the tab reducer.                 | `TabCore`     |
| `TabConnection` | The `tabd` client over any `ByteStream`: requests, grids, reconnects, tunnels. | `TabClient`   |

## Why & Invariants

- **Platform-neutral:** Foundation and `os` only — no AppKit, UIKit, processes, sockets or Keychain. Each app brings its own transport (Unix socket and SSH on the Mac, pinned TLS on iOS) and platform code; when shared code needs one, take it as a parameter. Keep `#if os(...)` to constants such as the log subsystem, and put app-only additions in an extension in that app (as `TabCore` extends `Release` and `Log`).
- **Protocol & state compatibility:** old and new builds of both apps talk to each other, and an App Store build can lag the Mac by months, so the protocol and JSON `Codable` types only grow (ignore unknown keys, reply `unsupported` to unknown requests; bump `ProtocolVersion` only for breaking changes). `Tests/TabProtocolTests/Fixtures` are frozen: never edit or delete one.
- **Public API:** everything the apps use is `public`; keep the rest `internal` and test it here with `@testable import`.
- **Dependencies:** none beyond Apple frameworks.
