#!/bin/sh
# Everything a change must pass: the package's tests on an iPhone simulator
# and the app build, with warnings as errors.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/simulator.sh"
DEVICE=$(iphone_simulator)
STRICT="GCC_TREAT_WARNINGS_AS_ERRORS=YES"

echo "== Tests"
(cd "$ROOT" && xcodebuild test -scheme TabKit -destination "id=$DEVICE" -derivedDataPath "$ROOT/.build/xc" \
    -skip-testing:TabMobileKitTests/LiveServerTests -quiet $STRICT)

echo "== App"
xcodebuild build -project "$ROOT/App/Tab.xcodeproj" -scheme Tab -destination "generic/platform=iOS" \
    -derivedDataPath "$ROOT/.build/app" -quiet CODE_SIGNING_ALLOWED=NO $STRICT $("$ROOT/scripts/version.sh")

echo "Validated."
