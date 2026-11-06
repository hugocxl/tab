#!/bin/sh
# Builds the app and (re)launches it on a simulator, booting it if needed.
#
#   scripts/run-sim.sh [iphone|ipad|UDID]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/simulator.sh"
case "${1:-iphone}" in
    iphone) DEVICE=$(iphone_simulator) ;;
    ipad) DEVICE=$(ipad_simulator) ;;
    *) DEVICE=$1 ;;
esac
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcodebuild -project "$ROOT/App/Tab.xcodeproj" -scheme Tab -destination "id=$DEVICE" \
    -derivedDataPath "$ROOT/.build/app" -quiet build
xcrun simctl terminate "$DEVICE" com.hugocorta.tabios 2>/dev/null || true
xcrun simctl install "$DEVICE" "$ROOT/.build/app/Build/Products/Debug-iphonesimulator/Tab.app"
xcrun simctl launch "$DEVICE" com.hugocorta.tabios > /dev/null
echo "$DEVICE"
