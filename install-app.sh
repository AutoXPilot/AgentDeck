#!/bin/sh
# Build from source and install ~/Applications/AgentDeck.app.
set -e
cd "$(dirname "$0")"
swift build -c release
cp Resources/AppIcon.icns .build/release/
exec scripts/make-app-bundle.sh .build/release
