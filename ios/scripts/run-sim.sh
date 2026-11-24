#!/bin/bash
# Builds the app and (re)launches only this checkout's build on a simulator.
# Usage: scripts/run-sim.sh [iphone|ipad|UDID]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/simulator.sh"
source "$ROOT/scripts/worktree.sh" com.hugocorta.tabios Tab
case "${1:-iphone}" in
    iphone) DEVICE="$(iphone_simulator)" ;;
    ipad) DEVICE="$(ipad_simulator)" ;;
    *) DEVICE="$1" ;;
esac
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
EXTRA=()
if [ "$WT_IS_LINKED" = 1 ]; then
    EXTRA+=(PRODUCT_BUNDLE_IDENTIFIER="$WT_BUNDLE_ID" INFOPLIST_KEY_CFBundleDisplayName="$WT_APP_NAME")
fi
DERIVED="$ROOT/.build/app/$WT_HASH"
xcodebuild -project "$ROOT/App/Tab.xcodeproj" -scheme Tab -destination "id=$DEVICE" \
    -derivedDataPath "$DERIVED" -quiet ${EXTRA[@]+"${EXTRA[@]}"} build
xcrun simctl terminate "$DEVICE" "$WT_BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$DERIVED/Build/Products/Debug-iphonesimulator/Tab.app"
xcrun simctl launch "$DEVICE" "$WT_BUNDLE_ID" > /dev/null
echo "$DEVICE ($WT_BUNDLE_ID)"
