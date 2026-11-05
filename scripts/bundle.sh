#!/bin/bash
# Assembles Tab.app from a SwiftPM build. Usage: scripts/bundle.sh [debug|release]
# The bundle lands in build/<config>/ and holds TabDesktop, tabd and tab. Its
# version is RELEASE_VERSION, or CHANGELOG.md's newest; the build number is the
# commit count. A debug bundle built in a linked Git worktree is named after it,
# such as "Tab Dev (wt-3513)", with its own bundle id and profile folder, so
# several worktrees' builds run at once; TAB_DEV_VARIANT overrides the name.
# The bundle's file keeps the plain name: build/debug/Tab Dev.app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
source "$ROOT/scripts/swift-settings.sh"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="${RELEASE_VERSION:-$("$ROOT/scripts/changelog.sh" version)}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-beta\.([1-9][0-9]*))?$ ]]; then
    echo "Error: expected an X.Y.Z or X.Y.Z-beta.N release version, got $VERSION" >&2
    exit 1
fi
# A beta's N is the commit count it was built from, which orders betas.
if [ -n "${BASH_REMATCH[2]}" ] && [ "${BASH_REMATCH[2]}" != "$BUILD_NUMBER" ]; then
    echo "Error: $VERSION must end in this commit's count, $BUILD_NUMBER" >&2
    exit 1
fi
SHORT_VERSION="${VERSION%%-*}"
DEV_VARIANT=""
if [ "$CONFIG" = "release" ]; then
    BUNDLE_ID="com.hugocorta.tab"; APP_NAME="Tab"
else
    BUNDLE_ID="com.hugocorta.tab-dev"; APP_NAME="Tab Dev"
    if [ -n "${TAB_DEV_VARIANT+set}" ]; then
        DEV_VARIANT="$TAB_DEV_VARIANT"
    elif [ "$(git -C "$ROOT" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" ]; then
        DEV_VARIANT="$(basename "$ROOT")"
    fi
    # Bundle ids allow letters, digits and hyphens; the cap keeps the profile's
    # socket paths under the SUN_LEN limit.
    DEV_VARIANT="$(printf '%s' "$DEV_VARIANT" | tr -c 'A-Za-z0-9-' '-' | cut -c 1-24)"
fi
FILE_NAME="$APP_NAME"
if [ -n "$DEV_VARIANT" ]; then
    BUNDLE_ID="$BUNDLE_ID.$DEV_VARIANT"; APP_NAME="Tab Dev ($DEV_VARIANT)"
fi

for product in TabDesktop tabd tab; do
    (cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --product "$product")
done
BIN="$(cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --show-bin-path)"
swift "$ROOT/scripts/build-icon.swift"
APP="$ROOT/build/$CONFIG/$FILE_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TabDesktop" "$BIN/tabd" "$BIN/tab" "$APP/Contents/MacOS/"
# SwiftPM records the deployment target as the SDK version, and macOS keeps
# apps linked against an old SDK in its compatibility look (no current
# toolbars or controls). Record the SDK the binaries were built with.
MIN_OS="$(otool -l "$APP/Contents/MacOS/TabDesktop" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
for product in TabDesktop tabd tab; do
    xcrun vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace \
        -output "$APP/Contents/MacOS/$product" "$APP/Contents/MacOS/$product"
done
# SwiftPM resource bundles sit beside the executables.
for bundle in "$BIN"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# Settings → Changelog reads the repository's changelog from the bundle.
cp "$ROOT/CHANGELOG.md" "$APP/Contents/Resources/CHANGELOG.md"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__VERSION__/$VERSION/g" \
    -e "s/__SHORT_VERSION__/$SHORT_VERSION/g" \
    -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g" \
    -e "s/__DEV_VARIANT__/$DEV_VARIANT/g" \
    "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
SIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY:--}")
if [ "${CODESIGN_IDENTITY:--}" = - ]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--options runtime --timestamp)
fi
for product in tab tabd TabDesktop; do
    codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/packaging/Tab.entitlements" "$APP/Contents/MacOS/$product"
done
codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT/packaging/Tab.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "$APP"
