#!/bin/zsh
# Builds Plumb.app and installs it to ~/Applications.
#   scripts/build-app.sh            build + install
#   scripts/build-app.sh --no-install
set -euo pipefail
cd "$(dirname "$0")/.."

# The Command Line Tools' newest SDK lacks the SwiftUI macro plugin; use the 26.x SDK.
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1 || true)
if ! xcode-select -p | grep -q Xcode.app && [ -n "$SDK" ]; then export SDKROOT="$SDK"; fi

VERSION=$(git describe --tags --always 2>/dev/null || echo 1.0)
# Reverse-DNS id of the app; set PLUMB_BUNDLE_ID to use your own.
BUNDLE_ID="${PLUMB_BUNDLE_ID:-dev.plumb.timer}"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Plumb

APP=build/Plumb.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Plumb"

if [ ! -f build/AppIcon.icns ]; then
  ICONSET=build/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Plumb</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Plumb</string>
  <key>CFBundleDisplayName</key><string>Plumb</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
    <key>CFBundleURLSchemes</key><array><string>plumb</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Plumb checks the open tab in your browser to block distracting websites during work intervals.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" != "--no-install" ]; then
  mkdir -p ~/Applications
  pkill -x Plumb 2>/dev/null && sleep 1 || true
  rm -rf ~/Applications/Plumb.app
  cp -R "$APP" ~/Applications/Plumb.app
  echo "Installed ~/Applications/Plumb.app"
fi
