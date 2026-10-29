#!/bin/zsh
# Builds a signed release and packages it for GitHub Releases:
#   build/release/Sector-<version>.dmg (drag-to-Applications) and its SHA-256.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release

app=build/Sector.app
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
codesign --verify --deep --strict "$app"

out=build/release
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out"
ditto "$app" "$stage/Sector.app"
ln -s /Applications "$stage/Applications"

dmg="$out/Sector-$version.dmg"
rm -f "$dmg"
hdiutil create -volname "Sector $version" -srcfolder "$stage" -fs APFS -format ULFO -ov "$dmg" >/dev/null
(cd "$out" && shasum -a 256 "Sector-$version.dmg" > "Sector-$version.dmg.sha256")
echo "$dmg"
