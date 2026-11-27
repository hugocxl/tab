#!/bin/sh
# The version build settings every iOS build passes to xcodebuild: the
# repository's CHANGELOG.md version (shared with the Mac app) and the commit
# count as the build number. Usage: xcodebuild ... $(scripts/version.sh)
set -eu
REPO=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=${RELEASE_VERSION:-$("$REPO/scripts/changelog.sh" version)}
echo "MARKETING_VERSION=${VERSION%%-*} CURRENT_PROJECT_VERSION=$(git -C "$REPO" rev-list --count HEAD)"
