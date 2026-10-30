#!/usr/bin/env bash
# Runs test targets on a macOS host with Command Line Tools only, where `swift test` cannot
# (no XCTest): each target is compiled against the recording XCTest shim in
# scripts/host-test/ and linked with the debug objects of a prior
# `swift build --build-system native` (Swift 6.4's default build system lays `.build` out
# differently), then run.
# A pass here means the assertions held on macOS; CI still runs the real XCTest on Linux.
#
#   scripts/host-test.sh TestTarget [TestTarget ...]
#
# Exit status: 0 when every test passed, 1 otherwise. A test that runs 30 s ends its target.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ] || [ "$#" -eq 0 ]; then
    echo "usage (macOS only): scripts/host-test.sh TestTarget [TestTarget ...]" >&2
    exit 2
fi
if [ ! -f .build/debug.yaml ] || [ ! -d .build/debug/Modules ]; then
    echo "host-test: run 'swift build --build-system native' first." >&2
    exit 2
fi

shim=scripts/host-test
out=.build/host-test
mkdir -p "$out"
sdk="$(xcrun --show-sdk-path)"
package_name="$(sed -n 's/.*"-package-name","\([^"]*\)".*/\1/p' .build/debug.yaml | head -n 1)"
# The shim is rebuilt when its source or the compiler changes: another Swift cannot import it.
compiler="$(xcrun swiftc --version 2>&1 | head -n 1)"
if [ ! -f "$out/libXCTest.a" ] || [ "$shim/XCTest.swift" -nt "$out/libXCTest.a" ] \
    || [ "$(cat "$out/compiler" 2>/dev/null)" != "$compiler" ]; then
    xcrun swiftc -swift-version 5 -parse-as-library -emit-module -emit-library -static \
        -module-name XCTest -sdk "$sdk" -emit-module-path "$out/XCTest.swiftmodule" \
        -o "$out/libXCTest.a" "$shim/XCTest.swift"
    printf '%s\n' "$compiler" > "$out/compiler"
fi
swift package describe --type json > "$out/package.json"

failed=0
for target in "$@"; do
    # Line 1: the Swift modules the target depends on directly (each `@testable` imported).
    # Then one "name path" line per target in its dependency closure, to link.
    plan="$(python3 -I - "$out/package.json" "$target" <<'PY'
import json, sys
targets = {t["name"]: t for t in json.load(open(sys.argv[1]))["targets"]}
test = targets[sys.argv[2]]
print(",".join(d for d in test["target_dependencies"] if targets[d]["module_type"] == "SwiftTarget"))
closure, queue = [], list(test["target_dependencies"])
while queue:
    name = queue.pop(0)
    if name not in closure:
        closure.append(name)
        queue += targets[name].get("target_dependencies", [])
for name in closure:
    print(name, targets[name]["path"])
PY
)"
    IFS=',' read -ra modules <<< "$(head -n 1 <<< "$plan")"
    objects=()
    bridge=()
    while read -r name path; do
        # A C target needs its headers and the module map SwiftPM generated for it.
        if [ -f .build/debug/"$name".build/module.modulemap ]; then
            bridge+=(-I "$path/include" -Xcc -fmodule-map-file=.build/debug/"$name".build/module.modulemap)
        fi
        for object in .build/debug/"$name".build/*.o; do
            base="${object##*/}"
            # Objects of deleted sources linger in the build directory; skip them.
            if [[ "$base" == *.swift.o ]] && [ -z "$(find "$path" -name "${base%.o}" | head -n 1)" ]; then
                continue
            fi
            objects+=("$object")
        done
    done < <(tail -n +2 <<< "$plan")

    dir="$out/$target"
    mkdir -p "$dir"
    files=(Tests/"$target"/*.swift)
    python3 -I "$shim/gen.py" "$dir/main.swift" ${modules[@]+"${modules[@]}"} -- "${files[@]}" > /dev/null
    if ! xcrun swiftc -swift-version 5 -Onone -sdk "$sdk" -module-name "$target" \
        -package-name "$package_name" -I .build/debug/Modules -I "$out" -L "$out" -lXCTest \
        ${bridge[@]+"${bridge[@]}"} "${files[@]}" "$dir/main.swift" "${objects[@]}" \
        -o "$dir/tests" > "$dir/build.log" 2>&1; then
        echo "FAIL $target (does not build; $dir/build.log)"
        grep -E 'error:' "$dir/build.log" | head -20
        failed=1
        continue
    fi
    echo "== $target"
    "$dir/tests" || failed=1
done
exit "$failed"
