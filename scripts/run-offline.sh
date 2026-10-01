#!/usr/bin/env bash
#
# run-offline.sh — launch Notch Pilot under a macOS sandbox profile that
# denies all IP networking (in and out). Unix-domain sockets stay allowed,
# so the hook socket in ~/.notch-pilot keeps working.
#
# This is a second line of defence on top of the fork's code changes
# (no URLSession anywhere) and the LuLu firewall.
#
# Usage: scripts/run-offline.sh

set -euo pipefail
cd "$(dirname "$0")/.."

BIN="dist/Notch Pilot.app/Contents/MacOS/NotchPilot"
[ -x "$BIN" ] || { echo "❌ Build first: scripts/build.sh"; exit 1; }

pkill -x NotchPilot 2>/dev/null || true

PROFILE='(version 1)
(allow default)
(deny network-outbound (remote ip))
(deny network-inbound (local ip))'

nohup sandbox-exec -p "$PROFILE" "$BIN" >/tmp/notchpilot.log 2>&1 &
echo "▶ Notch Pilot started offline (pid $!), log: /tmp/notchpilot.log"
