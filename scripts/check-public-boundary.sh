#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v rg >/dev/null 2>&1; then
    echo "Public boundary check requires ripgrep (rg)." >&2
    exit 127
fi

git_checkout() {
    git -c "safe.directory=$PWD" "$@"
}

if ! git_checkout rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Public boundary check requires a Git checkout with reachable history." >&2
    exit 2
fi

forbidden='WavoLogger|TelemetryRecorder|TelemetryEvent|TelemetryKind|FlightRecorder|RemoteApprovalCoordinator|RemoteHTTPServer|RemotePage|WavoMac|WavoiOS|TapQBrandKit|WavoRemoteKit'
forbidden_imports='^import (WavoCore|WavoAgentBridge|TapQDiagnostics|TapQPrivateContext|TapQLocalBroker|TapQRemoteRuntime|TapQBridgeProtocol)$'
credential_signatures='-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|(AKIA|ASIA)[A-Z0-9]{16}|sk-(proj-)?[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[A-Za-z0-9_-]{35}|sk_live_[A-Za-z0-9]{16,}|https?://[^/:[:space:]]+:[^/@[:space:]]+@'
sensitive_path_pattern='(^|/)(\.claude/|\.codex/|\.agents/|\.env($|\.)|.*\.(key|pem|cer|der|csr|p12|pfx|jks|keystore|mobileprovision|jsonl|log)$|capture[^/]*\.(csv|json)$)'
allowed_environment_example='(^|/)\.env(\.[^/]*)?\.example$'
excluded_scan_path=':(exclude)scripts/check-public-boundary.sh'

check_current_content() {
    local description="$1"
    local pattern="$2"
    local matches
    local status

    set +e
    matches="$(git_checkout grep -l -I -E -e "$pattern" -- . "$excluded_scan_path")"
    status=$?
    set -e

    if [ "$status" -gt 1 ]; then
        echo "Public boundary check failed: unable to scan tracked content." >&2
        exit "$status"
    fi
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$matches"
        echo "Public boundary check failed: $description found in tracked content." >&2
        exit 1
    fi
}

check_historical_content() {
    local commit="$1"
    local description="$2"
    local pattern="$3"
    local matches
    local status

    set +e
    matches="$(git_checkout grep -l -I -E -e "$pattern" "$commit" -- . "$excluded_scan_path")"
    status=$?
    set -e

    if [ "$status" -gt 1 ]; then
        echo "Public boundary check failed: unable to scan commit $commit." >&2
        exit "$status"
    fi
    if [ "$status" -eq 0 ]; then
        printf '%s\n' "$matches"
        echo "Public boundary check failed: $description found in commit $commit." >&2
        exit 1
    fi
}

check_current_content "non-public implementation reference" "$forbidden"
check_current_content "non-public or retired module import" "$forbidden_imports"
check_current_content "credential or private-key signature" "$credential_signatures"

# Wavo was TapQ's internal pre-release codename. Its two migration paths (old broker
# records, old hooks) were deleted with the broker and the hook adapters on 2026-10-08, so
# no runtime reference to it is expected anywhere now.
while IFS= read -r path; do
    echo "Public boundary check failed: unexpected legacy Wavo reference in $path." >&2
    exit 1
done < <(rg -il 'wavo' Sources Executables || true)

tracked_paths="$(git_checkout ls-files)"
sensitive_paths="$(
    printf '%s\n' "$tracked_paths" \
        | rg "$sensitive_path_pattern" \
        | rg -v "$allowed_environment_example" \
        || true
)"
if [ -n "$sensitive_paths" ]; then
    printf '%s\n' "$sensitive_paths"
    echo "Public boundary check failed: sensitive local-state or credential file is tracked." >&2
    exit 1
fi

while IFS= read -r commit; do
    check_historical_content "$commit" \
        "non-public implementation reference" "$forbidden"
    check_historical_content "$commit" \
        "non-public or retired module import" "$forbidden_imports"
    check_historical_content "$commit" \
        "credential or private-key signature" "$credential_signatures"

    sensitive_paths="$(
        git_checkout ls-tree -r --name-only "$commit" \
            | rg "$sensitive_path_pattern" \
            | rg -v "$allowed_environment_example" \
            || true
    )"
    if [ -n "$sensitive_paths" ]; then
        printf '%s\n' "$sensitive_paths"
        echo "Public boundary check failed: sensitive path found in commit $commit." >&2
        exit 1
    fi
done < <(git_checkout rev-list --all)

# The embedded Info.plist carries a tapq.ai identifier: TCC keys the microphone grant on
# it. Unguarded: a plist is text, so both legs can read it.
if ! rg -q '<string>ai\.tapq\.kernel</string>' Executables/tapq-kernel/Info.plist; then
    echo "Public boundary check failed: the kernel bundle ID must use the tapq.ai namespace." >&2
    exit 1
fi

if rg -n 'dev\.tapq' Sources Executables; then
    echo "Public boundary check failed: legacy dev.tapq namespace found." >&2
    exit 1
fi

portable=(
    Sources/TapQKernel
    Sources/TapQKernelClaude
    Sources/TapQKernelCodex
    Sources/TapQOpenAI
    Sources/TapQVoiceIO
    Sources/TapQContracts
    Sources/TapQVoiceBackends
)

# A path that is not there makes `rg` exit 2, which an `if rg …` reads as "no match" — a
# silent pass. Every directory the scans below name must exist.
for directory in "${portable[@]}" Sources/TapQPOSIXSupport; do
    if [ ! -d "$directory" ]; then
        echo "Portability check failed: $directory is listed but does not exist." >&2
        exit 1
    fi
done

# SwiftUI, Combine and Observation are on the list too: a copied view file that reached for
# an `@Published` here would compile on this Mac and fail the Linux leg. `@preconcurrency` is
# allowed for because a moved file can carry it on the import.
if rg -n '^\s*(@preconcurrency )?import (CoreMotion|Speech|AVFoundation|CoreAudio|AppKit|UIKit|SwiftUI|Combine|Observation|Security|ServiceManagement|Darwin|Glibc)$' "${portable[@]}"; then
    echo "Portability check failed: OS framework imported by a portable target." >&2
    exit 1
fi

# The same frameworks behind a `canImport`, which compiles everywhere and is how a
# platform-conditional Apple dependency sneaks into a target that is supposed to have none.
if rg -n 'canImport\((AppKit|SwiftUI|Combine|Security|CoreMotion|Speech|AVFoundation)\)' "${portable[@]}"; then
    echo "Portability check failed: portable target compiles against an Apple framework conditionally." >&2
    exit 1
fi

# Observation by identifier rather than by import. A file copied from a SwiftUI app can
# conform to `ObservableObject` with no import line of its own — the protocol arrives with
# Foundation on Apple platforms and does not exist on Linux at all — so the identifier is
# what has to be refused. Portable types publish change through `onChange` closures.
# The leading `\b` has to be inside the first alternative: there is no word boundary
# before `@`, so `\b(…|@Published|…)` could never match any of the five wrappers and the
# scan was really only looking for `ObservableObject`.
if rg -n '(\bObservableObject|@Published|@StateObject|@ObservedObject|@EnvironmentObject|@Observable)\b' "${portable[@]}"; then
    echo "Portability check failed: Combine/Observation property wrapper in a portable target." >&2
    exit 1
fi

if rg -n '^import TapQAudioIO$' \
    "${portable[@]}" \
    Sources/TapQPOSIXSupport; then
    echo "Portability check failed: portable/POSIX target imports a macOS-only target." >&2
    exit 1
fi

# PlistBuddy is macOS-only, so the structural plist read lives here. Without the microphone
# usage string macOS kills the process the moment it touches the microphone. TapQ asks for
# nothing else: speech-to-text happens at the service.
if [ "$(uname -s)" = "Darwin" ]; then
    if ! /usr/libexec/PlistBuddy -c "Print :NSMicrophoneUsageDescription" \
        Executables/tapq-kernel/Info.plist >/dev/null 2>&1; then
        echo "macOS kernel check failed: NSMicrophoneUsageDescription is missing from Executables/tapq-kernel/Info.plist." >&2
        exit 1
    fi
fi

echo "Public and portability boundary checks passed."
