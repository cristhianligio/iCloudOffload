#!/bin/bash
# Actualiza Resources/Localizable.xcstrings con los textos del código (Text("…"), String(localized: "…")…).
# Después, añade las traducciones nuevas al inglés en el catálogo (o ábrelo en Xcode).
# Updates Resources/Localizable.xcstrings with the strings found in the code; then add the new English translations.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swift build --build-path "$TMP/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$TMP/strings"
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$TMP"/strings/*.stringsdata
python3 scripts/fill-source-language.py Resources/Localizable.xcstrings
echo "Catálogo actualizado / catalog updated: Resources/Localizable.xcstrings"
