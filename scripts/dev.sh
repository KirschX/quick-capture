#!/bin/zsh
# Builds the Debug app, installs it as /Applications/Quick Capture Dev.app and relaunches it.
# It has its own bundle ID (com.oralart.showandtell.dev) and stays Apple Development signed,
# so Screen Recording and Accessibility grants survive every rebuild.
set -euo pipefail

BUNDLE_ID=com.kirschx.quickcapture.dev
APP="/Applications/Quick Capture Dev.app"
DERIVED=build/DerivedData-dev
cd "$(dirname "$0")/.."

xcodegen generate -q
xcodebuild -project ShowAndTell.xcodeproj -scheme ShowAndTell -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  -quiet build

# Quit gracefully and wait, so the bundle isn't replaced under a running app.
osascript -e "quit app id \"$BUNDLE_ID\"" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -f "$APP/Contents/MacOS/" >/dev/null || break
  sleep 0.1
done
pkill -f "$APP/Contents/MacOS/" || true

rm -rf "$APP"
ditto "$DERIVED/Build/Products/Debug/Quick Capture.app" "$APP"
# By path: the build products copy has the same bundle ID.
open "$APP"
