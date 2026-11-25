#!/bin/bash
# Builds Murmur.app, installs it to ~/Applications and launches it (menu bar app).
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="com.dreamx.murmur"
APP="$HOME/Applications/Murmur.app"

swift build -c release

osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
sleep 1

mkdir -p "$APP/Contents/MacOS"
cp .build/release/murmur "$APP/Contents/MacOS/murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

open "$APP"
echo "Installed $APP — look for the mic icon in the menu bar."
echo "Logs: tail -f ~/Library/Logs/Murmur.log"
