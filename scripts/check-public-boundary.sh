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

# Wavo was TapQ's internal pre-release codename. Keep its runtime references confined
# to the two migration paths that can discover old broker records and replace old hooks.
while IFS= read -r path; do
    case "$path" in
        Sources/TapQClaudeAdapter/HookInstaller.swift|\
        Sources/TapQPOSIXBridgeClient/BrokerDiscovery.swift)
            ;;
        *)
            echo "Public boundary check failed: unexpected legacy Wavo reference in $path." >&2
            exit 1
            ;;
    esac
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

if ! rg -q '<string>ai\.tapq\.cli</string>' Executables/tapq/Info.plist; then
    echo "Public boundary check failed: the runtime bundle ID must use the tapq.ai namespace." >&2
    exit 1
fi

if rg -n 'dev\.tapq' Sources Executables; then
    echo "Public boundary check failed: legacy dev.tapq namespace found." >&2
    exit 1
fi

portable=(
    Sources/TapQContracts
    Sources/TapQGestureContracts
    Sources/TapQDetectionBaseline
    Sources/TapQCalibrationStore
    Sources/TapQInteractionBaseline
    Sources/TapQContextBaseline
    Sources/TapQWireProtocol
    Sources/TapQClaudeAdapter
    Sources/TapQCodexAdapter
    Sources/TapQOpenCodeAdapter
    Sources/TapQVoiceBackends
    Sources/TapQCLI
)

if rg -n '^import (CoreMotion|Speech|AVFoundation|CoreAudio|AppKit|UIKit|Darwin|Glibc)$' "${portable[@]}"; then
    echo "Portability check failed: OS framework imported by a portable target." >&2
    exit 1
fi

if rg -n '^import (TapQAppleAdapters|TapQGestures)$' \
    "${portable[@]}" \
    Sources/TapQPOSIXBridgeClient \
    Sources/TapQPOSIXSupport \
    Sources/TapQBrokerRuntime; then
    echo "Portability check failed: portable/POSIX target imports Apple adapters." >&2
    exit 1
fi

# The embeddable SDK is gesture-only by contract: no agent/approval domain, no broker or
# wire protocol, no microphone or speech, no UI framework. An app adopting TapQGestures
# must not inherit a microphone permission prompt or an approval model it never asked for.
if rg -n '^import (Speech|AVFoundation|AppKit|UIKit|TapQContracts|TapQInteractionBaseline|TapQContextBaseline|TapQWireProtocol|TapQBrokerRuntime|TapQAppleAdapters|TapQAudioCaptureBridge)$' \
    Sources/TapQGestures; then
    echo "SDK boundary check failed: TapQGestures must stay agent-free and microphone-free." >&2
    exit 1
fi

if [ "$(uname -s)" = "Darwin" ]; then
    plist="Executables/tapq/Info.plist"
    for key in NSMotionUsageDescription NSSpeechRecognitionUsageDescription NSMicrophoneUsageDescription; do
        if ! /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
            echo "macOS runtime check failed: $key is missing from $plist." >&2
            exit 1
        fi
    done
    if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.device.audio-input" \
        Executables/tapq/TapQ.entitlements 2>/dev/null | rg -q '^true$'; then
        echo "macOS runtime check failed: audio-input entitlement is missing." >&2
        exit 1
    fi
fi

echo "Public and portability boundary checks passed."
