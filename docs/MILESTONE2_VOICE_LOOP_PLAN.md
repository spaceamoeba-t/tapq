# TapQ Milestone Two — Implementation Plan (Live Voice Loop)

*Authored by the Fable 5 planning agent for orchestrator review, 2026-08-06.*
*Branch: `worktree-milestone2-voice-loop`, based on milestone-1 tip `0fc7474`.*

## Orchestrator decisions (ratified 2026-08-06)

Answers to the open questions in §3; implementers treat these as settled.

1. **WP3 (microphone pump) is in scope.** The confirmed M1 gap — no caller of `sendAudio` on the pipe path — is load-bearing; without WP3, scope items 1/4/5 are unreachable.
2. **Playback and the mic pump ride the existing `--voice-backend openai-realtime` flag.** No new sub-flag; M1's silence on that path was an implementation gap, not a contract.
3. **Conversation policy**: conversation = provider session lifetime with `idleClose` **60 s**; fail-through is sticky for the conversation lifetime, with `resetStickiness()` on idle-close reopen. The `openai-realtime` composition adopts `.conversation` immediately (WP3/WP6).
4. **Free-form plumbing** widens `VoiceCommand`/`InputIntent` with `.freeform(String)`, with **mandatory read-back confirmation**, scoped to selections and multi-option stop questions only. Tool approvals and yes/no stop questions stay binary: spoken free text must never authorize an agent action.
5. **Wire protocol bumps to version 4; the broker accepts {3, 4}**; `outboundVersion` bridges a v4 shim to a v3 broker, mirroring the existing v2 bridge.
6. **Codex free-text**: implement per WP9; the verdict comes from smoke item 4. Documented fallback if Codex re-asks: fail open, nothing worse than today.
7. **No acoustic endpointer this milestone.** Document honestly that `openai-realtime` without `--imu-turn-control` resolves windows by gesture/tap/timeout only; WP3's `onInputLevel` hook stays inert as the door to a future fallback.
8. **Linux proof requires a push, and pushing this branch stays a user decision** (standing repo rule). WP10 lands the triggers and the boundary-list fix only.
9. **Barge-in uses blunt `speech.stopAll()`** — accepted; document that queued cross-session notifications are dropped on barge-in.
10. The §1 framing corrections are acknowledged; where the plan's citations disagree with the original scope wording, the plan wins.
11. Per-WP calls ratified as recommended: idle-close 60 s with a virtual-clock seam; "a turn never spans a TTS-busy interval" must be an explicit test (WP1); the endpoint delay is a coordinator constant (default 0.4 s) with an init override, not a `WearerSpeechConfig` field (WP7).

**Execution**: strictly sequential WP1 → WP11, one Opus implementation agent per WP, one commit per WP; Fable checkpoint reviews after WP4 and WP9. Implementers do not push, do not open PRs, and touch `CHANGELOG.md`/`docs/CLI.md` only in WP11.

**Commit convention for implementers**: one commit per work package, message `milestone2 WPn: <short name>`, each leaving `swift build`, `swift test`, and `scripts/check-public-boundary.sh` green. Execution is strictly sequential (WP1 → … → WP11); all implementers share this worktree and its `.build`. `CHANGELOG.md` and `docs/CLI.md` are touched **only in WP11** to avoid rebase churn.

### Checkpoint A carry-forward (orchestrator, 2026-08-06)

The Checkpoint A review cycle (WP1-4 plus two fix rounds) settled the following; later WPs must honor them:

- **WP6 — conversation adoption seam.** Decision 3's "openai-realtime composition adopts `.conversation` immediately" lands in WP6 (WP3 deferred it — ratified). The provider exposes no idle-close/reopen notification yet, so WP6 must add that seam (e.g. a single-observer `onConversationReopened`) and call `FailThroughVoiceBackend.resetStickiness()` from it, per decision 3 — plus wire `shutdown()` into the serve teardown, the `supportsBargeIn` hint, and `responseAudio` when composing.
- **WP6 — suppress the match-resolved response.** In conversation mode a command match ends the turn via `endWindowKeepSession -> backend.endUserTurn()`, which on the OpenAI path sends `commit + response.create`: a spurious cloud response per voice-resolved window, dropped between windows and cancelled/deferred at the next `start()`. Add a commit-without-response path on the provider for match-resolved windows and cover it with a scripted test.
- **WP7 — session-scoped response tracking.** `_responseInFlight` is session-scoped (set on `.audio` before the handler guard, cleared on `responseCompleted`/`sessionFailed`, and cleared together with `pendingUserTurn` on idle-close/fresh open). The coordinator's `isResponseInFlight` read hook therefore observes responses spanning window boundaries; do not regress the stale-flag clears.
- **WP11 — smoke item.** The `AVAudioPlayerNode` int16-interleaved connect/schedule/completion path was empirically verified on one Mac only; the smoke checklist must confirm playback across output devices and OS versions.
- **Known cosmetics** (non-blocking; fix only if already touching the file): `MicrophonePumpVoiceBackend.openMicrophone`'s `.alreadyRunning` branch leaves a fresh continuation/controller unconsumed (unreachable in practice); after a mic-start failure `turnActive` stays true until the next `endUserTurn`/`close`.


## Design invariants (restated; non-negotiable)

- **Half-duplex with fast interruption.** The backend is a dumb speech pipe. Only TapQ calls `beginUserTurn`/`endUserTurn`; backend VAD must never end a turn (`Sources/TapQContracts/VoiceBackend.swift:150-165` states this as contract; `VoiceTurnStateMachine` enforces it mechanically).
- **Duplex transport, half-duplex policy.** Mic capture during agent playback is architecturally allowed, but this milestone deliberately keeps the microphone and the speaker mutually exclusive (see "Echo strategy" below). Barge-in arbitration is TapQ-side and IMU-driven, so it needs no open microphone at all.
- **Fail-open everywhere at runtime.** A broken IMU signal, dead backend, dropped socket, or unavailable playback device degrades to milestone-1 behavior: the window still resolves by gesture, tap, or timeout; nothing ever blocks or hangs an approval.
- **Default path byte-identical.** `tapq serve` with no new flags behaves exactly as milestone-1 tip: same composition (`Executables/tapq/AppleTapQRuntimeService.swift:131-151` keeps `VoiceListener` for `.apple`), same output, same wire bytes.
- **Every IMU-live feature ships default-off behind explicit flags with provisional thresholds** (`swipeDetectionEnabled: false` precedent) — the human capture study is still pending.
- **House idioms**: `@MainActor` classes + closure callbacks (no actors, no `AsyncSequence` API surface), generation counters for async invalidation, hardware-independent fakes, no live audio/network/hardware/CoreMotion in tests, ~4:1 test-to-code density, portable/macOS `Package.swift` split preserved (portable targets never import AVFoundation/CoreMotion/AppKit; `scripts/check-public-boundary.sh:134-151` is the grep gate).

### Echo strategy (explicit, as required)

No acoustic echo handling is needed in this milestone, and none should be built. The policy that already ships — `SpeechGatedVoice` closes the microphone whenever the speech engine is busy (`Sources/TapQInteractionBaseline/SpeechGatedVoice.swift:50-57`) — is extended to cover backend audio playback via a combined activity signal (WP2). The mic and the speaker are therefore never simultaneously live, so there is nothing to echo-cancel. Barge-in does not weaken this: the barge-in *trigger* is the jaw-vibration IMU signal, which the agent's speaker audio physically cannot reach, so interruption is detected with the mic closed; playback then stops, the activity signal drains, and `SpeechGatedVoice` reopens the mic. The accepted cost is that the first ~0.3–0.5 s of a barge-in utterance (IMU onset latency `minimumSpeakingSeconds` = 0.3 s default, `Sources/TapQDetectionBaseline/WearerSpeechConfig.swift:55`, plus mic-open latency) is not heard; the UX answer is that barge-in stops the agent and the user speaks their answer, it does not attempt to salvage the interrupting syllables. Cheapest adequate answer: strict half-duplex, zero echo code. True duplex-with-AEC would be a future milestone with its own hardware story.

---

## 1. Codebase findings

All verified against this worktree at `0fc7474`. Where the scope framing disagreed with the code, the correction is marked **[correction]**.

### Contract locations **[correction to framing]**
There is no `TapQVoiceCore` target. The VoiceBackend contract lives in `TapQContracts`:
- `Sources/TapQContracts/VoiceBackend.swift` — `VoiceAudioFormat`/`VoiceAudioChunk`/`VoiceBackendCapabilities`/`VoiceBackendEvent`/`VoiceBackendFailure` (lines 8–143), protocol at 169–209.
- `Sources/TapQContracts/VoiceBackendSession.swift` — `VoiceTurnViolation` + `VoiceTurnStateMachine` (states idle/open/userTurn/committed/responding; `cancelResponse` legal only with `supportsBargeIn`, lines 143–151).
- `Sources/TapQContracts/WearerSpeech.swift:16-32` — `WearerSpeechSignaling` (single-observer `onWearerSpeakingChange`; the doc comment at lines 27–31 explicitly anticipates "add a multicast on the implementation if a second consumer … ever needs the signal" — WP5 uses exactly that escape hatch, since M2 has two consumers: attribution and turn control).

### Audio events are discarded; there is no playback path — confirmed
`Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift:97-101`: `case .audio:` records `audio.ignored` and drops the chunk. No `AVAudioPlayerNode` (or any output path) exists anywhere in `Sources/`/`Executables/`; the ObjC bridge (`Sources/TapQAudioCaptureBridge/include/TapQAudioCaptureBridge.h`) exports only capture (`TapQAudioCaptureEngineStart/Stop` with an input-node tap).

### **[correction — the biggest gap in the scope list] Nothing feeds microphone audio into a pipe backend.**
The only caller of `VoiceBackend.sendAudio` in the whole tree is `FailThroughVoiceBackend`'s pass-through (`Sources/TapQVoiceBackends/FailThroughVoiceBackend.swift:132`). `AppleVoiceBackend` owns its own mic (opens it inside `beginUserTurn`, `AppleVoiceBackend.swift:139-193`), but `OpenAIRealtimeVoiceBackend` is a pure pipe — and the live composition (`AppleTapQRuntimeService.swift:135-151`) wraps it in `VoiceBackendCommandProvider` with no microphone pump anywhere. Consequently, on `--voice-backend openai-realtime` today, a turn opens, **zero audio is ever appended**, no user transcript can ever arrive, and voice can only resolve a window if the primary session *fails* and fail-through lands on Apple. Milestone-1 smoke item 6 ("a live approval answered by voice") cannot pass on the primary path as built. M2 must add the mic pump (WP3) or items 1, 4, 5, 6 of the ratified scope are unreachable. Related: `OpenAIRealtimeVoiceBackend.endUserTurn()` (lines 198–216) sends `input_audio_buffer.commit` + `response.create` even for a turn that carried no audio — the server rejects an empty commit, so the empty-turn guard in WP1 matters.

### A second OpenAI-path consequence: no transcripts until commit
The adapter maps only `conversation.item.input_audio_transcription.delta/completed` to transcript events (`Sources/TapQVoiceBackends/RealtimeMessages.swift:256-259`). Under `turn_detection: none`, the service creates the user conversation item — and therefore starts input transcription — only when the buffer is **committed**. So on the OpenAI path there are no mid-turn partials, and the M1 "match on partial transcript" resolution never fires before a commit. Today the only commit is the one buried in teardown (`VoiceBackendCommandProvider.swift:133-145`, after the window is already being torn down). **IMU endpointing (WP7) is therefore not a nicety on the OpenAI path; it is what makes voice resolution possible there at all.** (Apple's recognizer emits partials continuously, so the shipped match-on-partial behavior is unaffected.)

### Where turn end happens today — confirmed, with one addition
`VoiceBackendCommandProvider`: turn ends only in `teardown()` (`:133-145`, `backend.endUserTurn()` at `:139`), reached from (a) a command match (`consume`, `:116-131`), (b) `stop()` (`:62-64`), (c) `sessionFailed` (`:104-110`, which skips the endUserTurn into a dead backend). `stop()` arrives from `InputArbiter.finish` (`Sources/TapQInteractionBaseline/InputArbiter.swift:78-89`) on any resolution/timeout, **and — the addition — from `SpeechGatedVoice.speakingChanged` every time TTS becomes busy** (`SpeechGatedVoice.swift:50-57`). Since every prompt/re-prompt makes TTS busy, the openai provider as composed would open and close a *full WebSocket session per mic reopen*, several times per approval. This churn is the real target of scope item 5 ("per conversation, not per window").

### Fail-through granularity — confirmed per-open
`FailThroughVoiceBackend` fails over exactly once per `open` and retries the primary on every new `open` (`FailThroughVoiceBackend.swift:19-21, 64-97`). Combined with the churn above, a dead network costs a 5 s handshake timeout (`OpenAIRealtimeVoiceBackend.defaultTimeout`) at every mic reopen. Conversation-scoped sessions (WP1) plus a sticky-fallback policy fix both.

### HeadphoneMotionSource fan-out — exact answer to the posed question
`HeadphoneMotionSource` is an **internal** protocol (`Sources/TapQAppleAdapters/HeadphoneMotionSource.swift:13-17`); the production `HeadphoneMotionManagerSource` owns the single `CMHeadphoneMotionManager` (a second manager would contend — doc comments `HeadphoneMotionSource.swift:37-39`, `HeadGestureDetector.swift:5-7`). The sole consumer is `HeadGestureDetector`, which holds the source privately (`HeadGestureDetector.swift:80`) and installs **one** callback per window (`beginMotionUpdates`, `:242-258`). Every live sample flows through exactly one of two branches: `ingest(sample)` in detection mode (`:349-371`, feeding `MotionGesturePipeline` + optional encoder) or `onSample` in capture mode (`:253-254`, used by `startCapture`, `:262-274`). **A second consumer cannot attach at the source level without disturbing the epoch/watchdog machinery; the correct attachment point is a fan-out hook inside `HeadGestureDetector.ingest`** (plus a reset notification from `teardown`/`resetSession`, `:309-338`). Crucially, the motion stream is **per-window**: `InputArbiter.begin` starts the detector, `finish` stops it, so samples flow only while an approval/selection window is open — which is exactly when attribution, endpointing, and barge-in are needed, because `BargeIn.listen` speaks the prompt *concurrently* with the open window (`Sources/TapQInteractionBaseline/BargeIn.swift:13-21`). Between windows the wearer-speech signal is simply stale ⇒ `isSignalAvailable == false` ⇒ fail open, by design.

### WearerGatedVoice / WearerSpeechSignaling — confirmed not live
`WearerSpeechSignaling` has no runtime producer: references exist only in contracts, `WearerGatedVoice`, and tests. `WearerGatedVoice` appears nowhere under `Executables/`. The serve composition root is `Executables/tapq/AppleTapQRuntimeService.swift` (`TapQMain.swift:33` constructs the service; `TapQCLIApplication` takes it injected, `Sources/TapQCLI/TapQCLIApplication.swift:42,68`). The runtime already constructs the calibration store with a wearer-speech URL "purely to satisfy the initializer" (`AppleTapQRuntimeService.swift:35-41`) — WP6 makes it real. Documented stacking order for the gate is already written: `SpeechGatedVoice(wrapping: WearerGatedVoice(wrapping: rawVoice, signal:), activity:)` (`WearerGatedVoice.swift:16-20`).

### Wire protocol and where it is versioned — exact shape
- Version constant: `Sources/TapQWireProtocol/WireMessages.swift:20` (`WireProtocol.version = 3`), with a worked precedent for cross-version bridging: `legacyBridgeVersion = 2` + `outboundVersion(for:approvalSource:)` (`:25-44`) — the *shim* downgrades its outbound version to the peer's, discovered from the broker's discovery record (`Sources/TapQBrokerRuntime/BrokerRuntimeDiscovery.swift:64,100`; read via `Sources/TapQPOSIXBridgeClient/BrokerDiscovery.swift:150`). The broker itself requires an exact match (`BrokerServer.swift:223-225`) and rejects with `error("protocol_version")` (`:227-238`), which shims treat as fail-open.
- Decision path for approvals: broker → `onApproval` → `Decision` (allow/deny/ask only, `Sources/TapQContracts/Decision.swift`) → `BrokerResponse.decision(_, reason:)` (`WireMessages.swift:245-262`); the deny `reason` string already reaches both agents (Claude: `HookShim.swift:95,123`; Codex: `CodexHookShim.swift:314`).
- Selections: broker → `onSelection` → `SelectionResult` (choices + `timedOut`; `timedOut` maps to `error("timeout")`, `BrokerServer.swift:154`) → `BrokerResponse.selection(indices:labels:)` (`WireMessages.swift:275-277`). The Claude shim turns the labels into a PreToolUse deny reason (`HookShim.swift:388-397`); the Codex shim turns them into a `request_user_input` response JSON inside a deny reason (`CodexHookShim.swift:214-245`).
- **Stop questions already carry free text on the wire** (`action: "answer"` + `reply`, `WireMessages.swift:278-284`; consumed at `HookShim.swift:268-276` and `CodexHookShim.swift:483-494`, delivered to the agent as a Stop-block `reason`). What is missing is not wire capability but a *runtime producer* of free text: `StopQuestionCoordinator` only ever emits canned "Yes"/"No"/option-label replies (`Sources/TapQContextBaseline/StopQuestionCoordinator.swift:105,122,126,140-142`). So scope item 6 decomposes into: an interaction-layer free-text capture (WP8), an additive `free_text` field on the *selection* response + shim handling (WP9), and no change at all to the stop-question wire shape.
- Both shims decode replies leniently (`[String: JSONValue]` + `decodeIfPresent`-style reads), so **additive response fields are wire-safe against installed shims**.

### Linux CI **[correction to framing] — it already exists**
`.github/workflows/ci.yml:42-59` has a `linux` job (ubuntu-24.04, `container: swift:6.0`) that builds and tests the portable graph, including the boundary script. It triggers only on push to `main`/tags and on PRs — milestone worktree branches have never run it, which is the true gap. Additionally, `scripts/check-public-boundary.sh:134-143` **omits `Sources/TapQVoiceBackends` from the portable-targets list**, so the M1 target has never been grep-gated against OS imports (it is currently clean: `RealtimeTransport.swift` guards the live WebSocket class with `#if canImport(Darwin)` at `:63` and `FoundationNetworking` at `:2-4`). WP10 fixes the list, adds trigger coverage, and audits the new M2 code.

### Other load-bearing facts
- `OpenAIRealtimeVoiceBackend`: default model `gpt-realtime`, input transcription `gpt-4o-transcribe` (`RealtimeMessages.swift:8,12`); wire format pinned mono 24 kHz PCM16 (`OpenAIRealtimeVoiceBackend.swift:38`, format check rejects anything else at `:183-190`); `capabilities = (bargeIn: true, audio: true, duplex: true)`; ordered outbound pump; `cancelResponse` sends `response.cancel` (`:228-236`).
- `FailThroughVoiceBackend.capabilities` is the conservative **intersection** (`:50-56`) — with Apple (`transcriptOnly`) as fallback, the composed backend reports `producesAudio: false` and `supportsBargeIn: false`. WP2/WP7 must consult the *event stream and the inner call path*, not the composed capabilities, or playback and `cancelResponse` will be judged unavailable. This is a real design wrinkle; resolution proposed in WP2/WP7 and flagged in open questions.
- Activity gating: `SpeechEngine` implements `SpeechActivitySignaling` (busy covers queued + speaking, `SpeechEngine.swift:200-208`); `SpeechGatedVoice` asserts sole ownership of `onSpeakingChange` (`:26-27`); the contract doc invites an implementation-side multicast (`Sources/TapQContracts/Inputs.swift:183-186`).
- Existing fakes to reuse: `ScriptedVoiceBackend` (records call sequence, polices turn protocol, scripts events — `Tests/TapQVoiceBackendsTests/ScriptedVoiceBackend.swift`), `ScriptedRealtimeServer`, `FakeRecognizer`/`FakeAudioSource` idioms (`Tests/TapQAppleAdaptersTests`), `SpeechEngine.synthesisForTesting` seam, injectable `TapQRuntimeServing` for CLI serve tests, synthetic `AVAudioPCMBuffer` construction (`MicrophoneEnvelopeSourceTests`).
- Realtime-audio-thread discipline to copy: `MicrophoneEnvelopeSource` reduces on the tap thread and crosses to MainActor through one ordered buffering `AsyncStream` — never a `Task { @MainActor }` per buffer (`Sources/TapQAppleAdapters/MicrophoneEnvelopeSource.swift:102-124`).
- Budget chain: interaction total 245 s < shim socket 255 s < hook timeout 260 s (`Sources/TapQContracts/InteractionBudget.swift`).
- Wearer-speech detector API for the live producer: `WearerSpeechDetector.ingestDetailed(_:) -> WearerSpeechUpdate` with `transition` (`started_speaking`/`stopped_speaking`), gap-reset built in (`Sources/TapQDetectionBaseline/WearerSpeechAnalyzer.swift:234-360`); provisional defaults: onset 0.3 s, hangover 0.6 s, window 0.6 s, `maxSampleGapSeconds` 0.5 s (`WearerSpeechConfig.swift:51-71`).

---

## 2. Work packages

Ordering key: **Track P** = pipe plumbing (session/audio), **Track I** = IMU-live features, **Track F** = free-form + wire, **Track X** = cross-cutting. Strictly sequential WP1 → WP11; each WP builds only on committed predecessors and leaves the suite green.

---

### WP1 — Conversation-scoped sessions: provider persistence, re-arm, sticky fail-through (Track P)

**Goal**: `VoiceBackendCommandProvider` gains an opt-in *conversation* session policy: the backend session outlives individual `start()`/`stop()` windows (turns are per-window; the session is per-conversation), a matched command re-arms rather than one-shots, and fail-through becomes sticky per conversation. Default construction stays byte-identical to M1.

**Files**
- Modify `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift`:
  - `init` gains `sessionPolicy: SessionPolicy = .perWindow` where `SessionPolicy` is `{ case perWindow; case conversation(idleClose: TimeInterval) }` (portable, `Sendable`, in the same file). `.perWindow` is the existing code path, untouched.
  - `.conversation`: `start()` opens the session once and `beginUserTurn`; `stop()` ends the active turn (only if audio/turn state warrants — see empty-turn guard below) but leaves the session open and arms an idle-close task (injectable `monotonicNow` + task, generation-counted like `windowGeneration`); a match delivers the command, ends the turn, keeps the session; the next `start()` begins a fresh turn on the open session. `sessionFailed` closes and clears state so the next `start()` reopens (fail-open). Add `shutdown()` for host teardown (called where `rawVoice.stop()` sits today in the serve `defer`, `AppleTapQRuntimeService.swift:411-420` — actual call lands with WP6's composition edits; here it only exists and is tested).
  - New provider surface for later WPs (inert until used): `endActiveTurn()` (public; commits the current turn without tearing the window down — transcripts for the committed audio still route to the armed handler), `cancelActiveResponse()` (calls `backend.cancelResponse()` only when a response is in flight and the *inner* pipe supports barge-in — take a `supportsBargeIn: Bool` hint at init rather than reading composed capabilities; see FailThrough intersection wrinkle in findings), and a single-observer `onTranscriptFinal: ((String, _ matched: Bool) -> Void)?` (needed by WP8; fire after match evaluation).
- Modify `Sources/TapQVoiceBackends/OpenAIRealtimeVoiceBackend.swift`: **empty-turn guard** — track appended byte count per turn; `endUserTurn()` with zero appended audio ends the local turn state but sends neither `commit` nor `response.create` (server rejects empty commits; a silent teardown turn must not create spurious responses). Scripted test asserts no frames for an empty turn.
- Modify `Sources/TapQVoiceBackends/FailThroughVoiceBackend.swift`: `init` gains `stickiness: Stickiness = .retryEachOpen` with `.stickyAfterFailure` — once the primary has failed (open-failure or mid-session), subsequent `open`s go straight to the fallback with zero primary traffic; add `func resetStickiness()` so a host can re-probe on a new conversation. Default preserves M1 behavior exactly.

**Dependencies**: none.

**Acceptance criteria**
- All existing `VoiceBackendCommandProviderTests` and `FailThroughVoiceBackendTests` pass unmodified (default-path proof).
- Conversation mode (with `ScriptedVoiceBackend`): one `open` across N `start/stop` cycles; exactly one `beginUserTurn` per `start`; a match delivers once, ends the turn, session stays open; second `start()` yields turn #2 on the same session with a fresh cumulative-transcript slate; idle timer (virtual clock) closes the session after `idleClose` with no window open, and a `start()` after idle-close reopens; `stop()` during the async `open` handshake still closes exactly once (generation test, mirroring the existing `openWindow` guard at `:78-83`); `sessionFailed` mid-conversation → next `start()` reopens; `shutdown()` idempotent.
- `endActiveTurn()`: commits exactly once; a transcript arriving after the commit still matches and resolves; calling it with no active turn is a recorded no-op (never a protocol violation surfaced to the window).
- Sticky fail-through: after primary death, the next `open` touches only the fallback (call-sequence assert); `resetStickiness()` restores primary-first; both-fail still surfaces the wrapper's own `sessionFailed`.
- OpenAI empty-turn guard: scripted server sees no `commit`/`response.create` for an audio-less turn; a normal turn is unchanged.

**Test plan**: extend `Tests/TapQInteractionBaselineTests/VoiceBackendCommandProviderTests.swift`, `Tests/TapQVoiceBackendsTests/FailThroughVoiceBackendTests.swift`, `OpenAIRealtimeVoiceBackendTests.swift`. No new fakes needed; add an idle-clock seam.

**Risks / judgment calls**
- "Conversation" is defined operationally as *provider session lifetime with idle-close* (recommended default `idleClose: 60`). Ratify the number.
- Re-arm changes when `endUserTurn` fires relative to `SpeechGatedVoice` churn; keep the ordering property "turn never spans a TTS-busy interval" as an explicit test.
- Whether `.conversation` should also be adopted for the openai flag path immediately (WP3/WP6 composition) — recommended yes; it is opt-in already.

---

### WP2 — Response-audio playback contract, provider routing, combined activity signal (Track P, portable)

**Goal**: a portable seam for backend `.audio` playback, the provider routing into it, and the activity plumbing that keeps the self-hearing guard airtight when sound comes from something other than `AVSpeechSynthesizer`.

**Files**
- Create `Sources/TapQContracts/VoiceResponseAudio.swift` — `@MainActor public protocol VoiceResponseAudioPlaying: AnyObject`: `func enqueue(_ chunk: VoiceAudioChunk)`, `func finishStream()`, `func stopAndFlush()`, `var isPlaying: Bool { get }`, single-observer `var onPlayingChange: (@MainActor (Bool) -> Void)?` (documented exactly like `SpeechActivitySignaling`, `Inputs.swift:180-187`). Doc invariant: `isPlaying` must become true synchronously on the first `enqueue` — the mic gate must close *before* the first sample can sound.
- Create `Sources/TapQInteractionBaseline/CombinedSpeechActivity.swift` — `public final class CombinedSpeechActivity: SpeechActivitySignaling`: merges the TTS engine's signal and a `VoiceResponseAudioPlaying`'s signal (claims both inner single-observer slots with the house `assert`; exposes one outer slot; `isSpeaking = tts.isSpeaking || playback.isPlaying`). `SpeechGatedVoice` then wraps this with zero changes to itself.
- Modify `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift`: `init` gains `responseAudio: (any VoiceResponseAudioPlaying)? = nil`. `.audio` → `enqueue` when a player is present (else the existing `audio.ignored` diagnostic, byte-identical); `.responseCompleted` → `finishStream()`; teardown/`sessionFailed`/`cancelActiveResponse()` → `stopAndFlush()`. Gate on the *event stream* (an `.audio` event is proof the active pipe produces audio), not on composed capabilities (see FailThrough intersection finding).

**Dependencies**: WP1.

**Acceptance criteria**
- With a `FakePlayback` (new fake in `TapQInteractionBaselineTests`): chunks arrive in order; `finishStream` after `responseCompleted`; `stopAndFlush` on window teardown, on `sessionFailed`, and on `cancelActiveResponse`; without a player, behavior and diagnostics byte-identical to M1 (existing test untouched).
- `CombinedSpeechActivityTests`: truth table over (tts busy, playback busy); exactly one transition per outer change (no duplicate edges); ownership asserts fire on double-claim; composition test `SpeechGatedVoice(over: CombinedSpeechActivity)` proves the mic is held closed while *playback* is busy and reopens on drain — the M2 self-hearing guarantee.
- Portable: both new files import only Foundation + TapQContracts.

**Risks / judgment calls**: none major; the `isPlaying`-synchronous-on-enqueue invariant is the one subtle correctness point and is called out in the contract doc and tests.

---

### WP3 — Microphone pump for pipe backends (Track P, macOS)

**Goal**: close the M1 gap — a macOS `VoiceBackend` wrapper that owns the microphone for a pipe backend: opens the mic on `beginUserTurn`, converts buffers to the pipe's wire format, and streams them through `sendAudio`; closes the mic on `endUserTurn`. Wired into the `openai-realtime` composition so that flag path actually hears the wearer.

**Files**
- Create `Sources/TapQAppleAdapters/MicrophonePumpVoiceBackend.swift` — `@MainActor public final class MicrophonePumpVoiceBackend: VoiceBackend` wrapping `inner: any VoiceBackend` + `format: VoiceAudioFormat` (default `.pcm16Mono24k`):
  - `capabilities`/`open`/`close`/`requestResponse`/`cancelResponse` forward; `beginUserTurn` forwards then opens a fresh `VoiceAudioSourceController` window (`AVAudioEngineVoiceAudioSource`, same module — `internal` access is available, mirroring `MicrophoneEnvelopeSource.swift:98-101`); `endUserTurn` closes the mic then forwards (mic shuts before the commit, matching `AppleVoiceBackend.swift:195-207` ordering).
  - Tap thread → one ordered buffering `AsyncStream` → MainActor consumer → format conversion → `inner.sendAudio` (copy the `MicrophoneEnvelopeSource` crossing pattern verbatim; conversion via `AVAudioConverter` created once per mic window; chunks ≤ 100 ms — the inner adapter re-splits anyway, `OpenAIRealtimeVoiceBackend.swift:433-448`).
  - Route-change invalidation mid-turn → close mic, forward a synthetic session failure path: call `inner.close()` and emit `sessionFailed(.network(...))` through the pump's own event relay (the pump installs itself between `open`'s `onEvent` and the caller), so `FailThroughVoiceBackend` fails over to Apple exactly as for any network death.
  - Optional observer `onInputLevel: ((Double) -> Void)?` (per-buffer RMS, computed in the tap where the samples are already hot) — inert hook for a possible acoustic-silence endpoint fallback (open question 7); costs a few lines now, avoids reopening the realtime-thread code later.
- Modify `Executables/tapq/AppleTapQRuntimeService.swift` (minimal diff at `:135-151`): wrap the factory's realtime primary — composition becomes `FailThrough(primary: MicrophonePump(OpenAI…), fallback: AppleVoiceBackend)`. Achieve this via a new optional `makeRealtimePrimaryDecorator` closure parameter on `VoiceBackendFactory.select` (portable factory stays AVFoundation-free; the executable passes the pump constructor), mirroring the existing `makeAppleBackend` closure pattern (`Sources/TapQVoiceBackends/VoiceBackendProvider.swift:81-95`).

**Dependencies**: WP1 (empty-turn guard makes silent windows safe), WP2 (nothing structural, hotspot ordering only).

**Acceptance criteria**
- `Tests/TapQAppleAdaptersTests/MicrophonePumpVoiceBackendTests.swift` with a fake `VoiceAudioSource` and `ScriptedVoiceBackend` inner: mic opens only inside a user turn and never in `open` (the "never always-on" invariant, `AppleVoiceBackend.swift:20-22`); buffers reach `inner.sendAudio` in order and in the declared format; conversion math validated against synthetic `AVAudioPCMBuffer`s (48 kHz float stereo → 24 kHz int16 mono; sample-count and value spot checks); `endUserTurn` stops the mic before forwarding; route change mid-turn → inner closed + `sessionFailed` surfaced once; stale-generation audio after teardown dropped; stop idempotent. No test opens real audio hardware.
- Factory test (`VoiceBackendFactoryTests`): decorator applied to the primary only; `apple` provider untouched.
- Full-suite green; default serve path untouched (no flag ⇒ no pump constructed).

**Risks / judgment calls**
- This WP changes the observable behavior of the existing `--voice-backend openai-realtime` flag (it starts actually transmitting audio). Recommended: yes, without a new flag — the flag is opt-in and M1's silence was an omission, not a contract. **Needs ratification** (open question 1/2).
- `AVAudioConverter` behavior across route sample-rate changes: recreate the converter if the incoming buffer format differs from the last (assert-free, tested).

---

### WP4 — Backend audio playback engine (Track P, macOS)

**Goal**: the macOS implementation of `VoiceResponseAudioPlaying`: cloud voice output actually heard, exception-safe, fail-open.

**Files**
- Modify `Sources/TapQAudioCaptureBridge/include/TapQAudioCaptureBridge.h` + `TapQAudioCaptureBridge.m`: add `TapQAudioPlaybackEngine` (owns one `AVAudioEngine` + `AVAudioPlayerNode`) and exception-boundary functions `TapQAudioPlaybackEngineStart(engine, sampleRate, channels, error)`, `TapQAudioPlaybackEngineSchedule(engine, buffer, completion)`, `TapQAudioPlaybackEngineStop(engine, error)` — same NSException→NSError conversion contract as the capture functions (header comment parity).
- Create `Sources/TapQAppleAdapters/BackendAudioPlayback.swift` — `@MainActor public final class BackendAudioPlayback: VoiceResponseAudioPlaying`:
  - `enqueue`: converts `VoiceAudioChunk` (PCM16 mono, chunk's declared rate) into an `AVAudioPCMBuffer` (int16 format; the engine's mixer resamples), lazily starts the engine on the first chunk of a response, schedules with a completion that decrements an outstanding-buffer count; `isPlaying` true from first enqueue until (outstanding == 0 && stream finished); engine stopped when drained (no idle audio unit).
  - `stopAndFlush`: stop node, drop queue, `isPlaying` → false, single transition.
  - Any start/schedule failure or `AVAudioEngineConfigurationChange`: drop audio for the rest of the response, emit `playback.unavailable` diagnostic, transition `isPlaying` → false — **fail open**: transcripts and the window are unaffected (the provider keeps consuming events; `CombinedSpeechActivity` just never sees busy).
  - Test seam: `init(scheduler: AudioPlaybackScheduling)` where the internal protocol wraps the three bridge functions; production init uses the live bridge (thin, untested live layer — `SpeechEngine`/`AVAudioEngineVoiceAudioSource` precedent).
- (No composition change yet; WP6 wires the player + combined activity into serve.)

**Dependencies**: WP2 (protocol).

**Acceptance criteria**
- `Tests/TapQAppleAdaptersTests/BackendAudioPlaybackTests.swift` with a fake scheduler: PCM16→`AVAudioPCMBuffer` conversion correctness (values, frame counts, mono); `isPlaying` rises synchronously on first `enqueue`; drains only after `finishStream` + last completion; interleaved responses rejected/serialized deterministically; `stopAndFlush` cancels outstanding schedules and fires exactly one falling edge; scheduler failure → fail-open path with diagnostic, subsequent responses attempt a fresh engine; stale completions after flush ignored (generation counter).
- Bridge compiles with no new warnings; no test emits audible audio (fake scheduler only).

**Risks / judgment calls**: completion-handler threading from `AVAudioPlayerNode` (arrives on an internal queue) — hop via the same ordered pattern as elsewhere and generation-guard; keep every AVFAudio call inside the ObjC boundary.

---

### WP5 — Live wearer-speech signal producer (Track I)

**Goal**: `HeadphoneMotionSource → WearerSpeechAnalyzer/Detector → WearerSpeechSignaling`, live, with multicast for the milestone's two consumers, without perturbing gesture detection.

**Files**
- Create `Sources/TapQDetectionBaseline/WearerSpeechMonitor.swift` (portable): push-driven state holder over `WearerSpeechDetector` — `ingest(_ sample:)`, `streamInterrupted()` (resets detector, marks stale), `state`, `lastSampleAt`, `func isFresh(now:) -> Bool` (staleness horizon default = `config.maxSampleGapSeconds`), transition callback. Injectable `monotonicNow`. This is where all logic lives; the adapter below stays a shim.
- Create `Sources/TapQAppleAdapters/WearerSpeechSignalSource.swift`: `@MainActor public final class WearerSpeechSignalSource` — owns a `WearerSpeechMonitor` (profile config injected), implements the internal sample-tap protocol below, and exposes `func makeSignal() -> any WearerSpeechSignaling` returning independent child handles (each with its own single-observer slot; children read shared state) — the multicast the contract doc anticipates (`WearerSpeech.swift:27-31`). `isSignalAvailable` = tap attached ∧ stream fresh ∧ last sample had per-axis data (`HeadMotionSample.hasPerAxisData`, `HeadMotionSample.swift:96`).
- Modify `Sources/TapQAppleAdapters/HeadGestureDetector.swift`: internal `protocol MotionSampleObserving` `{ ingest(HeadMotionSample); streamInterrupted() }` + `public func setMotionSampleObserver(_:)`; called from `ingest(_:)` (after `:349`'s recovery handling, before pipeline dispatch), and `streamInterrupted()` from `teardown()`/`resetSession()`/`confirmMotionLoss` (`:309-338, 500-517`). No observer ⇒ zero behavior change (guarded single optional call).

**Dependencies**: none structurally (ordered here to keep `HeadGestureDetector` edits clear of Track P).

**Acceptance criteria**
- `Tests/TapQDetectionBaselineTests/WearerSpeechMonitorTests.swift`: synthetic speech stream → transitions mirror `WearerSpeechDetector` tests; staleness flips `isFresh` after the horizon (virtual clock); `streamInterrupted` resets to quiet and stale; magnitude-only stream reports unavailable-for-attribution per policy.
- `Tests/TapQAppleAdaptersTests`: `HeadGestureDetectorTests` extension — observer receives exactly the samples the pipeline ingests, `streamInterrupted` on stop/teardown/motion-loss, **all existing gesture/tap/tilt tests pass unmodified with no observer attached**; `WearerSpeechSignalSourceTests` — two children get independent callbacks for one transition, ownership assert per child slot, availability matrix (no tap / stale / magnitude-only / fresh).
- ~4:1 test density on the monitor (it is the safety-relevant logic).

**Risks / judgment calls**: per-window stream means the monitor sees hard gaps between windows — the built-in gap reset (`WearerSpeechDetector.ingestDetailed`, `WearerSpeechAnalyzer.swift:278-287`) handles it, but the first ~`windowSeconds` of each window is warm-up during which the signal reports quiet; attribution's backward-looking window (`WearerGatedVoice.defaultAttributionWindow` 2 s) absorbs this for the gate; note it for WP7's endpointing (never endpoint during warm-up: require a `startedSpeaking` before honoring a `stoppedSpeaking`).

---

### WP6 — Live wearer gate: `--wearer-gate` flag + serve composition (Track I)

**Goal**: `WearerGatedVoice` live behind an explicit opt-in flag, fail-open, with the wearer-speech calibration profile finally consumed at runtime.

**Files**
- Modify `Sources/TapQCLI/CLICommand.swift`: `ServeOptions.wearerGateEnabled = false` via `--wearer-gate`; usage/help text (state: default off, needs AirPods motion, uses `wearer-speech-calibration.json` when present, provisional thresholds otherwise, always fail-open).
- Modify `Sources/TapQCLI/RuntimeService.swift`: `TapQRuntimeConfiguration.wearerGateEnabled` (default false); `TapQRuntimeEndpoint.wearerSpeechStatus: String?` (nil when off; e.g. `"gate"`; WP7 extends to `"gate+turn-control"`).
- Modify `Sources/TapQCLI/TapQCLIApplication.swift`: plumb option → configuration; print `Wearer speech: …` in the ready block (next to `voiceBackendStatus`, `:210-211`).
- Modify `Executables/tapq/AppleTapQRuntimeService.swift`: when enabled — load the wearer-speech profile if present (store already constructed, `:35-41`; default config otherwise, mirroring gesture/tap), build `WearerSpeechSignalSource`, attach via `gestures.setMotionSampleObserver`, and compose `SpeechGatedVoice(wrapping: WearerGatedVoice(wrapping: rawVoice, signal: source.makeSignal(), diagnosticSink:), activity: …)` per the documented stacking order. Works for **both** `.apple` (VoiceListener) and `.openaiRealtime` raw voices. Keep the executable diff to composition-only `if` — anything with logic goes into tested portable/adapter code.

**Dependencies**: WP5.

**Acceptance criteria**
- `CLICommandParserTests`: flag parsing, help text; `TapQCLIApplicationTests`: configuration passthrough via `FakeRuntimeService`, status line rendering, and — flag omitted — serve output byte-identical to M1.
- A `CalibrationProfileTests`-adjacent test proving a malformed wearer-speech profile fails serve the same way malformed gesture/tap profiles do today (or is skipped-if-absent — match the existing `loadGestureIfPresent` semantics exactly).
- Existing `WearerGatedVoiceTests` composition tests remain the behavioral proof; add one InteractionBaseline test stacking `SpeechGatedVoice(WearerGated(inner))` with a *stale* fake signal proving verbatim pass-through (the fail-open regression sentinel).

**Risks / judgment calls**: none new — the gate's delivery policy was ratified in M1 (WP5). Call out in help text that with provisional thresholds the gate may pass bystander speech (attribution window is generous by design) until the capture study lands.

---

### WP7 — IMU turn control: endpointing + barge-in behind `--imu-turn-control` (Track I)

**Goal**: wearer speech-end commits the user turn (endpointing) with command-match/timeout untouched as fallback; wearer speech-onset during TTS/backend playback stops the audio (barge-in) and lets the normal gate machinery open the mic. Default off.

**Files**
- Create `Sources/TapQInteractionBaseline/WearerTurnCoordinator.swift` (portable): consumes one `WearerSpeechSignaling` child + closures `{ endpoint: () -> Void, interruptPlayback: () -> Void, isResponsePlaying: () -> Bool, isUserTurnActive: () -> Bool }` + injectable clock:
  - Endpointing: only after observing a `startedSpeaking` within the current turn (warm-up guard, WP5 note), a `stoppedSpeaking` transition starts an endpoint-delay timer (config `endpointDelaySeconds`, default 0.4, on top of the detector's 0.6 s hangover); if the wearer resumes, cancel; on expiry call `endpoint()` exactly once per turn. Signal unavailable/stale at any point ⇒ do nothing (match/timeout fallback — fail open).
  - Barge-in: `startedSpeaking` while `isResponsePlaying()` ⇒ `interruptPlayback()` once per response.
- Modify `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift`: expose the tiny read hooks the coordinator needs (`isUserTurnActiveForCoordination`, `isResponseInFlight`) — no policy inside the provider.
- Modify CLI/runtime plumbing (`CLICommand.swift`, `RuntimeService.swift`, `TapQCLIApplication.swift`): `--imu-turn-control` (default off; implies the signal source like `--wearer-gate` does; both flags share one `WearerSpeechSignalSource`); status string becomes `"gate"`, `"turn-control"`, or `"gate+turn-control"`.
- Modify `Executables/tapq/AppleTapQRuntimeService.swift`: compose the coordinator when enabled — `endpoint = provider.endActiveTurn`, `interruptPlayback = { playback?.stopAndFlush(); provider.cancelActiveResponse(); speech.stopAll() }`. Only meaningful on the backend-provider path; on the `.apple`/`VoiceListener` path the coordinator composes with `interruptPlayback = { speech.stopAll() }` and no endpoint (VoiceListener has no turn API) — barge-in-only there.

**Dependencies**: WP1 (`endActiveTurn`/`cancelActiveResponse`), WP2/WP4 (playback flush target), WP5 (signal), WP6 (flag plumbing + shared source).

**Acceptance criteria**
- `Tests/TapQInteractionBaselineTests/WearerTurnCoordinatorTests.swift` (fake signal, virtual clock, recording closures): endpoint fires once after delay; resume-within-delay cancels; no endpoint without a prior onset in-turn; no endpoint when signal unavailable; barge-in fires once per playing response and never when idle; no calls after `stop()`; a wedged signal never blocks anything (the coordinator only ever *adds* calls, never gates the existing paths — assert by composing with the full provider + `ScriptedVoiceBackend`: match-on-transcript and window timeout behave identically with the coordinator attached and the signal dead).
- End-to-end-shaped test: scripted pipe backend + fake playback + coordinator — wearer onset during response audio ⇒ flush + `response.cancel` frame (via `ScriptedVoiceBackend` call record) ⇒ next turn's transcript resolves the window; wearer speech-end ⇒ commit ⇒ post-commit `transcriptFinal` ⇒ command matched (the OpenAI-shaped flow from the findings).
- `speech.stopAll()` on barge-in is tested at the coordinator seam (closure recorded), documented as deliberately blunt.

**Risks / judgment calls**
- `speech.stopAll()` also drops queued notifications from other sessions — recommended accept (barge-in means "stop talking, I'm answering"); ratify.
- Endpoint-delay default (0.4 s) is provisional like every IMU threshold; keep it in `WearerSpeechConfig`? Recommended: no — it is interaction policy, not detection; a constant on the coordinator with an init override is enough until the study.
- False endpoints (jaw motion that is not speech) commit a turn early on the OpenAI path; consequence is an unmatched transcript and a re-armed turn (WP1), i.e., degraded-not-broken. State in docs.

---

### WP8 — Free-form answers: interaction layer (Track F)

**Goal**: a spoken free-text answer can resolve a selection (AskUserQuestion / `request_user_input` / multi-option stop question), with read-back confirmation, entirely in the portable layer. Off by default; enabled by `--voice-freeform`.

**Files**
- Modify `Sources/TapQContracts/Inputs.swift`: add `VoiceCommand.freeform(String)` and `InputIntent.freeform(String)` (+ `Equatable` arms, `intent` mapping). Compiler-forced switch updates: `InteractionController.resolve` (`.freeform` → keep listening in approval flow for this milestone), `SelectionController.resolve` (below). `VoiceListener`/`VoiceCommandMatcher` never produce it ⇒ default path untouched.
- Modify `Sources/TapQContracts/SelectionResult.swift`: `public let freeText: String?` (defaulted init parameter; `noSelection` unchanged). A result with `freeText != nil` and empty `choices` is a *resolution*, not a timeout.
- Modify `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift`: `freeformEnabled: Bool = false` init parameter — when true, a **final** transcript that matches no command is delivered once per turn as `.freeform(trimmed)` (final transcripts arrive on Apple via recognizer settling, on OpenAI after an endpoint commit — which is why this WP follows WP7).
- Modify `Sources/TapQInteractionBaseline/SelectionController.swift`: on `.freeform(text)` — speak read-back `"You said: '<text>'. Nod to send, shake to discard."`, listen; allow/select ⇒ `SelectionResult(choices: [], freeText: text)`; deny ⇒ discard, re-listen; timeout ⇒ defer as today. Condense text via `SpokenText` for the read-back only (the full text rides the result).
- Modify `Sources/TapQContextBaseline/StopQuestionCoordinator.swift`: multi-option branch — a `freeText` result produces `Self.reply(question:answer:)` with the free text (wording: "they answered: '<text>'"), records the answer for repeat-suppression exactly like a label answer.
- CLI plumbing: `--voice-freeform` in `CLICommand.swift`/`RuntimeService.swift`/`TapQCLIApplication.swift`; composition passes `freeformEnabled` into the provider on the backend path only (`AppleTapQRuntimeService.swift`); flag rejected (startup error) when the composed voice path cannot produce transcripts (i.e., `.apple` provider) — silent no-op would hide the misconfiguration (question-classifier precedent).

**Dependencies**: WP1 (transcript surfacing/re-arm), WP7 (endpointing makes free-form reachable on the OpenAI path).

**Acceptance criteria**
- Provider tests: unmatched final ⇒ exactly one `.freeform` per turn (only when enabled); matched final ⇒ command, never freeform; partials never freeform; empty/whitespace transcript never freeform.
- `SelectionControllerTests`: full read-back cycle (confirm ⇒ result carries text, empty choices, `timedOut == false`; discard ⇒ re-listen; navigation still works after a discard); existing selection tests unmodified.
- `StopQuestionCoordinatorTests`: free-text reply formatting + repeat suppression.
- Parser/application tests for the flag incl. the `.apple`-provider rejection message; flag off ⇒ all paths byte-identical.

**Risks / judgment calls**
- Widening the closed `VoiceCommand`/`InputIntent` enums is the one contract-shape change of the milestone — recommended over a parallel channel because every switch is compiler-audited; **ratify** (open question 4).
- Read-back-confirm is a deliberate safety tax; ratify (recommended: yes — a stray sentence becoming an agent instruction is worse than one extra nod).
- Yes/no stop questions and tool approvals stay binary this milestone (a free-form answer to an *approval* is an authorization surface change; out of scope).

---

### WP9 — Wire protocol: `free_text` selection reply + both agent shims (Track F)

**Goal**: the free-form answer flows to Claude Code and Codex.

**Files**
- Modify `Sources/TapQWireProtocol/WireMessages.swift`: `BrokerResponse.selection(indices:labels:freeText:)` — encode `free_text` only when non-nil; decode via `decodeIfPresent`. Version: bump `WireProtocol.version` to 4; broker accepts {4, 3} (change `validate`'s check to an accepted-set — request shapes are identical in v3/v4, so accepting 3 is sound and keeps every installed shim working); extend `outboundVersion(for:approvalSource:)` so a v4 shim speaks 3 to a v3 broker (mirroring the v2 bridge at `:34-44`). Old shim + new broker: works, simply never sees `free_text` semantics it wouldn't read anyway. New shim + old broker: works, no free-text offered.
- Modify `Sources/TapQBrokerRuntime/BrokerServer.swift` (`:138-157`): a result with `freeText` and no choices is success ⇒ `selection(indices: [], labels: [], freeText:)`; `timedOut` mapping unchanged.
- Modify `Sources/TapQClaudeAdapter/HookShim.swift` (`handleAskUserQuestion`, `:388-397`): when `selected_labels` empty but `free_text` present ⇒ deny reason `"User answered via TapQ hands-free interface. They answered in their own words: '<text>' for question: '<question>'. Please proceed accordingly without re-asking."`.
- Modify `Sources/TapQCodexAdapter/CodexHookShim.swift` (`handleRequestUserInput`, `:214-245`): accept the free-text reply shape ⇒ `answers[questionID] = [text]` response JSON (bypassing the option-label equality check for the free-text arm only; all other validation retained).

**Dependencies**: WP8.

**Acceptance criteria**
- `TapQWireProtocolTests`: encode/decode round-trip with and without `free_text` (absent field ⇒ byte-identical to v3 bytes); version acceptance matrix {nil,1,2,3,4}; `outboundVersion` matrix incl. the v2 rules unchanged.
- `TapQBrokerRuntimeTests`: free-text selection response; label selection and timeout responses byte-identical to before.
- `TapQClaudeAdapterTests`/`TapQCodexAdapterTests`: free-text reply handling; label replies and every fail-open branch unchanged; a reply carrying *both* labels and free_text prefers labels (defensive, tested).
- Old-shim-versus-new-broker compatibility asserted at the `validate` level (v3 request accepted).

**Risks / judgment calls**
- Whether Codex's `request_user_input` actually accepts non-option answer strings is **unverifiable from this repo** — the response JSON is a TapQ-fabricated model-visible claim, so the model will see the text either way, but native-UI expectations may differ; smoke item gates it (open question 6).
- Accept-{3,4} vs strict-exact at the broker: recommended accept-both (nothing in the request changed); if the orchestrator prefers the M1-style strict bump, the only cost is installed shims failing open until `tapq` hooks are reinstalled — decide (open question 5).

---

### WP10 — Linux CI coverage + portability hardening (Track X)

**Goal**: the portable graph provably builds and tests on Linux with the M2 code, and the guardrails actually cover the voice targets.

**Files**
- Modify `scripts/check-public-boundary.sh:134-143`: add `Sources/TapQVoiceBackends` to the `portable=(…)` list (and `Sources/TapQBrokerRuntime`/`TapQPOSIXBridgeClient` if the grep confirms they're intentionally excluded — investigate, don't assume).
- Modify `.github/workflows/ci.yml`: add `workflow_dispatch:` and `push: branches: ["main", "worktree-**"]` (keep pinned action SHAs and existing job structure) so milestone branches get macOS+Linux runs on push.
- Fix anything the audit finds: grep portable targets for Darwin-only APIs outside `#if canImport` guards, `FoundationNetworking` correctness, `Data`/`String` corelibs pitfalls in new M2 files (`WearerTurnCoordinator`, `CombinedSpeechActivity`, `VoiceResponseAudio`, provider changes, wire changes — all must be Linux-clean).
- Optional: `scripts/linux-check.sh` that runs the build+test inside `docker run --rm -v "$PWD":/src -w /src swift:6.0` when docker is present, exiting with a clear "docker unavailable, run in CI" message otherwise.

**Dependencies**: all previous (it audits their output).

**Acceptance criteria**
- `scripts/check-public-boundary.sh` green with the expanded list on macOS.
- If docker is available in the implementer's environment: `swift build && swift test` green in the `swift:6.0` container; if not, a dry audit checklist recorded in the commit message and the CI trigger in place so the next push proves it.
- Workflow YAML validates (`actionlint` if available, else careful review); no change to the macOS job's steps.

**Risks / judgment calls**: pushing this branch to run CI is outside the implementer's authority (no-push rule from M1 header stands) — the trigger change is preparation; the actual Linux run happens when the orchestrator pushes. Flagged in open questions (8).

---

### WP11 — Docs, changelog, full verification, M2 smoke checklist (Track X, final)

**Goal**: whole-milestone verification and the human handoff artifact.

**Work**
- `swift build` (debug + release), full `swift test`, `scripts/check-public-boundary.sh`, `scripts/package-runtime-app.sh debug` on macOS.
- `docs/CLI.md`: serve flags `--wearer-gate`, `--imu-turn-control`, `--voice-freeform`; rewrite the "Voice backend" section (mic pump, playback, conversation sessions + idle-close, sticky fail-through, the OpenAI no-transcript-before-commit behavior and why `--imu-turn-control` is effectively required for voice resolution on that path); Claude/Codex integration sections gain the free-text answer story; wire-protocol/version note (v4, v3 accepted, old-shim behavior).
- `CHANGELOG.md` Unreleased entries (match the M1 entry style — behavior-first prose, fail-open guarantees named).
- README design-principles touch only if the half-duplex/echo statement belongs there (check; likely not).
- Cross-package consistency pass: flag spellings, diagnostic category names (`WearerGate`, `WearerTurn`, `Playback`, `MicPump` — settle one naming scheme), no portable target importing AVFoundation (grep gate), help text matches parser tests.
- Write `docs/MILESTONE2_SMOKE_CHECKLIST.md` (human + hardware; agents must not attempt), covering at minimum:
  1. `serve --voice-backend openai-realtime` (with key): speak an answer, **hear the cloud voice**, approval resolves by voice on the *primary* path (the thing M1 could not do).
  2. `--imu-turn-control`: stop talking ⇒ commit within ~1 s (endpoint), window resolves without waiting for timeout; speak during the agent's audio ⇒ playback stops (barge-in), answer heard on the next turn.
  3. `--wearer-gate`: a bystander (or a phone speaker) issuing "yes" during a window is rejected; the wearer's own "yes" passes; pulling AirPods motion mid-window degrades to pass-through (fail-open).
  4. `--voice-freeform` + AskUserQuestion from Claude Code: answer off-list, hear the read-back, nod, verify Claude receives the free text; same via Codex `request_user_input` — **record whether Codex accepts it** (WP9 risk).
  5. Wi-Fi kill mid-conversation: fail-through to Apple, sticky (no per-window handshake stalls), voice still works; mic never stuck open.
  6. Old shim (build from `0fc7474`) against new broker: fails open loudly to the on-screen prompt; reinstalling hooks fixes it.
  7. Regression: flagless `tapq serve` — no new status lines, all M1 behaviors identical; `--voice-backend openai-realtime` *without* the new flags still resolves windows by gesture/tap/timeout.

**Dependencies**: all packages.

---

## 3. Open questions for the orchestrator

1. **Missing scope item — microphone pump (WP3).** The ratified list omits it, but without it scope items 1/4/5 are unreachable and `--voice-backend openai-realtime` transmits no audio (finding above; M1 smoke item 6 could not have passed by voice on the primary). Recommend: ratify WP3 as in-scope.
2. **Playback + pump ride the existing `openai-realtime` flag, no new flag.** Recommended (the flag is opt-in; M1's silence was an implementation gap, not a contract) — the alternative is a `--voice-playback` sub-flag nobody would ever want off.
3. **Conversation definition + policies.** Recommend: conversation = provider session lifetime with `idleClose` 60 s; sticky fail-through for the session lifetime, primary re-probed on the next conversation open (`resetStickiness` on idle-close reopen). Numbers need ratification.
4. **Free-form plumbing = widening `VoiceCommand`/`InputIntent` with `.freeform(String)`**, plus mandatory read-back-confirm, scoped to selections and multi-option stop questions only (approvals and yes/no stop questions stay binary). Recommended as stated; the enum widening is the one contract-shape change.
5. **Wire version: bump to 4 with the broker accepting {3, 4}** (requests are shape-identical; only a response field was added). Alternative A: no bump at all (technically sufficient — additive optional response field, tolerant decoders both sides). Alternative B: strict exact-4 (M1-style), breaking installed shims until reinstall. Recommend the middle path; the scope's "wire-protocol bump" wording suggests A would under-deliver, B over-breaks.
6. **Codex free-text**: whether `request_user_input` tolerates non-option answers is unverifiable offline; implement (WP9) and gate on smoke item 4, with pass-through as the documented fallback if Codex re-asks.
7. **Endpointing fallback without IMU on the OpenAI path**: since transcripts only exist post-commit there, `openai-realtime` without `--imu-turn-control` resolves windows only by gesture/tap/timeout. Recommend documenting that honestly rather than adding an acoustic RMS-silence endpointer this milestone; the `onInputLevel` hook in WP3 keeps that door open as a fast follow (it would still be TapQ-side arbitration, so it does not violate the backend-VAD invariant).
8. **CI trigger**: WP10 adds `worktree-**` push triggers + `workflow_dispatch`, but the actual Linux proof requires a push, which implementers are barred from. Orchestrator should push (or dispatch) after WP10 lands.
9. **Barge-in uses `speech.stopAll()`**, which also drops queued cross-session notifications. Recommend accepting the bluntness; a priority-selective stop is a `SpeechEngine` surgery this milestone doesn't need.
10. **Scope-framing corrections to acknowledge**: contract lives in `TapQContracts` (no `TapQVoiceCore`); Linux CI workflow already exists (gap is triggers + the boundary-script's portable list omitting `TapQVoiceBackends`); stop-question free text needs no wire change (runtime producer only); and `FailThroughVoiceBackend`'s capability *intersection* means composed capabilities can't be used to gate playback/barge-in — WP2/WP7 gate on the event stream and an explicit hint instead.

---

## Genuinely human/hardware-bound (no agent work planned)

Everything in the WP11 smoke checklist; all live OpenAI sessions; the capture study that will replace every provisional threshold (`WearerSpeechConfig` defaults, attribution window, endpoint delay) — all of which remain data changes by construction.
