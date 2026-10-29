#!/bin/bash
# The validation every change must pass before it is finished.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -d vendor/GhosttyVT.xcframework ] || scripts/build-ghostty.sh
swift build --build-tests -Xswiftc -warnings-as-errors 2>&1 | tail -20
swift test 2>&1 | tail -40
scripts/bundle.sh debug > /dev/null
echo "validation passed"
