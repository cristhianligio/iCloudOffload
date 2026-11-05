#!/bin/bash
# Compila y empaqueta "iCloud Offload.app" en ./build
set -euo pipefail
cd "$(dirname "$0")"

# Usa Xcode si está instalado aunque no esté seleccionado con xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release --product iCloudOffload
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/iCloud Offload.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/iCloudOffload" "$APP/Contents/MacOS/iCloudOffload"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Firma ad-hoc (necesaria para que macOS muestre el permiso de Fotos).
codesign --force --sign - "$APP"

echo "Listo: $APP"
