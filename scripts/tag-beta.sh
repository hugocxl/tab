#!/bin/bash
# Tags the pushed main as a beta of CHANGELOG.md's newest version and pushes
# the tag, starting the Release workflow. Usage: scripts/tag-beta.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ "$#" = 0 ] || { echo "Usage: $0" >&2; exit 1; }
REPO="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
NAME="$(basename "$ROOT")"
git fetch --quiet --tags origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Error: release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Error: commit or discard changes first" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Error: push main first, or pull it" >&2; exit 1; }
VERSION="$(scripts/changelog.sh version)"
[ -n "$VERSION" ] || { echo "Error: CHANGELOG.md lists no version" >&2; exit 1; }
TAG="v$VERSION-beta.$(git rev-list --count HEAD)"
if git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null; then
    echo "Error: $TAG already exists" >&2
    exit 1
fi
git tag -a "$TAG" -m "$NAME ${TAG#v}"
git push origin "$TAG"
echo "Pushed $TAG: https://github.com/$REPO/actions/workflows/release.yml"
