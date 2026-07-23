# Changelog

All notable changes to TapQ will be recorded in this file. The project uses
[Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

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
- The macOS runtime now uses the `ai.tapq.cli` bundle identifier associated with
  [tapq.ai](https://tapq.ai). Existing development installs may be asked for Motion,
  Speech Recognition, and Microphone permissions again after rebuilding.
- Documentation now identifies Wavo as TapQ's internal pre-release codename, and the
  brand policy permits ordinary source-code forks used for contributions.

### Security

- Codex installation leaves exact-definition hook trust to Codex. Users must review and
  trust new or changed TapQ command hooks through `/hooks`; TapQ does not bypass or write
  Codex trust state.

The Codex slice does not yet provide strict `PreToolUse`, structured
`request_user_input`, `UserPromptSubmit` steering, or generic notification-hook parity.

[Unreleased]: https://github.com/spaceamoeba-t/tapq/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.1.0
