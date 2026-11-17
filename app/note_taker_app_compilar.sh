#!/bin/bash
# Arma ~/Applications/NoteTaker.app (firma local). Ver README.md
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/NoteTaker.app"
mkdir -p "$HOME/Applications"
pkill -x NoteTaker 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/../transcribir/note_taker_transcribir.py" "$APP/Contents/Resources/"
swiftc -O -parse-as-library "$DIR"/note_taker_app_*.swift -o "$APP/Contents/MacOS/NoteTaker"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.notetaker</string>
<key>CFBundleName</key><string>NoteTaker</string>
<key>CFBundleDisplayName</key><string>Note Taker</string>
<key>CFBundleExecutable</key><string>NoteTaker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSMicrophoneUsageDescription</key><string>Para grabar tu voz junto con el audio de la Mac.</string>
<key>NSScreenCaptureUsageDescription</key><string>Para grabar la pantalla y el audio de la Mac.</string>
<key>CFBundleURLTypes</key><array><dict><key>CFBundleURLName</key><string>local.notetaker</string><key>CFBundleURLSchemes</key><array><string>notetaker</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.notetaker --requirements '=designated => identifier "local.notetaker"' "$APP"
echo "Listo: $APP"
