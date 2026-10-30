#!/bin/bash
# Versions come from CHANGELOG.md: every commit adds a `## X.Y.Z - date`
# section on top, and that is the commit's version.
#
#   scripts/changelog.sh version [REV]       the newest version at REV (HEAD)
#   scripts/changelog.sh tag BEFORE AFTER    checks that each commit pushed in
#       BEFORE..AFTER adds a new version, then tags every untagged version
#       since the last tagged one at the last commit that has it (local tags)
#   scripts/changelog.sh notes [SINCE]       the sections newer than version SINCE
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

version_at() {
    { git show "$1:CHANGELOG.md" 2> /dev/null || true; } | sed -n 's/^## \([0-9][0-9.]*\) - .*/\1/p' | head -1
}

newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" = "$1" ]
}

check_pushed() {
    local before="$1" after="$2" range commit parent current previous
    if [[ "$before" =~ ^0+$ ]] || ! git merge-base --is-ancestor "$before" "$after" 2> /dev/null; then
        range="$after^!"
    else
        range="$before..$after"
    fi
    for commit in $(git rev-list --reverse --no-merges "$range"); do
        current="$(version_at "$commit")"
        [ -n "$current" ] || { echo "Error: $commit has no version in CHANGELOG.md" >&2; exit 1; }
        parent="$(git rev-parse --verify --quiet "$commit^" || true)"
        [ -n "$parent" ] || continue
        previous="$(version_at "$parent")"
        if ! newer "$current" "$previous"; then
            echo "Error: $(git log -1 --format='%h "%s"' "$commit") must add a CHANGELOG.md version newer than $previous" >&2
            exit 1
        fi
    done
}

tag_versions() {
    local after="$1" last commits commit current next tag existing index
    last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' "$after" 2> /dev/null || true)"
    if [ -n "$last" ]; then
        commits=($(git rev-list --reverse --first-parent "$last..$after"))
    else
        commits=($(git rev-list --reverse --first-parent "$after"))
    fi
    for index in "${!commits[@]}"; do
        commit="${commits[$index]}"
        current="$(version_at "$commit")"
        [ -n "$current" ] || continue
        next=""
        if [ $((index + 1)) -lt "${#commits[@]}" ]; then next="$(version_at "${commits[$((index + 1))]}")"; fi
        [ "$next" = "$current" ] && continue
        tag="v$current"
        existing="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}" || true)"
        if [ -n "$existing" ]; then
            [ "$existing" = "$commit" ] || { echo "Error: $tag already tags $existing, not $commit" >&2; exit 1; }
            continue
        fi
        git tag -a "$tag" -m "Tab $current" "$commit"
        echo "Tagged $tag at $(git log -1 --format='%h %s' "$commit")"
    done
}

notes() {
    local since="${1:-}"
    awk -v since="$since" '
        /^## / { started = 1; split($2, v, " "); if (since != "" && v[1] == since) exit }
        started { print }
    ' CHANGELOG.md
}

case "${1:-}" in
    version) version_at "${2:-HEAD}" ;;
    tag)
        [ "$#" = 3 ] || { echo "Usage: $0 tag BEFORE AFTER" >&2; exit 1; }
        check_pushed "$2" "$3"
        tag_versions "$3"
        ;;
    notes) notes "${2:-}" ;;
    *) echo "Usage: $0 version [REV] | tag BEFORE AFTER | notes [SINCE]" >&2; exit 1 ;;
esac
