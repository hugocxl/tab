#!/bin/bash
# Builds and (re)launches this checkout's debug app. Usage: scripts/run-dev.sh
# Each worktree's build is its own app (see bundle.sh), so this quits only this
# checkout's build and leaves other worktrees' builds and the release app alone.
# A new worktree profile starts with a copy of the main Tab Dev profile's
# settings, so remote servers and preferences carry over.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$("$ROOT/scripts/bundle.sh" debug | tail -1)"
INFO="$APP/Contents/Info.plist"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO")"
SUPPORT="$HOME/Library/Application Support"
PROFILE="$SUPPORT/$APP_NAME"

if [ "$APP_NAME" != "Tab Dev" ] && [ ! -d "$PROFILE" ]; then
    mkdir -m 700 -p "$PROFILE"
    for file in settings.json server.json; do
        [ -f "$SUPPORT/Tab Dev/$file" ] && cp "$SUPPORT/Tab Dev/$file" "$PROFILE/$file"
    done
fi

osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
for _ in $(seq 50); do
    pgrep -f "^$APP/Contents/MacOS/TabDesktop" >/dev/null || break
    sleep 0.1
done
# Shells inside Tab export the profile they belong to; the dev app must pick its own.
env -u TAB_DIR -u TAB_AGENT_ID -u TAB_SERVER_ID -u TAB_SERVER_BIN -u TAB_SESSION_ID open "$APP"
echo "$APP_NAME: $PROFILE"
