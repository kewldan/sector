#!/bin/zsh
# Builds build/Sector.app with Xcode (release by default; pass "debug").
#
# Signing uses DEVELOPMENT_TEAM from Config/Local.xcconfig. Without it the
# app is signed to run locally: everything works except the widgets, which
# need a team for their App Group.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
config="${1:-release}"
configuration="${(C)config}"

xcodegen generate --quiet
signing=()
if ! grep -qs '^DEVELOPMENT_TEAM *= *[A-Z0-9]' Config/Local.xcconfig; then
  signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
fi

xcodebuild -project Sector.xcodeproj -scheme Sector -configuration "$configuration" \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' -quiet \
  -allowProvisioningUpdates "${signing[@]}" build

rm -rf build/Sector.app
ditto "build/DerivedData/Build/Products/$configuration/Sector.app" build/Sector.app
echo build/Sector.app
