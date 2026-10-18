#!/bin/zsh
# Regenerates the README screenshots in docs/screenshots from invented demo data.
# Never touches real data: the app runs against a throwaway data folder.
set -euo pipefail
cd "$(dirname "$0")/.."
if ! xcode-select -p | grep -q Xcode.app; then
  SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$SDK" ] && export SDKROOT="$SDK"
fi
swift build
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PLUMB_DATA_DIR="$TMP/data" .build/debug/Plumb --render-snapshots "$TMP/shots" -AppleLocale en_US -AppleLanguages '(en-US)'
mkdir -p docs/screenshots
for name in panel panel-dark panel-away today task-forecast reports reports-dark break-card-dark settings-sounds settings-blocking; do
  cp "$TMP/shots/$name.png" docs/screenshots/
done
echo "Updated docs/screenshots"
