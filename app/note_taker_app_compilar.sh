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
[ -f "$DIR/logo.png" ] && cp "$DIR/logo.png" "$APP/Contents/Resources/logo.png"  # logo opcional del tema
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
# Alias de Finder en el Escritorio a las notas transcritas (se omite con NOTE_TAKER_SIN_ALIAS=1; si algo falla, la instalación sigue).
(
  [ "${NOTE_TAKER_SIN_ALIAS:-0}" = "1" ] && { echo "Alias del Escritorio omitido (NOTE_TAKER_SIN_ALIAS=1)."; exit 0; }
  NOTAS="$HOME/Movies/Note-Taker/Note-Taker-Transcriptions"
  ALIAS="$HOME/Desktop/Notas transcritas Note Taker"
  mkdir -p "$NOTAS"
  if [ -e "$ALIAS" ]; then echo "El alias del Escritorio ya existe: $ALIAS"; exit 0; fi
  TMPA="$(mktemp -d)"; trap 'rm -rf "$TMPA"' EXIT
  cat > "$TMPA/alias.swift" <<'SWIFT'
import Foundation
let a = CommandLine.arguments
guard a.count == 3 else { exit(2) }
do {
    let datos = try URL(fileURLWithPath: a[1], isDirectory: true).bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(datos, to: URL(fileURLWithPath: a[2]))
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
SWIFT
  swiftc -O "$TMPA/alias.swift" -o "$TMPA/alias" && "$TMPA/alias" "$NOTAS" "$ALIAS" && echo "Alias creado en el Escritorio: $ALIAS"
) || echo "Aviso: no se pudo crear el alias en el Escritorio (se puede crear a mano: Finder › Archivo › Crear alias sobre ~/Movies/Note-Taker/Note-Taker-Transcriptions)."
echo "Listo: $APP"
