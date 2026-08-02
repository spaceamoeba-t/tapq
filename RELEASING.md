# Releasing TapQ

TapQ releases are currently source-only GitHub Releases. GitHub's generated source ZIP
and tarball are the only published artifacts; signed application downloads, notarization,
Homebrew, and other distribution channels are intentionally out of scope for now.

## Version model

| Surface | Value for the first beta | Rule |
|---|---:|---|
| `VERSION`, CLI, Git tag, GitHub Release | `0.4.0-beta.1` | Full Semantic Version |
| `CFBundleShortVersionString` | `0.4.0` | Three-component numeric SemVer core |
| `CFBundleVersion` | `4` | Positive integer, increased for every release build |
| Wire protocol | `3` | Independent compatibility version; change only with a protocol change |

`VERSION` is the canonical product version. The release check keeps the compiled CLI,
bundle metadata, CLI documentation, changelog, and an optional tag name synchronized.
Apple documents the separate formats for
[`CFBundleShortVersionString`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
and
[`CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion).

## Repository safeguards

Before releasing, confirm that the repository's `v*` tag ruleset blocks tag updates and
deletions, and that immutable GitHub Releases are enabled. Release tags are signed,
annotated tags. Publishing an immutable Release locks its associated tag and release
assets and creates a release attestation. GitHub still permits edits to the title and
notes, but review every draft before publishing it.

Configure Git to sign tags with the maintainer's GitHub-registered signing key. For an
SSH signing key, the relevant settings are:

```bash
git config gpg.format ssh
git config user.signingkey /path/to/signing-key.pub
git config tag.gpgSign true
git config gpg.ssh.allowedSignersFile /path/to/allowed_signers
```

The allowed-signers file maps the maintainer's commit email to the registered public key,
using OpenSSH's `allowed_signers` format. This lets `git tag -v` verify the signature
locally; GitHub must also report the pushed tag signature as verified.

Never weaken the repository safeguards to repair released source, a tag, or an asset. If
one of those is wrong, correct the source and issue the next version. Title or note-only
corrections may be made without changing the released contents.

## Prepare the release pull request

1. Branch from current `origin/main`.
2. Update `VERSION`, `TapQVersion.current`, the bundle versions, the CLI version example,
   and `CHANGELOG.md`. Increment `CFBundleVersion` even when only the prerelease suffix
   changes.
3. Leave a fresh `Unreleased` section and add a dated section for the candidate.
4. Record user-visible additions, changes, fixes, security notes, and compatibility
   changes. Do not claim a live environment that has not actually been tested.
5. Run the automated release gates:

   ```bash
   scripts/check-release-version.sh
   scripts/check-public-boundary.sh
   swift build -c release
   TAPQ_CODEX_HOOK_EXECUTABLE="$(swift build -c release --show-bin-path)/tapq-codex-hook" swift test
   scripts/package-runtime-app.sh release
   build/TapQRuntime.app/Contents/MacOS/tapq version --json
   codesign --verify --deep --strict --verbose=2 build/TapQRuntime.app
   ```

6. Open the pull request and wait for both required `macos` and `linux` checks.

## Complete the live release gate

Before merging a release-prep pull request, record the exact macOS, hardware/AirPods,
Swift, Claude Code, Codex CLI, TapQ, and wire-protocol versions used. At minimum:

- Start the packaged runtime with voice and calibrated AirPods input, then confirm allow,
  deny, option navigation, selection, and return-to-screen behavior.
- Install the Claude Code adapter in `native` mode and verify a native approval, a final
  response question, and runtime-absent fallback.
- Complete the exit criteria in
  [`docs/CODEX_ADAPTER_MANUAL_TEST_PLAN.md`](docs/CODEX_ADAPTER_MANUAL_TEST_PLAN.md),
  including hook review/trust, supported approval and question paths, and fail-through.
- Confirm no blocker or major defect remains open.

The GitHub Release compatibility section must distinguish automated contract coverage
from authenticated live-client testing. Use this shape:

```text
Compatibility
- macOS / hardware / AirPods tested: ...
- Claude Code tested: ... (native policy)
- Codex CLI tested: ...
- TapQ wire protocol: ...
- Distribution: source only; no prebuilt binaries
```

## Tag and publish

1. Merge only after CI and the live gate pass. Wait for the resulting `main` CI run to
   pass, then fetch `main` and resolve its exact commit.
2. From that exact commit, run the consistency check with the candidate tag, create a
   signed annotated tag, verify it locally, and push only that tag:

   ```bash
   scripts/check-release-version.sh v0.4.0-beta.1
   git tag -s v0.4.0-beta.1 -m "TapQ 0.4.0-beta.1"
   git tag -v v0.4.0-beta.1
   git push origin refs/tags/v0.4.0-beta.1
   ```

3. Wait for the tag's `macos` and `linux` CI jobs to pass. Confirm the remote annotated
   tag dereferences to the tested `main` commit and GitHub reports its signature verified.
4. Create a draft GitHub Release using the reviewed changelog and compatibility notes.
   Mark a prerelease version with `--prerelease`, keep it out of the `latest` slot, verify
   the existing tag, and attach no custom artifacts:

   ```bash
   gh release create v0.4.0-beta.1 \
       --verify-tag \
       --draft \
       --prerelease \
       --latest=false \
       --title "TapQ 0.4.0-beta.1" \
       --notes-file /path/to/reviewed-release-notes.md
   ```

5. Inspect the draft in GitHub. Publishing locks the associated tag and any release
   assets. Publish only when its tag, title, prerelease state, compatibility notes, and
   source-only scope are exact.
6. Verify the published Release with `gh release verify v0.4.0-beta.1` and confirm the tag
   and generated source archives are visible on the Release page.
