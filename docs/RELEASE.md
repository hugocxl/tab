# Releasing Tab

Tab ships one Apple silicon DMG and an `update.json` feed in each GitHub Release,
following Codesh's schema-1 layout. macOS 14.0 is the minimum. No release script
launches the GUI, pushes a commit, or publishes a release locally; publishing is a
tag push, which `scripts/tag-release.sh` makes.

## Build locally

Use an Apple silicon Mac, Xcode's command-line tools and Swift toolchain, and
Zig 0.17.0 for the pinned Ghostty VT build. There are no added package dependencies.

```sh
scripts/validate.sh
RELEASE_VERSION=0.2.0 scripts/release.sh
```

The release tag is the only source of a release's version: `vX.Y.Z` for a stable
release, `vX.Y.Z-beta.N` for a beta, where `N` is the tagged commit's
`git rev-list --count`, which orders betas. `release.sh` requires `RELEASE_VERSION`;
the workflow sets it from the tag. Local bundles from `bundle.sh` without it are
`X.Y.<commit count>` from `VERSION` (`X.Y`) and are never published.
`CFBundleShortVersionString` is `X.Y.Z`, as macOS expects; the full version, with
any `-beta.N`, is the `TabVersion` key, which the app and the updater read.
`CFBundleVersion` is the commit count. Nothing edits source files to stamp a version.

Outputs (existing local outputs are replaced):

- `build/release/Tab.app`
- `build/release/Tab-X.Y.Z-arm64.dmg`
- `build/release/update.json`

Without `CODESIGN_IDENTITY`, the scripts explicitly report ad-hoc signing and skip
Developer ID signing, notarization and stapling. Such builds are for local checks;
the updater requires a Developer ID team and will not activate for them. With an
identity but no notarization credentials, the script reports that notarization is
skipped. `REQUIRE_NOTARIZATION=1` makes missing signing, notarization or feed
signing credentials an error, and the release workflow always sets it.

`UPDATE_SIGNING_KEY` is the base64 Ed25519 private key that signs `update.json`.
Installed apps hold its public half (`UpdateFeed.signingKey`) and refuse feeds it
didn't sign. Without it, `release.sh` writes an unsigned feed for local checks.
The key lives in the maintainer's login keychain as "Tab update signing key":

```sh
export UPDATE_SIGNING_KEY="$(security find-generic-password -a tab-release -s 'Tab update signing key' -w)"
```

Back it up somewhere safe. Losing it means installed apps can't update until they
are reinstalled by hand from a release with a new key.

For signed local packaging, set `CODESIGN_IDENTITY` to the Developer ID Application
certificate's name or SHA-1 identity from `security find-identity -v -p codesigning`.
Supply one of these credential sets, in priority order:

1. `NOTARY_KEYCHAIN_PROFILE`: a profile created with `xcrun notarytool store-credentials`.
2. `APPLE_API_KEY_PATH`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`: the local App Store
   Connect `.p8` key path, key ID and issuer ID.
3. `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`: the same variables as
   Codesh's workflow. Use an app-specific password, not an Apple account password.

When `APPLE_TEAM_ID` is set, it must match the signing certificate's team. The team
in the manifest is read from the actual signature. Ad-hoc builds write `teamID: null`.
Partial credential sets are errors. Credentials are never placed in the bundle/feed.

`release.sh` builds all three products with `bundle.sh release`, regenerates the icon,
signs each executable and the app with `packaging/Tab.entitlements`, hardened runtime
and a secure timestamp, and verifies the sealed bundle. It checks `tab --build-info`
against `tabd --build-info` and the bundle version before submitting anything to Apple.
It notarizes a ZIP of the app and staples the app, then creates an HFS+ DMG containing
`Tab.app`, an `/Applications` symlink and `.VolumeIcon.icns`. The mounted volume's
Finder custom-icon flag is set before compression. The DMG is signed, notarized,
stapled and verified. A final read-only mount verifies the sealed app, symlink,
icons and build metadata; only then is `update.json` written with the final DMG's
SHA-256 and byte count. App and DMG Gatekeeper assessments run for notarized builds.

## GitHub secrets and release tags

The repository must be public: installed apps download the feed and the DMG
without credentials. Set every secret at once with:

```sh
scripts/setup-release-secrets.sh DeveloperID.p12 --api-key AuthKey_KEYID.p8 <issuer-id>
scripts/setup-release-secrets.sh DeveloperID.p12 --apple-id you@example.com
```

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE` | Base64-encoded Developer ID Application `.p12`, including its private key |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password protecting that `.p12` |
| `APPLE_API_KEY_P8` | Base64-encoded App Store Connect API key (`.p8`) with the Developer role |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER_ID` | The API keys' issuer ID |
| `APPLE_TEAM_ID` | Ten-character Apple team ID |
| `UPDATE_SIGNING_KEY` | The feed signing key, from the login keychain |

The workflow notarizes with the API key. Without `APPLE_API_KEY_P8` it falls back
to `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD`, Codesh's secrets. Its signing
keychain gets a random password per run. `GITHUB_TOKEN` is supplied by GitHub.

Each release's changes are listed in `CHANGELOG.md`, which the app shows in
Settings → Changelog. `tag-release.sh` refuses a version that isn't the
changelog's newest. To cut a release, push the validated commit to `main`, then:

```sh
scripts/tag-release.sh 0.2.0          # stable: tags and pushes v0.2.0
scripts/tag-release.sh 0.2.0 --beta   # beta: tags and pushes v0.2.0-beta.<commit count>
```

The workflow runs on GitHub's Apple silicon `xcode-27` runner with Xcode 27.1. It
refuses tags that aren't on `main` and betas whose `N` isn't the commit count,
builds Ghostty if uncached, runs `scripts/validate.sh`, imports the certificate into
a temporary keychain, and calls `scripts/release.sh`.

It creates a draft release for the tag, uploads `Tab-<version>-arm64.dmg` and
`update.json`, checks uploaded sizes, and publishes it. A stable release becomes the
latest release, and so the stable feed, unless a newer stable version already is. A
beta is published as a prerelease, then its `update.json` replaces the one in the
`beta` release, the beta feed, unless that names a newer beta. A failed upload
leaves a draft that can be retried by re-running the workflow. Already public
releases are left immutable; fix problems in a new version. The temporary
certificate, key and keychain are removed even on failure. Validation logs are
retained as workflow artifacts.

## How installed apps update

Stable apps read
`https://github.com/hugocxl/tab/releases/latest/download/update.json` hourly and
through Check for Updates. Betas read `releases/download/beta/update.json` and the
stable feed, and take the newest release that replaces them: a beta with a larger
`N`, or a stable release of their `X.Y.Z` or later, which moves them to the stable
channel. Stable apps never take betas. A feed that can't be reached is skipped
while another answers.

The generated schema is:

```json
{
  "schema": 1,
  "version": "0.1.28",
  "minimumSystemVersion": "14.0",
  "teamID": "ABCDEFGHIJ",
  "buildInfo": { "version": "0.1.28", "compatibility": 21, "protocol": [1] },
  "protocolVersions": [1],
  "signature": "<base64 Ed25519 signature>",
  "platforms": {
    "macos-aarch64": {
      "url": "https://github.com/hugocxl/tab/releases/download/v0.1.28/Tab-0.1.28-arm64.dmg",
      "sha256": "<64 lowercase hexadecimal characters>",
      "size": 12345678
    }
  }
}
```

Protocol/compatibility values come from the packaged executables, not constants in
the release script. `signature` covers, one per line, `tab-update-1`, the version,
the DMG URL, its SHA-256, its size and the minimum macOS. The updater requires that
signature from the release key, a version that replaces the installed one, the
exact release asset URL and filename, supported macOS, and matching download
size/checksum. It validates the DMG and nested app against the installed app's
Apple team, the `com.hugocorta.tab` bundle identifier, arm64 executables and version.
It then executes the verified `tab` and `tabd` with `--build-info` and requires them
to agree. `buildInfo` and `teamID` in the feed are informational extra fields;
the updater establishes these values from the signature and verified binaries.
Feed protocol hints cannot authorize keeping a server alive.

Compatible releases can replace the app while preserving a running server; the
server switches once idle or on explicit restart. Incompatible updates wait for
terminals to end, or require explicit confirmation to end them. An old bundle is
retained while its server still runs.

Apps that can't update themselves say so in Check for Updates instead of
downloading: debug builds, ad-hoc signed or unversioned builds, apps run from the
DMG or translocated by Gatekeeper, and apps whose folder or bundle this account
can't write, such as one an administrator installed in `/Applications`.

## Icons and verification

`scripts/build-icon.swift` renders `packaging/AppIcon.svg`, using
`AppIconSmall.svg` for the small (16–64 pixel) representations, and writes the PNG
and ICNS. It uses native AppKit rasterization and PNG entries in the ICNS container.
`Info.plist` names `AppIcon` with `CFBundleIconFile`; the file is copied to
`Contents/Resources/AppIcon.icns`. macOS 14 supports this without `CFBundleIconName`
or `Assets.car`: Apple's [Info.plist reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html)
specifies the `CFBundleIconFile` fallback when no catalog icon name is provided.
Codesh has no document icon or document-type registration, so Tab adds none.

The GUI executable remains `TabDesktop`; `Tab` and the CLI's `tab` would collide on
a case-insensitive disk. Bundles include the speech/microphone/local-network usage
descriptions, `tab://` handler, developer-tools category, high-resolution capability,
web-content HTTP support for browser panes, and disabled automatic/sudden termination.

To inspect without opening the app:

```sh
iconutil --convert iconset --output /tmp/Tab.iconset packaging/AppIcon.icns
sips -g pixelWidth -g pixelHeight /tmp/Tab.iconset/*.png
plutil -p build/release/Tab.app/Contents/Info.plist
codesign --verify --deep --strict build/release/Tab.app
build/release/Tab.app/Contents/MacOS/tabd --build-info
build/release/Tab.app/Contents/MacOS/tab --build-info
hdiutil verify build/release/Tab-X.Y.Z-arm64.dmg
```

For an agent sandbox that blocks Swift's user cache or nested SwiftPM sandbox,
the scripts keep caches under `.build` and accept `TAB_DISABLE_SWIFTPM_SANDBOX=1`.
This does not grant socket, disk-image or keychain access denied by the outer
sandbox. `validate.sh` saves full build/test logs in `build/validation`, bundles
even when tests fail, and still exits nonzero on failure. Optional arguments are
passed through to `swift test`, such as `--filter PackagingManifestTests` for a
focused packaging check; the release workflow always runs the full suite.
`TAB_SWIFT_SCRATCH_PATH=/absolute/path` selects an isolated SwiftPM build directory
when other builds are using the checkout concurrently.
`TAB_SWIFT_BUILD_SYSTEM=native` selects SwiftPM's native backend on toolchains
whose Swift Build service cannot generate release dSYMs inside an agent sandbox.
