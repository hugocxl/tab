#!/bin/bash
# Terminates only this checkout's Tab iOS app on the target simulator.
# Usage: scripts/stop.sh [iphone|ipad|UDID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/simulator.sh"
source "$ROOT/../scripts/worktree.sh" com.hugocorta.tabios Tab
case "${1:-iphone}" in
    iphone) DEVICE="$(iphone_simulator)" ;;
    ipad) DEVICE="$(ipad_simulator)" ;;
    *) DEVICE="$1" ;;
esac
xcrun simctl terminate "$DEVICE" "$WT_BUNDLE_ID" 2>/dev/null || true
