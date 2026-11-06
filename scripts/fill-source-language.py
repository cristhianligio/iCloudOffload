#!/usr/bin/env python3
"""Copia el texto original (español) como localización «es» explícita en Localizable.xcstrings.

Sin ella, xcstringstool no genera es.lproj/Localizable.strings y macOS, al no encontrar esa tabla,
muestra la del idioma de desarrollo (inglés) aunque el usuario tenga el sistema en español.
Copies the Spanish source text into an explicit "es" localization so es.lproj gets compiled.
"""
import json, sys
path = sys.argv[1] if len(sys.argv) > 1 else "Resources/Localizable.xcstrings"
d = json.load(open(path))
for key, entry in d["strings"].items():
    if entry.get("shouldTranslate") is False:
        continue
    locs = entry.setdefault("localizations", {})
    if "es" not in locs:
        locs["es"] = {"stringUnit": {"state": "translated", "value": key}}
with open(path, "w") as f:
    json.dump(d, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")
