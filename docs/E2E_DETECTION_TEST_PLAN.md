# End-to-end detection-path test plan

Status: ratified by the orchestrator, 2026-08-09. This document is the authoritative
spec for the `e2e-detection-paths` branch. Implementation agents follow it exactly;
deviations require an explicit note in the commit message explaining why.

## Goal

An automated suite that feeds simulated AirPods IMU sample streams (and transcript
strings for voice) through the **real, fully composed detection-to-decision
pipeline** and asserts on the resulting `Decision` / `SelectionResult` / wire
response. Today, unit tests stop at detector outputs, `tapq replay` stops at
`MotionDetectionResult`, and broker tests start above detection with faked inputs —
no automated test exercises the whole critical path. This suite closes that gap.

Deliberately small: ~10–12 new tests total. Quality and realism of composition over
quantity.

## Non-goals

- **Not** a real-world accuracy validation. Synthetic traces are shaped by
  construction; the capture study remains the accuracy gate for all IMU defaults.
- No live audio, network, or hardware in tests (house rule).
- No changes to runtime behavior except the one seam in D5. Flagless defaults must
  remain byte-identical.

## What exists (verified by exploration; line numbers approximate — re-verify on read)

- Sample type: `Sources/TapQDetectionBaseline/HeadMotionSample.swift` (`MotionVector`,
  per-axis + magnitude fields, `hasPerAxisData`).
- Detectors (all portable, synchronous, timestamp-driven — no clock injection
  needed): `MotionGesturePipeline` (`ingest(_:)` → nod/shake via `GestureAnalyzer`,
  tap via `TapAnalyzer`, roll-tilt via `TiltAnalyzer`, swipe via `SwipeAnalyzer`,
  swipe default **off**). Configs with thresholds: `HeadGestureConfig` (amplitude
  0.30 rad), `TapConfig` (amplitude 0.45 g, rotationQuiet 0.6 rad/s),
  `TiltConfig` (amplitude 0.18 rad), `SwipeConfig`.
- Voice: `VoiceCommandMatcher` (transcript `String` → `VoiceCommand?`; negation
  words make `.yes` unreachable).
- Decision layer: `InputArbiter` (nod→`.allow`, shake→`.deny`, first-wins),
  `SelectionArbiter` (nod→`.select`, tilt→`.next`/`.previous`), `InteractionController`
  (`resolve(_:deadline:requiredConfirmation:)`, clock seam `var now`),
  `SelectionController` (same seam), `RequiredConfirmation.gestureAndVoice` +
  `ResolvedInput` channel provenance, `BrokerServer` (`handle(_ data:)` → response
  bytes; transport is the tiny `BrokerTransport` protocol).
- M2 components (on main): `WearerSpeechDetector`/`WearerSpeechMonitor`
  (synthetic jerk-envelope streams; injectable `monotonicNow`), `WearerGatedVoice`
  (fail-open when signal unavailable, `defaultAttributionWindow` 2.0 s),
  `WearerTurnCoordinator` (injectable `delaySleep`, endpoint delay 0.4 s).
- Existing waveform precedent: `feedNod`/`feedShake`/`feedTap` in
  `Tests/TapQDetectionBaselineTests/MotionGesturePipelineTests.swift`, `feedTilt` in
  `MotionPipelineTiltTests.swift`, `StreamBuilder` in `WearerSpeechMonitorTests.swift`.
- Trace format + replay: `Sources/TapQCLI/MotionCapture.swift`
  (`MotionSampleFormatter`, JSONL `CaptureRecord`) and
  `Sources/TapQCLI/CaptureReplay.swift` (`MotionCaptureReader`, `ReplayEvaluator`,
  `ReplayBackendRunner` — all internal to `TapQCLI`).
- Test clock precedent: `VirtualClock` in
  `Tests/TapQInteractionBaselineTests/InteractionDeadlineTests.swift`.
- Known gap: `InputArbiter` timeout uses raw `Task.sleep` with no seam
  (`Sources/TapQInteractionBaseline/InputArbiter.swift`, ~line 71).

## Ratified decisions

- **D1 — Location.** New test target `TapQDetectionE2ETests` in the portable test
  graph (must build and run on Linux). Depends on `TapQDetectionBaseline`,
  `TapQInteractionBaseline`, `TapQBrokerRuntime`, `TapQContracts`, and
  `@testable import TapQCLI` (for `MotionCaptureReader`/`MotionSampleFormatter` in
  the compatibility test only). If wiring a dedicated target fights
  `scripts/check-public-boundary.sh` or the Package graph disproportionately, fall
  back to placing the suite inside `Tests/TapQCLITests/` under an `E2E` subfolder —
  and say so in the commit message. Do NOT widen any `internal` type to `public`
  for this suite.
- **D2 — Traces are generated in code, not checked in.** A shared
  `TraceGenerators` helper (test-support source in the new target) produces
  deterministic 25 Hz timestamped `[HeadMotionSample]` waveforms parameterized by
  amplitude/duration/axis. No fixture files. One **compatibility test** serializes
  a generated nod trace through `MotionSampleFormatter` JSONL, reads it back with
  `MotionCaptureReader`, asserts sample fidelity, and runs the samples through the
  pipeline to the same detection — proving every generated trace is also
  `tapq replay`-runnable. No `Date.now`/randomness in generators; fully
  deterministic timestamps starting at a fixed epoch.
- **D3 — Composition.** The harness composes the REAL portable stack:
  `MotionGesturePipeline` → a small `PipelineInputAdapter` test shim that conforms
  to the input-providing protocols (`HeadGestureProviding`, `TapCommandProviding`,
  `TiltCommandProviding`, swipe equivalent) by forwarding pipeline callbacks →
  real `InputArbiter`/`SelectionArbiter` → real
  `InteractionController`/`SelectionController` with `VirtualClock` on the `now`
  seam. The shim forwards; it must not filter, debounce, or interpret. Voice enters
  as transcript strings through the real `VoiceCommandMatcher` (wrapped in a
  minimal `VoiceCommandProviding` shim), never as pre-built `VoiceCommand` values,
  so the matcher's grammar is inside the tested path.
- **D4 — At least one wire-to-wire test.** Tier 1 case 1 must go bytes-in →
  bytes-out through a real `BrokerServer` with an in-memory fake transport
  (approval request JSON in, response JSON out, wire protocol v4), with the broker's
  approval closure wired to the real controller+arbiter+pipeline harness. Remaining
  cases may stop at `InteractionController.resolve` / `SelectionController.resolve`
  to stay focused.
- **D5 — InputArbiter timeout seam.** Add an injectable async sleep seam to
  `InputArbiter` (and `SelectionArbiter` if it shares the raw `Task.sleep`
  pattern), following the existing house pattern (`delaySleep`/`idleSleep` in the
  M2 components): default remains `Task.sleep`, runtime behavior unchanged, tests
  inject an instant or controllable sleep. Smallest possible diff.
- **D6 — Margins, not knife edges.** Positive traces at ≥1.5× the relevant
  detection threshold; negative traces ≤0.5× or built to trip a specific analyzer
  rejection reason. Never generate at the margin — the suite must catch gross
  config drift without flakiness.
- **D7 — House test idioms.** Class-level `@MainActor` + `async` test methods
  (Linux-safe; sync `@MainActor` tests do not compile on Linux). Polling via the
  existing `waitUntil`-style helper where needed. `RecordingSink` on
  `TapQDiagnosticSink` for pipeline-internal assertions where useful. No
  `XCTestExpectation` for actor hops.
- **D8 — Docs and changelog.** One `### Added` line under `[Unreleased]` in
  `CHANGELOG.md`. A README-style header comment at the top of the harness file
  explaining what the suite guarantees (wiring/config/logic regressions) and what
  it does not (real-world accuracy — capture study). No other doc changes.

## Test cases

### Tier 1 — core approval loop (WP1)

1. **Nod approves, wire-to-wire.** Broker approval request bytes → harness → nod
   trace ingested → response bytes carry allow. (D4 path.)
2. **Shake denies.** Approval prompt via controller → shake trace → `.deny`.
3. **Selection: tilt, tilt, nod.** Selection prompt with ≥3 options → tilt-right
   trace → `.next`; tilt-right → `.next`; nod → `.select` of the expected index.
   Sequential prompts through `SelectionController`.
4. **gestureAndVoice confirmation.** Approval with
   `RequiredConfirmation.gestureAndVoice`: nod alone must NOT resolve; nod + spoken
   "yes" (transcript through the real matcher) resolves `.allow`. Verify the
   channel-provenance rules exactly as `InteractionConfirmationTests` models them.
5. **Compatibility test** (also WP1): generated trace → JSONL → `MotionCaptureReader`
   → pipeline → same detection as the in-memory run (D2).

### Tier 2 — false-positive rejection (WP2)

6. **Ambient noise never approves.** A sustained mixed-motion noise trace
   (walking-cadence low-amplitude oscillation + slow head turns, all ≤0.5×
   thresholds) fed during an approval window → no input resolves; the controller
   takes its timeout path (verify actual timeout semantics in
   `InteractionController` — assert the exact outcome, and that it is not
   `.allow`).
7. **Rotation-contaminated tap rejected.** A tap-amplitude accel spike with
   concurrent rotation above `rotationQuiet` → `TapAnalyzer` rejects; no tap intent
   reaches the arbiter (assert via diagnostics sink rejection reason + no
   resolution).
8. **Flagless default: swipe stays off.** A clean swipe trace with default pipeline
   config produces no selection movement; the same trace with
   `swipeDetectionEnabled = true` produces `.next`/`.previous` — proving both the
   default-off guarantee and that the trace is a real swipe.

### Tier 3 — M2 wearer/voice paths (WP3)

9. **Wearer-gate trio** (one test, three phases, real `WearerGatedVoice` +
   `WearerSpeechMonitor` fed synthetic jerk envelopes):
   (a) "yes" transcript with wearer-speech IMU envelope inside the attribution
   window → accepted; (b) "yes" with quiet IMU (bystander) → rejected; (c) IMU
   signal unavailable/stale → fail-open accepted.
10. **Turn control: barge-in + endpoint.** Real `WearerTurnCoordinator` driven by a
    real `WearerSpeechMonitor` ingesting a synthetic envelope: speech onset during
    response playback fires `interruptPlayback`; speech end fires `endpoint()`
    after the 0.4 s delay (inject `delaySleep`; assert delay was requested with the
    configured duration).

## Work packages (sequential; commit after each)

- **WP1 — Seam, generators, harness, Tier 1.**
  1. D5 seam in `InputArbiter` (+`SelectionArbiter` if applicable) with existing
     unit tests still green.
  2. New target `TapQDetectionE2ETests` (D1) with `TraceGenerators` (D2) and the
     composition harness (D3).
  3. Tests 1–5.
  Acceptance: new tests green; full `swift build` green; existing suite untouched
  and green in the affected targets; boundary script green.
- **WP2 — Tier 2.** Tests 6–8, reusing generators (extend with noise + swipe
  waveforms). Acceptance: same bar.
- **WP3 — Tier 3 + polish.** Tests 9–10; CHANGELOG line + harness header comment
  (D8); run the FULL test suite and report the total count. Acceptance: full suite
  green.

## Execution rules (binding on all agents)

- Work ONLY in `/Users/finale/tapq-open/.claude/worktrees/e2e-detection-paths`.
  Use absolute paths and `git -C` for every git command; never rely on the shell
  cwd persisting.
- Never pipe build/test output through `tail`/`head` in a way that masks exit
  codes: redirect to a file under the scratchpad and echo `$?` separately, then
  read the file.
- Do not push. Do not touch `VERSION`, `Info.plist`, version constants, or
  `docs/CLI.md`'s version JSON. CHANGELOG: only the one `[Unreleased]` line in WP3.
- Match surrounding code style; comments only for constraints code can't express.
- Commit messages: imperative, concise subject; body explains any deviation from
  this plan; end with the Co-Authored-By line for Claude.
- Verify line numbers by reading files; this plan's references may be stale.
