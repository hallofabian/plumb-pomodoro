#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed, SwiftUI's macro
# plugin is missing from the newest SDK and swift-testing's plugin is not on the
# default search path, so both are pointed at explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
  PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
  exec swift test -Xswiftc -load-plugin-library -Xswiftc "$PLUGIN" "$@"
fi
exec swift test "$@"
