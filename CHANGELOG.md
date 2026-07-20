# Changelog

All notable changes to TapQ will be recorded in this file. The project uses
[Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

### Added

- Per-axis headphone motion throughout the portable pipeline: `HeadMotionSample` now
  carries roll attitude and signed 3-axis user acceleration, rotation rate, and gravity
  alongside the existing magnitudes. `tapq capture` writes the new fields in both JSONL
  and CSV; the original five CSV columns keep their positions, and records captured
  before this change still decode.
- Double roll-tilt navigation: two quick same-direction lateral tilts (ear toward
  shoulder) select the next (right) or previous (left) option. Tilt detection is
  roll-dominant with pitch/yaw crosstalk gates and double-tilt pairing, so nods, shakes,
  and single leans never navigate — the structural collisions that forced the original
  pitch-based tilt out of the runtime.
- An experimental motion-swipe analyzer that recognizes sustained gentle drags on the
  earbud or ear from per-axis acceleration, with gravity-referenced up/down direction.
  Disabled by default (`MotionGesturePipeline.swipeDetectionEnabled`) pending capture
  study validation on real AirPods streams.

### Changed

- `TiltCommand` cases are now `tiltLeft`/`tiltRight`; the pitch-based
  `tiltUp`/`tiltDown` tilt and its displacement analyzer are retired.

## [0.1.0] - Unreleased

### Added

- Portable Swift packages for motion detection, calibration, interaction,
  context classification, wire messages, and agent-neutral broker behavior.
- A headless macOS runtime for AirPods motion, voice, and volume input.
- A cross-platform CLI for runtime management, calibration profiles, motion
  capture, Claude Code integration, Codex integration, and version reporting.
- Strict and native Claude Code permission policies with fail-through behavior.
- Explicitly enabled Claude Haiku classification of questions in final agent responses,
  with deterministic local classification as the default.
- A stable Codex lifecycle-hook adapter and `tapq-codex-hook` executable, tested against
  the Codex CLI 0.142.5 hook contract. The initial slice handles native
  `PermissionRequest` approvals for `Bash` and `apply_patch`, plus `Stop` completion and
  final-response questions through `last_assistant_message` with native fail-through.
- `tapq integration codex install`, `status`, and `uninstall` commands for merging TapQ
  hooks into `~/.codex/hooks.json` or `$CODEX_HOME/hooks.json` while preserving unrelated
  entries and backing up existing configuration.
- macOS and Linux CI definitions and public-boundary checks.

### Changed

- Agent identity, runtime presentation, and documentation now distinguish Claude Code
  and Codex requests without changing wire protocol v3.

### Security

- Codex installation leaves exact-definition hook trust to Codex. Users must review and
  trust new or changed TapQ command hooks through `/hooks`; TapQ does not bypass or write
  Codex trust state.

The Codex slice does not yet provide strict `PreToolUse`, structured
`request_user_input`, `UserPromptSubmit` steering, or generic notification-hook parity.

[Unreleased]: https://github.com/spaceamoeba-t/tapq/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.1.0
