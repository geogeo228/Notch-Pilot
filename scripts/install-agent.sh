#!/usr/bin/env bash
#
# install-agent.sh — autostart Notch Pilot at login, always inside the
# no-network sandbox. Writes ~/Library/LaunchAgents/com.georgi.notchpilot.plist
# and loads it. Remove with: scripts/install-agent.sh --uninstall
#
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="com.georgi.notchpilot"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$PLIST"
    echo "✓ LaunchAgent removed"
    exit 0
fi

BIN="${HOME}/Applications/Notch Pilot.app/Contents/MacOS/NotchPilot"
[ -x "$BIN" ] || { echo "❌ Build first: scripts/build.sh"; exit 1; }
SB="$PWD/scripts/sandbox.sb"

pkill -x NotchPilot 2>/dev/null || true
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/sandbox-exec</string>
        <string>-f</string>
        <string>${SB}</string>
        <string>${BIN}</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
    <key>StandardOutPath</key><string>/tmp/notchpilot.log</string>
    <key>StandardErrorPath</key><string>/tmp/notchpilot.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap "${DOMAIN}" "$PLIST"
echo "✓ LaunchAgent installed and started (offline). Log: /tmp/notchpilot.log"
