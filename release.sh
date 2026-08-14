#!/bin/bash
# Publishes a Bonsai release: build, zip, EdDSA-sign, appcast entry, git tag,
# GitHub release. Sparkle in installed apps picks the update from appcast.xml.
#
#   ./release.sh 1.0.1 "What changed in this version"
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:?usage: release.sh <version> [notes]}"
NOTES="${2:-Improvements and fixes.}"
REPO="finkoegor/Bonsai"
KEY="$HOME/.config/bonsai/sparkle_private_key"
TOOLS="$HOME/.config/bonsai/sparkle-tools"

[ -f "$KEY" ] || { echo "no Sparkle signing key at $KEY"; exit 1; }

# Bootstrap Sparkle CLI tools once.
if [ ! -x "$TOOLS/bin/sign_update" ]; then
    echo "▸ downloading Sparkle tools"
    mkdir -p "$TOOLS"
    curl -sL -o /tmp/sparkle-tools.tar.xz \
        "https://github.com/sparkle-project/Sparkle/releases/download/2.9.5/Sparkle-2.9.5.tar.xz"
    tar xf /tmp/sparkle-tools.tar.xz -C "$TOOLS" bin
fi

echo "$VER" > VERSION
./build.sh

ZIP="Build/Bonsai-$VER.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Build/Bonsai.app "$ZIP"
echo "▸ zipped: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"

SIG_ATTRS=$("$TOOLS/bin/sign_update" -f "$KEY" "$ZIP")   # sparkle:edSignature="..." length="..."
echo "▸ signed: $SIG_ATTRS"

URL="https://github.com/$REPO/releases/download/v$VER/Bonsai-$VER.zip"
DATE=$(date -R)
python3 - "$VER" "$URL" "$DATE" "$SIG_ATTRS" "$NOTES" <<'EOF'
import sys, os, html
ver, url, date, sig, notes = sys.argv[1:6]
item = f"""    <item>
      <title>{ver}</title>
      <pubDate>{date}</pubDate>
      <sparkle:version>{ver}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{html.escape(notes)}]]></description>
      <enclosure url="{url}" {sig} type="application/octet-stream"/>
    </item>
"""
path = "appcast.xml"
if os.path.exists(path):
    text = open(path).read()
    marker = "<language>en</language>\n"
    text = text.replace(marker, marker + item, 1)
else:
    text = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Bonsai</title>
    <language>en</language>
{item}  </channel>
</rss>
"""
open(path, "w").write(text)
print("▸ appcast updated")
EOF

git add VERSION appcast.xml
git commit -qm "Release $VER"
git tag "v$VER"
git push origin main --tags
echo "▸ pushed main + tag v$VER"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
    gh release create "v$VER" "$ZIP" --repo "$REPO" --title "Bonsai $VER" --notes "$NOTES"
    echo "▸ GitHub release published"
else
    echo ""
    echo "gh CLI is not authorized. Finish the release manually:"
    echo "  1. open https://github.com/$REPO/releases/new?tag=v$VER"
    echo "  2. drag $ZIP into the assets area and publish"
    echo "(or run 'gh auth login' once, then re-run: gh release create v$VER $ZIP --title \"Bonsai $VER\" --notes \"$NOTES\")"
fi
