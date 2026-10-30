# Contributing to TapQ

Thank you for helping improve TapQ. Contributions are welcome across the kernel, the
agent delegates, the voice adapters, tests, and documentation.

By participating, you agree to follow the project’s
[Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through
[SECURITY.md](SECURITY.md), not a public issue.

## Before you start

For a substantial feature, new dependency, protocol change, or public API
change, open an issue first so the design and ownership boundary can be agreed
before implementation. Small fixes and documentation improvements can go
directly to a pull request.

For a bug, include the TapQ version or commit, macOS version, CPU architecture,
Swift version, the agent and its version, the command and its output, and minimal
reproduction steps. Sanitized `TAPQ_DEBUG=1` output can help. Do not post API keys,
agent settings, journals, complete transcripts, private source code, or unredacted
local paths. Describe feature requests in terms of the use case and desired behavior.

Development requires Swift 6.0 or newer on macOS 14+ or a Swift-supported Linux
distribution. From the repository root, run:

```bash
swift build
swift test
scripts/check-release-version.sh
scripts/check-public-boundary.sh
```

The boundary check needs [ripgrep](https://github.com/BurntSushi/ripgrep). On a Mac with
only the Command Line Tools, `swift test` has no XCTest to run on; build with
`swift build --build-system native` and use `scripts/typecheck-tests.sh` and
`scripts/host-test.sh <TestTarget> ...` in its place. `scripts/slim-check.sh` runs a fast
subset in a `swift:6.0` container.

## Choose the owning target

- `TapQContracts` holds shared data types and protocols, not convenience implementations.
- `TapQKernel` is the loop, and stays portable: no Apple framework, no network, no
  subprocess. Speech, text models and delegates reach it as protocols, so every rule in it
  can be proven in a test on Linux.
- Everything an agent's wire says belongs in that agent's delegate: `TapQKernelClaude` or
  `TapQKernelCodex`.
- Text-model prompts and their calls belong in `TapQOpenAI`; realtime voice sessions in
  `TapQVoiceBackends` and `TapQVoiceIO`.
- Process control belongs in `TapQPOSIXSupport`; AVFoundation and CoreAudio in
  `TapQAudioIO` and `TapQAudioCaptureBridge`.
- `tapq-kernel` only composes: command line, startup checks, wiring.

Public modules must not import or reproduce proprietary product UI, private product
telemetry backends, hosted account or billing code, remote commercial orchestration,
proprietary model assets, or commercial policy.

## Make the change reviewable

- Keep the change in the smallest owning target.
- Add or update tests for behavior changes and regressions. Every sentence TapQ speaks is
  pinned by a test.
- Use dependency injection at hardware, clock, filesystem, network, and process
  boundaries so tests remain deterministic. Order voice-timing events by what the fakes
  report, never by sleeps.
- Every test method in a `@MainActor` test class must be `async`: Linux's test discovery
  cannot register a synchronous one.
- Do not request microphone or other system permissions in CI.
- Update user documentation for command, configuration, privacy, protocol, or
  compatibility changes.
- Avoid adding third-party dependencies unless the benefit and license impact
  have been discussed.
- Do not commit secrets, raw captures, customer data, complete transcripts,
  private fixtures, or proprietary binaries.

## Contribution license

TapQ source code and documentation are licensed under the
[Apache License 2.0](LICENSE). Unless explicitly stated otherwise, any
contribution intentionally submitted for inclusion in that covered material is
licensed under Apache 2.0, consistent with Section 5 of that license.

Apache 2.0 does not grant rights to use the TapQ name or marks. The logo, icon,
and other artwork in `assets/brand/` are separately copyright-reserved. A brand
asset contribution requires prior written approval and a separate written
copyright or license agreement with the trademark owner; the ordinary
contribution terms above do not apply. Ordinary source-code forks used to
prepare contributions may retain the unmodified bundled assets under the
development-fork exception in [TRADEMARKS.md](TRADEMARKS.md).

By submitting a contribution, you represent that you have the right to do so.
Do not submit third-party material unless its compatible license, provenance,
and required attribution are documented. The project does not currently require
a separate contributor license agreement.

## Pull requests

A pull request should explain the problem, the chosen approach, user-visible
effects, and how it was verified. Keep unrelated changes separate. Reviewers may
request changes to preserve the public API, wire compatibility, portability, or
the guarantee that nothing is approved without the user.
