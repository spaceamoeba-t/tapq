#!/usr/bin/env bash
# Assemble the GestureBar example into the app container macOS requires before it will
# associate a Motion permission with a stable identity.
#
#   Examples/GestureBar/scripts/package-example-app.sh [debug|release]   (default: debug)
#
# Output: Examples/GestureBar/build/GestureBar.app
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/GestureBar.app"
SIGN_IDENTITY="${TAPQ_SIGN_IDENTITY:--}"

case "$CONFIG" in
  debug|release) ;;
  *) echo "error: configuration must be debug or release" >&2; exit 64 ;;
esac

echo "==> Building GestureBar ($CONFIG)"
swift build --package-path "$ROOT" -c "$CONFIG" --product GestureBar
BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/GestureBar"
[ -x "$BIN" ] || { echo "error: built GestureBar binary not found at $BIN" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GestureBar"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/GestureBar"

echo "==> Signing example container"
codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist")"
if [ "$bundle_id" != "ai.tapq.example.gesturebar" ]; then
  echo "error: unexpected example bundle identifier: $bundle_id" >&2
  exit 1
fi
# The motion key is the whole reason this bundle exists; an app without it is killed on
# the first CoreMotion call rather than prompted.
/usr/libexec/PlistBuddy -c "Print :NSMotionUsageDescription" "$APP/Contents/Info.plist" >/dev/null

echo "Done: $APP"
echo "Run: open $APP"
