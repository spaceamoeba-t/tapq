# Rung B — Conversation Memory and Spoken Q&A: Implementation Plan

*Ratified 2026-08-15. Branch `rung-b-conversation-memory`, stacked on
`rung-a-spoken-summaries` (PR #26). Parent program: `docs/VOICE_AGENT_PLAN.md` §4.
File:line references verified against this branch's base on 2026-08-15.*

Goal: "what did it just do?" has an answer. A bounded per-session memory of what
was asked and decided, spoken recall intents that work on the Apple path with zero
cloud dependency, grounded free-form Q&A on the realtime path, and a fleet answer
to "who's waiting?".

## Verified inventory (what the plan builds on)

- `InteractionGate` is a chained-`Task` FIFO with no count and no identity
  (`Sources/TapQInteractionBaseline/InteractionGate.swift:10-25`); `sessionID`
  rides every contract but is never read by the interaction layer. The four gate
  entry points live in `Executables/tapq/AppleTapQRuntimeService.swift`
  (466-468, 489-491, 530-536, 562-566); notifications bypass the gate (590-593).
- The single point where an approval request and its final `Decision` coexist is
  the `resolveApproval` closure (`AppleTapQRuntimeService.swift:457-547`);
  selection resolves at 562-566/594-599; stop questions inside
  `StopQuestionCoordinator.handle`; notifications at `BrokerServer.swift:127-132`.
- State pattern to copy: `AnsweredQuestionStore` — a bounded `Sendable` struct
  with `mutating` methods, FIFO-evicted at capacity 8, owned by a `@MainActor`
  class (`Sources/TapQContextBaseline/AnsweredQuestionStore.swift:8-37`).
- Informational intents that do NOT resolve: `.repeatRequest`/`.details` set
  `utterance` and fall through the loop (`InteractionController.swift:209-212`);
  in `SelectionController`, `.details` is a bail-out returning `.noSelection`
  (173-174) — new informational intents must NOT join that group.
- Grammar seam: the if-ladder in `VoiceCommandMatcher.match`
  (`Sources/TapQDetectionBaseline/VoiceCommandMatcher.swift:35-52`); new branches
  go BEFORE `.yes`/`.no` so interrogatives never reach the affirmative guard.
  Enums + hand-written `==` + `intent` map in `Sources/TapQContracts/Inputs.swift`.
- Realtime: `RealtimeSessionConfiguration.instructions` exists and is never set
  (`RealtimeMessages.swift:73`); per-response grounding needs no API change —
  `VoiceBackendCommandProvider.speakViaBackend(_:)` (332-353) already reaches
  `response.create(instructions:)`. `.freeform` is delivered once per turn
  (526-533) and ignored by `InteractionController` at 213-217.
- Redaction contract (`ApprovalRequest.swift:16-19`): `toolInput`, `cwd`,
  `permissionMode` must never reach diagnostics or speech.

## Ratified decisions

- **RB1 — `SessionContextStore`** (new, TapQContextBaseline, portable):
  bounded value-type ring per session (default: last 16 events per session, 8
  sessions FIFO-evicted — mirroring `AnsweredQuestionStore`'s shape), owned by
  the `@MainActor` runtime. Events record ONLY speech-safe fields: kind
  (approval/selection/stopAnswer/notification), agent display name, request
  `summary` (and `detail` for stop answers), tool name, the outcome
  (allow/deny/ask, chosen labels, or the free-text answer), and an injectable
  clock's timestamp. **`toolInput`, `cwd`, and `permissionMode` are structurally
  absent from the event type** — the redaction contract is enforced by
  construction, not by discipline.
- **RB2 — Recall intents, deterministic, no new flags.** New `VoiceCommand` /
  `InputIntent` cases `.status` and `.whatChanged` with matcher branches placed
  before the yes/no guards ("status", "what's the status", "who's waiting",
  "what changed", "what did you change", "what did you do"). Both are
  informational: set `utterance`, continue the loop, never resolve, in BOTH
  controllers. Answers come from an injected `recallResponder:
  (@MainActor (InputIntent) -> String?)` (the `controlsHint` provider pattern) so
  controllers stay ignorant of the store. `.whatChanged` speaks the current
  session's recent events (≤3, newest first, composed deterministically from
  stored summaries + outcomes); `.status` speaks the fleet line (RB4). Responder
  `nil` ⇒ "Nothing recorded yet." — spoken, loop continues. Works identically on
  the Apple path.
- **RB3 — Grounded free-form Q&A, realtime only, additive.** In an approval
  window, a delivered `.freeform` whose text is a question (deterministic check:
  trailing "?" or leading interrogative word) is offered to an injected
  `freeformResponder: (@MainActor (String) -> Bool)`. The runtime wires it to:
  compose instructions = short answering preamble + context digest (speech-safe
  store fields + the current request's `summary`/`detail` only) + the question;
  route via `speakViaBackend`. Handled ⇒ loop continues silently (the backend
  audio is the answer; mic gating already covers playback). Not handled or
  responder absent ⇒ exactly today's behavior. Hard limits: ≤3 grounded answers
  per window (diagnostic `qa.budget_exhausted`), never resolves anything, dead
  without `--voice-freeform` + the realtime backend (no new flag). Selection
  windows keep their existing free-form read-back semantics untouched.
- **RB4 — `SessionWaitRegistry`** (new, TapQInteractionBaseline): a small
  `@MainActor` registry with `begin(sessionID:agent:)`/`end(token:)` wrapped
  around the four gate call sites, exposing waiting counts and per-agent display
  names. `.status` composes from it: "⟨Agent⟩: ⟨current summary⟩. 2 more
  waiting." (counts + display names only — session IDs are opaque and never
  spoken). Registry state is also structurally speech-safe.
- **RB5 — Grounded re-enable stays OFF.** `endActiveTurn` keeps
  `expectingResponse: false`; Rung B grounds ONLY explicit Q&A via
  `speakViaBackend`. The Rung A design note at
  `VoiceBackendCommandProvider.swift:292-296` continues to hold.
- **RB6 — Base session instructions.** `RealtimeSessionConfiguration.instructions`
  gets one short static system string (≤50 words, plain register) telling the
  model its two jobs: speak TapQ-authored text verbatim; answer wearer questions
  briefly from provided context only, never inventing agent state. Constant in
  TapQVoiceBackends, covered by a session.update assertion test.
- **RB7 — RA invariants persist.** Approval-authorization sentences untouched;
  recall/Q&A can never authorize, deny, or select; no wire changes; everything
  new is additive and the absence of the responders reproduces today's behavior
  byte-identically.

## Work packages

### Track A — memory core (worktree `rung-b-track-a`; NEW FILES ONLY)

`Sources/TapQContextBaseline/SessionContextStore.swift` + digest/recall
composition (`SessionRecall.swift`: deterministic "what changed" prose + Q&A
digest builder, caps on length) + `Tests/TapQContextBaselineTests/…` for: ring
bounds + FIFO eviction, event field completeness, redaction-by-construction
(the event type has no unsafe fields — compile-time, plus a test pinning the
spoken composition never contains a path-like string), recall prose
determinism, digest caps.

### Track B — grammar + interaction seams (worktree `rung-b-track-b`)

Files: `Sources/TapQContracts/Inputs.swift`, `Sources/TapQDetectionBaseline/VoiceCommandMatcher.swift`,
`Sources/TapQInteractionBaseline/{InteractionController,SelectionController,SessionWaitRegistry}.swift`
(+ their test files). MUST NOT touch TapQContextBaseline, TapQVoiceBackends,
CLI, or Executables.

1. Enum cases, `==`, `intent` map; matcher branches before yes/no guards; tests
   incl. negation non-collision ("don't tell me the status" must not approve).
2. Controllers: `.status`/`.whatChanged` informational per RB2 in both
   controllers (SelectionController: NOT in the bail-out group); injected
   `recallResponder` with default nil preserving today's behavior;
   `.freeform`-question offer to injected `freeformResponder` per RB3 with the
   per-window budget; tests for loop-continuation, non-resolution, budget,
   question-detection determinism, and unchanged selection free-form.
3. `SessionWaitRegistry` + tests (counts, begin/end pairing, agent names).

### Integration (single writer, after tracks merge; worktree `rung-b-conversation-memory`)

1. Runtime wiring: store recording at the four resolution points + notification
   site; registry around the four gate call sites; responders composed from
   store + registry + `speakViaBackend`; RB6 constant into the realtime session
   config construction sites.
2. Docs: CLI.md recall/Q&A subsection beside the Rung A material (incl. the
   "recall works only while a window is open" limitation and what the Q&A
   digest contains); CHANGELOG bullets; extend `docs/RUNGA_SMOKE_CHECKLIST.md`
   pattern with `docs/RUNGB_SMOKE_CHECKLIST.md` (hardware-only items).
3. Tests: runtime-facing integration tests where testable (store recording via
   portable harness paths, one E2E-style test in the existing
   TapQDetectionE2ETests harness: nod-approve then a "what changed" trace
   speaks the recorded event and the window still resolves normally).

## Execution rules (binding for every agent)

All rules from `docs/RUNG_A_SPOKEN_SUMMARIES_PLAN.md` §Execution rules apply
verbatim (git -C absolute paths; no exit-code masking; full suite + boundary
script before final commit; style parity; commit trailer; no pushes; deviations
must be justified in the report). Additionally:

- **D7 idiom (mandatory): any `@MainActor` test class uses `async` test
  methods** — synchronous ones fail to compile on Linux XCTest, and macOS local
  runs cannot catch it. Check every new test class before committing.
- Baseline at this branch's base: 1,678 tests / 0 failures. The suite must end
  ≥ baseline + your additions, 0 failures.
- Nothing here adds a CLI flag; if you believe one is needed, that is a
  deviation to justify.

## Exit criteria

Full suite green; boundary green; grammar additions cannot reach the
affirmative guard (negation tests); absence of responders reproduces today's
behavior byte-identically; no speech or diagnostic line can contain
`toolInput`/`cwd` content (enforced structurally + tested); Q&A budget enforced;
`--voice-freeform` off ⇒ Q&A dead; E2E recall test green on both CI jobs.
