#!/bin/sh
# Copies the code the iOS app shares with the Mac app from ../macos into Vendor/, so
# the app speaks exactly the protocol of the Tab version it was synced with.
# Never edit Vendor/ by hand: change Tab, then run this again.
#
#   scripts/sync-tab.sh [path to the Mac app package, default ../macos]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAB=$(cd "${1:-$ROOT/../macos}" && pwd)
[ -d "$TAB/Sources/TabProtocol" ] || { echo "not the Mac app package: $TAB" >&2; exit 1; }

rm -rf "$ROOT/Vendor/TabProtocol" "$ROOT/Vendor/TabShared/Tab"
mkdir -p "$ROOT/Vendor/TabShared/Tab/Resources"
cp -R "$TAB/Sources/TabProtocol" "$ROOT/Vendor/TabProtocol"

# TabCore and TabClient files that build without AppKit, processes or sockets.
# They become one module, so their imports of each other go away.
for file in TabCore/Tabs/TabReducer.swift TabCore/Theme.swift \
    TabClient/Client.swift TabClient/Requests.swift TabClient/ClientError.swift \
    TabClient/Grid.swift TabClient/Reconnect.swift TabClient/Tunnel.swift; do
    target="$ROOT/Vendor/TabShared/Tab/$(basename "$file")"
    sed -e '/^import TabCore$/d' "$TAB/Sources/$file" > "$target"
    grep -q '^import TabProtocol$' "$target" || sed -i '' 's/^import Foundation$/import Foundation\
import TabProtocol/' "$target"
done
cp -R "$TAB/Sources/TabCore/Resources/Themes" "$ROOT/Vendor/TabShared/Tab/Resources/Themes"

REVISION=$(git -C "$TAB" rev-parse HEAD)
VERSION=$(sed -n 's/^## \([0-9][0-9.]*\) .*/\1/p' "$TAB/../CHANGELOG.md" | head -1)
printf '%s %s\n' "$VERSION" "$REVISION" > "$ROOT/Vendor/TAB_REVISION"
echo "Synced Tab $VERSION ($REVISION)"
