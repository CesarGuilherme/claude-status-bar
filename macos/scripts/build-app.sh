#!/bin/bash
# Builds macos/build/ClaudeStatusBar.app from the SwiftPM release binary.
# Signed for this Mac: enough for SMAppService login items.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin="$(swift build -c release --show-bin-path)/ClaudeStatusBar"
app="build/ClaudeStatusBar.app"

rm -rf "$app" build/AppIcon.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/ClaudeStatusBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/claude.svg "$app/Contents/Resources/claude.svg"

swift scripts/make-icon.swift build/AppIcon.iconset Resources/claude.svg
iconutil -c icns build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"

# A development certificate keeps the signature stable across rebuilds, so the
# Keychain "Always Allow" for the Claude Code item survives. Ad-hoc otherwise.
identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${identity:--}" "$app"
echo "$(pwd)/$app"
