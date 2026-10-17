#!/bin/bash
# Sends an app bundle to Apple's notary service and staples the ticket to it,
# so Gatekeeper opens it without a warning, even offline.
#
# Needs a notarytool keychain profile for team Y2N47YUAJH, created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <Apple ID> --team-id Y2N47YUAJH
# The profile name is read from NOTARY_PROFILE (default: Bonsai).
#
# Usage: scripts/notarize.sh <app>
set -euo pipefail

TARGET="${1:?Usage: scripts/notarize.sh <app>}"
PROFILE="${NOTARY_PROFILE:-Bonsai}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The notary service takes archives, not bare bundles.
UPLOAD="$WORK/$(basename "$TARGET" .app).zip"
ditto -c -k --keepParent "$TARGET" "$UPLOAD"

RESULT="$(xcrun notarytool submit "$UPLOAD" --keychain-profile "$PROFILE" --wait)"
echo "$RESULT"
if ! grep -q "status: Accepted" <<< "$RESULT"; then
    SUBMISSION="$(awk '/^ *id:/ { print $2; exit }' <<< "$RESULT")"
    echo "Notarization failed. Details: xcrun notarytool log $SUBMISSION --keychain-profile $PROFILE" >&2
    exit 1
fi

xcrun stapler staple "$TARGET"
