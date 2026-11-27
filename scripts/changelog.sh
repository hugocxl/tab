#!/bin/bash
# Versions come from CHANGELOG.md: every commit adds a `## X.Y.Z - YYYY-MM-DD`
# section on top, and that is the commit's version.
#
#   scripts/changelog.sh check                  validate format and descending order
#   scripts/changelog.sh version [REV]          newest version in working tree or at REV
#   scripts/changelog.sh tag BEFORE AFTER       check pushed commits and create local vX.Y.Z tags
#   scripts/changelog.sh tag-new [REV]          tag every untagged version since newest tag and print tags
#   scripts/changelog.sh notes [SINCE]          sections newer than version SINCE
#   scripts/changelog.sh notes-version VERSION  the single section for VERSION
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="${APP_NAME:-$(basename "$ROOT")}"

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
    for commit in $(git rev-list --reverse --first-parent --no-merges "$range"); do
        current="$(version_at "$commit")"
        [ -n "$current" ] || { echo "Error: $commit has no version in CHANGELOG.md" >&2; exit 1; }
        parent="$(git rev-parse --verify --quiet "$commit^" || true)"
        [ -n "$parent" ] || continue
        previous="$(version_at "$parent")"
        if [ -n "$previous" ] && ! newer "$current" "$previous"; then
            echo "Error: $(git log -1 --format='%h "%s"' "$commit") must add a CHANGELOG.md version newer than $previous" >&2
            exit 1
        fi
    done
}

tag_versions() {
    local after="$1" last commits commit current next tag index
    last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' --exclude '*-*' "$after" 2> /dev/null || true)"
    commits=()
    local range="$after"
    if [ -n "$last" ]; then range="$last..$after"; fi
    while IFS= read -r commit; do commits+=("$commit"); done < <(git rev-list --reverse --first-parent "$range")
    for index in "${!commits[@]}"; do
        commit="${commits[$index]}"
        current="$(version_at "$commit")"
        [ -n "$current" ] || continue
        next=""
        if [ $((index + 1)) -lt "${#commits[@]}" ]; then next="$(version_at "${commits[$((index + 1))]}")"; fi
        [ "$next" = "$current" ] && continue
        tag="v$current"
        git rev-parse --verify --quiet "refs/tags/$tag" > /dev/null && continue
        git tag -a "$tag" -m "$APP_NAME $current" "$commit"
        echo "Tagged $tag at $(git log -1 --format='%h %s' "$commit")"
    done
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
        git tag -a "v$current" -m "$APP_NAME $current" "$commit"
        echo "v$current"
    done
}

notes() {
    local since="${1:-}"
    awk -v since="$since" '
        /^## / { started = 1; split($2, v, " "); if (since != "" && v[1] == since) exit }
        started { print }
    ' CHANGELOG.md
}

notes_version() {
    awk -v version="$1" '
        /^## / { if (found) exit; split($2, v, " "); found = (v[1] == version); next }
        found { print }
    ' CHANGELOG.md | sed '/./,$!d'
}

case "${1:-}" in
    check) python3 scripts/check-changelog.py ;;
    check-pushed) check_pushed "$2" "$3" ;;
    version)
        if [ "$#" = 1 ]; then sed -n 's/^## \([0-9][0-9.]*\) - .*/\1/p' CHANGELOG.md | head -1; else version_at "$2"; fi
        ;;
    tag)
        [ "$#" = 3 ] || { echo "Usage: $0 tag BEFORE AFTER" >&2; exit 1; }
        check_pushed "$2" "$3"
        tag_versions "$3"
        ;;
    tag-new) tag_new "${2:-HEAD}" ;;
    notes) notes "${2:-}" ;;
    notes-version) [ "$#" = 2 ] || { echo "Usage: $0 notes-version VERSION" >&2; exit 1; }; notes_version "$2" ;;
    *) echo "Usage: $0 check | check-pushed BEFORE AFTER | version [REV] | tag BEFORE AFTER | tag-new [REV] | notes [SINCE] | notes-version VERSION" >&2; exit 1 ;;
esac
