#!/usr/bin/env bash
set -euo pipefail

# Fast verification path: the loop you run while iterating.
#
#   scripts/slim-check.sh [--one-shot] [ExtraSuite ...]
#
# What it does, and why in this shape:
#   1. `swift build` (debug) on the macOS HOST. The Linux container only builds
#      the portable + POSIX graph, so the host build is the ONLY thing here that
#      catches TapQAppleAdapters / runtime-app compile breakage. Fails fast.
#   2. ONE swift:6.0 container: the two boundary checks, then the slim suite
#      list. One spin-up, one warm build — that is where the 45-70 minutes went.
#
# This is NOT the exhaustive gate. CI runs the full ~2,500-test suite on macOS
# and Linux in ~3 minutes on push. See CLAUDE.md.
#
# Why a loop, retries, and short first-attempt timeouts:
#   This container wedges NONDETERMINISTICALLY. Measured here: roughly one
#   `swift test` invocation in five stalls at ~0% CPU and never finishes, and it
#   is never the same suite twice — suites that stall run clean in 1s on the
#   next attempt. Repeated `--filter` flags in ONE invocation are ~30s faster
#   but lose the whole run to a single wedge (measured: 14 suites in one process
#   wedged twice out of two attempts). So: one process per suite, a short first
#   attempt, and a retry. A wedge then costs seconds instead of the run.
#   `--one-shot` opts into the single fast invocation when you feel lucky.
#
#   A suite that wedges on EVERY attempt exits 2 (inconclusive), not 1 (real
#   test failure), so the two are never confused. Both are non-zero.

# --- The slim list -----------------------------------------------------------
# Class names. SwiftPM matches each --filter as a REGEX against the full test
# identifier `Target.Class/testMethod`, so a bare class name matches by
# substring. Two traps: a class name that is also a substring of its target name
# (WireProtocolTests inside TapQWireProtocolTests) pulls in that target's
# sibling classes too — fine where it happens below; and an ANCHORED pattern
# like '^(A|B)$' matches nothing at all, running 0 tests and exiting 0.
#
# Keep this lean. It guards the invariants that keep breaking; it is not a
# second copy of CI. Add the suites you touched as arguments instead of editing
# this list for a one-off.
SLIM_SUITES=(
    WireProtocolTests                  # wire v6 framing + renewable-lease back-compat (whole tiny target)
    VoiceBackendCommandProviderTests   # provider core: window lifecycle, degrade, idle close
    VoiceResponseSuppressionTests      # agent prose never leaks into the wearer's ear
    VoicePlaybackAcrossRotationTests   # newest regression family: playback survives session rotation
    VoiceBackendToolIntentTests        # tool intents map to the right actions
    VoiceBackendContractTests          # the VoiceBackend protocol contract itself
    InstructionWaitRegistryTests       # broker instruction.wait + lease renewal / expiry
    RealtimeBaseInstructionsTests      # realtime session-update carries the base instructions
    OpenAIRealtimeToolCallTests        # realtime tool declaration + call/result round trip
    OpenAIRealtimeVoiceBackendTests    # realtime session open, manual turns, turn-detection override
    InteractionControllerTests         # the interaction state machine
    VoiceSessionE2ETests               # end-to-end: a voice session over the real route
    VoiceProviderRouteE2ETests         # end-to-end: provider selection / degrade route
    ApprovalPathE2ETests               # end-to-end: gesture -> approval -> agent
)

# Suites that legitimately take real time (they sleep), space-separated. Everything
# in the list finishes in about a second, so anything longer means the process
# wedged. Empty today: VoiceBackendCommandProviderTests used to sit here at ~61s,
# but that was never the idle-sleep timer — it was the container wedge being
# rescued at 60s granularity by a pending idle-timer task. The suite now runs its
# own 100ms main-actor heartbeat (see executorStallHeartbeat in the test file),
# which does the same rescue in ~0.1s.
SLIM_SLOW_SUITES=""

FAST_TIMEOUT="${TAPQ_SLIM_FAST_TIMEOUT:-30}"      # first attempt, ordinary suite
SLOW_TIMEOUT="${TAPQ_SLIM_SLOW_TIMEOUT:-150}"     # first attempt for a slow suite, and every retry
ATTEMPTS="${TAPQ_SLIM_ATTEMPTS:-3}"               # per suite, before calling it wedged
TOTAL_TIMEOUT="${TAPQ_SLIM_TIMEOUT:-900}"         # whole run, in --one-shot mode
BUILD_VOLUME="${TAPQ_SLIM_VOLUME:-tapq-linux-build}"

mode="loop"
extra=()
for arg in "$@"; do
    case "$arg" in
        --one-shot) mode="one-shot" ;;
        --loop)     mode="loop" ;;
        -h|--help)
            sed -n '3,30p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        -*) echo "unknown option: $arg" >&2; exit 64 ;;
        *)  extra+=("$arg") ;;
    esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Git worktree support (the .claude/worktrees/agent-* trees run this script
# too). A worktree's .git is a FILE — "gitdir: <parent>/.git/worktrees/<name>"
# — with the parent repo's absolute path baked in, so git inside the container
# can only resolve it if the parent .git directory is mounted at that SAME
# absolute path. Mount it read-only (the boundary checks only read), and tell
# the container which extra directories to mark safe alongside /src.
git_extra_mounts=()
git_safe_dirs="/src"
if [ -f "$repo_root/.git" ]; then
    git_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
    worktree_git_dir="$(git rev-parse --path-format=absolute --git-dir)"
    git_extra_mounts+=(-v "${git_common_dir}:${git_common_dir}:ro")
    git_safe_dirs="$git_safe_dirs $git_common_dir $worktree_git_dir"
fi

suites=("${SLIM_SUITES[@]}" ${extra+"${extra[@]}"})

if ! command -v docker >/dev/null 2>&1; then
    echo "slim-check needs Docker for the Linux leg." >&2
    exit 127
fi

# Refuse to race another container against the shared build volume: concurrent
# builds against it starve each other.
racing="$(docker ps --filter "volume=${BUILD_VOLUME}" --format '{{.Names}}' || true)"
if [ -n "$racing" ]; then
    echo "Another container is already using the '${BUILD_VOLUME}' volume: ${racing}" >&2
    echo "Concurrent builds against it starve each other. Wait for it, or stop it." >&2
    exit 1
fi

echo "=== 1/2  Host build (debug, macOS graph) ==="
host_start=$(date +%s)
swift build
host_end=$(date +%s)
host_secs=$((host_end - host_start))
echo "Host build OK in ${host_secs}s."
echo ""

echo "=== 2/2  Linux container: boundary checks + ${#suites[@]} suites (${mode}) ==="
container_log="$(mktemp -t tapq-slim-check)"
trap 'rm -f "$container_log"' EXIT

container_start=$(date +%s)
set +e
docker run --rm \
    -v "$repo_root":/src \
    -w /src \
    -v "${BUILD_VOLUME}":/build \
    ${git_extra_mounts+"${git_extra_mounts[@]}"} \
    -e TAPQ_SLIM_GIT_SAFE_DIRS="$git_safe_dirs" \
    -e TAPQ_SLIM_SUITES="${suites[*]}" \
    -e TAPQ_SLIM_SLOW_SUITES="${SLIM_SLOW_SUITES}" \
    -e TAPQ_SLIM_MODE="$mode" \
    -e TAPQ_SLIM_FAST_TIMEOUT="$FAST_TIMEOUT" \
    -e TAPQ_SLIM_SLOW_TIMEOUT="$SLOW_TIMEOUT" \
    -e TAPQ_SLIM_ATTEMPTS="$ATTEMPTS" \
    -e TAPQ_SLIM_TIMEOUT="$TOTAL_TIMEOUT" \
    swift:6.0 \
    bash -c '
        set -uo pipefail

        # The bind mounts are owned by another uid and both check scripts want
        # git. A worktree run adds its parent repo git paths to the list.
        for dir in $TAPQ_SLIM_GIT_SAFE_DIRS; do
            git config --global --add safe.directory "$dir"
        done

        # check-public-boundary.sh needs ripgrep. Installing it costs an apt-get
        # round trip every run, so cache the binary in the build volume.
        export PATH="/build/tools:$PATH"
        if ! command -v rg >/dev/null 2>&1; then
            echo "--- installing ripgrep (first run for this volume) ---"
            apt-get update -qq && apt-get install -y -qq ripgrep >/dev/null 2>&1
            mkdir -p /build/tools && cp "$(command -v rg)" /build/tools/rg
        fi

        echo "--- release version check ---"
        scripts/check-release-version.sh || exit 1

        echo "--- public and portability boundary check ---"
        scripts/check-public-boundary.sh || exit 1

        echo "--- building test graph ---"
        swift build --build-tests --scratch-path /build || exit 1

        total_ran=0
        total_failed=0
        bad=0
        report=""

        count_from() {
            grep -E "Executed [0-9]+ tests?, with [0-9]+ failure" "$1" | tail -1
        }

        if [ "$TAPQ_SLIM_MODE" = "one-shot" ]; then
            echo "--- slim suites (one invocation) ---"
            filters=()
            for suite in $TAPQ_SLIM_SUITES; do
                filters+=(--filter "$suite")
            done
            timeout "$TAPQ_SLIM_TIMEOUT" swift test --scratch-path /build "${filters[@]}" \
                2>&1 | tee /tmp/slim-oneshot.log
            rc=${PIPESTATUS[0]}
            line="$(count_from /tmp/slim-oneshot.log)"
            total_ran=$(printf "%s" "$line" | sed -n "s/.*Executed \([0-9]*\) tests\{0,1\}, with.*/\1/p")
            total_failed=$(printf "%s" "$line" | sed -n "s/.*with \([0-9]*\) failure.*/\1/p")
            [ "$rc" -eq 0 ] || bad=1
            [ "$rc" -eq 124 ] && echo "!!! one-shot run TIMED OUT; re-run without --one-shot to find the culprit suite"
        else
            echo "--- slim suites (one process each, up to ${TAPQ_SLIM_ATTEMPTS} attempts) ---"
            wedged=0
            for suite in $TAPQ_SLIM_SUITES; do
                log="/tmp/slim-${suite}.log"
                printf "  %-34s " "$suite"

                # A slow suite gets the generous budget up front; everything
                # else is expected to finish in about a second, so a short first
                # attempt turns a wedge into a cheap retry rather than a stall.
                first_timeout="$TAPQ_SLIM_FAST_TIMEOUT"
                for slow in $TAPQ_SLIM_SLOW_SUITES; do
                    [ "$slow" = "$suite" ] && first_timeout="$TAPQ_SLIM_SLOW_TIMEOUT"
                done

                attempt=1
                retries=""
                while : ; do
                    if [ "$attempt" -eq 1 ]; then
                        budget="$first_timeout"
                    else
                        budget="$TAPQ_SLIM_SLOW_TIMEOUT"
                    fi
                    start=$(date +%s)
                    timeout "$budget" swift test --scratch-path /build --filter "$suite" \
                        > "$log" 2>&1
                    rc=$?
                    elapsed=$(( $(date +%s) - start ))
                    # 124 is the wedge; anything else is a real answer.
                    if [ "$rc" -ne 124 ] || [ "$attempt" -ge "$TAPQ_SLIM_ATTEMPTS" ]; then
                        break
                    fi
                    retries="${retries} wedged@${budget}s"
                    attempt=$(( attempt + 1 ))
                done

                line="$(count_from "$log")"
                n=$(printf "%s" "$line" | sed -n "s/.*Executed \([0-9]*\) tests\{0,1\}, with.*/\1/p")
                f=$(printf "%s" "$line" | sed -n "s/.*with \([0-9]*\) failure.*/\1/p")
                n=${n:-0}; f=${f:-0}
                total_ran=$(( total_ran + n ))
                total_failed=$(( total_failed + f ))

                if [ "$rc" -eq 124 ]; then
                    echo "WEDGED (${TAPQ_SLIM_ATTEMPTS} attempts, environmental)"
                    report="${report}\n  WEDGED   ${suite} - stalled on every attempt; verify via CI"
                    wedged=1
                elif [ "$rc" -ne 0 ]; then
                    echo "FAIL (${n} tests, ${f} failed, ${elapsed}s)"
                    report="${report}\n  FAIL     ${suite} (${f} failed)"
                    bad=1
                    echo "    ---- failures in ${suite} ----"
                    grep -E "error:|XCTAssert.*failed|failed -" "$log" | head -20 | sed "s/^/    /"
                elif [ "$n" -eq 0 ]; then
                    echo "NO TESTS MATCHED (${elapsed}s)"
                    report="${report}\n  NOMATCH  ${suite} - check the suite name"
                    bad=1
                else
                    echo "ok (${n} tests, ${elapsed}s)${retries:+  [retried:${retries}]}"
                fi
            done
            # A wedge is inconclusive, not a failing test. Keep the two apart.
            [ "$bad" -eq 0 ] && [ "$wedged" -eq 1 ] && bad=2
        fi

        echo ""
        if [ -n "$report" ]; then
            echo "--- problem suites ---"
            printf "%b\n" "$report"
        fi
        echo "SLIM_TOTALS ran=${total_ran:-0} failed=${total_failed:-0}"
        exit "$bad"
    ' 2>&1 | tee "$container_log"
container_rc="${PIPESTATUS[0]}"
set -e
container_end=$(date +%s)
container_secs=$((container_end - container_start))

totals="$(grep -E '^SLIM_TOTALS ' "$container_log" | tail -1 || true)"
ran="$(printf '%s' "$totals" | sed -n 's/.*ran=\([0-9]*\).*/\1/p')"
failed="$(printf '%s' "$totals" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"

echo ""
echo "================ slim-check summary ================"
printf 'mode             %s\n'    "$mode"
printf 'host build      %4ds\n'   "$host_secs"
printf 'linux container %4ds\n'   "$container_secs"
printf 'total           %4ds\n'   "$((host_secs + container_secs))"
printf 'suites          %4d\n'    "${#suites[@]}"
printf 'tests run       %4s\n'    "${ran:-?}"
printf 'tests failed    %4s\n'    "${failed:-?}"

if [ "$container_rc" -eq 2 ]; then
    echo "RESULT: INCONCLUSIVE - no test failed, but a suite wedged every attempt."
    echo "        That is this container, not your change. Confirm via CI."
    echo "===================================================="
    exit 2
fi
if [ "$container_rc" -ne 0 ]; then
    echo "RESULT: FAIL"
    echo "===================================================="
    exit 1
fi
echo "RESULT: PASS"
echo "===================================================="
