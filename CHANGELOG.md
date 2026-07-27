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
- TapQ-1 stage-1 encoder infrastructure: a versioned feature contract
  (`EncoderFeatureLayout`, 9 channels × 32 samples at 25 Hz), a window builder, a
  `MotionWindowScoring` backend protocol, and an `EncoderMotionPipeline` decision layer
  that converts per-window class scores into the same doubled commands as the heuristic
  pipeline. `CoreMLMotionScorer` runs exported models on Core ML and refuses any model
  whose embedded contract metadata disagrees with the runtime. The deterministic
  heuristics always keep running as the offline fallback.
- `tapq replay`: stream a recorded capture through the detection backends offline.
  With a JSONL label file it reports per-gesture precision/recall and false positives
  per minute, and `--encoder-model` adds a side-by-side TapQ-1 encoder run — the
  evaluation yardstick for the capture study and for backend comparison.
- `tapq serve --encoder-model PATH [--encoder-mode shadow|primary]`: attach a TapQ-1
  model in shadow mode (detections recorded as diagnostics while heuristics keep
  driving events) or promote it to primary (heuristic detections logged for
  comparison). A model that fails to load degrades to heuristics and says so.
- `ml/`: the TapQ-1 training pipeline — LIMU-BERT-style masked-reconstruction
  pretraining, supervised joint-head training with time-warp/rotation/noise
  augmentation, Core ML export that embeds the contract metadata, and a synthetic
  smoke test covering train → export → load with no captured data.

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
