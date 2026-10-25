#!/usr/bin/env bash
# Builds Rex Radar with its desktop widget (Xcode). The widget needs real signing:
# set DEVELOPMENT_TEAM to your Apple Development team ID (Xcode → Settings → Accounts).
#
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/build.sh            → build/Build/Products/Release/RexRadar.app
#   DEVELOPMENT_TEAM=ABCDE12345 scripts/build.sh --install  → also copy to ~/Applications and launch
#   scripts/build.sh --unsigned                             → compile check only, no signing
#
# BUNDLE_PREFIX=com.example sets the bundle ID and App Group prefix (default house.milapan, which
# only its owner's team can sign).
#
# Without the widget, bundle.sh still builds the app alone with the command-line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
xcodegen generate --quiet

args=(-project RexRadar.xcodeproj -scheme RexRadar -configuration Release -derivedDataPath build -quiet)
[[ -n ${BUNDLE_PREFIX:-} ]] && args+=("BUNDLE_PREFIX=$BUNDLE_PREFIX")
if [[ ${1:-} == --unsigned ]]; then
  xcodebuild "${args[@]}" CODE_SIGNING_ALLOWED=NO build
  echo "compiled (unsigned)"
  exit 0
fi
[[ -n $DEVELOPMENT_TEAM ]] || { echo "set DEVELOPMENT_TEAM to your Apple Development team ID" >&2; exit 1; }
xcodebuild "${args[@]}" -allowProvisioningUpdates build

app=build/Build/Products/Release/RexRadar.app
echo "built $app"
if [[ ${1:-} == --install ]]; then
  pkill -x RexRadar 2>/dev/null || true
  rm -rf ~/Applications/RexRadar.app
  cp -R "$app" ~/Applications/
  open ~/Applications/RexRadar.app
  echo "installed ~/Applications/RexRadar.app"
fi
