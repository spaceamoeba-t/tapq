#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v rg >/dev/null 2>&1; then
    echo "Public boundary check requires ripgrep (rg)." >&2
    exit 127
fi

forbidden='WavoLogger|TelemetryRecorder|TelemetryEvent|TelemetryKind|FlightRecorder|RemoteApprovalCoordinator|RemoteHTTPServer|RemotePage|WavoMac|WavoiOS|TapQBrandKit|WavoRemoteKit'

if rg -n "$forbidden" Sources Executables; then
    echo "Public boundary check failed: private symbol or module reference found." >&2
    exit 1
fi

if rg -n '^import (WavoCore|WavoAgentBridge|TapQDiagnostics|TapQPrivateContext|TapQLocalBroker|TapQRemoteRuntime|TapQBridgeProtocol)$' Sources Executables; then
    echo "Public boundary check failed: private or retired module import found." >&2
    exit 1
fi

portable=(
    Sources/TapQContracts
    Sources/TapQDetectionBaseline
    Sources/TapQInteractionBaseline
    Sources/TapQContextBaseline
    Sources/TapQWireProtocol
    Sources/TapQClaudeAdapter
    Sources/TapQCLI
)

if rg -n '^import (CoreMotion|Speech|AVFoundation|CoreAudio|AppKit|UIKit|Darwin|Glibc)$' "${portable[@]}"; then
    echo "Portability check failed: OS framework imported by a portable target." >&2
    exit 1
fi

if rg -n '^import TapQAppleAdapters$' \
    "${portable[@]}" \
    Sources/TapQPOSIXBridgeClient \
    Sources/TapQPOSIXSupport \
    Sources/TapQBrokerRuntime; then
    echo "Portability check failed: portable/POSIX target imports Apple adapters." >&2
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
