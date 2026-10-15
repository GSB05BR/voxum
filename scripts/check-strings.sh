#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Every string the code localizes (String(localized:), SwiftUI Text/Button/… literals) must be a key
# of Sources/Transcricao/Resources/en.lproj/Localizable.strings. The build (the package has a
# defaultLocalization) extracts the exact keys, with their %@ / %lld, into .stringsdata files; this
# lists the keys missing from en.lproj and the en keys no code uses.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --disable-keychain --product Voxum >/dev/null # public dependencies: no Keychain lookup
python3 - "$PWD" <<'PY'
import glob, json, os, plistlib, subprocess, sys
root = sys.argv[1]
used = set()
for f in glob.glob(root + "/.build/**/Debug/**/*.stringsdata", recursive=True):
    data = json.load(open(f))
    src = data.get("source", "")
    if not src.startswith(root + "/Sources/") or not os.path.exists(src):
        continue
    for entries in data["tables"].values():
        used.update(e["key"] for e in entries)
if not used:
    sys.exit("no extracted strings found under .build")
en_path = root + "/Sources/Transcricao/Resources/en.lproj/Localizable.strings"
xml = subprocess.run(["plutil", "-convert", "xml1", "-o", "-", en_path], check=True, capture_output=True).stdout
en = set(plistlib.loads(xml))
missing, unused = sorted(used - en), sorted(en - used)
for k in missing: print("missing in en.lproj:", repr(k))
for k in unused: print("unused key:", repr(k))
print(f"{len(used)} keys in code, {len(en)} in en.lproj, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
PY
