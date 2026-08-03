# TapQ Milestone One — Implementation Plan (Wearer-Speech Detection + VoiceBackend Contract)

*Authored by the Fable 5 planning agent, reviewed and approved by the orchestrator, 2026-08-03.*
*Branch: `worktree-milestone1-wearer-voice`, based on `origin/main` at `373b498`.*

## Orchestrator execution decisions

- **Execution order is strictly sequential: WP1 → WP2 → WP3 → WP4 → WP5 → WP6 → WP7 → WP8 → WP9 → WP10.** This satisfies every declared dependency and the merge-hotspot order (WP2 → WP3 → WP4 → WP9 on `CLICommand.swift` / `TapQCLIApplication.swift`). Do not parallelize: all implementers share this worktree and its `.build` directory.
- Each work package must leave `swift build` and `swift test` green, then be committed on this branch (no push) with message `milestone1 WPn: <short name>`.
- `CHANGELOG.md` and `docs/CLI.md` are touched **only in WP10** to avoid conflicts.
- Ratified judgment calls: WP3's fail-closed mic-capture policy for study tooling; WP5's WearerGatedVoice staying out of the live runtime composition this milestone; `calibration` target `all` expanding to include the wearer-speech profile (WP2).

---

## Codebase findings that shape the plan

- **Portable/macOS split**: `Package.swift` keeps `TapQContracts`, `TapQDetectionBaseline`, `TapQInteractionBaseline`, `TapQContextBaseline`, `TapQCLI` identical on macOS/Linux; everything touching AVFoundation/Speech/CoreMotion lives in the `#if os(macOS)` block (`TapQAudioCaptureBridge`, `TapQAppleAdapters`) or the `tapq` executable. All new analyzers/contracts must stay in the portable half.
- **Language mode is v5** (`.swiftLanguageMode(.v5)` on Swift 6 tools) — strict concurrency is not fully enforced, but the house discipline is `@MainActor` classes with closure callbacks, `Sendable` value types, and generation counters (`sessionGeneration`) to invalidate stale async callbacks. New streaming-audio code must follow that pattern, not actors.
- **Injection seams already exist everywhere needed**: `TapQCLIApplication` takes injected `TapQMotionCapturing`, IO, env, home dir; `VoiceListener` has `VoiceSpeechRecognizing` + `makeAudioSource` test seams; `OpenAILunaQuestionClassifier` has an injected `HTTPSender`; CLI tests drive everything through `FakeCapture` + fake IO (`Tests/TapQCLITests/TapQCLIApplicationTests.swift:79`).
- **Mic plumbing**: `VoiceAudioSource`/`VoiceAudioSourceController` (`Sources/TapQAppleAdapters/VoiceAudioSource.swift`) are `internal` to `TapQAppleAdapters` and already handle route-change invalidation (`AVAudioEngineConfigurationChange`), NSException→NSError conversion via the ObjC bridge, and generation-counted teardown. The capture-study mic co-record must reuse this, not open a second AVAudioEngine path.
- **Calibration is two independent documents** (`gesture-calibration.json`, `tap-calibration.json`) with per-kind load/save/reset in `Sources/TapQCLI/CalibrationProfile.swift`; profile payloads live portably in `Sources/TapQDetectionBaseline/CalibrationProfile.swift`. The third profile follows this exactly.
- **Replay** (`Sources/TapQCLI/CaptureReplay.swift`) is event-based (`ReplayEventLabel`, `ReplayEvaluator` with per-label TP/FN/FP). Wearer speech is *interval-valued*, so it needs a parallel segment evaluator, not a new case in the event enum (unknown labels currently throw `badLabelLine`, so the label reader needs a tolerant partition step).
- **Provider-adapter precedent**: `QuestionClassifierProvider` + `QuestionClassifierFactory` (`Sources/TapQContextBaseline/ResponseQuestionClassifier.swift`) — explicit provider flags, missing API key throws at startup, runtime failures return nil and fall through. `--voice-backend` should mirror this shape.
- **Fail-open reference**: `SpeechGatedVoice` (`Sources/TapQInteractionBaseline/SpeechGatedVoice.swift`) — single-owner `assert` on `activity.onSpeakingChange`, wedged-synthesizer failure mode leaves voice closed but never blocks gesture/tap/timeout resolution. `WearerGatedVoice` mirrors this but in the *pass-through* direction: no signal ⇒ deliver commands unchanged.
- **Clocks**: `HeadMotionSample.timestamp` is CoreMotion's seconds-since-boot. Audio buffers carry `AVAudioTime` host time. Alignment must be anchor-based (capture one `(hostTime, systemUptime)` pair at start, convert via `mach_timebase_info`), packaged as a pure, injectable-constant function so it is unit-testable.

---

## Work packages

Ordering key: **Track A** = wearer-speech detection, **Track B** = capture-study tooling, **Track C** = VoiceBackend contract + adapters.

---

### WP1 — WearerSpeechAnalyzer core (Track A)

**Goal**: A pure, portable analyzer that turns the 25 Hz IMU stream into a wearer-speaking/quiet state signal using a jaw/skull vibration envelope heuristic, patterned on `TapAnalyzer` (pure windowed core) plus a small stateful wrapper (patterned on `MotionGesturePipeline`'s ownership of windows/debounce).

**Files**
- Create `Sources/TapQDetectionBaseline/WearerSpeechConfig.swift` — `Codable`, `Sendable`, `Equatable` config mirroring `TapConfig`: envelope enter/exit thresholds (hysteresis), minimum-duration-to-enter, hangover/hold time, rotation-quiet gate, window length. Tolerant decoding policy per `HeadGestureConfig`.
- Create `Sources/TapQDetectionBaseline/WearerSpeechAnalyzer.swift` — two layers in one file:
  - a pure `analyze(...)` over trailing windows returning an analysis struct with a `Rejection` enum (insufficient samples, below envelope, rotation-not-quiet, too-brief), like `TapAnalysis`;
  - a stateful `WearerSpeechDetector` struct with `mutating func ingest(_ sample: HeadMotionSample) -> WearerSpeechState` (`.speaking`/`.quiet`, plus transition events), owning the differenced-acceleration envelope (jerk proxy — at 25 Hz the speech signature is sustained modest elevation of |Δ userAcceleration| with low rotation, distinguished from taps by duration and from gestures by the rotation gate), hysteresis, and hangover. Must treat magnitude-only samples (`hasPerAxisData == false` is acceptable — envelope can run on `accelerationMagnitude`) and define behavior for timestamp gaps (reset, like `MotionGesturePipeline.reset()`).

**Dependencies**: none.

**Acceptance criteria**
- `Tests/TapQDetectionBaselineTests/WearerSpeechAnalyzerTests.swift` exists with, at minimum: synthetic sustained-vibration stream detected as speaking; resting jitter never detected; a `TapAnalyzer`-shaped single spike rejected (too brief); a nod/shake-shaped stream rejected (rotation gate); hysteresis (mid-band values do not chatter); hangover keeps state through short pauses; timestamp-gap reset; magnitude-only stream still works; config decode tolerance round-trip.
- Doc comments explain the physical rationale (jaw/skull-borne vibration at 25 Hz) the way `TapAnalyzer`'s header does.
- `swift test` green; no new dependencies; file compiles on Linux (no Foundation-macOS APIs).

**Risk notes**: 25 Hz Nyquist is ~12.5 Hz — the "envelope" is a proxy (sample-to-sample jerk), not a real speech band; keep thresholds in config so the capture study can retune. Do not share window state with `MotionGesturePipeline`; the analyzer is a separate consumer of the same samples.

---

### WP2 — Wearer-speech calibration profile + CLI (Track A)

**Goal**: Third calibration profile document with calibrator, store support, and `calibration run/show/reset` coverage, mirroring the gesture/tap pattern exactly.

**Files**
- Create `Sources/TapQDetectionBaseline/WearerSpeechCalibrator.swift` — pure, mirrors `TapCalibrator`: input = resting envelope samples + speaking-phase envelope samples; output = suggested `WearerSpeechConfig` thresholds + an `Assessment` (`isUsable` requires headroom multiple between speaking envelope and resting envelope; absolute floor/ceiling clamps).
- Modify `Sources/TapQDetectionBaseline/CalibrationProfile.swift` — add `TapQWearerSpeechCalibrationProfile` (schemaVersion 1, calibratedAt, config, quality) + `WearerSpeechCalibrationQuality` (resting/speaking sample counts, resting/speaking envelope peaks).
- Modify `Sources/TapQCLI/CalibrationProfile.swift` — `CalibrationProfileKind.wearerSpeech` (raw value `"wearer_speech"`), third URL `wearer-speech-calibration.json`, `loadWearerSpeech()/save(_:)`, `exists/reset/url` coverage.
- Modify `Sources/TapQCLI/CLICommand.swift` — `CalibrationTarget` gains `.wearerSpeech` (CLI spelling `wearer-speech`); `--wearer-speech-profile PATH` on run/show/reset and `--profile` routing; `--speak-seconds N` run option; update usage strings.
- Modify `Sources/TapQCLI/CalibrationTimeline.swift` — a "Speak" stage (instruction: read aloud, head still) appended when target includes wearer speech, with transition stage.
- Modify `Sources/TapQCLI/TapQCLIApplication.swift` — `runCalibrationSession` collects the speak phase and saves/reports the third profile (independent failure text, like tap's); `showCalibration`/`resetCalibration`/`calibrationStore`/help text extended; `CalibrationProfileCollection` gains the third member.

**Dependencies**: WP1 (config type; the calibrator must compute the envelope with the *same* code the detector uses — expose that as an internal static on the analyzer).

**Acceptance criteria**
- New `Tests/TapQDetectionBaselineTests/WearerSpeechCalibratorTests.swift` (usable/unusable separation, clamps, base-config preservation).
- Extended `Tests/TapQCLITests/CalibrationProfileTests.swift` (round-trip, schema rejection, independent reset — resetting wearer-speech never touches gesture/tap), `CLICommandParserTests` (target parsing, `--profile` routing, `--speak-seconds`), `CalibrationTimelineTests` (phase boundaries per target), `TapQCLIApplicationTests` (run with `FakeCapture` streams saves the profile; show/reset text and `--json` output; unusable speak phase fails with the documented message while preserving other saved profiles).
- `tapq calibration show` with all three profiles prints all three blocks; `show --json` for target `all` includes the third key.
- `swift test` green after this package alone (WP1 + WP2 form a shippable unit).

**Risk notes**: `CalibrationTarget.all` now includes wearer speech for run/show/reset (ratified) — call it out in help text. Keep the existing `--profile`-with-`all` rejection message updated for three kinds.

---

### WP3 — Capture-study arm: microphone-envelope co-recording (Track B)

**Goal**: `tapq capture` can co-record a mic-envelope ground-truth label track time-aligned to the IMU stream, written as a sidecar JSONL file. Tooling only; no human protocol.

**Files**
- Modify `Sources/TapQCLI/CLICommand.swift` — `CaptureOptions.micEnvelopePath: String?` via `--mic-envelope PATH` (also honors `--force`); update capture help.
- Create `Sources/TapQCLI/EnvelopeCapture.swift` (new sibling to `MotionCapture.swift`, keeping files small):
  - `TapQAudioEnvelopeCapturing` protocol mirroring `TapQMotionCapturing`: capture with `onSample` callback, start/stop bracketing the motion capture;
  - portable `MicEnvelopeSample` (timestamp in the IMU clock, rms, peak) and `MicEnvelopeTrackMeta` (schema `"tapq-mic-envelope-v1"`, clock `"boottime"`, sampleRate, blockFrames);
  - `EnvelopeSampleFormatter` + `EnvelopeTrackReader` (writer/reader round-trip: meta line first, then sample lines; reader validates schema version) — the reader is consumed by WP4;
  - typed errors (`TapQEnvelopeCaptureError`: unavailable, invalidated(route change), etc.).
- Modify `Sources/TapQCLI/TapQCLIApplication.swift` — `runCapture` starts envelope capture before motion capture and stops after; sidecar written through a second `CaptureFileWriter`. Failure policy: if `--mic-envelope` was requested and the mic cannot start, the command **fails with a clear error before capturing** (a silently missing label track ruins a study session — this is tooling, not runtime input, so fail-closed is correct here); a mid-capture route-change invalidation finishes the IMU capture, reports the truncation on stderr, and exits nonzero.
- Create `Sources/TapQAppleAdapters/MicrophoneEnvelopeSource.swift` — public `@MainActor` class reusing `VoiceAudioSourceController` + `AVAudioEngineVoiceAudioSource` (same module, so `internal` access works): computes per-buffer RMS/peak inside the tap callback (no allocation), forwards `(hostTime, rms, peak)` through an `AsyncStream` (buffering, order-preserving — do **not** spawn a `Task { @MainActor }` per buffer; Task scheduling does not guarantee order) to a MainActor consumer. Includes a pure `AudioClockAnchor` struct: constructed from one `(machHostTime, systemUptime, timebaseNumer/Denom)` anchor, converts buffer host times to the IMU clock; fully unit-testable with injected constants.
- Modify `Executables/tapq/TapQMain.swift` — compose `AppleMicrophoneEnvelopeCapture` (thin executable-level adapter over `MicrophoneEnvelopeSource`, mirroring `AppleHeadphoneMotionCapture`) and pass it to `TapQCLIApplication` (new optional init parameter, default nil).

**Dependencies**: none (but lands after WP2 for CLI-file hotspot ordering).

**Acceptance criteria**
- `Tests/TapQCLITests`: parser tests for `--mic-envelope`; formatter/reader round-trip incl. meta line, schema rejection, bad-line errors; `TapQCLIApplicationTests` with a `FakeEnvelopeCapture` — sidecar written alongside motion output, `--force` semantics, mic-start failure aborts before motion capture, mid-capture invalidation exits nonzero with truncation notice, and capture *without* the flag is byte-identical to today.
- `Tests/TapQAppleAdaptersTests/MicrophoneEnvelopeSourceTests.swift`: RMS/peak math against synthetic `AVAudioPCMBuffer`s (constructible without hardware), `AudioClockAnchor` conversion math, stop is idempotent, route-change invalidation surfaces the typed error. No test opens real audio hardware.
- `swift test` green on macOS; portable targets still build for Linux (`EnvelopeTrackReader` etc. have no AVFoundation imports).

**Risk notes**: This is the package that hits the repo's historical pain. (1) Route changes: the controller's generation-counted invalidation already handles teardown — do not add a second observer; consume the existing `onInvalidation`. (2) OSStatus/NSError: `TapQAudioCaptureEngineStart/Stop` already convert exceptions and errors — check the `NSError` from Stop too (currently ignored in `AVAudioEngineVoiceAudioSource.stop()`; the envelope source should at least log it via diagnostics rather than discard it). (3) Opening the AirPods mic switches Bluetooth to HFP and can degrade the audio route mid-study — document in the capture help text that the **Mac's built-in mic** should be selected as system input for ground-truth recording; smoke-checked in WP10. (4) Tap callback runs on a realtime audio thread: no locks shared with MainActor state; AsyncStream continuation `yield` only.

---

### WP4 — Replay wiring + precision/recall for wearer speech (Track A)

**Goal**: `tapq replay` runs `WearerSpeechDetector` over a capture and reports interval-level precision/recall against ground truth, where truth comes from either explicit `wearer_speech` label segments or a co-recorded envelope sidecar.

**Files**
- Create `Sources/TapQCLI/WearerSpeechReplay.swift`:
  - tolerant label partition: extend label reading so lines whose `label` is `"wearer_speech"` are routed to `[ReplaySpeechSegment]` and all other lines continue through the existing `ReplayLabelReader` path unchanged (keep `ReplayEventLabel` event-only; do not add an enum case);
  - `EnvelopeLabelDeriver` — pure: envelope track → speech truth segments via threshold + hysteresis + min-gap merge (thresholds either from CLI flags or derived from the track's noise floor; keep deterministic and documented);
  - `WearerSpeechReplayRunner` — streams samples through the detector, produces speaking intervals;
  - `SpeechIntervalEvaluator` — frame-level precision/recall/F1 at the IMU sample rate plus onset-latency mean and false-activation count per minute; tolerance parameter reusing replay's `--tolerance` for edge slack.
- Modify `Sources/TapQCLI/CLICommand.swift` — `ReplayOptions` gains `micEnvelopePath: String?` (`--mic-envelope`) and `wearerSpeechProfilePath: String?` (`--wearer-speech-profile`); help text.
- Modify `Sources/TapQCLI/TapQCLIApplication.swift` — `runReplay` loads the wearer-speech profile (default config when absent, matching gesture/tap behavior), resolves truth (labels take precedence over sidecar; both present = labels win with a stderr note), prints a "wearer speech" report section in text and `--json` (keys: `frame_precision`, `frame_recall`, `f1`, `onset_latency_mean_seconds`, `false_activations_per_minute`, `truth_source`).

**Dependencies**: WP1 (detector), WP2 (profile flag), WP3 (`EnvelopeTrackReader`).

**Acceptance criteria**
- New `Tests/TapQCLITests/WearerSpeechReplayTests.swift`: evaluator math on hand-computed cases (perfect overlap, missed segment, spurious activation, edge tolerance); deriver hysteresis/merge; label partition keeps existing event labels working and old label files parsing byte-identically; unknown labels other than `wearer_speech` still throw `badLabelLine`.
- `TapQCLIApplicationTests`/`ReplayCommandParsingTests` extensions: full replay over a synthetic capture with known speaking intervals produces expected metrics in text and JSON; replay without the new flags is output-identical to today.
- One test deliberately offsets the envelope clock and asserts the metric degradation is visible (guards against silent misalignment).
- `swift test` green.

**Risk notes**: keep the event evaluator untouched — its consumed/tolerance semantics are load-bearing for existing gesture benchmarks.

---

### WP5 — WearerGatedVoice composition wrapper (Track A)

**Goal**: A composition-time wrapper mirroring `SpeechGatedVoice` that attributes voice commands to the wearer using the IMU speech signal, failing open in every degraded state. **Not wired into the live runtime this milestone** (same precedent as `swipeDetectionEnabled: false` — live promotion awaits the capture study).

**Files**
- Create `Sources/TapQContracts/WearerSpeech.swift` — `@MainActor public protocol WearerSpeechSignaling: AnyObject`: `var isWearerSpeaking: Bool { get }`, `var isSignalAvailable: Bool { get }` (false = no motion stream / magnitude-only / stale), and single-observer `var onWearerSpeakingChange: (@MainActor (Bool) -> Void)? { get set }` with the same single-owner documentation as `SpeechActivitySignaling`.
- Create `Sources/TapQInteractionBaseline/WearerGatedVoice.swift` — `@MainActor public final class WearerGatedVoice: VoiceCommandProviding`:
  - `init(wrapping:signal:attributionWindow:diagnosticSink:)` with `assert(signal.onWearerSpeakingChange == nil, ...)` exactly like `SpeechGatedVoice.init`'s ownership assertion;
  - delivery policy: pass a matched command through iff the wearer was speaking at any point within the trailing attribution window (default ~2 s, configurable) **or** `isSignalAvailable == false` (fail open — degraded analyzer must reproduce today's shipped behavior verbatim);
  - never opens/closes the inner mic (that is `SpeechGatedVoice`'s job); it only filters delivery, recording `command.rejected_nonwearer` / `command.passed_signal_unavailable` diagnostics;
  - documented stacking order: `WearerGatedVoice(wrapping: rawVoice)` inside, `SpeechGatedVoice` outside (TTS gating owns mic lifecycle; attribution filters what survives).
- Create `Tests/TapQInteractionBaselineTests/WearerGatedVoiceTests.swift`.

**Dependencies**: WP1 conceptually; compiles independently (contracts only).

**Acceptance criteria**
- Tests: pass-through when signal unavailable; pass when wearer spoke within window; reject when wearer silent; window expiry; ownership assertion (mirror `SpeechGatedVoiceTests`'s approach); a wedged signal (never fires) still lets commands through when `isSignalAvailable` is false and blocks nothing else; composition test stacking `SpeechGatedVoice(WearerGatedVoice(inner))` with fake activity + fake signal proving both behaviors compose; start/stop forwarding.
- Test-to-code ratio at house standard (~4:1 — `SpeechGatedVoice` is 67 lines with a full test file; match that density).
- `swift test` green; both new files portable.

**Risk notes**: attribution timing races — a command's transcript match arrives after recognition latency (hundreds of ms), so the attribution window must look *backwards* from delivery time; make the clock injectable (`monotonicNow` closure, per `TapQCLIApplication` precedent) so tests control it.

---

### WP6 — VoiceBackend contract in TapQContracts (Track C)

**Goal**: The slim, duplex-capable `VoiceBackend` protocol with half-duplex as policy; turn arbitration and wearer attribution permanently on TapQ's side.

**Files**
- Create `Sources/TapQContracts/VoiceBackend.swift`:
  - value types: `VoiceAudioFormat` (sampleRate, channels, pcm16), `VoiceAudioChunk` (`Data` + format + timestamp; `Sendable`), `VoiceBackendCapabilities` (`supportsBargeIn: Bool`, `producesAudio: Bool`, `duplex: Bool`), `VoiceBackendEvent` enum (`transcriptPartial(String)`, `transcriptFinal(String)`, `audio(VoiceAudioChunk)`, `responseCompleted`, `sessionFailed(VoiceBackendFailure)`), `VoiceBackendFailure` (typed, `Equatable`, network/protocol/authorization/closed reasons);
  - `@MainActor public protocol VoiceBackend: AnyObject`: `var capabilities: VoiceBackendCapabilities { get }`; `func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws`; `func close()`; **explicit turn control** `func beginUserTurn()`, `func endUserTurn()` (commit — only TapQ calls these; a backend's own VAD must never end a turn, and the doc comment states this as a contract invariant); `func sendAudio(_ chunk: VoiceAudioChunk)`; `func requestResponse(text: String)` (TTS/agent-response path for backends that produce audio); `func cancelResponse()` (barge-in, meaningful only when `supportsBargeIn`).
- Create `Sources/TapQContracts/VoiceBackendSession.swift` — a small pure `VoiceTurnStateMachine` (idle → open → userTurn → committed → responding → open …, with legal-transition checking and typed violations). Adapters use it internally so "TapQ owns turns" is enforced mechanically, and it is the contract's primary test surface.

**Dependencies**: none.

**Acceptance criteria**
- `Tests/TapQContractsTests/VoiceBackendContractTests.swift`: state-machine legality matrix (every illegal transition rejected with the right violation: sendAudio before open, endUserTurn before beginUserTurn, double-begin, requestResponse mid-user-turn under half-duplex policy, cancelResponse without barge-in capability); event/failure `Equatable` semantics; capability defaults.
- Doc comments carry the two non-negotiables: turn arbitration lives on TapQ's side; backend is a dumb speech pipe.
- `swift test` green; zero new imports beyond Foundation.

**Risk notes**: resist adding convenience that pulls policy into the contract (e.g. auto-commit on silence) — that is exactly the backend-VAD hole the design rule forbids. Keep the protocol `@MainActor` + closure events to match `VoiceCommandProviding` idiom rather than introducing `AsyncSequence` requirements the rest of the codebase doesn't use.

---

### WP7 — Apple default VoiceBackend + command-provider adapter (Track C)

**Goal**: Default `VoiceBackend` implementation over the existing Apple stack, plus the portable adapter that turns any `VoiceBackend` into a `VoiceCommandProviding` so it can slot into today's arbiter composition.

**Files**
- Create `Sources/TapQAppleAdapters/AppleVoiceBackend.swift` — `@MainActor public final class` implementing `VoiceBackend`: `beginUserTurn` opens a mic window through `VoiceAudioSourceController` + a fresh `SFSpeechAudioBufferRecognitionRequest` (reusing the `VoiceSpeechRecognizing` seam and generation-counter discipline from `VoiceListener` — factor shared logic only if it stays readable; duplication of ~40 lines is acceptable house style over a premature abstraction); `endUserTurn` calls `request.endAudio()` and finalizes; transcripts stream as `transcriptPartial/Final` events; TTS: `requestResponse(text:)` delegates to an injected `SpeechPresenting` (the shared `SpeechEngine` — never a second `AVSpeechSynthesizer`); `capabilities = (supportsBargeIn: false, producesAudio: false, duplex: false)`; route-change invalidation surfaces as `sessionFailed`.
- Create `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift` — portable `@MainActor final class` implementing `VoiceCommandProviding` over any `VoiceBackend` + `VoiceCommandMatcher`: `start(onCommand:)` opens (if needed) and begins a user turn; each transcript event runs the matcher (cumulative transcripts, matching `VoiceListener.handleRecognition` semantics); on match → end turn, deliver once, teardown window; `stop()` ends turn/closes window; `sessionFailed` → silent teardown (fail open — window resolves by gesture/tap/timeout, per `SpeechGatedVoice`'s documented behavior).

**Dependencies**: WP6.

**Acceptance criteria**
- `Tests/TapQInteractionBaselineTests/VoiceBackendCommandProviderTests.swift` with a `ScriptedVoiceBackend` fake: match on partial transcript fires exactly one command and ends the turn; unmatched final transcript delivers nothing; `sessionFailed` mid-window tears down without delivering; stop() is idempotent; a second start() after failure opens a fresh turn; **backend never ends a turn on its own** (fake asserts `endUserTurn` is only ever caller-initiated).
- `Tests/TapQAppleAdaptersTests/AppleVoiceBackendTests.swift` using the existing `FakeRecognizer`/`FakeAudioSource` idioms from `VoiceListenerTests`: lifecycle, stale-generation callbacks ignored, route-change → `sessionFailed`, `requestResponse` reaches the injected `SpeechPresenting`, no recognition task created when recognizer unavailable (open throws typed failure).
- `swift test` green on macOS and portable half on Linux.

**Risk notes**: this must not perturb the shipped `VoiceListener` path — no refactor of `VoiceListener` itself in this package (WP9 keeps `apple` default on the existing composition). Generation counters everywhere a delayed recognizer callback could land after teardown; that is the concurrency bug class this file will attract.

---

### WP8 — OpenAI Realtime adapter + scripted fake server (Track C)

**Goal**: `OpenAIRealtimeVoiceBackend` in manual-turn half-duplex mode (`turn_detection: none`; TapQ commits audio buffers), in a new small portable target, tested entirely against a scripted in-process fake server.

**Files**
- Modify `Package.swift` — new portable target + product `TapQVoiceBackends` (deps: `TapQContracts`), new test target `TapQVoiceBackendsTests`; `TapQCLI` and the `tapq` executable gain the dependency (executable wiring lands in WP9, but declare the target here so Package.swift is touched once).
- Create `Sources/TapQVoiceBackends/RealtimeTransport.swift` — `RealtimeTransporting` protocol (connect, send text frame, receive stream of text frames, close, with typed failures) + `URLSessionWebSocketRealtimeTransport` live implementation guarded so the portable build still compiles where `URLSessionWebSocketTask` is unavailable (`#if canImport(FoundationNetworking)` care; the seam means Linux tests never need the live class).
- Create `Sources/TapQVoiceBackends/RealtimeMessages.swift` — Codable client/server events for the slice used: `session.update` (with `turn_detection: none`, pcm16 formats, model), `input_audio_buffer.append` (base64 pcm16), `input_audio_buffer.commit`, `response.create`, `response.cancel`; server: session.created/updated, transcript deltas/completions, `response.output_audio.delta`, response.completed, error. Defaults (`defaultModel`, `defaultEndpoint`, `defaultTimeout`) as statics, per `OpenAILunaQuestionClassifier`. Version pinned in a doc comment; decoding tolerant of unknown event types (ignore, don't fail the session).
- Create `Sources/TapQVoiceBackends/OpenAIRealtimeVoiceBackend.swift` — implements `VoiceBackend` over a `RealtimeTransporting` (injected; live transport by default): open = connect + configure session (fails typed on timeout/error); `beginUserTurn`/`sendAudio`/`endUserTurn` = buffer/append/commit + `response.create` per manual-turn mode; transcript/audio events mapped to `VoiceBackendEvent`; `capabilities = (supportsBargeIn: true, producesAudio: true, duplex: true)` with half-duplex enforced by TapQ policy, not the adapter; any transport error or server `error` event → `sessionFailed` (never a hang: all awaits bounded by the timeout pattern used in `OpenAILunaQuestionClassifier.classify`). API key only in headers, never logged. Chunk sizes bounded (~100 ms) so no single `sendAudio` stalls the MainActor.
- Create `Sources/TapQVoiceBackends/FailThroughVoiceBackend.swift` — wrapper `VoiceBackend` over (primary, fallback): open tries primary, falls back on typed failure; a mid-session `sessionFailed` from primary tears it down, opens fallback, replays only *state* (re-begins a user turn if one was active) and surfaces a diagnostic; fallback failure surfaces as the wrapper's own `sessionFailed`. This is the fail-open guarantee as code.
- Create `Tests/TapQVoiceBackendsTests/ScriptedRealtimeServer.swift` — an in-process `RealtimeTransporting` that asserts the exact client frame sequence (session.update with `turn_detection: none` first; append/commit ordering; response.create only after commit) and replays scripted server event sequences, including mid-stream disconnects.

**Dependencies**: WP6.

**Acceptance criteria**
- `Tests/TapQVoiceBackendsTests/`: message codec round-trips (incl. base64 audio framing and unknown-field tolerance); handshake failure → typed open error; the manual-turn invariant (fake server asserts no `response.create` before an explicit commit, and that no server VAD event ever ends a client turn); transcript and audio event mapping; error-event and disconnect → `sessionFailed`; `cancelResponse` sends `response.cancel`; `FailThroughVoiceBackendTests` — primary open failure falls back transparently, mid-session failure re-opens fallback with an active turn, both-fail surfaces failure, and zero fallback activity while primary is healthy.
- No test opens a network socket; CI-safe on macOS and Linux.
- `swift test` green; the portable graph builds (verify the `FoundationNetworking` guard compiles).

**Risk notes**: `URLSessionWebSocketTask` on Linux corelibs is historically flaky: the transport seam is the mitigation; do not let any portable test depend on the live transport.

---

### WP9 — `--voice-backend` flag, factory, and runtime composition (Track C, integrative)

**Goal**: `tapq serve --voice-backend apple|openai-realtime` following the `--question-classifier` precedent, with the OpenAI path composed behind fail-through to the Apple stack and the default path byte-for-byte today's behavior.

**Files**
- Create `Sources/TapQVoiceBackends/VoiceBackendProvider.swift` — `VoiceBackendProvider: String, CaseIterable` (`apple`, `openaiRealtime = "openai-realtime"`) + `VoiceBackendFactory.select(provider:openAIAPIKey:diagnosticSink:makeAppleBackend:)` mirroring `QuestionClassifierFactory.select`: explicit `openai-realtime` with missing/empty `OPENAI_API_KEY` **throws at startup** (`VoiceBackendConfigurationError.missingOpenAIAPIKey`, message shaped like the classifier's); returns the FailThrough(OpenAI → Apple) composition. `makeAppleBackend` is a closure so the portable factory never imports AVFoundation.
- Modify `Sources/TapQCLI/CLICommand.swift` — `ServeOptions.voiceBackend: VoiceBackendProvider = .apple`, `--voice-backend` parsing with the exact error-message shape of `--question-classifier`; serve help text (state fail-through and the API-key requirement).
- Modify `Sources/TapQCLI/RuntimeService.swift` — `TapQRuntimeConfiguration.voiceBackend` (default `.apple`); `TapQRuntimeEndpoint.voiceBackendStatus: String?` (nil for default; e.g. `"openai-realtime (fail-through: apple)"`).
- Modify `Sources/TapQCLI/TapQCLIApplication.swift` — plumb option → configuration; print the status line in `runServe`'s onReady block.
- Modify `Executables/tapq/AppleTapQRuntimeService.swift` — composition: when `.apple`, keep the existing `VoiceListener` path **unchanged** (zero risk to shipped behavior); when `.openaiRealtime`, build `AppleVoiceBackend` (sharing the one `SpeechEngine`), run the factory, wrap in `VoiceBackendCommandProvider`, then `SpeechGatedVoice` exactly where `rawVoice` sits today; startup configuration errors abort serve like classifier misconfiguration does.

**Dependencies**: WP6, WP7, WP8 (strictly sequential after all three).

**Acceptance criteria**
- `Tests/TapQCLITests/CLICommandParserTests` + `TapQCLIApplicationTests`: flag parsing incl. rejection message listing valid providers; configuration passes through; serve with a fake runtime service receives the provider; status line rendering.
- `Tests/TapQVoiceBackendsTests/VoiceBackendFactoryTests`: missing-key throws; key present composes FailThrough with Apple fallback; `apple` provider returns the Apple closure's product directly.
- An end-to-end-shaped test at the `VoiceBackendCommandProvider` level: scripted OpenAI transport dies mid-window → command still resolvable through the Apple fake (fail-through proven above the adapter seam).
- `--voice-backend apple` (and flag omitted) leaves every existing serve test output unchanged.
- `swift test` green.

**Risk notes**: the composition happens in the untested executable file (`AppleTapQRuntimeService.swift`) — keep the executable diff to a minimal `if/else` around already-tested components; anything with logic goes in the portable factory where it has tests. Do not let the OpenAI path capture the mic outside listen windows: `VoiceBackendCommandProvider` opening turns only inside `start()` preserves the "mic never always-on" invariant documented on `VoiceListener`.

---

### WP10 — Final verification and human smoke checklist

**Goal**: whole-milestone verification and the handoff artifact for the human.

**Work**
- `swift build` (debug + release) and full `swift test` on macOS; compile-check the portable graph.
- Docs: update `docs/CLI.md` (capture `--mic-envelope`, replay wearer-speech section, calibration `wearer-speech` target, serve `--voice-backend`), `docs/ROADMAP.md` checkbox updates if applicable, `CHANGELOG.md` entry. Verify all help-text strings match parser reality (the repo tests help output — check `CLICommandParserTests`).
- Cross-package consistency pass: naming (`wearer_speech` raw values consistent across profile kind, labels, JSON keys), diagnostic category names, no portable target importing AVFoundation (grep gate).
- Write the manual smoke checklist to `docs/MILESTONE1_SMOKE_CHECKLIST.md` (human + hardware; agents must not attempt):
  1. AirPods connected: `tapq capture --duration 30 --mic-envelope /tmp/env.jsonl -o /tmp/imu.jsonl` while speaking two sentences and staying silent between — verify sidecar timestamps overlay IMU timestamps and speech is visible in the envelope.
  2. Repeat with system input set to AirPods mic — confirm the documented HFP-degradation warning story and that route behavior matches docs.
  3. Mid-capture route change (switch input device) — verify truncation message and nonzero exit.
  4. `tapq calibration run wearer-speech`, then `calibration show`/`show --json`/`reset wearer-speech` — verify third profile lifecycle and that gesture/tap profiles survive the reset.
  5. `tapq replay` on the recorded capture with `--mic-envelope` — sane precision/recall; then with a deliberate silent recording — zero false activations target.
  6. `OPENAI_API_KEY` set: `tapq serve --voice-backend openai-realtime` — status line, a live approval answered by voice; then kill network mid-session — verify fail-through to Apple stack without a stuck window; then unset key — verify startup error message.
  7. Regression: default `tapq serve` voice/gesture approval flow unchanged.

**Dependencies**: all packages.

---

## Genuinely human/hardware-bound (no agent work planned)

- All live recordings, the capture-study protocol itself, calibration sessions, live OpenAI Realtime sessions, and every item in the WP10 smoke checklist.
- Threshold *values* in `WearerSpeechConfig` defaults are provisional until the human capture study; the plan treats them as config, so retuning is a data change, not a code change.
