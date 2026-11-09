#!/bin/sh
# Copies Tab Icons, Tab's own SVG icon set, from a Tab checkout into the app's
# asset catalog: one template image per SVG, named `TabIcons/<name>`, with its
# licenses beside it. `scripts/sync-tab.sh` runs this too.
#
#   scripts/sync-icons.sh [path to a tab checkout, default ../tab]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAB=$(cd "${1:-$ROOT/../tab}" && pwd)
SOURCE="$TAB/Sources/TabApp/Resources/TabIcons"
[ -d "$SOURCE" ] || { echo "no Tab Icons in $TAB" >&2; exit 1; }

CATALOG="$ROOT/App/Resources/Assets.xcassets/TabIcons"
rm -rf "$CATALOG"
mkdir -p "$CATALOG"
printf '{ "info" : { "author" : "xcode", "version" : 1 }, "properties" : { "provides-namespace" : true } }\n' > "$CATALOG/Contents.json"
for svg in "$SOURCE"/*.svg; do
    name=$(basename "$svg" .svg)
    mkdir "$CATALOG/$name.imageset"
    cp "$svg" "$CATALOG/$name.imageset/"
    printf '{ "images" : [ { "filename" : "%s.svg", "idiom" : "universal" } ], "info" : { "author" : "xcode", "version" : 1 }, "properties" : { "preserves-vector-representation" : true, "template-rendering-intent" : "template" } }\n' \
        "$name" > "$CATALOG/$name.imageset/Contents.json"
done
cp "$SOURCE/LICENSE" "$ROOT/App/Resources/TAB-ICONS-LICENSE.txt"
echo "Synced $(ls "$SOURCE"/*.svg | wc -l | tr -d ' ') Tab Icons"
