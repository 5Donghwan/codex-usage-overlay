#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="dist/CodexUsageOverlay.app"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/CodexUsageOverlay "$APP/Contents/MacOS/CodexUsageOverlay"
codesign --force -s - "$APP"
echo "built: $APP"
echo "Accessibility permission is requested on first launch."
