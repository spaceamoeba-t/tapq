# Voice-route E2E test plan

Simulated-voice end-to-end tests for the interaction stack, in the same spirit as the
simulated-IMU suite: a request enters as wire bytes, an utterance enters as a scripted
transcript, and the assertion reads what left on the wire and what the speech spy heard.

## Why this layer is missing

The E2E target already drives transcripts through the real spoken-command grammar —
`DetectionPathHarness.hear(_:)` feeds `TranscriptVoiceChannel`, which calls
`VoiceCommandMatcher.match` (`Tests/TapQDetectionE2ETests/DetectionPathHarness.swift:306`).
What it bypasses is everything the *production* voice path wraps around that match:

- `VoiceBackendCommandProvider` (turn/session lifecycle, one-shot-per-turn freeform,
  teardown-on-match) — the harness channel restates the freeform rule by hand at
  `DetectionPathHarness.swift:330`, so provider drift would not fail a test.
- Per-utterance wearer attribution — today the only lever is streaming synthetic IMU
  envelopes into a real `WearerSpeechMonitor`, which is coarse and cannot express
  "this utterance, unattributed" cleanly.
- `QuietSpeech` cue-vs-speech routing — the harness speech spy has no decorator slot.
- The voice-only degrade branch (`never_streamed` / `silent_stream`) — the branch lives
  in the macOS-only host and must be restated portably, the way `FilterPath` restates
  `runApproval`.

## Deliverables

All inside `Tests/TapQDetectionE2ETests`. **No `Sources/` file changes.**

### 1. Fakes (harness stage)

- `ScriptedVoiceBackend: VoiceBackend` — test-owned; emits scripted
  `.transcriptPartial` / `.transcriptFinal` events into a REAL
  `VoiceBackendCommandProvider` constructed with `match: VoiceCommandMatcher.match`.
- `ScriptedWearerSignal: WearerSpeechSignaling` — settable `(isWearerSpeaking,
  isSignalAvailable)`; one instance per `WearerGatedVoice`
  (`WearerGatedVoice.swift:49` asserts single subscription).
- `CueRecorder` — captures `NotificationCue` via `QuietSpeech`'s `playCue` closure.

### 2. Harness extensions (harness stage)

Four `DetectionPathHarness` init parameters, **all defaulting to today's composition**
so every existing E2E test passes unmodified:

1. voice channel factory (default: today's `TranscriptVoiceChannel`),
2. speech decorator slot (default: identity over `RecordingSpeech`),
3. attribution script (default: today's `MonitorSpeechSignal` path),
4. motion-availability flag (default: today's behavior).

Plus `hear(_:attributed:)` (delivers a transcript with a scripted per-utterance
verdict) and a provider-mode delivery that emits partial-then-final events. `hear`
after `waitForWindow` — the provider ignores events while its handler is nil
(`VoiceBackendCommandProvider.swift:426,:457`), so an early transcript silently drops.

### 3. Test files (one per track, disjoint)

**`VoiceProviderRouteE2ETests.swift`** — the provider is the subject:
- approval allow and deny wire-to-wire via provider-over-scripted-backend, delivered
  as partial-then-final transcripts;
- freeform fires once per turn, enforced by the PROVIDER (not the channel restatement);
- teardown-on-match ends the turn; "details" / "repeat" keep the window open;
- a transcript delivered before the window opens is dropped (pins the handler-nil
  guard as intended behavior).

**`VoiceAttributionE2ETests.swift`** — per-utterance verdicts:
- the invariant pair in the SAME signal-unavailable state: spoken "yes" still resolves
  the approval (commands fail OPEN) while "tell it to…" is refused (instructions fail
  CLOSED);
- non-wearer variants of both;
- attributed dictation end to end: begin → "Go ahead." → text → read-back → confirm →
  queued → `stop.question` drains it; assert the outbound `BrokerResponse.stopQuestion`
  by decoding wire JSON as `InstructionPathE2ETests` does.

**`VoiceDegradeAndQuietE2ETests.swift`** — degrade + quiet:
- `never_streamed`: harness built with motion unavailable and no `feed()`; window
  opens, `SelectionController` uses `voiceOnlyControlsHint`, `MotionGatedSwipes` is
  ineligible, nothing is cancelled;
- `silent_stream` / `lost_while_streaming`: restate the host order
  (`AppleTapQRuntimeService.swift:597-609`) as a closure — `route(.motionLost)` then
  arbiter cancel — and assert the notice plus the window deferring to screen;
- quiet mode via the decorator slot: an approval prompt plays a cue and speaks
  nothing, "status" then speaks the request in full and a spoken "yes" resolves it;
  a notification plays the flat cue; a dictation read-back is still spoken.

## Ratified rules (binding on every agent)

- **R1** Zero `Sources/` changes. If a change seems required, stop and report the
  deviation instead of making it.
- **R2** Harness defaults preserve today's composition; the full existing suite must
  pass without edits to any existing test.
- **R3** Tests inject transcripts, never pre-parsed intents. The grammar and the
  provider stay real; pass `VoiceCommandMatcher.match` explicitly.
- **R4** Every fake is a `@MainActor final class`. D7 discipline: in `@MainActor`
  XCTestCase classes, test methods AND `setUp`/`tearDown` overrides are `async`
  (`setUp() async throws` + `try await super.setUp()`), or Linux CI fails.
- **R5** Pin routes, not sentences — sentence composition is pinned by the unit suites
  (`VoiceCommandMatcherTests`, `InteractionControllerTests`, `QuietSpeechTests`, …).
  Wire assertions decode JSON, never compare raw strings.
- **R6** Deterministic only: `VirtualClock` / `ManualTimeout`; no real timers, IMU,
  audio, or network. Deliver `hear` only after `waitForWindow` (except the deliberate
  drop test) — a misrouted transcript costs the 20 s watchdog per test.
- **R7** One `ScriptedWearerSignal` per `WearerGatedVoice` instance.
- **R8** Never import macOS-only types (`MotionLossReason`, `AudioCue`,
  `AppleVoiceBackend`, …) — `TapQAppleAdapters` is outside this target's dependency
  graph by design. Restate host ordering the way `FilterPath` does.
- **R9** `scripts/check-release-version.sh` must pass before the final commit.

## Orchestration

Stage 1 (single writer): fakes + harness extensions + proof tests, full suite green.
Stage 2 (three parallel tracks, own worktrees off the stage-1 commit): one test file
each, E2E target green. Stage 3: merge, full suite, D7 sweep, review, push. Branch
`voice-e2e-suite`, stacked on `rung-d-delegation-attention` (PR base = that branch).
