#!/bin/bash
# Sets the GitHub Actions secrets for signing, notarization, and optional update
# feed signing. Run once per repo, and again when a credential rotates.
#
# Usage: scripts/setup-release-secrets.sh <DeveloperID.p12> --api-key <AuthKey_KEYID.p8> <issuer-id> [--update-key <service> <account>]
#        scripts/setup-release-secrets.sh <DeveloperID.p12> --apple-id <email> [--update-key <service> <account>]
set -euo pipefail
usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
REPO="$(git remote get-url origin | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
[ "$#" -ge 3 ] || usage
CERTIFICATE="$1"
MODE="$2"
[ -f "$CERTIFICATE" ] || { echo "Error: no certificate at $CERTIFICATE" >&2; exit 1; }
shift 2

API_KEY="" ISSUER="" KEY_ID="" APPLE_ID="" UPDATE_SERVICE="" UPDATE_ACCOUNT=""
case "$MODE" in
    --api-key)
        [ "$#" -ge 2 ] || usage
        API_KEY="$1"; ISSUER="$2"; shift 2
        [ -f "$API_KEY" ] || { echo "Error: no API key at $API_KEY" >&2; exit 1; }
        KEY_ID="$(basename "$API_KEY" .p8)"; KEY_ID="${KEY_ID#AuthKey_}"
        [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "Error: name the key AuthKey_<KEYID>.p8" >&2; exit 1; }
        [[ "$ISSUER" =~ ^[0-9a-f-]{36}$ ]] || { echo "Error: the issuer ID must be a UUID" >&2; exit 1; }
        ;;
    --apple-id)
        [ "$#" -ge 1 ] || usage
        APPLE_ID="$1"; shift 1
        [[ "$APPLE_ID" == *@* ]] || { echo "Error: the Apple ID must be an email address" >&2; exit 1; }
        ;;
    *) usage ;;
esac

if [ "${1:-}" = "--update-key" ]; then
    [ "$#" = 3 ] || usage
    UPDATE_SERVICE="$2"; UPDATE_ACCOUNT="$3"
elif [ "$#" -gt 0 ]; then
    usage
fi

if [ -z "${P12_PASSWORD:-}" ]; then
    read -r -s -p "Password of $(basename "$CERTIFICATE"): " P12_PASSWORD
    echo
fi
export P12_PASSWORD

SUBJECT="$(openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nokeys -legacy 2>/dev/null \
    || openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nokeys 2>/dev/null)" \
    || { echo "Error: $(basename "$CERTIFICATE") doesn't open with that password" >&2; exit 1; }
TEAM="$(sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$SUBJECT" | head -1)"
[ -n "$TEAM" ] || { echo "Error: $(basename "$CERTIFICATE") holds no Developer ID Application certificate" >&2; exit 1; }
openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nocerts -nodes -legacy 2>/dev/null | grep -q "PRIVATE KEY" \
    || openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nocerts -nodes 2>/dev/null | grep -q "PRIVATE KEY" \
    || { echo "Error: $(basename "$CERTIFICATE") has no private key" >&2; exit 1; }
echo "Developer ID team: $TEAM ($REPO)"

if [ "$MODE" = --apple-id ] && [ -z "${APP_SPECIFIC_PASSWORD:-}" ]; then
    read -r -s -p "App-specific password of $APPLE_ID: " APP_SPECIFIC_PASSWORD
    echo
fi

set_secret() { gh secret set "$1" --repo "$REPO" > /dev/null; echo "set $1"; }
base64 -i "$CERTIFICATE" | set_secret DEVELOPER_ID_APPLICATION_CERTIFICATE
printf '%s' "$P12_PASSWORD" | set_secret DEVELOPER_ID_APPLICATION_PASSWORD
printf '%s' "$TEAM" | set_secret APPLE_TEAM_ID

if [ -n "$UPDATE_SERVICE" ]; then
    SIGNING_KEY="$(security find-generic-password -a "$UPDATE_ACCOUNT" -s "$UPDATE_SERVICE" -w)" \
        || { echo "Error: login keychain has no \"$UPDATE_SERVICE\"" >&2; exit 1; }
    printf '%s' "$SIGNING_KEY" | set_secret UPDATE_SIGNING_KEY
fi

if [ "$MODE" = --api-key ]; then
    base64 -i "$API_KEY" | set_secret APPLE_API_KEY_P8
    printf '%s' "$KEY_ID" | set_secret APPLE_API_KEY_ID
    printf '%s' "$ISSUER" | set_secret APPLE_API_ISSUER_ID
else
    printf '%s' "$APPLE_ID" | set_secret APPLE_ID
    printf '%s' "$APP_SPECIFIC_PASSWORD" | set_secret APPLE_APP_SPECIFIC_PASSWORD
    for NAME in APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
        gh secret delete "$NAME" --repo "$REPO" 2>/dev/null || true
    done
fi
