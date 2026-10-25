#!/bin/sh
# Keeps a host route to an Apple device on another VLAN, so Xcode can install on it. Xcode's
# pairing daemon checks a network device with ARP before connecting, and ARP fails across
# subnets: the device shows as "unavailable". A host route through the Wi-Fi or Ethernet
# interface makes the Mac treat the device as on-link; the traffic still goes via the router.
#
#   sudo macos/scripts/device-route.sh install 10.0.50.20 en0 10.0.10.   → launch daemon, route now
#   sudo macos/scripts/device-route.sh uninstall                         → remove both
#   macos/scripts/device-route.sh check 10.0.50.20 en0 10.0.10.          → what it would do
#
# The last argument is the start of the Mac's address on that network: the route exists only
# while the interface has such an address, so it doesn't misroute the device's address elsewhere.
# The daemon applies it at boot and on every network change. BUNDLE_PREFIX names it (default
# house.milapan).
set -eu

label="${BUNDLE_PREFIX:-house.milapan}.rex-radar.device-route"
plist="/Library/LaunchDaemons/$label.plist"
helper="/usr/local/libexec/rex-radar-device-route"

has_route() { netstat -rn -f inet | awk -v d="$1" '$1 == d { found = 1 } END { exit !found }'; }

apply() {
  device=$1 interface=$2 prefix=$3 dry=${4:-}
  address=$(ipconfig getifaddr "$interface" 2>/dev/null || true)
  case "$address" in
  "$prefix"*)
    if has_route "$device"; then echo "route to $device already there"; return; fi
    echo "adding route to $device on $interface ($address)"
    [ -n "$dry" ] || /sbin/route -n add -host "$device" -interface "$interface" >/dev/null
    ;;
  *)
    if ! has_route "$device"; then echo "not on $prefix* ($interface: ${address:-no address}), no route"; return; fi
    echo "not on $prefix* ($interface: ${address:-no address}), removing route to $device"
    [ -n "$dry" ] || /sbin/route -n delete -host "$device" >/dev/null
    ;;
  esac
}

case "${1:-}" in
apply) apply "$2" "$3" "$4" ;;
check) apply "$2" "$3" "$4" dry ;;
install)
  device=$2 interface=$3 prefix=$4
  mkdir -p "$(dirname "$helper")"
  install -m 755 "$0" "$helper"
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper</string><string>apply</string>
    <string>$device</string><string>$interface</string><string>$prefix</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration</string></array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
EOF
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist"
  echo "installed $label: keeps a route to $device on $interface while on $prefix*"
  ;;
uninstall)
  device=$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$plist" 2>/dev/null || true)
  launchctl bootout system "$plist" 2>/dev/null || true
  rm -f "$plist" "$helper"
  if [ -n "$device" ] && has_route "$device"; then /sbin/route -n delete -host "$device" >/dev/null; fi
  echo "removed $label"
  ;;
*)
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
