#!/bin/sh
# Creates AgentDeck.app from a directory containing the built binaries + icon.
#   usage: make-app-bundle.sh <src-dir> [dest-app-path]
# <src-dir> must contain: AgentDeck, agentdeck-hook, AppIcon.icns
set -e
SRC="$1"
APP="${2:-$HOME/Applications/AgentDeck.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
for v in "$SCRIPT_DIR/VERSION" "$SCRIPT_DIR/../VERSION"; do
    [ -f "$v" ] && VERSION="$(cat "$v")" && break
done
VERSION="${VERSION:-0.0.0}"

[ -x "$SRC/AgentDeck" ] || { echo "error: $SRC/AgentDeck not found" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/AppIcon.icns" "$APP/Contents/Resources/"
cp "$SRC/AgentDeck" "$SRC/agentdeck-hook" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.tonyhoang.agentdeck</string>
    <key>CFBundleName</key><string>AgentDeck</string>
    <key>CFBundleExecutable</key><string>AgentDeck</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>AgentDeck focuses the iTerm2 tab for the session you click, and reads tab titles to label rows.</string>
</dict>
</plist>
EOF

# A stable signing identity matters beyond tidiness: macOS keys Automation
# and Notification grants to it, and SwiftPM's linker-signed default changes
# identity on every rebuild — which silently revokes those grants.
codesign --force --sign - --identifier com.tonyhoang.agentdeck "$APP" 2>/dev/null \
    || echo "warning: ad-hoc codesign failed; permissions may reset on upgrade" >&2

echo "Created $APP (v${VERSION})"
echo "Next: open it, click 'Install hooks' in the popover footer, and add it"
echo "to System Settings > General > Login Items for reboot persistence."
