#!/usr/bin/env bash
# Assemble the headless TapQ macOS runtime into the app container required by TCC.
#
#   scripts/package-runtime-app.sh [debug|release]   (default: debug)
#
# Output: build/TapQRuntime.app
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/TapQRuntime.app"
SIGN_IDENTITY="${TAPQ_SIGN_IDENTITY:--}"

case "$CONFIG" in
  debug|release) ;;
  *) echo "error: configuration must be debug or release" >&2; exit 64 ;;
esac

echo "==> Building tapq ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/tapq"
[ -x "$BIN" ] || { echo "error: built tapq binary not found at $BIN" >&2; exit 1; }

echo "==> Building wavo-hook compatibility adapter ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product wavo-hook
HOOK_BIN="$BIN_DIR/wavo-hook"
[ -x "$HOOK_BIN" ] || { echo "error: built wavo-hook binary not found at $HOOK_BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/tapq"
cp "$HOOK_BIN" "$APP/Contents/MacOS/wavo-hook"
cp "$ROOT/Executables/tapq/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/tapq" "$APP/Contents/MacOS/wavo-hook"

echo "==> Signing runtime container"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/wavo-hook"
codesign --force --options runtime \
  --entitlements "$ROOT/Executables/tapq/TapQ.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
for key in NSMotionUsageDescription NSSpeechRecognitionUsageDescription NSMicrophoneUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null
done

echo "Done: $APP"
echo "Run: $APP/Contents/MacOS/tapq serve"
