#!/bin/bash
# Assemble a .app bundle from the SPM build.
#
# No .xcodeproj: the whole thing stays readable in git and buildable from a
# terminal. A menu bar app needs LSUIElement, which needs an Info.plist, which is
# the only reason this script exists.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
NAME=ClaudeInbox
APP="build/$NAME.app"

# Only the bundle path goes to stdout: this script is meant to be substituted
# into a variable, and a compiler log in that variable is a path that is not one.
# One binary for both kinds of Mac: a disk image that only opens on Apple
# silicon is a support thread waiting to happen.
ARCHES=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHES[@]}" >&2
BIN=$(swift build -c "$CONFIG" "${ARCHES[@]}" --show-bin-path 2>/dev/null)/"$NAME"

# The icon is the picture on every notification banner, so it is part of the
# build rather than something remembered later.
[ -f build/$NAME.icns ] || swift icon.swift >&2

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
# The hooks travel with the app, so a downloaded copy can install them itself.
mkdir -p "$APP/Contents/Resources/bridge"
for f in install.sh lib.sh hook-permission.sh hook-session.sh statusline.sh; do cp "../bridge/$f" "$APP/Contents/Resources/bridge/"; done
chmod +x "$APP/Contents/Resources/bridge/"*.sh
[ -f build/$NAME.icns ] && cp "build/$NAME.icns" "$APP/Contents/Resources/$NAME.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Claude Inbox</string>
  <key>CFBundleIdentifier</key><string>com.blckgh.claude-inbox</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- menu bar only: no dock icon, no app switcher entry -->
  <key>CFBundleIconFile</key><string>$NAME</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc is enough to run locally; a Developer ID is a distribution problem.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
