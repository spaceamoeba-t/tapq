# Contributing to TapQ

Thank you for helping improve TapQ. Contributions are welcome across the
portable libraries, POSIX runtime, macOS adapters, CLI, tests, and documentation.

By participating, you agree to follow the project’s
[Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through
[SECURITY.md](SECURITY.md), not a public issue.

## Before you start

For a substantial feature, new dependency, protocol change, or public API
change, open an issue first so the design and ownership boundary can be agreed
before implementation. Small fixes and documentation improvements can go
directly to a pull request.

For a bug, include the TapQ version or commit, operating system, CPU
architecture, Swift version, command and error output, affected component, and
minimal reproduction steps. Sanitized `TAPQ_DEBUG=1` output can help when the
problem involves the runtime or an agent integration. Do not post API keys,
Claude settings, complete transcripts, private source code, or unredacted local
paths. Describe feature requests in terms of the use case and desired behavior.

Development requires Swift 6.0 or newer on macOS 14+ or a Swift-supported Linux
distribution. From the repository root, run:

```bash
swift build
swift test
scripts/check-public-boundary.sh
```

Changes to the macOS live runtime should also verify that the headless app can
be assembled:

```bash
scripts/package-runtime-app.sh debug
```

## Choose the owning target

- `TapQContracts` contains shared data types and protocols, not convenience
  implementations.
- Detection, calibration, interaction, and context policy belong in their
  portable baseline targets.
- Unix socket, discovery, and secure filesystem behavior belong in the POSIX
  targets or `TapQBrokerRuntime`.
- CoreMotion, Speech, AVFoundation, and CoreAudio behavior belongs in
  `TapQAppleAdapters`.
- Agent-specific event parsing belongs in that agent’s adapter.
- Command grammar and platform-neutral command behavior belong in `TapQCLI`;
  executables compose concrete platform services.

Public modules must not import or reproduce proprietary product UI, private
product telemetry backends, hosted account or billing code, remote commercial
orchestration, proprietary model assets, or commercial policy. The authenticated
local broker and its lifecycle are public parts of TapQ.

## Make the change reviewable

- Keep the change in the smallest owning target.
- Add or update tests for behavior changes and regressions.
- Use dependency injection at hardware, clock, filesystem, network, and process
  boundaries so tests remain deterministic.
- Do not request microphone, speech, motion, or other system permissions in CI.
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
contribution terms above do not apply. See [TRADEMARKS.md](TRADEMARKS.md).

By submitting a contribution, you represent that you have the right to do so.
Do not submit third-party material unless its compatible license, provenance,
and required attribution are documented. The project does not currently require
a separate contributor license agreement.

## Pull requests

A pull request should explain the problem, the chosen approach, user-visible
effects, and how it was verified. Keep unrelated changes separate. Reviewers may
request changes to preserve the public API, wire compatibility, portability, or
fail-through safety guarantees.
