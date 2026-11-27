#!/bin/bash
# Shared SwiftPM settings; sourced after ROOT is set.
set -euo pipefail
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
SWIFT_FLAGS=(--cache-path "$ROOT/.build/cache" --config-path "$ROOT/.build/configuration"
    --security-path "$ROOT/.build/security" --manifest-cache local)
if [ -n "${TAB_SWIFT_SCRATCH_PATH:-}" ]; then
    SWIFT_FLAGS+=(--scratch-path "$TAB_SWIFT_SCRATCH_PATH")
fi
if [ -n "${TAB_SWIFT_BUILD_SYSTEM:-}" ]; then
    SWIFT_FLAGS+=(--build-system "$TAB_SWIFT_BUILD_SYSTEM")
fi
if [ "${TAB_DISABLE_SWIFTPM_SANDBOX:-0}" = 1 ]; then
    SWIFT_FLAGS+=(--disable-sandbox)
fi
