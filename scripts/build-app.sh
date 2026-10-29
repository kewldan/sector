#!/bin/zsh
# Builds build/Sector.app (release by default; pass "debug" for a debug build)
# and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
config="${1:-release}"

swift build -c "$config" --product Sector
bin="$(swift build -c "$config" --show-bin-path)"

app="build/Sector.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Sector" "$app/Contents/MacOS/Sector"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$app/Contents/Resources/"

codesign --force --sign - --options runtime --timestamp=none "$app" >/dev/null
echo "$app"
