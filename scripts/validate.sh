#!/bin/bash
# The validation every change must pass before it is finished.
# Usage: scripts/validate.sh [shared] [macos] [ios] [website]   (default: all projects)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath .githooks 2>/dev/null || true

PROJECTS=("$@")
[ "${#PROJECTS[@]}" -gt 0 ] || PROJECTS=(shared macos ios website)

# CI keeps build/validation/*.log, so gather the Swift packages' logs there too.
collect_logs() {
    mkdir -p build/validation
    for log in shared/build/validation/*.log macos/build/validation/*.log; do
        [ -f "$log" ] && cp "$log" "build/validation/${log%%/*}-$(basename "$log")"
    done
    return 0
}
trap collect_logs EXIT

scripts/changelog.sh check
for project in "${PROJECTS[@]}"; do
    case "$project" in
        shared | macos | ios) "$project/scripts/validate.sh" ;;
        website)
            (
                cd website
                npm ci --silent
                npm run --silent build:site
                npm run --silent check:site
            )
            echo "website: build and checks passed"
            ;;
        *) echo "Unknown project: $project (expected shared, macos, ios, or website)" >&2; exit 1 ;;
    esac
done
git diff --check
echo "validation passed"
