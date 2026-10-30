#!/usr/bin/env bash
# Type-checks test targets on a host with Command Line Tools only, where `swift test`
# cannot run (no XCTest): each target's files are checked in one swiftc invocation
# against the stub XCTest module in scripts/xctest-stub and the modules of a prior
# `swift build --build-system native` (the default build system of Swift 6.4 lays `.build` out
# differently). A pass means "compiles", not "passes"; CI runs the tests.
#
#   scripts/typecheck-tests.sh [TestTarget ...]    (default: every Tests/*Tests)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
    echo "typecheck-tests: macOS only (Linux runs the real tests)." >&2
    exit 2
fi
modules=.build/debug/Modules
if [ ! -d "$modules" ] || [ ! -f .build/debug.yaml ]; then
    echo "typecheck-tests: $modules is missing; run 'swift build --build-system native' first." >&2
    exit 2
fi

sdk="$(xcrun --show-sdk-path)"
# Package.swift: platforms .macOS(.v14), swiftLanguageMode(.v5).
target_triple="$(uname -m)-apple-macosx14.0"
# SwiftPM derives the package name from the checkout directory; `package` symbols need it.
package_name="$(sed -n 's/.*"-package-name","\([^"]*\)".*/\1/p' .build/debug.yaml | head -n 1)"

stub=.build/xctest-stub
# The stub is rebuilt when its source or the compiler changes: another Swift cannot import it.
compiler="$(xcrun swiftc --version 2>&1 | head -n 1)"
if [ ! -f "$stub/XCTest.swiftmodule" ] || [ scripts/xctest-stub/XCTest.swift -nt "$stub/XCTest.swiftmodule" ] \
    || [ "$(cat "$stub/compiler" 2>/dev/null)" != "$compiler" ]; then
    mkdir -p "$stub"
    xcrun swiftc -emit-module -parse-as-library -module-name XCTest -sdk "$sdk" \
        -target "$target_triple" -o "$stub/XCTest.swiftmodule" scripts/xctest-stub/XCTest.swift
    printf '%s\n' "$compiler" > "$stub/compiler"
fi

if [ "$#" -gt 0 ]; then
    targets=("$@")
else
    targets=()
    for directory in Tests/*Tests; do targets+=("$(basename "$directory")"); done
fi

failed=0
for target in "${targets[@]}"; do
    files=()
    while IFS= read -r file; do files+=("$file"); done < <(find "Tests/$target" -name '*.swift' | sort)
    if [ "${#files[@]}" -eq 0 ]; then
        echo "FAIL $target (no Swift files under Tests/$target)"
        failed=1
        continue
    fi
    if output="$(xcrun swiftc -typecheck -parse-as-library -sdk "$sdk" -target "$target_triple" \
        -swift-version 5 -DSWIFT_PACKAGE -DDEBUG -package-name "$package_name" \
        -I "$modules" -I "$stub" \
        -I Sources/TapQAudioCaptureBridge/include \
        -I Tests/TapQAudioCaptureBridgeTestSupport/include \
        -Xcc -fmodule-map-file=.build/debug/TapQAudioCaptureBridge.build/module.modulemap \
        -Xcc -fmodule-map-file=.build/debug/TapQAudioCaptureBridgeTestSupport.build/module.modulemap \
        "${files[@]}" 2>&1)"; then
        echo "PASS $target"
    else
        echo "FAIL $target"
        printf '%s\n' "$output" | grep -E '^[^ ].*error:' | sed 's/^/    /'
        failed=1
    fi
done
exit "$failed"
