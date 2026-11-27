#!/bin/bash
# Builds the Mac app's release into build/release/, where the Release workflow
# publishes it from. Takes the same environment as macos/scripts/release.sh.
# TestFlight uploads of the iOS app go through ios/scripts/release.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
macos/scripts/release.sh "$@"
rm -rf build/release
mkdir -p build
cp -R macos/build/release build/release
