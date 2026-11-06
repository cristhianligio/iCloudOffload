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

# Icono (formato Liquid Glass de Icon Composer). actool genera Assets.car para macOS 26
# y AppIcon.icns de respaldo para macOS 14 y 15.
# actool necesita rutas absolutas (las relativas las resuelve contra otro directorio).
xcrun actool "$PWD/Icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/build/icon-partial.plist" \
  --errors --warnings --output-format human-readable-text > /dev/null

# Firma ad-hoc (necesaria para que macOS muestre el permiso de Fotos).
codesign --force --sign - "$APP"

echo "Listo: $APP"
