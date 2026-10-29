#!/bin/bash
# Builds libghostty-vt from the pinned Ghostty commit with Zig and packages it
# as vendor/GhosttyVT.xcframework for SwiftPM. Needs Zig 0.17.0 and Xcode.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMIT="6ba144158577d033ccb6ed4b574e4013957c9161"
SRC="$ROOT/vendor/ghostty-src"
VT="$ROOT/vendor/ghostty-vt"
OUT="$ROOT/vendor/GhosttyVT.xcframework"
OPTIMIZE="${GHOSTTY_OPTIMIZE:-ReleaseFast}"

if [ ! -d "$SRC/.git" ]; then
    git clone --quiet https://github.com/ghostty-org/ghostty.git "$SRC"
fi
git -C "$SRC" checkout --quiet "$COMMIT"
git -C "$SRC" checkout --quiet -- .
git -C "$SRC" apply "$VT/clear-screen.patch"

(cd "$SRC" && zig build -Demit-lib-vt=true "-Doptimize=$OPTIMIZE" -Demit-xcframework=false \
    -Dapp-runtime=none --prefix "$SRC/zig-out/install")

rm -rf "$VT/include" "$VT/lib"
cp -R "$SRC/zig-out/install/include" "$VT/include"
mkdir -p "$VT/lib"
cp "$SRC/zig-out/install/lib/libghostty-vt.a" "$VT/lib/"
cat > "$VT/include/module.modulemap" <<'MAP'
module CGhosttyVT {
    umbrella header "ghostty/vt.h"
    export *
}
MAP
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$VT/lib/libghostty-vt.a" -headers "$VT/include" -output "$OUT" > /dev/null
echo "Built $OUT"
