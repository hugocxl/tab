#!/bin/bash
# Re-packages an already built vendor/ghostty-vt/{include,lib} as the
# xcframework, without rebuilding with Zig.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VT="$ROOT/vendor/ghostty-vt"
OUT="$ROOT/vendor/GhosttyVT.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$VT/lib/libghostty-vt.a" -headers "$VT/include" -output "$OUT" > /dev/null
echo "Built $OUT"
