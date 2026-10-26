#!/bin/sh
# Keeps the Mac reachable from the home network while Cloudflare WARP is on. A WARP profile that
# doesn't exclude the home addresses (here only 192.168.0.0/16 is excluded, the home is 10.0.*)
# sends the Mac's replies into the tunnel, so the iPhone, watch and Apple TV can't reach the hub.
# While the Mac is on the home network this re-applies WARP's local network access, which ends at
# every reconnect and covers only the Mac's own /24, and routes the other home subnets (VLANs,
# WireGuard) through the router with routes more specific than WARP's.
#
#   sudo macos/scripts/warp-lan.sh install 10.0.10. 10.0.50.0/24 10.101.0.0/24   → launch daemon, apply now
#   sudo macos/scripts/warp-lan.sh uninstall                                    → remove both
#   macos/scripts/warp-lan.sh check 10.0.10. 10.0.50.0/24 10.101.0.0/24          → what it would do
#
# The first argument is the start of the Mac's address on the home network (three octets); the
# rest are the subnets to route through that network's router. Nothing happens elsewhere, and the
# routes are removed. The daemon applies it at boot, on every network change and every 5 minutes.
# BUNDLE_PREFIX names it (default house.milapan).
set -eu

label="${BUNDLE_PREFIX:-house.milapan}.rex-radar.warp-lan"
plist="/Library/LaunchDaemons/$label.plist"
helper="/usr/local/libexec/rex-radar-warp-lan"
state="/var/run/rex-radar-warp-lan"
warp=/usr/local/bin/warp-cli

# The interface whose IPv4 address starts with $1, if any.
home_interface() {
  for i in $(ifconfig -l); do
    case "$(ipconfig getifaddr "$i" 2>/dev/null || true)" in "$1"*) echo "$i"; return ;; esac
  done
}

route_field() { /sbin/route -n get "$1" 2>/dev/null | awk -v f="$2:" '$1 == f { print $2 }'; }

apply() {
  prefix=$1 dry=$2; shift 2
  interface=$(home_interface "$prefix")
  if [ -z "$interface" ]; then
    echo "not on $prefix*"
    for file in "$state"/*; do
      [ -f "$file" ] || continue
      subnet=$(basename "$file" | tr _ /)
      echo "removing route to $subnet"
      # Only the route this script added: an away network on the same subnet keeps its own.
      [ -n "$dry" ] || { /sbin/route -n delete -net "$subnet" "$(cat "$file")" >/dev/null 2>&1 || true; rm -f "$file"; }
    done
    return
  fi
  router=$(ipconfig getoption "$interface" router 2>/dev/null || true)
  echo "on $prefix* via $interface, router ${router:-unknown}"

  # WARP's local network access, when WARP holds the Mac's own subnet.
  if [ -x "$warp" ] && [ "$(route_field "${prefix}254" interface)" != "$interface" ]; then
    echo "allowing WARP local network access"
    [ -n "$dry" ] || "$warp" --accept-tos override local-network allow >/dev/null || true
  fi

  [ -n "$router" ] || return 0
  for subnet in "$@"; do
    if [ "$(route_field "${subnet%/*}" gateway)" = "$router" ]; then continue; fi
    echo "routing $subnet through $router"
    [ -n "$dry" ] && continue
    /sbin/route -n add -net "$subnet" "$router" >/dev/null 2>&1 \
      || /sbin/route -n change -net "$subnet" "$router" >/dev/null
    mkdir -p "$state"
    echo "$router" >"$state/$(echo "$subnet" | tr / _)"
  done
}

case "${1:-}" in
apply) prefix=$2; shift 2; apply "$prefix" "" "$@" ;;
check) prefix=$2; shift 2; apply "$prefix" dry "$@" ;;
install)
  shift
  mkdir -p "$(dirname "$helper")"
  install -m 755 "$0" "$helper"
  args=""
  for a in "$@"; do args="$args<string>$a</string>"; done
  cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$helper</string><string>apply</string>$args
  </array>
  <key>RunAtLoad</key><true/>
  <key>WatchPaths</key><array><string>/Library/Preferences/SystemConfiguration</string></array>
  <key>StartInterval</key><integer>300</integer>
</dict>
</plist>
EOF
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist"
  echo "installed $label: keeps the Mac reachable on $1* while WARP is on"
  ;;
uninstall)
  launchctl bootout system "$plist" 2>/dev/null || true
  for file in "$state"/*; do
    [ -f "$file" ] || continue
    /sbin/route -n delete -net "$(basename "$file" | tr _ /)" "$(cat "$file")" >/dev/null 2>&1 || true
  done
  rm -rf "$plist" "$helper" "$state"
  echo "removed $label"
  ;;
*)
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
