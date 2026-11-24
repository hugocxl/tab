#!/bin/bash
# Shared multi-worktree isolation helper. Source from build/run/stop/validate scripts:
#   source scripts/worktree.sh <base-bundle-id> <base-app-name>
#
# Identity follows the physical checkout path, not the branch (which changes) or
# basename alone (which can collide across worktrees).
WT_BASE_BUNDLE_ID="${1:?base bundle id required}"
WT_BASE_APP_NAME="${2:?base app name required}"
WT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WT_HASH="$(printf '%s' "$WT_ROOT" | shasum -a 256 | cut -c 1-8)"
WT_LABEL="$(basename "$WT_ROOT" | LC_ALL=C tr -c 'A-Za-z0-9-' '-' | cut -c 1-24)"

WT_IS_LINKED=0
if [ "$(git -C "$WT_ROOT" rev-parse --git-dir 2>/dev/null || true)" != "$(git -C "$WT_ROOT" rev-parse --git-common-dir 2>/dev/null || true)" ]; then
    WT_IS_LINKED=1
fi

if [ "$WT_IS_LINKED" = 1 ]; then
    WT_BUNDLE_ID="${WT_BASE_BUNDLE_ID}-dev.${WT_HASH}"
    WT_APP_NAME="${WT_BASE_APP_NAME} Dev (${WT_LABEL})"
else
    WT_BUNDLE_ID="${WT_BASE_BUNDLE_ID}"
    WT_APP_NAME="${WT_BASE_APP_NAME}"
fi

WT_DERIVED_BASE="${DERIVED_DATA_PATH:-$WT_ROOT/build/debug}"
[[ "$WT_DERIVED_BASE" = /* ]] || WT_DERIVED_BASE="$WT_ROOT/$WT_DERIVED_BASE"
WT_DERIVED_DATA="$WT_DERIVED_BASE/$WT_HASH"
WT_STATE_DIR="$WT_ROOT/build/home"
