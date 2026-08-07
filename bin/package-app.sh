#!/bin/sh
# Build quill and package it as ~/Applications/quill.app, signed with the
# stable local identity so TCC grants (mic, Input Monitoring, Accessibility)
# survive rebuilds. Re-run after every change; then restart the agent:
#   launchctl kickstart -k gui/$(id -u)/com.swarajban.quill
set -e
cd "$(dirname "$0")/.."

swift build -c release

APP="$HOME/Applications/quill.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/quill "$APP/Contents/MacOS/quill"
cp Sources/quill/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "quill-local" --identifier com.swarajban.quill "$APP"

# Register with LaunchServices so UNUserNotificationCenter and TCC see the bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "✓ packaged $APP"
