#!/bin/zsh
# Builds a release and installs it as /Applications/Sector.app, keeping
# Launch Services (and so the widgets) pointed at the installed copy.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build-app.sh release
osascript -e 'quit app id "com.kewldan.sector"' 2>/dev/null || true
ditto build/Sector.app /Applications/Sector.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in build/Sector.app build/DerivedData/Build/Products/*/Sector.app(N); do
  "$lsregister" -u "$PWD/$copy"
done
"$lsregister" -f /Applications/Sector.app
open /Applications/Sector.app
echo /Applications/Sector.app
