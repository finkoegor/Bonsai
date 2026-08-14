#!/bin/bash
# Builds Bonsai.app into ./Build
#
#   ./build.sh            build; refreshes /Applications/Bonsai.app if installed
#   ./build.sh install    build and install into /Applications
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=0
if [ "${1:-}" = "install" ]; then INSTALL=1; fi

VER="$(cat VERSION 2>/dev/null || echo 1.0.0)"
APP="Build/Bonsai.app"
DEST="/Applications/Bonsai.app"

echo "▸ swift build (release, v$VER)"
swift build -c release 2>&1 | tail -3

BIN=".build/release/Bonsai"
BUNDLE=".build/release/Bonsai_Bonsai.bundle"
SPARKLE_FW=$(find .build/artifacts -type d -name "Sparkle.framework" -path "*macos*" | head -1)
[ -n "$SPARKLE_FW" ] || { echo "Sparkle.framework not found in .build/artifacts"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/Bonsai"
cp -R "$BUNDLE" "$APP/Contents/Resources/"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
cp Build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# The swift-build binary references @rpath/Sparkle...; point rpath inside the bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Bonsai" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Bonsai</string>
    <key>CFBundleIdentifier</key><string>com.egorfinko.bonsai</string>
    <key>CFBundleName</key><string>Bonsai</string>
    <key>CFBundleDisplayName</key><string>Bonsai</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VER</string>
    <key>CFBundleVersion</key><string>$VER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/finkoegor/Bonsai/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>9fEPCD4rqrxfoMKIgtdtAep6WO8l0vghyZo0MlOu3n8=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF Document</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null
echo "▸ built: $APP (v$VER)"

# Install into /Applications on demand, and auto-refresh an existing install
# on every subsequent build.
if [ "$INSTALL" = 1 ] || [ -d "$DEST" ]; then
    WAS_RUNNING=0
    if pgrep -xq Bonsai; then
        WAS_RUNNING=1
        osascript -e 'tell application "Bonsai" to quit' >/dev/null 2>&1 || pkill -x Bonsai || true
        sleep 1
    fi
    rsync -a --delete "$APP/" "$DEST/"
    echo "▸ installed: $DEST"
    if [ "$WAS_RUNNING" = 1 ]; then
        open "$DEST"
        echo "▸ relaunched"
    fi
fi
