#!/bin/bash
# Builds Tab's dynamically loaded plugins as Mach-O .bundle archives into
# build/<config>/plugins/ (outside Tab.app; no plugins ship installed by default).
# Usage: scripts/build-plugins.sh [debug|release]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
case "$CONFIG" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 1 ;; esac
source "$ROOT/scripts/swift-settings.sh"

BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
VERSION="${RELEASE_VERSION:-$("$ROOT/scripts/changelog.sh" version)}"
SHORT_VERSION="${VERSION%%-*}"

BIN="$(cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --show-bin-path)"
if [ ! -d "$BIN/Modules" ] || [ ! -f "$BIN/Modules/TabApp.swiftmodule" ]; then
    (cd "$ROOT" && swift build "${SWIFT_FLAGS[@]}" -c "$CONFIG" --product TabDesktop)
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
OPT_FLAGS=()
if [ "$CONFIG" = "release" ]; then
    OPT_FLAGS=(-O)
else
    OPT_FLAGS=(-Onone -g)
fi

SIGN_ARGS=(--force --sign "${CODESIGN_IDENTITY:--}")
if [ "${CODESIGN_IDENTITY:--}" = - ]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--options runtime --timestamp)
fi

OUT_DIR="$ROOT/build/$CONFIG/plugins"
mkdir -p "$OUT_DIR"

build_plugin() {
    local id="$1"
    local module="$2"
    local display_name="$3"
    local principal="$4"
    local src_dir="$ROOT/Sources/$module"
    local bundle="$OUT_DIR/$id.bundle"

    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS"

    local sources=()
    while IFS= read -r file; do
        sources+=("$file")
    done < <(find "$src_dir" -name '*.swift' -type f | sort)

    if [ "${#sources[@]}" -eq 0 ]; then
        echo "Error: no Swift sources found in $src_dir" >&2
        exit 1
    fi

    swiftc \
        -swift-version 5 \
        -target arm64-apple-macosx14.0 \
        -sdk "$SDK_PATH" \
        -module-name "$module" \
        -parse-as-library \
        -warnings-as-errors \
        -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
        -I "$BIN/Modules" \
        -I "$BIN" \
        "${OPT_FLAGS[@]}" \
        -emit-library \
        -Xlinker -bundle \
        -Xlinker -undefined -Xlinker dynamic_lookup \
        -o "$bundle/Contents/MacOS/$module" \
        "${sources[@]}"

    local min_os
    min_os="$(otool -l "$bundle/Contents/MacOS/$module" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
    if [ -n "$min_os" ]; then
        xcrun vtool -set-build-version macos "$min_os" "$SDK_VERSION" -replace \
            -output "$bundle/Contents/MacOS/$module" "$bundle/Contents/MacOS/$module"
    fi

    cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$module</string>
    <key>CFBundleIdentifier</key>
    <string>com.hugocorta.tab.plugin.$id</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$display_name</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>$principal</string>
    <key>TabPluginId</key>
    <string>$id</string>
    <key>TabPluginVersion</key>
    <string>$VERSION</string>
</dict>
</plist>
EOF
    plutil -lint "$bundle/Contents/Info.plist" > /dev/null
    codesign "${SIGN_ARGS[@]}" "$bundle/Contents/MacOS/$module"
    codesign "${SIGN_ARGS[@]}" "$bundle"
    codesign --verify --deep --strict "$bundle"
}

build_plugin "explorer" "TabExplorerPlugin" "Explorer" "TabExplorerPluginFactory"
build_plugin "diff" "TabDiffPlugin" "Diff View" "TabDiffPluginFactory"
build_plugin "usage" "TabUsagePlugin" "AI Usage" "TabUsagePluginFactory"
build_plugin "git-graph" "TabGitGraphPlugin" "Git Graph" "TabGitGraphPluginFactory"

echo "$OUT_DIR"
