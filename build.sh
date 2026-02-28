#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
BUNDLE_ID="com.kitlangton.Hex"
DEST="/Applications/Hex.app"

# 1. Kill running instance
echo "==> Killing Hex..."
killall Hex 2>/dev/null || true
sleep 0.5

# 2. Build Release
echo "==> Building Hex (Release)..."
xcodebuild \
  -scheme Hex \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM=XX2LCT52QE \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  build 2>&1 | grep -E '(error:|BUILD|FAILED|\*\*)' || true

# Find the built app
BUILD_APP=""
for name in "Hex.app" "Hex Debug.app"; do
  candidate="$DERIVED_DATA/Build/Products/Release/$name"
  if [ -d "$candidate" ]; then
    BUILD_APP="$candidate"
    break
  fi
done

if [ -z "$BUILD_APP" ]; then
  echo "ERROR: No .app found in Release products."
  ls "$DERIVED_DATA/Build/Products/Release/"*.app 2>/dev/null || echo "  (none)"
  exit 1
fi

echo "==> Found: $BUILD_APP"

# 3. Install to /Applications
echo "==> Installing to $DEST..."
rm -rf "$DEST"
cp -R "$BUILD_APP" "$DEST"

# 4. Reset TCC permissions for a clean slate
echo "==> Resetting permissions..."
tccutil reset Microphone "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent "$BUNDLE_ID" 2>/dev/null || true

# 5. Launch and tail logs
echo "==> Launching Hex..."
open "$DEST"
echo "==> Done! Tailing logs (Ctrl+C to stop)..."
echo ""
log stream --predicate 'subsystem == "com.kitlangton.Hex"' --style compact
