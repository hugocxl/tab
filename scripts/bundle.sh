#!/bin/bash
# Assembles Tab.app from a SwiftPM build. Usage: scripts/bundle.sh [debug|release]
# The bundle lands in build/<config>/ and holds TabDesktop, tabd and tab.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
source "$ROOT/scripts/swift-settings.sh"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="${RELEASE_VERSION:-$(cat "$ROOT/VERSION").$BUILD_NUMBER}"
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
if [ "$CONFIG" = "release" ]; then
    BUNDLE_ID="com.hugocorta.tab"; APP_NAME="Tab"
else
    BUNDLE_ID="com.hugocorta.tab-dev"; APP_NAME="Tab Dev"
fi

for product in TabDesktop tabd tab; do
    (cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --product "$product")
done
BIN="$(cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --show-bin-path)"
swift "$ROOT/scripts/build-icon.swift"
APP="$ROOT/build/$CONFIG/$APP_NAME.app"
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
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__VERSION__/$VERSION/g" \
    -e "s/__SHORT_VERSION__/$SHORT_VERSION/g" \
    -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/g" \
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
