# Rung D — Delegation, Always-On, Voice-Processing Spike, Quiet Output

*Ratified 2026-08-15. Branch `rung-d-delegation-attention`, stacked on
`rung-c-instruction-channel`, with `launch-review-fixes` merged in at branch
creation (leg 1 composes with the fixed permission-mode gate). Parent program:
`docs/VOICE_AGENT_PLAN.md` §6. File:line references verified 2026-08-15 against
the Rung B base (M) and the fixes branch (F).*

Goal: the four legs of §6, each behind its own default-off flag, each shippable
and machine-verifiable to the extent hardware allows. What only hardware can
prove goes to `docs/RUNGD_SMOKE_CHECKLIST.md`.

## Verified inventory (load-bearing facts)

- Reasoner: every assessed request carries a `RiskTier` incl. `routine`, but
  routine is inert by construction (`ContextReasoning.swift:124-130`) and the
  contract deliberately has no approve case (`ReasonerContract.swift:130-132`)
  — an auto-allow must live in the HOST on user policy. The slot: in
  `runApproval`'s primary path between `await assessment.value` and
  `interactionGate.run` (`AppleTapQRuntimeService.swift:544-550`); returning
  `.allow` there still records memory via the wrapper (:580-595). Audit-log
  pattern to copy: `ReasonerShadowLog` (JSONL, 0600, 5 MB rotation, swallowed
  write failures).
- Fixed gate (F): `AgentPermissionMode` — `dontAsk`/`bypassPermissions`
  auto-allow everything and skip stop questions; `acceptEdits` auto-allows only
  edit tools and still gets stop questions; broker auto-pass at
  `BrokerServer.swift:78-85` never reaches `onApproval`. TapQ's filter
  therefore only ever sees requests Claude's own mode did NOT bypass — no
  double-answer risk at the chosen slot.
- No policy artifact exists; the pattern for one is `CalibrationStore`
  (`CalibrationProfile.swift:33-146`: TAPQ_CONFIG_DIR / Application Support,
  schemaVersion, typed load/save, malformed ⇒ serve aborts).
- Always-on: arbiters' `finish()` unconditionally stops the detector
  (`InputArbiter.swift:86-97` → `HeadGestureDetector.stop()` :343-355);
  `startDetecting()` is idempotent (:257-270). `WearerSpeechSignalSource` is
  attached once per serve and never torn down; between windows it goes stale
  only because samples stop. The wake seam already exists:
  `onWearerSpeakingChange` via `makeSignal()` (:35-39, :85). Windows can only
  be opened by agent requests today; the reusable primitive for a
  runtime-initiated window is `InputArbiter.listenForInput(timeout:)` +
  `InteractionGate.run` + the Rung B responders (inventory's ~40-line
  `CommandWindowController` sketch). Do NOT reuse `InteractionBudget` numbers.
- AEC: capture and playback are SEPARATE `AVAudioEngine`s
  (`TapQAudioCaptureBridge.m:32` vs :181). No voice-processing references exist.
  Enabling VPIO without a shared engine gives no echo reference; enabling it
  also fires `AVAudioEngineConfigurationChange`, which `VoiceAudioSource`
  treats as fatal (:141, :186-189); VP's AGC shifts the RMS envelope the
  endpointing reads.
- Quiet output: no non-speech cue facility exists anywhere; the playback engine
  already accepts raw int16 buffers (`.m:223-227`) so a synthesized chime needs
  no asset. The notification chokepoint is the `onNotification` closure
  (`AppleTapQRuntimeService.swift:648-657`), which currently skips
  `memory.record` when announcements are off — suppression and recording must
  be decoupled. `--no-announcements` does not cover motion-lost, deferToScreen,
  approval prompts, or backend responses.
- Notification kinds: `waitingForInput`/`permissionWaiting` are Claude-only;
  all four adapters emit `finished`; only Claude populates `summary`.

## Ratified decisions

- **RD1 — Delegation filter (`--auto-answer off|routine`, default off).**
  Requires `--reasoner` provider + mode `primary` (startup validation,
  classifier-style). At the verified slot: auto-allow iff the assessment
  `.decided`, `riskTier == routine`, `confidence >= policy.minimumConfidence`,
  and `toolName` not in `policy.neverAutoTools`. Approvals only — stop
  questions and selections are conversations, never auto-answered in v1.
  Auto-allows are SILENT (that is the point), always recorded to memory
  (kind approval, outcome allow, auto-flagged) and to a new `AutoAnswerLog`
  (JSONL, `ReasonerShadowLog`'s exact discipline). Rung B's `.status` gains
  "Auto-answered N this session." The escalation-only reasoner contract is
  untouched: the reasoner still cannot approve; the HOST applies user policy.
- **RD2 — Policy file `auto-answer-policy.json`** beside the calibration
  profiles (same directory resolution, `schemaVersion: 1`, malformed ⇒ serve
  aborts like a malformed calibration profile). Fields:
  `minimumConfidence` (default 0.8), `neverAutoTools` (default empty — the
  routine tier is the gate; users narrow further if they wish). Absent file ⇒
  defaults. `tapq policy show` prints the effective policy (tiny CLI addition).
- **RD3 — IMU-gated attention (`--attention off|imu`, default off; requires
  `--wearer-gate`).** A hold/refcount seam on `HeadGestureDetector` keeps
  low-rate detection running between windows (arbiter `finish()` releases only
  its own hold). Between windows, an attributed wearer-speech onset opens a
  **command window**: new portable `CommandWindowController` — the inventory's
  minimal composition (listen primitive + gate serialization + soft spoken cue
  "Yes?" + short fixed deadline of 8 s), accepting ONLY informational intents
  (`.status`, `.whatChanged`, `.repeatRequest`) and Rung C's `.beginInstruction`
  dictation. It can never approve, deny, or select — those intents are ignored
  with a spoken "Nothing is waiting." when no request is pending. Battery cost
  of continuous motion documented in CLI.md and the smoke checklist.
- **RD4 — Voice-processing spike (`--voice-processing`, default off,
  experimental, macOS-only).** Scope is plumbing + validation, NOT duplex:
  (a) playback player node optionally hosted on the capture engine so VPIO has
  its echo reference; (b) `setVoiceProcessingEnabled` on the input node behind
  the flag; (c) `VoiceAudioSource` tolerates the VP-induced configuration
  change instead of treating it as fatal; (d) `SpeechGatedVoice` half-duplex
  REMAINS — acoustic barge-in ships only after the smoke checklist proves AEC
  quality on hardware. Flag off ⇒ byte-identical audio path (two engines, as
  today).
- **RD5 — Quiet output (`--quiet`, default off).** A `NotificationPolicy`
  (portable) decides speak/chime/suppress at the single chokepoint, with
  per-session dedupe (a session already waiting is not re-announced). In quiet
  mode: notification- and approval-priority utterances become a short
  synthesized chime (two distinct cues: prompt vs notification; generated
  sine bursts through a dedicated `AudioCue` engine instance — no assets);
  wearer-initiated speech (recall answers, repeat, read-backs) is always
  spoken; deferToScreen and motion-lost notices chime too; nothing about
  resolution semantics changes — gestures answer as usual. Memory recording is
  decoupled from suppression: EVERYTHING is recorded regardless of quiet or
  `--no-announcements` (fixes the :649/:655 conflation for both flags).
- **RD6 — All prior invariants persist.** Auto-answer can never fire for
  non-routine tiers, abstentions, or timeouts (fail = ask the human);
  attention windows never resolve agent requests; the VP flag cannot change
  half-duplex semantics; quiet mode cannot suppress recording. Everything
  default-off ⇒ byte-identical behavior.

## Work packages

### Track A — filter + policy (TapQContextBaseline + TapQCLI, new files only)
`AutoAnswerPolicy.swift` (ContextBaseline: pure evaluation —
`decision(for assessment:toolName:) -> AutoAnswerVerdict` with reasons) +
`AutoAnswerPolicyStore.swift` (TapQCLI: CalibrationStore-pattern load/save,
schemaVersion, defaults-on-absent) + `AutoAnswerLog.swift` (TapQCLI:
ShadowLog-pattern JSONL) + tests (verdict matrix incl. abstain/timeout/low-
confidence/neverAuto; store round-trip + malformed-aborts; log rotation).

### Track B — attention + notification policy (TapQInteractionBaseline, new files only)
`CommandWindowController.swift` (the minimal loop; informational + dictation
intents only; fixed short deadline; injected responders/cue) +
`NotificationPolicy.swift` (speak/chime/suppress + per-session dedupe, consumes
`SessionWaitRegistry`) + tests (window cannot resolve; unknown intents ignored;
dedupe matrix; quiet-mode routing table).

### Track C — Apple-side seams (TapQAppleAdapters + TapQAudioCaptureBridge)
Detector hold/refcount (`HeadGestureDetector` — arbiter stop releases only its
hold; teardown when count reaches zero; existing behavior byte-identical when
no hold is taken) + `AudioCue.swift` (synthesized dual chimes via a dedicated
playback-engine instance) + VP toggle (bridge `.m/.h` C API +
`setVoiceProcessingEnabled` + optional shared-engine hosting for the player
node + `VoiceAudioSource` config-change tolerance scoped to the VP transition)
+ tests (hold semantics with scripted source; cue buffer synthesis; XCTSkip-
gated hardware paths per existing Apple-test conventions).

### Integration (single writer)
Flags + validations; runtime wiring (auto-answer slot + log + status line;
attention arming via `onWearerSpeakingChange` between windows + hold
acquisition at serve start under the flag; notification policy at the
chokepoint with registry made reachable; quiet routing + record decoupling for
BOTH suppression flags); `tapq policy show`; docs (CLI.md sections with the
battery note, `docs/RUNGD_SMOKE_CHECKLIST.md` — the largest hardware list of
the ladder: AEC quality, chime audibility, always-on battery, auto-answer
live-fire), CHANGELOG; E2E tests: routine-tier auto-allow wire-to-wire with a
stubbed reasoner (protocol is portable) + logged; non-routine opens a window
unchanged; abstain ⇒ window; command window answers status and cannot approve
(simulated onset); quiet mode chimes-not-speaks while memory still records;
every flag off ⇒ byte-identical suite behavior.

## Execution rules

All prior plans' rules apply verbatim (Rung A §Execution rules; D7 idiom
mandatory; no exit-code masking; full suite + boundary before final commit; no
pushes; justify deviations). ADDITIONALLY: `scripts/check-release-version.sh`
must pass before the integration agent's final commit — Rung C's wire bump
broke CI because the docs/CLI.md version example is pinned by that script and
no plan listed it as a gate. Baseline: the Rung C branch's final green count.
ObjC bridge edits follow the existing `.m` style; C API additions mirror the
existing header discipline.

## Exit criteria

Full suite + boundary green; all four flags off ⇒ byte-identical behavior
(E2E-pinned); auto-answer never fires on abstain/timeout/low-confidence/
non-routine (verdict matrix + E2E); command window structurally cannot resolve
agent requests; VP flag compiles and passes its seam tests with the flag off
on CI (hardware validation deferred to smoke); recording decoupled from both
suppression flags; audit log matches the ShadowLog discipline.
