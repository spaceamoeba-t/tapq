# Releasing TapQ

TapQ releases are source-only GitHub Releases. GitHub's generated source ZIP and tarball
are the only published artifacts; signed downloads, notarization, Homebrew, and other
distribution channels are out of scope for now.

## Version model

| Surface | Value today | Rule |
|---|---:|---|
| `VERSION`, Git tag, GitHub Release | `0.6.0-beta.1` | Full Semantic Version |
| `CFBundleShortVersionString` in `Executables/tapq-kernel/Info.plist` | `0.6.0` | The three-component SemVer core of `VERSION`. `tapq-kernel` sends it to Codex as `clientInfo.version` |
| `CFBundleVersion` in the same plist | `1` | A positive integer, increased for every release build |

`VERSION` is the canonical product version. `scripts/check-release-version.sh [vVERSION]`
keeps the plist, the first dated `CHANGELOG.md` section, its release link and an optional
tag name in agreement. Apple documents the formats of
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
2. Update `VERSION`, the plist's two versions and `CHANGELOG.md`. Increment
   `CFBundleVersion` even when only the prerelease suffix changes.
3. Add a dated section for the candidate, and its release link at the end of the file.
4. Record user-visible additions, changes, fixes, security notes, and compatibility
   changes. Do not claim a live environment that has not actually been tested.
5. Run the automated release gates:

   ```bash
   scripts/check-release-version.sh
   scripts/check-public-boundary.sh
   swift build -c release
   swift test
   ```

6. Open the pull request and wait for both required `macos` and `linux` checks.

## Complete the live release gate

Before merging a release-prep pull request, record the exact macOS, Swift, Claude Code,
Codex and TapQ versions used, and the microphone and speaker or headset. With
`tapq-kernel run` on a scratch folder, confirm at least, for each agent:

- an instruction relayed, and its reply spoken; a long one summarized, then "read it all";
- a permission request read aloud, then approved by voice, and another denied;
- a question answered by voice;
- a status asked for while the agent works;
- its conversations listed, switched to, and a new one started;
- a restart that reports the cut-off work and resends nothing.

Confirm no blocker or major defect remains open. The GitHub Release compatibility section
must distinguish automated coverage from live testing. Use this shape:

```text
Compatibility
- macOS / audio setup tested: ...
- Claude Code tested: ...
- Codex CLI tested: ...
- Distribution: source only; no prebuilt binaries
```

## Tag and publish

1. Merge only after CI and the live gate pass. Wait for the resulting `main` CI run to
   pass, then fetch `main` and resolve its exact commit.
2. From that exact commit, run the consistency check with the candidate tag, create a
   signed annotated tag, verify it locally, and push only that tag:

   ```bash
   scripts/check-release-version.sh v0.6.0-beta.1
   git tag -s v0.6.0-beta.1 -m "TapQ 0.6.0-beta.1"
   git tag -v v0.6.0-beta.1
   git push origin refs/tags/v0.6.0-beta.1
   ```

3. Wait for the tag's `macos` and `linux` CI jobs to pass. Confirm the remote annotated
   tag dereferences to the tested `main` commit and GitHub reports its signature verified.
4. Create a draft GitHub Release using the reviewed changelog and compatibility notes.
   Mark a prerelease version with `--prerelease`, keep it out of the `latest` slot, verify
   the existing tag, and attach no custom artifacts:

   ```bash
   gh release create v0.6.0-beta.1 \
       --verify-tag \
       --draft \
       --prerelease \
       --latest=false \
       --title "TapQ 0.6.0-beta.1" \
       --notes-file /path/to/reviewed-release-notes.md
   ```

5. Inspect the draft in GitHub. Publishing locks the associated tag and any release
   assets. Publish only when its tag, title, prerelease state, compatibility notes, and
   source-only scope are exact.
6. Verify the published Release with `gh release verify v0.6.0-beta.1` and confirm the tag
   and generated source archives are visible on the Release page.
