# Tab

A Swift-only, native macOS terminal workspace, rewritten from
[Codesh](https://github.com/hugocxl/codesh). Apple silicon; macOS 14 or later.
Terminals run in a separate `tabd` process and survive closing the desktop app.

Build with Xcode's Swift toolchain and Zig 0.17.0:

```sh
scripts/build-ghostty.sh
scripts/validate.sh
scripts/bundle.sh debug
```

The development bundle is `build/debug/Tab Dev.app`. Each bundle contains
`TabDesktop` (the app), `tab` (the CLI), and `tabd` (the server).

For a local release package, run `RELEASE_VERSION=X.Y.Z scripts/release.sh`. Without signing credentials
it produces an ad-hoc signed app and DMG for local inspection. Distribution builds
use Developer ID signing and Apple notarization; see [Releasing](docs/RELEASE.md).

See [Architecture](docs/ARCHITECTURE.md) for module boundaries and
[Migration](docs/MIGRATION.md) for implementation and verification status.
