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

"$ROOT/scripts/check-release-version.sh"

echo "==> Building tapq ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/tapq"
[ -x "$BIN" ] || { echo "error: built tapq binary not found at $BIN" >&2; exit 1; }

echo "==> Building tapq-hook adapter ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq-hook
HOOK_BIN="$BIN_DIR/tapq-hook"
[ -x "$HOOK_BIN" ] || { echo "error: built tapq-hook binary not found at $HOOK_BIN" >&2; exit 1; }

echo "==> Building tapq-codex-hook adapter ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq-codex-hook
CODEX_HOOK_BIN="$BIN_DIR/tapq-codex-hook"
[ -x "$CODEX_HOOK_BIN" ] || { echo "error: built tapq-codex-hook binary not found at $CODEX_HOOK_BIN" >&2; exit 1; }

echo "==> Building tapq-cursor-hook adapter ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq-cursor-hook
CURSOR_HOOK_BIN="$BIN_DIR/tapq-cursor-hook"
[ -x "$CURSOR_HOOK_BIN" ] || { echo "error: built tapq-cursor-hook binary not found at $CURSOR_HOOK_BIN" >&2; exit 1; }

echo "==> Building tapq-opencode-hook adapter ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product tapq-opencode-hook
OPENCODE_HOOK_BIN="$BIN_DIR/tapq-opencode-hook"
[ -x "$OPENCODE_HOOK_BIN" ] || { echo "error: built tapq-opencode-hook binary not found at $OPENCODE_HOOK_BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/tapq"
cp "$HOOK_BIN" "$APP/Contents/MacOS/tapq-hook"
cp "$CODEX_HOOK_BIN" "$APP/Contents/MacOS/tapq-codex-hook"
cp "$CURSOR_HOOK_BIN" "$APP/Contents/MacOS/tapq-cursor-hook"
cp "$OPENCODE_HOOK_BIN" "$APP/Contents/MacOS/tapq-opencode-hook"
cp "$ROOT/Executables/tapq/Info.plist" "$APP/Contents/Info.plist"
chmod +x \
  "$APP/Contents/MacOS/tapq" \
  "$APP/Contents/MacOS/tapq-hook" \
  "$APP/Contents/MacOS/tapq-codex-hook" \
  "$APP/Contents/MacOS/tapq-cursor-hook" \
  "$APP/Contents/MacOS/tapq-opencode-hook"

echo "==> Signing runtime container"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/tapq-hook"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/tapq-codex-hook"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/tapq-cursor-hook"
codesign --force --options runtime --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/tapq-opencode-hook"
codesign --force --options runtime \
  --entitlements "$ROOT/Executables/tapq/TapQ.entitlements" \
  --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [ "$bundle_id" != "ai.tapq.cli" ]; then
  echo "error: unexpected runtime bundle identifier: $bundle_id" >&2
  exit 1
fi
for key in NSMotionUsageDescription NSSpeechRecognitionUsageDescription NSMicrophoneUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null
done

echo "Done: $APP"
echo "Run: $APP/Contents/MacOS/tapq serve"
