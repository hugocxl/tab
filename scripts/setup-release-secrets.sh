#!/bin/bash
# Sets the GitHub Actions secrets the Release workflow signs, notarizes and
# signs the update feed with. Run once, and again when a credential changes.
#
# Usage: scripts/setup-release-secrets.sh <DeveloperID.p12> --api-key <AuthKey_KEYID.p8> <issuer-id>
#        scripts/setup-release-secrets.sh <DeveloperID.p12> --apple-id <email>
#
# <DeveloperID.p12>  the "Developer ID Application" certificate and its private
#                    key, exported from Keychain Access; its team is the release team.
# --api-key          notarize with an App Store Connect API key (Developer role);
#                    the key ID is read from the file name.
# --apple-id         notarize with an Apple ID and an app-specific password.
# Passwords are asked for, or read from P12_PASSWORD and APP_SPECIFIC_PASSWORD.
# The feed signing key is read from the login keychain item
# "Tab update signing key"; back that item up, apps only trust its public half.
set -euo pipefail
usage() { sed -n '5,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
REPO="hugocxl/tab"
[ "$#" -ge 3 ] || usage
CERTIFICATE="$1"
MODE="$2"
[ -f "$CERTIFICATE" ] || { echo "Error: no certificate at $CERTIFICATE" >&2; exit 1; }
case "$MODE" in
    --api-key)
        [ "$#" = 4 ] || usage
        API_KEY="$3"
        ISSUER="$4"
        [ -f "$API_KEY" ] || { echo "Error: no API key at $API_KEY" >&2; exit 1; }
        KEY_ID="$(basename "$API_KEY" .p8)"
        KEY_ID="${KEY_ID#AuthKey_}"
        [[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "Error: name the key AuthKey_<KEYID>.p8 as App Store Connect does" >&2; exit 1; }
        [[ "$ISSUER" =~ ^[0-9a-f-]{36}$ ]] || { echo "Error: the issuer ID is a UUID" >&2; exit 1; }
        ;;
    --apple-id)
        [ "$#" = 3 ] || usage
        APPLE_ID="$3"
        [[ "$APPLE_ID" == *@* ]] || { echo "Error: the Apple ID is an email address" >&2; exit 1; }
        ;;
    *) usage ;;
esac

if [ -z "${P12_PASSWORD:-}" ]; then
    read -r -s -p "Password of $(basename "$CERTIFICATE"): " P12_PASSWORD
    echo
fi
export P12_PASSWORD
# The certificate must open with this password and hold a Developer ID
# Application identity, whose team signs and notarizes releases.
SUBJECT="$(openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nokeys -legacy 2>/dev/null \
    || openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nokeys 2>/dev/null)" \
    || { echo "Error: $(basename "$CERTIFICATE") doesn't open with that password" >&2; exit 1; }
TEAM="$(sed -n 's/.*Developer ID Application: .*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$SUBJECT" | head -1)"
[ -n "$TEAM" ] || { echo "Error: $(basename "$CERTIFICATE") holds no Developer ID Application certificate" >&2; exit 1; }
openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nocerts -nodes -legacy 2>/dev/null | grep -q "PRIVATE KEY" \
    || openssl pkcs12 -in "$CERTIFICATE" -passin env:P12_PASSWORD -nocerts -nodes 2>/dev/null | grep -q "PRIVATE KEY" \
    || { echo "Error: $(basename "$CERTIFICATE") has no private key; export the identity, not only the certificate" >&2; exit 1; }
echo "Developer ID team: $TEAM"

if [ "$MODE" = --apple-id ] && [ -z "${APP_SPECIFIC_PASSWORD:-}" ]; then
    read -r -s -p "App-specific password of $APPLE_ID: " APP_SPECIFIC_PASSWORD
    echo
fi

SIGNING_KEY="$(security find-generic-password -a tab-release -s "Tab update signing key" -w)" \
    || { echo "Error: the login keychain has no \"Tab update signing key\"" >&2; exit 1; }

set_secret() { gh secret set "$1" --repo "$REPO" > /dev/null; echo "set $1"; }
base64 -i "$CERTIFICATE" | set_secret DEVELOPER_ID_APPLICATION_CERTIFICATE
printf '%s' "$P12_PASSWORD" | set_secret DEVELOPER_ID_APPLICATION_PASSWORD
printf '%s' "$TEAM" | set_secret APPLE_TEAM_ID
printf '%s' "$SIGNING_KEY" | set_secret UPDATE_SIGNING_KEY
if [ "$MODE" = --api-key ]; then
    base64 -i "$API_KEY" | set_secret APPLE_API_KEY_P8
    printf '%s' "$KEY_ID" | set_secret APPLE_API_KEY_ID
    printf '%s' "$ISSUER" | set_secret APPLE_API_ISSUER_ID
else
    printf '%s' "$APPLE_ID" | set_secret APPLE_ID
    printf '%s' "$APP_SPECIFIC_PASSWORD" | set_secret APPLE_APP_SPECIFIC_PASSWORD
    # The workflow prefers an API key; remove a stale one so the Apple ID is used.
    for NAME in APPLE_API_KEY_P8 APPLE_API_KEY_ID APPLE_API_ISSUER_ID; do
        gh secret delete "$NAME" --repo "$REPO" 2>/dev/null || true
    done
fi
