#!/bin/sh
# Packages AgentDeck as a stable .app in ~/Applications so Login Items
# doesn't point at a disposable .build/ path.
set -e
cd "$(dirname "$0")"
swift build -c release

APP="$HOME/Applications/AgentDeck.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.tonyhoang.agentdeck</string>
    <key>CFBundleName</key><string>AgentDeck</string>
    <key>CFBundleExecutable</key><string>AgentDeck</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
EOF
cp .build/release/AgentDeck .build/release/agentdeck-hook "$APP/Contents/MacOS/"
echo "Installed $APP"
echo "Add it to System Settings > General > Login Items for reboot persistence."
