#!/bin/bash
# Assembles Tab.app from a SwiftPM build. Usage: scripts/bundle.sh [debug|release]
# The bundle lands in build/<config>/Tab.app and holds Tab, tabd and tab.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
VERSION="$(cat "$ROOT/VERSION").$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
if [ "$CONFIG" = "release" ]; then
    BUNDLE_ID="com.hugocorta.tab"; APP_NAME="Tab"
else
    BUNDLE_ID="com.hugocorta.tab-dev"; APP_NAME="Tab Dev"
fi

(cd "$ROOT" && swift build -c "$CONFIG" --product TabDesktop --product tabd --product tab)
BIN="$ROOT/.build/$CONFIG"
APP="$ROOT/build/$CONFIG/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TabDesktop" "$APP/Contents/MacOS/Tab"; cp "$BIN/tabd" "$BIN/tab" "$APP/Contents/MacOS/"
# SwiftPM resource bundles sit beside the executables.
for bundle in "$BIN"/*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
if [ -f "$ROOT/packaging/AppIcon.icns" ]; then
    cp "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__APP_NAME__/$APP_NAME/g" -e "s/__VERSION__/$VERSION/g" \
    "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" --entitlements "$ROOT/packaging/Tab.entitlements" "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "$APP"
