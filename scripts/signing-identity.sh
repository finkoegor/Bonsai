#!/bin/bash
# Prints the code signing identity of the project's Apple developer team: SIGN_IDENTITY if set,
# otherwise the Developer ID Application or Apple Development certificate issued to TEAM_ID.
# Certificates of other teams are never used.
set -euo pipefail

TEAM_ID="${TEAM_ID:-Y2N47YUAJH}"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "$SIGN_IDENTITY"
    exit 0
fi

team_of() {
    security find-certificate -c "$1" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | awk -F' = ' '/organizationalUnitName/ { print $2; exit }'
}

NAMES="$(security find-identity -v -p codesigning | awk -F'"' 'NF > 1 { print $2 }')"
for KIND in "Developer ID Application" "Apple Development"; do
    while IFS= read -r NAME; do
        if [[ "$NAME" == "$KIND:"* ]] && [ "$(team_of "$NAME")" = "$TEAM_ID" ]; then
            echo "$NAME"
            exit 0
        fi
    done <<< "$NAMES"
done

echo "No signing certificate for team $TEAM_ID in the keychain." >&2
exit 1
