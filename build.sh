#!/bin/bash
# Quick dev iteration script for Hex.
# Builds Release, installs to /Applications, grants permissions, and launches.
# Settings, models, and history persist across rebuilds automatically.
#
# Usage:
#   ./build.sh          # build + install + launch
#   ./build.sh --log    # same, then tail unified logs
#
# First run: System Settings will open — toggle Hex ON for Accessibility
# and Input Monitoring. After that, subsequent runs skip the prompt.
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="$PROJECT_DIR/build/DerivedData"
BUNDLE_ID="com.jdleaverton.Hex"
DEST="/Applications/Hex.app"
TEAM="XX2LCT52QE"
USER_TCC="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

TAIL_LOGS=false
for arg in "$@"; do
  case "$arg" in
    --log|-l) TAIL_LOGS=true ;;
  esac
done

# ── 1. Kill running instance ────────────────────────────────────────
echo "==> Killing Hex..."
killall Hex 2>/dev/null || true
sleep 0.3

# ── 2. Build Release ────────────────────────────────────────────────
echo "==> Building Hex (Release)..."
xcodebuild \
  -scheme Hex \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -skipMacroValidation \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  build 2>&1 | tee /tmp/hex-build.log | grep -E '(error:|BUILD|FAILED)' || true

if grep -q "BUILD FAILED" /tmp/hex-build.log; then
  echo ""
  echo "!! BUILD FAILED. Errors:"
  grep "error:" /tmp/hex-build.log
  echo "Full log: /tmp/hex-build.log"
  exit 1
fi
echo "    Build succeeded."

# ── 3. Find the .app ────────────────────────────────────────────────
BUILD_APP=""
for name in "Hex.app" "Hex Debug.app"; do
  candidate="$DERIVED_DATA/Build/Products/Release/$name"
  if [ -d "$candidate" ]; then
    BUILD_APP="$candidate"
    break
  fi
done
if [ -z "$BUILD_APP" ]; then
  echo "ERROR: No .app found in build products."
  exit 1
fi

# ── 4. Install to /Applications ─────────────────────────────────────
echo "==> Installing to $DEST..."
rm -rf "$DEST"
cp -R "$BUILD_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# ── 5. Write TCC permissions for this build's CDHash ────────────────
echo "==> Setting permissions for $BUNDLE_ID..."

CDHASH=$(codesign -dvvv "$DEST" 2>&1 | awk -F= '/^CDHash=/{print $2}')

if [ -n "$CDHASH" ]; then
  CSREQ_HEX=$(python3 -c "
import struct, binascii
h = bytes.fromhex('$CDHASH')
expr = struct.pack('>II', 8, 0x14) + h
blob = struct.pack('>II', 0xFADE0C00, 8 + len(expr)) + struct.pack('>I', 1) + expr
print(binascii.hexlify(blob).decode().upper())
")

  # User TCC (Microphone)
  sqlite3 "$USER_TCC" "
    DELETE FROM access WHERE client = '$BUNDLE_ID' AND service = 'kTCCServiceMicrophone';
    INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier, flags, last_modified)
      VALUES ('kTCCServiceMicrophone', '$BUNDLE_ID', 0, 2, 4, 1, X'$CSREQ_HEX', 'UNUSED', 0, CAST(strftime('%s','now') AS INTEGER));
  " 2>/dev/null && echo "    Microphone: granted" || echo "    WARN: Microphone failed"

  # System TCC (Accessibility + Input Monitoring)
  # The system TCC DB is SIP-protected; no process can write it directly.
  # Check if permissions are already granted — do NOT reset, as that forces
  # the user to re-toggle every build. macOS re-validates the CDHash itself.
  ACCESSIBILITY_OK=$(sqlite3 "$SYSTEM_TCC" "SELECT auth_value FROM access WHERE client='$BUNDLE_ID' AND service='kTCCServiceAccessibility';" 2>/dev/null)
  LISTEN_OK=$(sqlite3 "$SYSTEM_TCC" "SELECT auth_value FROM access WHERE client='$BUNDLE_ID' AND service='kTCCServiceListenEvent';" 2>/dev/null)

  if [ "$ACCESSIBILITY_OK" = "2" ] && [ "$LISTEN_OK" = "2" ]; then
    echo "    Accessibility + Input Monitoring: already granted"
  else
    echo "    Accessibility + Input Monitoring: need manual grant."
    echo "    Opening System Settings — toggle Hex ON for both Accessibility and Input Monitoring."
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  fi
else
  echo "    WARN: Could not extract CDHash."
fi

# ── 6. Migrate app data from old container ───────────────────────────
NEW_CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support"
OLD_CONTAINER="$HOME/Library/Containers/com.kitlangton.Hex/Data/Library/Application Support"
GLOBAL_MODELS="$HOME/Library/Application Support/FluidAudio/Models"
NEW_APP_DIR="$NEW_CONTAINER/$BUNDLE_ID"
OLD_APP_DIR="$OLD_CONTAINER/com.kitlangton.Hex"

# Settings
if [ ! -f "$NEW_APP_DIR/hex_settings.json" ]; then
  # Try old container, then global Application Support, then Documents
  for src in "$OLD_APP_DIR/hex_settings.json" \
             "$HOME/Library/Application Support/com.kitlangton.Hex/hex_settings.json" \
             "$HOME/Documents/hex_settings.json"; do
    if [ -f "$src" ]; then
      echo "==> Migrating settings from old install..."
      mkdir -p "$NEW_APP_DIR"
      cp "$src" "$NEW_APP_DIR/hex_settings.json"
      echo "    Done."
      break
    fi
  done
fi

# Transcription history
if [ ! -d "$NEW_APP_DIR/Recordings" ] && [ -d "$OLD_APP_DIR/Recordings" ]; then
  echo "==> Migrating transcription history..."
  mkdir -p "$NEW_APP_DIR"
  cp -R "$OLD_APP_DIR/Recordings" "$NEW_APP_DIR/Recordings"
  echo "    Done."
fi

# Parakeet models
NEW_MODELS="$NEW_CONTAINER/FluidAudio/Models"
for model in parakeet-tdt-0.6b-v2-coreml parakeet-tdt-0.6b-v3-coreml; do
  if [ -d "$NEW_MODELS/$model" ] && find "$NEW_MODELS/$model" -name "*.mlmodelc" -print -quit 2>/dev/null | grep -q .; then
    continue
  fi
  SRC=""
  for candidate in "$OLD_CONTAINER/FluidAudio/Models/$model" "$GLOBAL_MODELS/$model"; do
    if [ -d "$candidate" ] && find "$candidate" -name "*.mlmodelc" -print -quit 2>/dev/null | grep -q .; then
      SRC="$candidate"
      break
    fi
  done
  if [ -n "$SRC" ]; then
    echo "==> Copying $model from existing cache..."
    mkdir -p "$NEW_MODELS"
    rm -rf "$NEW_MODELS/$model"
    cp -R "$SRC" "$NEW_MODELS/$model"
    echo "    Done ($(du -sh "$NEW_MODELS/$model" | cut -f1))."
  fi
done

# WhisperKit models
OLD_WHISPER="$OLD_APP_DIR/models"
NEW_WHISPER="$NEW_APP_DIR/models"
if [ -d "$OLD_WHISPER" ] && [ ! -d "$NEW_WHISPER" ]; then
  echo "==> Migrating WhisperKit models..."
  mkdir -p "$NEW_APP_DIR"
  cp -R "$OLD_WHISPER" "$NEW_WHISPER"
  echo "    Done ($(du -sh "$NEW_WHISPER" | cut -f1))."
fi

# ── 7. Launch ────────────────────────────────────────────────────────
echo "==> Launching Hex..."
open "$DEST"
echo "==> Done."

# ── 8. Optionally tail logs ─────────────────────────────────────────
if [ "$TAIL_LOGS" = true ]; then
  echo ""
  log stream --predicate "subsystem == \"$BUNDLE_ID\"" --style compact
fi
