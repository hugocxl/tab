#!/bin/sh
# Runs the tests that talk to a real tabd. Starts an isolated server (its own
# TAB_DIR, port 7431) from a Tab checkout, shows a pairing code, and passes the
# link to the tests on an iOS simulator.
#
#   scripts/test-live.sh [path to a built tab checkout, default ../tab]
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAB_CHECKOUT=$(cd "${1:-$ROOT/../tab}" && pwd)
TAB="$TAB_CHECKOUT/.build/debug/tab"
[ -x "$TAB" ] || { echo "build tab first: (cd $TAB_CHECKOUT && swift build)" >&2; exit 1; }

export TAB_DIR="$ROOT/.build/tabd"
unset TAB_AGENT_ID TAB_SERVER_ID
mkdir -p "$TAB_DIR"
# Enabling a server that already listens makes it rebind its busy port.
"$TAB" mobile status | grep -q "listening on port 7431" || "$TAB" mobile enable --port 7431 > /dev/null

PAIR_LOG="$TAB_DIR/pair.log"
"$TAB" mobile pair --address 127.0.0.1 > "$PAIR_LOG" 2>&1 &
PAIR=$!
trap 'kill $PAIR 2>/dev/null || true' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do
    LINK=$(grep -o 'tab://pair?[^ ]*' "$PAIR_LOG" | head -1 || true)
    [ -n "$LINK" ] && break
    sleep 0.5
done
[ -n "${LINK:-}" ] || { cat "$PAIR_LOG" >&2; exit 1; }

. "$ROOT/scripts/simulator.sh"
TEST_RUNNER_TAB_PAIR_LINK="$LINK" xcodebuild test -scheme TabKit -destination "id=$(iphone_simulator)" \
    -derivedDataPath "$ROOT/.build/xc" -only-testing:TabMobileKitTests/LiveServerTests -quiet
