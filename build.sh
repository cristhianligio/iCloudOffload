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

# Idiomas: inglés y español. El catálogo de textos se compila a en.lproj/es.lproj (Localizable.strings);
# es.lproj/InfoPlist.strings traduce los textos del Info.plist (base en inglés).
xcrun xcstringstool compile "$PWD/Resources/Localizable.xcstrings" --output-directory "$PWD/$APP/Contents/Resources" > /dev/null
mkdir -p "$APP/Contents/Resources/es.lproj"
cp Resources/es.lproj/InfoPlist.strings "$APP/Contents/Resources/es.lproj/InfoPlist.strings"

# Icono (formato Liquid Glass de Icon Composer). actool genera Assets.car para macOS 26
# y AppIcon.icns de respaldo para macOS 14 y 15.
# actool necesita rutas absolutas (las relativas las resuelve contra otro directorio).
xcrun actool "$PWD/Icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$PWD/build/icon-partial.plist" \
  --errors --warnings --output-format human-readable-text > /dev/null

# Firma ad-hoc (necesaria para que macOS muestre el permiso de Fotos) con Hardened Runtime:
# impide que otro programa inyecte código en la app (DYLD_INSERT_LIBRARIES, bibliotecas sin firmar)
# y herede su acceso a Fotos. Sin excepciones de runtime: solo el permiso de Fotos.
codesign --force --sign - --options runtime \
  --entitlements Resources/iCloudOffload.entitlements "$APP"

echo "Listo: $APP"
