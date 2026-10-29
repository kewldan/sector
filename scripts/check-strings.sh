#!/bin/zsh
# Lists localization keys missing an English translation in
# Resources/Localizable.xcstrings: keys the compiler extracted while building
# the app and the widgets (run scripts/build-app.sh first), plus Plural noun
# forms, which are looked up at runtime. Exit code 1 when anything is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -I - <<'PY'
import glob, json, re, sys
keys = set()
data = glob.glob("build/DerivedData/Build/Intermediates.noindex/**/*.stringsdata", recursive=True)
if not data:
    sys.exit("No .stringsdata found; run scripts/build-app.sh first.")
for f in data:
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries)
# Plural noun forms: three single-word Russian literals in a row, outside
# comments (Plural.format arguments and tuples of forms).
word = r'"([А-Яа-яЁё]+)"'
for f in glob.glob("Sources/**/*.swift", recursive=True) + glob.glob("Widgets/**/*.swift", recursive=True):
    for line in open(f):
        if line.lstrip().startswith("//"):
            continue
        for m in re.finditer(word + r',\s*' + word + r',\s*' + word, line):
            keys.update(m.groups())
catalog = json.load(open("Resources/Localizable.xcstrings"))["strings"]
def translated(k):
    return "en" in catalog.get(k, {}).get("localizations", {})
missing = sorted(k for k in keys if re.search("[А-Яа-яЁё]", k) and not translated(k))
print("\n".join(missing) if missing else f"All {len(keys)} keys translated.")
sys.exit(1 if missing else 0)
PY
