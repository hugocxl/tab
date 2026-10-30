#!/bin/bash
# The validation every change must pass before it is finished.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/swift-settings.sh"
[ -d vendor/GhosttyVT.xcframework ] || scripts/build-ghostty.sh
mkdir -p build/validation
swift build "${SWIFT_FLAGS[@]}" --build-tests -Xswiftc -warnings-as-errors 2>&1 | tee build/validation/build.log | tail -20
TEST_STATUS=0
swift test "${SWIFT_FLAGS[@]}" --skip-build "$@" 2>&1 | tee build/validation/test.log | tail -40 || TEST_STATUS=$?
scripts/bundle.sh debug > /dev/null
if [ "$TEST_STATUS" != 0 ]; then
    echo "validation failed: tests exited $TEST_STATUS (see build/validation/test.log)" >&2
    exit "$TEST_STATUS"
fi
echo "validation passed"
