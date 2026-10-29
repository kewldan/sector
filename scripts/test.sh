#!/bin/zsh
# Runs the test suite. Command Line Tools ship the swift-testing macro plugin
# outside the default search path, so point the compiler at it; with Xcode
# selected the flag is unnecessary but harmless.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
plugins="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
extra=()
[[ -d "$plugins" ]] && extra=(-Xswiftc -plugin-path -Xswiftc "$plugins")
exec swift test "${extra[@]}" "$@"
