#!/bin/bash
# Builds the Apple silicon app, DMG and GitHub Releases update.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/swift-settings.sh"
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "Error: releases require an Apple silicon Mac and Xcode" >&2
    exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=14.0
# Releases are numbered by their tag (vX.Y.Z or vX.Y.Z-beta.N), never by default.
: "${RELEASE_VERSION:?Set RELEASE_VERSION to the X.Y.Z or X.Y.Z-beta.N being released}"
export RELEASE_VERSION
IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_ARGS=()
if [ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
elif [ -n "${APPLE_API_KEY_PATH:-}${APPLE_API_KEY_ID:-}${APPLE_API_ISSUER_ID:-}" ]; then
    : "${APPLE_API_KEY_PATH:?Path to the App Store Connect .p8 key is required}"
    : "${APPLE_API_KEY_ID:?API key ID is required}"
    : "${APPLE_API_ISSUER_ID:?API issuer ID is required}"
    NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
elif [ -n "${APPLE_ID:-}${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
    : "${APPLE_ID:?APPLE_ID is required}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
    NOTARY_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi
if [ "${REQUIRE_NOTARIZATION:-0}" = 1 ] && { [ "$IDENTITY" = - ] || [ "${#NOTARY_ARGS[@]}" = 0 ] || [ -z "${UPDATE_SIGNING_KEY:-}" ]; }; then
    echo "Error: this release requires a Developer ID identity, notarization credentials and UPDATE_SIGNING_KEY" >&2
    exit 1
fi
if [ -z "${UPDATE_SIGNING_KEY:-}" ]; then
    echo "==> No UPDATE_SIGNING_KEY: update.json is unsigned and installed apps will refuse it"
fi
if [ "$IDENTITY" = - ]; then
    echo "==> No CODESIGN_IDENTITY: using an ad-hoc signature; skipping signing with Developer ID, notarization and stapling"
elif [ "${#NOTARY_ARGS[@]}" = 0 ]; then
    echo "==> Signing with Developer ID; no notarization credentials, skipping notarization and stapling"
fi

APP="$ROOT/build/release/Tab.app"
OUTPUT="$ROOT/build/release"
DMG="$OUTPUT/Tab-$RELEASE_VERSION-arm64.dmg"
# Do not leave a stale feed if any packaging or notarization step fails.
rm -f "$OUTPUT/update.json"
CODESIGN_IDENTITY="$IDENTITY" scripts/bundle.sh release
STAGING="$(mktemp -d "$OUTPUT/.release.XXXXXX")"
MOUNT="$STAGING/mount"
MOUNTED=0
cleanup() {
    if [ "$MOUNTED" = 1 ]; then hdiutil detach -force "$MOUNT" >/dev/null || true; fi
    rm -rf "$STAGING"
}
trap cleanup EXIT
TEAM=-
if [ "$IDENTITY" != - ]; then
    codesign -d --verbose=4 "$APP" 2> "$STAGING/signature.txt"
    grep -q '^Authority=Developer ID Application:' "$STAGING/signature.txt"
    TEAM="$(sed -n 's/^TeamIdentifier=//p' "$STAGING/signature.txt")"
    if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { [ -n "${APPLE_TEAM_ID:-}" ] && [ "$TEAM" != "$APPLE_TEAM_ID" ]; }; then
        echo "Error: signing identity has an unexpected Apple team identifier" >&2
        exit 1
    fi
fi
for product in TabDesktop tabd tab; do
    [ -x "$APP/Contents/MacOS/$product" ]
    [ "$(lipo -archs "$APP/Contents/MacOS/$product")" = arm64 ]
done
# Check both packaged executables before submitting anything to Apple.
printf 'metadata check\n' > "$STAGING/Tab-$RELEASE_VERSION-arm64.dmg"
swift scripts/release-metadata.swift "$APP" "$STAGING/Tab-$RELEASE_VERSION-arm64.dmg" "$TEAM" "$STAGING/check.json"

notarize() {
    local archive="$1"
    local status=0
    if [ "$IDENTITY" = - ] || [ "${#NOTARY_ARGS[@]}" = 0 ]; then return; fi
    echo "==> Notarizing $(basename "$archive")"
    xcrun notarytool submit "$archive" "${NOTARY_ARGS[@]}" --wait --timeout 30m \
        --output-format plist > "$STAGING/notary.plist" || status=$?
    plutil -p "$STAGING/notary.plist" || true
    if [ "$status" != 0 ] || [ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$STAGING/notary.plist")" != Accepted ]; then
        local submission
        submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$STAGING/notary.plist" 2>/dev/null || true)"
        if [ -n "$submission" ]; then xcrun notarytool log "$submission" "${NOTARY_ARGS[@]}" || true; fi
        echo "Error: Apple did not accept the notarization submission" >&2
        exit 1
    fi
}
staple() {
    if [ "$IDENTITY" = - ] || [ "${#NOTARY_ARGS[@]}" = 0 ]; then return; fi
    xcrun stapler staple "$1"
    xcrun stapler validate "$1"
}
if [ "$IDENTITY" != - ] && [ "${#NOTARY_ARGS[@]}" != 0 ]; then
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGING/Tab.zip"
    notarize "$STAGING/Tab.zip"
    staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi
mkdir -p "$STAGING/volume" "$MOUNT"
ditto "$APP" "$STAGING/volume/Tab.app"
ln -s /Applications "$STAGING/volume/Applications"
cp packaging/AppIcon.icns "$STAGING/volume/.VolumeIcon.icns"
for attempt in 1 2 3 4 5; do
    rm -f "$STAGING/Tab-rw.dmg"
    if hdiutil create -volname Tab -srcfolder "$STAGING/volume" -format UDRW -fs HFS+ "$STAGING/Tab-rw.dmg"; then break; fi
    if [ "$attempt" = 5 ]; then echo "Error: hdiutil create failed after $attempt attempts" >&2; exit 1; fi
    sleep "$((attempt * 5))"
done
hdiutil attach -readwrite -nobrowse -noautoopen -mountpoint "$MOUNT" "$STAGING/Tab-rw.dmg"
MOUNTED=1
xcrun SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT"
MOUNTED=0
rm -f "$DMG"
hdiutil convert "$STAGING/Tab-rw.dmg" -format UDZO -o "$DMG"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [ "$IDENTITY" = - ]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--timestamp --options runtime); fi
codesign "${SIGN_ARGS[@]}" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG"
staple "$DMG"
if [ "$IDENTITY" != - ] && [ "${#NOTARY_ARGS[@]}" != 0 ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi
hdiutil verify "$DMG"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT" "$DMG"
MOUNTED=1
codesign --verify --deep --strict --verbose=2 "$MOUNT/Tab.app"
[ "$(readlink "$MOUNT/Applications")" = /Applications ]
cmp packaging/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
cmp packaging/AppIcon.icns "$MOUNT/Tab.app/Contents/Resources/AppIcon.icns"
xcrun GetFileInfo -a "$MOUNT" | grep -q C
swift scripts/release-metadata.swift "$MOUNT/Tab.app" "$DMG" "$TEAM" "$STAGING/update.json"
hdiutil detach "$MOUNT"
MOUNTED=0
mv "$STAGING/update.json" "$OUTPUT/update.json"
echo "==> Built $APP"
echo "==> Built $DMG"
echo "==> Built $OUTPUT/update.json"
