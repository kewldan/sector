# Sourced by the build scripts. Without Xcode, Command Line Tools lack the
# SwiftUI macro plugin the macOS 27 SDK needs (@State is a macro there), so
# fall back to the newest macOS 26 SDK, which has the same Liquid Glass API.
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" != *Xcode*.app* ]]; then
  for sdk in "$developer_dir"/SDKs/MacOSX26.[0-9]*.sdk(NOn) "$developer_dir"/SDKs/MacOSX26.sdk; do
    if [[ -d "$sdk" ]]; then
      export SDKROOT="$sdk"
      break
    fi
  done
fi
