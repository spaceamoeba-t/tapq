#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "Release version check failed: $*" >&2
    exit 1
}

if [ "$#" -gt 1 ]; then
    echo "Usage: scripts/check-release-version.sh [vVERSION]" >&2
    exit 64
fi

version="$(sed -n '1p' VERSION)"
[ -n "$version" ] || fail "VERSION is empty."
version_line_count="$(awk 'END { print NR + 0 }' VERSION)"
[ "$version_line_count" -eq 1 ] || fail "VERSION must contain exactly one line."

semver_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
if [[ ! "$version" =~ $semver_pattern ]]; then
    fail "VERSION '$version' is not valid SemVer."
fi

plist_value() {
    local key="$1"
    local path="$2"
    awk -v key="$key" '
        index($0, "<key>" key "</key>") {
            if (getline > 0) {
                gsub(/^[[:space:]]*<string>/, "")
                gsub(/<\/string>[[:space:]]*$/, "")
                print
            }
            exit
        }
    ' "$path"
}

marketing_version="${version%%-*}"
marketing_version="${marketing_version%%+*}"

previous_tag=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for candidate in $(git tag --merged HEAD --list 'v*' --sort=-version:refname); do
        if [ "$candidate" != "v$version" ]; then
            previous_tag="$candidate"
            break
        fi
    done
fi

# Accumulated across every bundle checked, so the closing summary names each one. It has
# to exist before the first check_plist call: the script runs under `set -u`.
bundle_summary=""

# Every embedded Info.plist is checked the same way (today only tapq-kernel's). Each plist's
# build number is compared only against ITS OWN path in the previous tag, so a bundle
# introduced after that tag starts wherever it likes.
check_plist() {
    local label="$1"
    local plist_path="$2"
    local plist_marketing_version plist_build_version previous_build_version

    [ -f "$plist_path" ] || fail "$plist_path is missing."
    plist_marketing_version="$(plist_value CFBundleShortVersionString "$plist_path")"
    plist_build_version="$(plist_value CFBundleVersion "$plist_path")"

    [ "$plist_marketing_version" = "$marketing_version" ] || fail \
        "$plist_path CFBundleShortVersionString '$plist_marketing_version' must equal SemVer core '$marketing_version'."
    [[ "$plist_build_version" =~ ^[1-9][0-9]*$ ]] || fail \
        "$plist_path CFBundleVersion '$plist_build_version' must be a positive integer."

    # Monotonicity is skipped, not failed, when this plist did not exist at the previous
    # tag: there is no predecessor to exceed.
    if [ -n "$previous_tag" ] && git cat-file -e "$previous_tag:$plist_path" 2>/dev/null; then
        previous_build_version="$(
            git show "$previous_tag:$plist_path" 2>/dev/null \
                | awk '
                    index($0, "<key>CFBundleVersion</key>") {
                        if (getline > 0) {
                            gsub(/^[[:space:]]*<string>/, "")
                            gsub(/<\/string>[[:space:]]*$/, "")
                            print
                        }
                        exit
                    }
                '
        )"
        [[ "$previous_build_version" =~ ^[1-9][0-9]*$ ]] || fail \
            "could not read a positive CFBundleVersion for $plist_path from $previous_tag."
        if [ "$plist_build_version" -le "$previous_build_version" ]; then
            fail "$plist_path CFBundleVersion '$plist_build_version' must exceed '$previous_build_version' from $previous_tag."
        fi
    fi

    bundle_summary="${bundle_summary:+$bundle_summary, }$label $plist_marketing_version/$plist_build_version"
}

check_plist tapq-kernel Executables/tapq-kernel/Info.plist

changelog_version="$(
    sed -n 's/^## \[\([^]]*\)\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/\1/p' \
        CHANGELOG.md \
        | sed -n '1p'
)"
[ "$changelog_version" = "$version" ] \
    || fail "first dated changelog version '$changelog_version' does not match VERSION '$version'."

release_link="[$version]: https://github.com/spaceamoeba-t/tapq/releases/tag/v$version"
grep -Fqx "$release_link" CHANGELOG.md \
    || fail "CHANGELOG.md is missing the release link for v$version."

requested_tag="${1:-}"
if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    github_tag="${GITHUB_REF_NAME:-}"
    [ -n "$github_tag" ] || fail "GITHUB_REF_TYPE is tag but GITHUB_REF_NAME is empty."
    if [ -n "$requested_tag" ] && [ "$requested_tag" != "$github_tag" ]; then
        fail "requested tag '$requested_tag' does not match GitHub tag '$github_tag'."
    fi
    requested_tag="$github_tag"
fi
if [ -n "$requested_tag" ] && [ "$requested_tag" != "v$version" ]; then
    fail "tag '$requested_tag' does not match VERSION 'v$version'."
fi

echo "Release version checks passed for $version (bundles $bundle_summary)."
