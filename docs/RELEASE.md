# Releasing Tab

Tab ships one Apple silicon DMG and an `update.json` feed in each GitHub Release,
following Codesh's schema-1 layout. macOS 14.0 is the minimum. No release script
launches the GUI, creates a tag, pushes a commit, or publishes a release locally.

## Build locally

Use an Apple silicon Mac, Xcode's command-line tools and Swift toolchain, and
Zig 0.17.0 for the pinned Ghostty VT build. There are no added package dependencies.

```sh
scripts/validate.sh
scripts/release.sh
```

`VERSION` contains `X.Y`; the default version is `X.Y.<git commit count>`, matching
Codesh's version convention. `RELEASE_VERSION=X.Y.Z` overrides this for a tag build.
Only stable `X.Y.Z` release versions are packaged; the `v*` workflow rejects other
tags. `CFBundleShortVersionString` is the full release version and `CFBundleVersion`
is the checkout's commit count. Neither command edits source files to stamp a version.

Outputs (existing local outputs are replaced):

- `build/release/Tab.app`
- `build/release/Tab-X.Y.Z-arm64.dmg`
- `build/release/update.json`

Without `CODESIGN_IDENTITY`, the scripts explicitly report ad-hoc signing and skip
Developer ID signing, notarization and stapling. Such builds are for local checks;
the updater requires a Developer ID team and will not activate for them. With an
identity but no notarization credentials, the script reports that notarization is
skipped. `REQUIRE_NOTARIZATION=1` makes missing signing/notarization credentials an
error, and the release workflow always sets it.

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

Configure these repository secrets, using the same names as Codesh:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_CERTIFICATE` | Base64-encoded Developer ID Application `.p12`, including its private key |
| `DEVELOPER_ID_APPLICATION_PASSWORD` | Password protecting that `.p12` |
| `KEYCHAIN_PASSWORD` | A strong temporary signing-keychain password |
| `APPLE_ID` | Apple developer account email |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for that account |
| `APPLE_TEAM_ID` | Ten-character Apple team ID |

Set them with `gh secret set`; examples:

```sh
base64 < /path/to/DeveloperID.p12 | gh secret set DEVELOPER_ID_APPLICATION_CERTIFICATE --repo hugocxl/tab
gh secret set DEVELOPER_ID_APPLICATION_PASSWORD --repo hugocxl/tab
gh secret set KEYCHAIN_PASSWORD --repo hugocxl/tab
gh secret set APPLE_ID --repo hugocxl/tab
gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo hugocxl/tab
gh secret set APPLE_TEAM_ID --repo hugocxl/tab
```

`GITHUB_TOKEN` is supplied by GitHub automatically with release write permission;
no personal access token is needed. The workflow uses Apple ID credentials; the
profile/API-key alternatives are supported for local use.

To cut a release, finish validation on the intended commit, choose `X.Y.Z` (normally
`$(cat VERSION).$(git rev-list --count HEAD)`), and have the maintainer create and push
`vX.Y.Z`. The workflow uses a full-history checkout on the Apple silicon `macos-15`
runner, builds Ghostty if uncached, runs `scripts/validate.sh`, imports the certificate
into a temporary keychain, and calls `scripts/release.sh`. It resolves
`CODESIGN_IDENTITY` from the imported Developer ID Application certificate.

It creates a draft release for the existing tag, uploads `Tab-X.Y.Z-arm64.dmg` and
`update.json`, checks uploaded sizes, and publishes it as the latest stable release.
A failed upload leaves a draft that can be retried. Already public releases are
left immutable; fix problems in a new version. The temporary certificate/keychain
are removed even on failure. Validation logs are retained as workflow artifacts.

## How installed apps update

Stable apps read
`https://github.com/hugocxl/tab/releases/latest/download/update.json` on their
automatic schedule and through Check for Updates. The current implementation checks
hourly. Beta/local versions use the separate `releases/download/beta/update.json`
channel; this workflow publishes stable releases only.

The generated schema is:

```json
{
  "schema": 1,
  "version": "0.1.28",
  "minimumSystemVersion": "14.0",
  "teamID": "ABCDEFGHIJ",
  "buildInfo": { "version": "0.1.28", "compatibility": 21, "protocol": [1] },
  "protocolVersions": [1],
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
the release script. The updater requires a newer version on the same channel,
the exact release asset URL and filename, supported macOS, and matching download
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
