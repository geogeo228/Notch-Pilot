#!/usr/bin/env bash
#
# run-offline.sh — (re)start Notch Pilot under the no-network sandbox
# (scripts/sandbox.sb: all IP traffic denied, unix sockets allowed so the
# hook socket in ~/.notch-pilot keeps working).
#
# If the LaunchAgent is installed (scripts/install-agent.sh) it restarts
# it through launchd; otherwise launches directly.
#
# Usage: scripts/run-offline.sh

set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.georgi.notchpilot"
BIN="${HOME}/Applications/Notch Pilot.app/Contents/MacOS/NotchPilot"
[ -x "$BIN" ] || { echo "❌ Build first: scripts/build.sh"; exit 1; }

if launchctl print "gui/$(id -u)/${LABEL}" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/${LABEL}"
    echo "▶ Notch Pilot restarted via launchd (offline), log: /tmp/notchpilot.log"
else
    pkill -x NotchPilot 2>/dev/null || true
    nohup sandbox-exec -f "$PWD/scripts/sandbox.sb" "$BIN" >/tmp/notchpilot.log 2>&1 &
    echo "▶ Notch Pilot started offline (pid $!), log: /tmp/notchpilot.log"
fi
