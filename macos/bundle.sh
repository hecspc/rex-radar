#!/usr/bin/env bash
# Builds RexRadar.app: a menu-bar-only app (LSUIElement, no Dock icon), ad-hoc signed.
#
#   ./bundle.sh            → build/RexRadar.app
#   ./bundle.sh --install  → also copy it to ~/Applications and launch it
#
# BUNDLE_PREFIX=com.example sets the bundle ID prefix (default house.milapan).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
app=build/RexRadar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/RexRadar" "$app/Contents/MacOS/RexRadar"
mkdir -p "$app/Contents/Resources" && cp ../watcher/rex-radar.lua "$app/Contents/Resources/"
cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_PREFIX:-house.milapan}.rex-radar</string>
  <key>CFBundleName</key><string>RexRadar</string>
  <key>CFBundleExecutable</key><string>RexRadar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "built $app"

if [[ ${1:-} == --install ]]; then
  mkdir -p ~/Applications
  pkill -x RexRadar 2>/dev/null || true
  rm -rf ~/Applications/RexRadar.app
  cp -R "$app" ~/Applications/
  open ~/Applications/RexRadar.app
  echo "installed ~/Applications/RexRadar.app"
fi
