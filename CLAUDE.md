# Agents

Guidance for AI coding agents working in this repository.

## Repository

- Tab is a native macOS terminal workspace written only in Swift, a rewrite of
  Codesh (`~/repos/codesh`, Rust + GPUI) that supports only macOS 14+ on Apple
  silicon. Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before any change
  and keep [docs/MIGRATION.md](docs/MIGRATION.md) current: it is the 1:1
  feature inventory and the definition of done.
- One SwiftPM package. Executables: `TabDesktop` (the app, bundled as `Tab`), `tabd` (the server),
  `tab` (the CLI). Libraries: `TabCore`, `TabProtocol`, `TabTerminal`,
  `TabServer`, `TabClient`, `TabApp`. Keep the dependency graph in
  `Package.swift` and the architecture document in sync.
- The Codesh source is the behavioral reference. When porting a feature, read
  the Rust implementation and its tests, then write the Swift version from the
  product's point of view: same behavior, native implementation, no Linux
  paths, no dead settings.
- AI agents may commit when asked. Do not push, open pull requests, or comment
  on issues unless asked.

## Building and validating

```sh
scripts/build-ghostty.sh        # once: builds vendor/GhosttyVT.xcframework (needs Zig 0.17)
swift build                     # everything
swift test                      # all tests
swift test --filter TabCoreTests
scripts/bundle.sh debug         # build/debug/Tab Dev.app
scripts/validate.sh             # what every change must pass before it is finished
```

Run `scripts/validate.sh` before finishing. Warnings are errors.

## Changelog

Every commit updates [CHANGELOG.md](CHANGELOG.md) in the same commit. The app
bundles the file and shows it in Settings → Changelog, so write it for users.

- Each version is a `## X.Y.Z - YYYY-MM-DD` section, newest first, with
  `### Added`, `### Changed`, `### Fixed` or `### Removed` groups of `- `
  entries. Wrapped lines are indented two spaces. Inline Markdown only.
- The newest section is the version the commit will be tagged as. If it is
  not tagged yet (`git tag -l vX.Y.Z` is empty), add to it; otherwise start a
  new section with the next version (see Releasing) and today's date.
- Describe what changed for someone using Tab, in one sentence each: not file
  names, refactors or test-only work. A commit with no visible change, such as
  a CI fix, gets a short entry under `### Fixed` or `### Changed` all the same.
- `ChangelogTests` checks the format and order, and `scripts/tag-release.sh`
  refuses a version that isn't the changelog's newest.

## Releasing

Every commit pushed to `main` ships as a new tagged version. After pushing,
run `scripts/tag-release.sh X.Y.Z` on the pushed `main` and check that the
Release workflow succeeds. Bump the patch for fixes and the minor version for
new features or visible changes; use `--beta` only when asked. X.Y.Z is the
newest version in `CHANGELOG.md`.

## Dependencies

No third-party packages. Only Apple frameworks and the vendored libghostty-vt.
Anything else needs the maintainer's approval first, with its GitHub URL, star
count and maintenance status.

## Performance

- The terminal renderer, split layout and sidebar are hot paths: no allocation
  or layout work per frame beyond what changed, no polling timers, no redraw
  without a change. Measure with Instruments when in doubt.
- Server threads never block on disk or on process launches while handling
  input. Screen frames merge instead of queueing.

## Code standards

- Swift 6 toolchain, Swift 5 language mode. Prefer value types, `enum` state,
  and `actor`s or serial queues for shared mutable state. No force unwraps or
  `try!` outside tests. No `print` in libraries; use the logging helpers.
- Early returns over nested conditionals. Self-explanatory names over
  comments; `///` doc comments for public API.
- Persisted formats are JSON through `Codable`. Decoders must tolerate unknown
  keys and missing optional keys so settings and state files only grow.
- Follow existing patterns. Fix root causes, not symptoms.

## Testing

- XCTest in `Tests/<Module>Tests`. Test real scenarios and risks: data loss,
  protocol compatibility, concurrency, regressions. Don't test defaults.
- Server and client tests may start a real `tabd` through a Unix socket in a
  temporary `TAB_DIR`. Keep socket paths short (`SUN_LEN` limit).
