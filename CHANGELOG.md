# Changelog

All notable changes to TapQ will be recorded in this file. The project uses
[Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

### Changed

- The default voice now prefers a downloaded high-quality Samantha. The generic English
  selection (`en-US`/`en`, including the default) resolves to premium or enhanced
  Samantha when one is installed and only falls back to the compact system pick — Eddy
  on a bare machine — when the user never downloaded a voice. Regional tags (`en-GB`)
  and explicit voice identifiers are never redirected, so a deliberate Eddy pin still
  gets Eddy. A future cloud or custom local TTS provider will slot in ahead of this
  preference; today the chain is downloaded Samantha, then the system default.

## [0.3.0] - 2026-07-29

### Added

- `tapq serve --reasoner off|apple [--reasoner-mode shadow|primary]`: a stage-2 risk
  reasoner that reads the context of a pending approval — tool name, command text,
  working directory, agent, and the summary TapQ speaks — and answers inside the versioned
  `tapq1-decision-v1` contract with a risk tier, a rationale code from a closed set, a
  bounded note, and a confidence. `off` is the default, so gaining the capability never
  gains a reasoner. `shadow` is the mode default and records decisions as diagnostics while
  the confirmation actually demanded stays exactly what deterministic policy set; `primary`
  lets a decision raise the requirement for that request. A reasoner can only ask for
  *more* confirmation — it can never approve, deny, resolve, or weaken a request — so an
  abstention, a confidence below threshold, a timeout, a backend error, and an absent
  model all leave behavior exactly as it is without a reasoner. Every assessment runs under
  a hard 2.25-second wall-clock bound (a 2-second backend budget plus a quarter-second
  backstop), after which the answer is discarded whether or not it arrives. A reasoner that
  cannot be built degrades to no reasoner and reports it rather than refusing to serve.
- Apple Foundation Models as the first reasoner backend, selected with `--reasoner apple`.
  It runs entirely on device, constrains decoding to the contract's own tier and code
  vocabulary, and builds a fresh session per request so one approval's text cannot reach
  the next one's prompt. It requires macOS 26 or newer and a device where Apple
  Intelligence reports the model available; ineligible hardware, Apple Intelligence
  switched off, and assets still downloading are ordinary states that produce no decision
  rather than an error.
- A local shadow-review log at `<broker-dir>/reasoner-log.jsonl`, started whenever a
  reasoner is selected. One JSON line per reasoner-observed approval records the risk tier,
  rationale code, bounded note, confidence or abstention reason, latency, the confirmation
  the decision implied, whether an escalation was actually applied, and what the user then
  decided. Comparing what a decision asked for against what the user did is the only way to
  answer whether `primary` would have been safe. The file is created `0600` inside the
  `0700` runtime directory, is capped at roughly 5 MB with a single rotation to
  `reasoner-log.1.jsonl`, never leaves the machine, and is never read back by TapQ.
- Question fusion: a question routed out of an agent's final response is assessed by the
  same reasoner as a tool approval. Question requests carry the synthetic tool name
  `AgentQuestion` — a value no adapter can produce — so a prompt, a corpus row, and a log
  line all name a question the same way. A question has no command line, no working
  directory, and no detail, so those rows put strictly less in front of the model, and into
  the log, than a `Bash` row does. Multi-option selections are not assessed: a selection
  result is a choice rather than an allow/deny, so there is nothing there for a
  confirmation requirement to raise.
- `tapq bench reasoner --scenarios PATH [--reasoner apple] [--limit N] [--json]`: scores a
  reasoner against a labeled scenario corpus, grading tier as an exact match and rationale
  code as membership in the row's acceptable set, and reporting abstentions, false
  escalation, and p50/p95 latency separately so an always-abstaining reasoner is visible as
  one. The tracked corpus `bench/reasoner-scenarios-v1.ndjson` holds 170 labeled cases
  across destructive, sensitive, routine, and two lookalike slices, with summaries produced
  by the real adapter renderers including their six-word truncation. Unlike `serve`, which
  serves on without a model because a missing reasoner can only mean "no escalation", bench
  fails when the backend is unavailable: a run of abstentions would print as a report and
  read as a result.
- `docs/TAPQ1_STAGE2.md`, the stage-2 design document: what the shipped track measures and
  what it cannot measure on ineligible hardware, the near-term local open-weights backend,
  the continuous-projection track and the paired data it would need, and the go/no-go gates
  in dependency order.
- `ApprovalRequest` carries the request context a reasoner needs to judge an action:
  `toolInput` (the tool's arguments exactly as the agent sent them, holding the full
  command line for `Bash`), `cwd`, `permissionMode`, and `approvalSource`. The broker fills
  them from the hook payload and rejects an approval that names no source. The context
  stays in process — it does not reach diagnostics, the debug sink, or spoken output, and
  both `description` and `debugDescription` are redacted to identifying fields.
- `tapq serve --speech-voice VOICE` and `TAPQ_SPEECH_VOICE` select the voice used for
  spoken output, accepting either a BCP-47 language tag (`en-US`, `zh-CN`) or a macOS
  voice identifier. The environment variable is the practical control for the packaged
  runtime app, which is launched through `open` and takes no flags. A selection that
  matches no installed voice is reported as a `voice.unavailable` warning instead of
  silently falling back; a regional substitution inside the requested language (`en-GB` →
  `en-US`) is accepted, a cross-language one never is, regardless of which way the host's
  AVFoundation happens to fall back. This selects a voice, not a translation: TapQ's spoken
  scaffolding is still English regardless of the value.

### Changed

- `TapQRuntimeServing.serve` takes a `reasonerLoader` parameter alongside the
  configuration, because a loader is a closure while the configuration is portable data. A
  nil loader is not an error: the host reports an unavailable reasoner and serves without
  one. This is a source-breaking change for anything outside this repository that
  implements the protocol, which is why the release is 0.3.0 rather than 0.2.1.
- `JSONValue` and `ApprovalSource` moved from `TapQWireProtocol` to `TapQContracts` so
  `ApprovalRequest` can carry a tool's arguments and its originating hook event with the
  module dependency still running wire → contracts only. `TapQWireProtocol` re-exports both
  declarations, so `import TapQWireProtocol` alone remains sufficient and existing source
  keeps compiling. The encodings are the declarations' own and the bytes are unchanged.
- Auto-mode requests stay exempt from the reasoner. The broker still answers a strict
  `PreToolUse` request whose reported permission mode contains `auto` with allow before an
  `ApprovalRequest` is built, so no such request is assessed, escalated, or logged. This is
  deliberate — it preserves the compatibility shortcut described under strict policy — and
  is worth revisiting once shadow-log field data says what those requests contain.
- Multi-option selection no longer re-teaches its controls on every question. "Volume, then
  nod twice or double-tap." is spoken on the session's first selection and whenever the user
  asks to repeat, and is dropped from every other prompt — the controls do not change
  between questions, and the suffix was a third of the opening utterance. Navigation
  announcements were already terse and are unaffected.
- Spoken output no longer follows the system language. `SpeechEngine` left
  `AVSpeechUtterance.voice` unset, so AVFoundation resolved a voice from the system
  language and never from the text — on a Chinese-language Mac every English prompt was
  read by a Chinese voice, mixing English and Chinese phonology and rendering the readout
  barely intelligible. Synthesis now pins to `en-US` by default, matching the en-US pin
  `VoiceListener.grammarLocale` already applied to recognition.
- `SpeechEngine.voiceIdentifier` is replaced by `SpeechEngine.voiceSelection`, which also
  accepts language tags and is resolved once on assignment rather than per utterance. The
  old property accepted only voice identifiers and no supported configuration path ever
  set it.
- `TapQRuntimeConfiguration` carries `speechVoice`; hosts must apply it to their
  synthesizer.
- The broker wire protocol is unchanged at version 3. Hooks and brokers built against the
  previous release remain compatible with this runtime.

### Security

- The stage-2 reasoner is on-device only in this release. Apple's Foundation Models
  framework runs the assessment locally and no request text — command line, patch text,
  working directory, or spoken summary — is sent anywhere. Selecting a reasoner enables no
  network processing of any kind; cloud processing remains the separate, explicit
  `--question-classifier anthropic|openai` choice.
- A reasoner is shown more than the question classifier is: the complete tool input for the
  request it is judging, rather than assistant reply text alone. All of it stays on the
  machine.
- `reasoner-log.jsonl` is new local state of the same sensitivity class as `broker.json`.
  It omits the full command line, the working directory, and the adapter's detail, but the
  `summary` it records is the text TapQ speaks aloud, and for a `Bash` request that summary
  is the *front* of the command line, which can carry a secret passed as an early argument.
  Deleting the file at any time is safe. See [SECURITY.md](SECURITY.md).

## [0.2.0] - 2026-07-27

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
- `tapq serve --question-classifier auto|apple|anthropic|openai|local`: choose which
  backend classifies questions in a final agent response. Apple Foundation Models and
  OpenAI GPT-5.6 Luna join the existing Claude Haiku option. `auto` never enables cloud
  processing — it uses the on-device Apple model when available and otherwise the
  deterministic local heuristic. Cloud providers require their API key in the runtime
  environment and fall back to the local heuristic when a request fails.

### Changed

- Denying an approval now requires a double shake, so a single head turn can no longer
  deny a request. `HeadGestureConfig` gains `doubleShakeWindowSeconds` and
  `minDoubleShakeGap`; profiles saved before this change still decode and take the
  defaults.
- Response windows are considerably longer: the interaction budget total moved from 105
  to 245 seconds, and the `tapq serve --timeout` default and maximum from 100 to 240,
  keeping the interaction total inside the shim socket and hook timeouts.
- `TiltCommand` cases are now `tiltLeft`/`tiltRight`; the pitch-based
  `tiltUp`/`tiltDown` tilt and its displacement analyzer are retired. Together with the
  new roll-based `TiltAnalyzer.detect` signature, this is a source-breaking change for
  code consuming `TapQContracts` or `TapQDetectionBaseline` as libraries.
- The TapQ-1 encoder backend pairs shake detections the same way the heuristics do, so
  both backends turn the same physical motion into the same command. Replay label
  segments span the complete doubled gesture accordingly: a `shake` segment covers the
  full double shake, as a `nod` segment covers the full double nod.
- The broker wire protocol is unchanged at version 3. Hooks and brokers built against
  the previous release remain compatible with this runtime.

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

[Unreleased]: https://github.com/spaceamoeba-t/tapq/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.3.0
[0.2.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.2.0
[0.1.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.1.0
