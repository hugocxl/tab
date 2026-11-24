#!/bin/bash
# Quits only this checkout's Tab Dev app (by bundle id) and stops its tabd server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/debug/Tab Dev.app"
[ -d "$APP" ] || exit 0
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
env -u TAB_DIR -u TAB_AGENT_ID -u TAB_SERVER_ID -u TAB_SERVER_BIN -u TAB_SESSION_ID \
    "$APP/Contents/MacOS/tab" server stop --force --yes 2>/dev/null || true
