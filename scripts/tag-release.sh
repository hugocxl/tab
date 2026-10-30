#!/bin/bash
# Tags the pushed main for release and pushes the tag, which starts the
# Release workflow. Usage: scripts/tag-release.sh X.Y.Z [--beta]
# A stable release is tagged vX.Y.Z; a beta vX.Y.Z-beta.N, where N is the
# commit count, which orders betas.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { [ "$#" = 2 ] && [ "$2" != --beta ]; } || [ "$#" -gt 2 ]; then
    echo "Usage: $0 X.Y.Z [--beta]" >&2
    exit 1
fi
git fetch --quiet --tags origin main
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Error: release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Error: commit or stash your changes first" >&2; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Error: push main first, or pull it" >&2; exit 1; }
# The changelog's newest version is the release, so the app lists it.
LISTED="$(sed -n 's/^## \([^ ]*\).*/\1/p' CHANGELOG.md | head -1)"
[ "$LISTED" = "$VERSION" ] || { echo "Error: CHANGELOG.md's newest version is ${LISTED:-missing}; add a $VERSION section first" >&2; exit 1; }

if [ "${2:-}" = --beta ]; then
    TAG="v$VERSION-beta.$(git rev-list --count HEAD)"
else
    TAG="v$VERSION"
    NEWEST="$(git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^v//' \
        | sort -t. -k1,1n -k2,2n -k3,3n | tail -1 || true)"
    if [ -n "$NEWEST" ] && [ "$(printf '%s\n%s\n' "$NEWEST" "$VERSION" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$VERSION" ]; then
        echo "Warning: $NEWEST is newer; $TAG will publish without becoming the latest release" >&2
    fi
fi
if git rev-parse --quiet --verify "refs/tags/$TAG" > /dev/null; then
    echo "Error: $TAG already exists" >&2
    exit 1
fi
git tag -a "$TAG" -m "Tab ${TAG#v}"
git push origin "$TAG"
echo "Pushed $TAG: https://github.com/hugocxl/tab/actions/workflows/release.yml"
