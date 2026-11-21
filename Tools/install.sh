#!/bin/sh
# Builds Rhino for everyday use, signs it and puts it in /Applications.
#
# Signing with a real identity (not "ad hoc") is what lets macOS recognise
# each new build as the same app, so it does not ask again for the Keychain
# items Rhino saved. Set RHINO_SIGN_IDENTITY to use another identity.
set -e
cd "$(dirname "$0")/.."

IDENTITY="${RHINO_SIGN_IDENTITY:-Apple Development}"
APP="build/Build/Products/Release/Rhino.app"
TARGET="/Applications/Rhino.app"

xcodegen generate >/dev/null
# Nothing is installed unless the build really succeeded: a failed build can
# leave a half-made app behind.
rm -rf "$APP"
LOG="$(mktemp)"
xcodebuild -project Rhino.xcodeproj -scheme Rhino -configuration Release -derivedDataPath build build >"$LOG" 2>&1 || true
if ! grep -q "BUILD SUCCEEDED" "$LOG" || [ ! -x "$APP/Contents/MacOS/Rhino" ]; then
  grep -E "error:" "$LOG" | sort -u | head -20
  echo "The build failed; nothing was installed."
  rm -f "$LOG"
  exit 1
fi
rm -f "$LOG"

codesign --force --deep --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# A build left in the build folder would be a second Rhino for macOS to find.
rm -rf build/Build/Products/Debug/Rhino.app

# Every running copy has to go, wherever it was started from: two at once
# would both run the schedules and write to the same history.
osascript -e 'tell application id "app.rhino.Rhino" to quit' >/dev/null 2>&1 || true
sleep 1
pkill -TERM -f "/Rhino.app/Contents/MacOS/Rhino" 2>/dev/null || true
sleep 1
rm -rf "$TARGET"
ditto "$APP" "$TARGET"
rm -rf "$APP"
open -g "$TARGET"
echo "Installed $(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString) in $TARGET"
