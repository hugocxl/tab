#!/bin/bash
# Sets the GitHub Actions secrets the Release workflow signs, notarizes and
# signs the update feed with. Run once, and again when a credential changes.
#
# Usage: scripts/setup-release-secrets.sh <DeveloperID.p12> <AuthKey_KEYID.p8> <issuer-id> <team-id>
#
# <DeveloperID.p12>  the "Developer ID Application" certificate and its private
#                    key, exported from Keychain Access; asks for its password.
# <AuthKey_KEYID.p8> an App Store Connect API key with the Developer role; the
#                    key ID is read from the file name.
# The feed signing key is read from the login keychain item
# "Tab update signing key"; back that item up, apps only trust its public half.
set -euo pipefail
if [ "$#" != 4 ]; then
    sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 1
fi
CERTIFICATE="$1"
API_KEY="$2"
ISSUER="$3"
TEAM="$4"
REPO="hugocxl/tab"

[ -f "$CERTIFICATE" ] || { echo "Error: no certificate at $CERTIFICATE" >&2; exit 1; }
[ -f "$API_KEY" ] || { echo "Error: no API key at $API_KEY" >&2; exit 1; }
KEY_ID="$(basename "$API_KEY" .p8)"
KEY_ID="${KEY_ID#AuthKey_}"
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo "Error: name the key AuthKey_<KEYID>.p8 as App Store Connect does" >&2; exit 1; }
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "Error: the team ID has 10 letters and digits" >&2; exit 1; }
[[ "$ISSUER" =~ ^[0-9a-f-]{36}$ ]] || { echo "Error: the issuer ID is a UUID" >&2; exit 1; }

read -r -s -p "Password of $(basename "$CERTIFICATE"): " PASSWORD
echo
# The certificate must open with this password and hold a Developer ID
# Application identity of this team.
SUBJECT="$(openssl pkcs12 -in "$CERTIFICATE" -passin fd:3 -nokeys -legacy 3<<<"$PASSWORD" 2>/dev/null \
    || openssl pkcs12 -in "$CERTIFICATE" -passin fd:3 -nokeys 3<<<"$PASSWORD")"
grep -q "Developer ID Application: .*($TEAM)" <<<"$SUBJECT" \
    || { echo "Error: $(basename "$CERTIFICATE") holds no Developer ID Application certificate of team $TEAM" >&2; exit 1; }

SIGNING_KEY="$(security find-generic-password -a tab-release -s "Tab update signing key" -w)" \
    || { echo "Error: the login keychain has no \"Tab update signing key\"" >&2; exit 1; }

set_secret() { gh secret set "$1" --repo "$REPO"; }
base64 -i "$CERTIFICATE" | set_secret DEVELOPER_ID_APPLICATION_CERTIFICATE
printf '%s' "$PASSWORD" | set_secret DEVELOPER_ID_APPLICATION_PASSWORD
base64 -i "$API_KEY" | set_secret APPLE_API_KEY_P8
printf '%s' "$KEY_ID" | set_secret APPLE_API_KEY_ID
printf '%s' "$ISSUER" | set_secret APPLE_API_ISSUER_ID
printf '%s' "$TEAM" | set_secret APPLE_TEAM_ID
printf '%s' "$SIGNING_KEY" | set_secret UPDATE_SIGNING_KEY
gh secret list --repo "$REPO"
