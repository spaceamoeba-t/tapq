#!/usr/bin/env bash
# Foreground development launcher for the TCC-safe, headless macOS runtime bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${TAPQ_BUILD_CONFIG:-debug}"
APP="$ROOT/build/TapQRuntime.app"
EXEC="$APP/Contents/MacOS/tapq"
ARGS=("$@")
[ "${#ARGS[@]}" -gt 0 ] || ARGS=(serve)

if [ "${TAPQ_SKIP_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/package-runtime-app.sh" "$CONFIG"
fi
[ -x "$EXEC" ] || {
  echo "error: runtime bundle is missing; run scripts/package-runtime-app.sh $CONFIG" >&2
  exit 1
}

if pgrep -f "^$EXEC( |$)" >/dev/null; then
  echo "error: TapQRuntime.app is already running" >&2
  exit 1
fi

LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tapq-runtime.XXXXXX")"
STDOUT_LOG="$LOG_DIR/stdout.log"
STDERR_LOG="$LOG_DIR/stderr.log"
touch "$STDOUT_LOG" "$STDERR_LOG"

OPEN_PID=""
RUNTIME_PID=""
TAIL_PID=""

cleanup() {
  trap - INT TERM EXIT
  if [ -n "$RUNTIME_PID" ] && kill -0 "$RUNTIME_PID" 2>/dev/null; then
    kill -TERM "$RUNTIME_PID" 2>/dev/null || true
    wait "$RUNTIME_PID" 2>/dev/null || true
  fi
  [ -z "$TAIL_PID" ] || kill "$TAIL_PID" 2>/dev/null || true
  [ -z "$OPEN_PID" ] || kill "$OPEN_PID" 2>/dev/null || true
  rm -rf "$LOG_DIR"
}
trap cleanup INT TERM EXIT

open -n -W --stdout "$STDOUT_LOG" --stderr "$STDERR_LOG" \
  "$APP" --args "${ARGS[@]}" &
OPEN_PID=$!

for _ in $(seq 1 100); do
  RUNTIME_PID="$(pgrep -f "^$EXEC( |$)" | tail -n 1 || true)"
  [ -n "$RUNTIME_PID" ] && break
  sleep 0.05
done

if [ -z "$RUNTIME_PID" ]; then
  wait "$OPEN_PID" || true
  cat "$STDOUT_LOG"
  cat "$STDERR_LOG" >&2
  echo "error: TapQRuntime.app did not launch" >&2
  exit 1
fi

tail -n +1 -F "$STDOUT_LOG" "$STDERR_LOG" &
TAIL_PID=$!
wait "$OPEN_PID"
