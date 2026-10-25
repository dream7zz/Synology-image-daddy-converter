#!/bin/bash
# Builds a real .app bundle for the menu bar app.
# A bare SwiftPM executable cannot register as a login item and looks like a
# stray process; a bundle fixes both.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
APP="$DIST/Synology Image Daddy Converter.app"
VERSION="0.3.0"

echo "==> building release"
swift build -c release --product SIAApp

BIN="$(swift build -c release --product SIAApp --show-bin-path)/SIAApp"
[ -x "$BIN" ] || { echo "build produced no binary"; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ImageDaddy"
chmod +x "$APP/Contents/MacOS/ImageDaddy"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Image Daddy</string>
    <key>CFBundleDisplayName</key><string>Synology Image Daddy Converter</string>
    <key>CFBundleIdentifier</key><string>local.sia.imagedaddy</string>
    <key>CFBundleExecutable</key><string>ImageDaddy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><false/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc signing"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(ad-hoc signing skipped)"

echo "==> done: $APP"
