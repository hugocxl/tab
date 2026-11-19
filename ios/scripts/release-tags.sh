#!/bin/bash
# Releases come from CHANGELOG.md: a commit that adds a `## X.Y.Z - date`
# section on top releases that version.
#
#   scripts/release-tags.sh tag [REV]      tags each commit since the newest
#       vX.Y.Z tag up to REV (HEAD) that adds a version as vX.Y.Z (local,
#       annotated) and prints the new tags oldest first; a version that already
#       has a tag is left as it is, and a run that never finished is caught up
#   scripts/release-tags.sh notes VERSION      that version's changelog section
set -euo pipefail
cd "$(dirname "$0")/.."
NAME='Tab iOS'

version_at() {
    { git show "$1:CHANGELOG.md" 2> /dev/null || true; } | sed -n 's/^## \([0-9][0-9.]*\) - .*/\1/p' | head -1
}

tag_new() {
    local after="$1" last range commit parent current
    last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' "$after" 2> /dev/null || true)"
    range="$after"
    if [ -n "$last" ]; then range="$last..$after"; fi
    for commit in $(git rev-list --reverse --first-parent "$range"); do
        current="$(version_at "$commit")"
        [ -n "$current" ] || continue
        parent="$(git rev-parse --verify --quiet "$commit^" || true)"
        if [ -n "$parent" ] && [ "$(version_at "$parent")" = "$current" ]; then continue; fi
        git rev-parse --verify --quiet "refs/tags/v$current" > /dev/null && continue
        git tag -a "v$current" -m "$NAME $current" "$commit"
        echo "v$current"
    done
}

notes() {
    awk -v version="$1" '
        /^## / { if (found) exit; split($2, v, " "); found = (v[1] == version); next }
        found { print }
    ' CHANGELOG.md | sed '/./,$!d'
}

case "${1:-}" in
    tag) tag_new "${2:-HEAD}" ;;
    notes) [ "$#" = 2 ] || { echo "Usage: $0 notes VERSION" >&2; exit 1; }; notes "$2" ;;
    *) echo "Usage: $0 tag [REV] | notes VERSION" >&2; exit 1 ;;
esac
