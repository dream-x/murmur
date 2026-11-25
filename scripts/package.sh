#!/bin/bash
# Builds a universal Murmur.app and zips it into dist/Murmur-<version>.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)}"
BUNDLE_ID="com.dreamx.murmur"
APP="dist/Murmur.app"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/murmur"

rm -rf dist && mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"

ditto -c -k --keepParent "$APP" "dist/Murmur-$VERSION.zip"
echo "dist/Murmur-$VERSION.zip"
