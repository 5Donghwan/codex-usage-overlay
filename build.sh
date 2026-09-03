#!/bin/bash
# Build the overlay and package it as a minimal .app bundle, signed with a
# stable local identity so the Accessibility grant survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")"

CERT_NAME="CodexUsageOverlay Local Signing"

./scripts/ensure-signing-identity.sh

swift build -c release

APP="dist/CodexUsageOverlay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp .build/release/CodexUsageOverlay "$APP/Contents/MacOS/CodexUsageOverlay"
codesign --force -s "$CERT_NAME" "$APP"
echo "built: $APP"
echo "Accessibility permission is requested on first launch (once per Mac)."
