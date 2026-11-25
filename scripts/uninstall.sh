#!/bin/bash
# Removes Murmur.app. Recordings and settings are kept.
set -euo pipefail
BUNDLE_ID="com.dreamx.murmur"
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
"$HOME/Applications/Murmur.app/Contents/MacOS/murmur" unregister-login 2>/dev/null || true
rm -rf "$HOME/Applications/Murmur.app"
echo "Uninstalled (recordings kept)."
