# Sourced by the build scripts. Without Xcode, Command Line Tools lack the
# SwiftUI macro plugin the macOS 27 SDK needs (@State is a macro there), so
# fall back to the newest macOS 26 SDK, which has the same Liquid Glass API.
developer_dir="$(xcode-select -p)"
case "$developer_dir" in
  *Xcode*.app*) ;;
  *)
    sdk="$(ls -d "$developer_dir"/SDKs/MacOSX26.*.sdk "$developer_dir"/SDKs/MacOSX26.sdk 2>/dev/null \
      | sort -V | tail -1)"
    [ -n "$sdk" ] && export SDKROOT="$sdk"
    ;;
esac
