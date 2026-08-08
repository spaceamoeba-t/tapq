#!/usr/bin/env bash
set -euo pipefail

# Run the portable+POSIX build and test suite inside a Swift 6.0 Linux container.
# Mirrors the linux CI job in .github/workflows/ci.yml.
#
# Requires Docker. When Docker is unavailable the script exits with a clear
# message — push to a worktree-** branch and let GitHub Actions run the Linux
# job instead.

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is not available on this machine." >&2
    echo "Push to a worktree-** branch (or main) and CI will run the Linux job." >&2
    exit 127
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

echo "Starting swift:6.0 container for Linux build+test..."
docker run --rm \
    -v "$repo_root":/src \
    -w /src \
    swift:6.0 \
    bash -c '
        set -euo pipefail
        echo "=== Toolchain ==="
        swift --version
        echo ""
        echo "=== Installing ripgrep ==="
        apt-get update -qq && apt-get install -y -qq ripgrep >/dev/null 2>&1
        echo ""
        echo "=== Release version check ==="
        scripts/check-release-version.sh
        echo ""
        echo "=== Public and portability boundary check ==="
        scripts/check-public-boundary.sh
        echo ""
        echo "=== Build (release) ==="
        swift build -c release
        echo ""
        echo "=== Test ==="
        TAPQ_CODEX_HOOK_EXECUTABLE="$(swift build -c release --show-bin-path)/tapq-codex-hook" swift test
    '
