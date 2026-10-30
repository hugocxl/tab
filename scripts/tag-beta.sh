#!/bin/bash
# Tags the pushed main as a beta of CHANGELOG.md's newest version and pushes
# the tag, which starts the Release workflow. Stable releases need no tag:
# every push to main publishes one. Usage: scripts/tag-beta.sh
# The tag is vX.Y.Z-beta.N, where N is the commit count, which orders betas.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "$#" = 0 ] || { echo "Usage: $0" >&2; exit 1; }
git fetch --quiet --tags origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Error: release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Error: commit or stash your changes first" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Error: push main first, or pull it" >&2; exit 1; }
VERSION="$(scripts/changelog.sh version)"
[ -n "$VERSION" ] || { echo "Error: CHANGELOG.md lists no version" >&2; exit 1; }
TAG="v$VERSION-beta.$(git rev-list --count HEAD)"
if git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null; then
    echo "Error: $TAG already exists" >&2
    exit 1
fi
git tag -a "$TAG" -m "Tab ${TAG#v}"
git push origin "$TAG"
echo "Pushed $TAG: https://github.com/hugocxl/tab/actions/workflows/release.yml"
