#!/bin/zsh
# Lists localization keys the compiler emits (plus Plural noun forms) that
# are missing from Resources/en.lproj/Localizable.strings. Exit code 1 when
# anything is missing.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift build --product Sector --build-path "$work/build" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$work/strings" \
  >/dev/null
python3 -I - "$work/strings" <<'PY'
import glob, json, re, subprocess, sys
keys = set()
for f in glob.glob(sys.argv[1] + "/*.stringsdata"):
    for entries in json.load(open(f)).get("tables", {}).values():
        keys.update(e["key"] for e in entries if re.search("[А-Яа-яЁё]", e["key"]))
# Plural noun forms: three single-word Russian literals in a row, outside
# comments (Plural.format arguments and tuples of forms).
word = r'"([А-Яа-яЁё]+)"'
for f in glob.glob("Sources/**/*.swift", recursive=True):
    for line in open(f):
        if line.lstrip().startswith("//"):
            continue
        for m in re.finditer(word + r',\s*' + word + r',\s*' + word, line):
            keys.update(m.groups())
plist = subprocess.run(
    ["plutil", "-convert", "json", "-o", "-", "Resources/en.lproj/Localizable.strings"],
    capture_output=True, text=True, check=True).stdout
missing = sorted(keys - set(json.loads(plist)))
print("\n".join(missing) if missing else f"All {len(keys)} keys translated.")
sys.exit(1 if missing else 0)
PY
