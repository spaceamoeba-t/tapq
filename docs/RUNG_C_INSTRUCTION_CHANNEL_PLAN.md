# Rung C — Instruction Channel: Implementation Plan

*Ratified 2026-08-15. Branch `rung-c-instruction-channel`, stacked on
`rung-b-conversation-memory`. Parent program: `docs/VOICE_AGENT_PLAN.md` §5.
File:line references verified 2026-08-15 (adapter/wire/wearer subsystems are
identical across the Rung A/B bases).*

Goal: "go ahead, and run the tests again after" reaches the agent's session —
dictated by voice, verified as the wearer's, confirmed by read-back, delivered at
the agent's next turn boundary. Authorization semantics are untouched.

## The policy split (the renegotiation, binding)

- **Authorize** — unchanged forever: never by free text; matched commands and
  gestures only; wearer gate FAIL-OPEN (the screen is the backstop).
- **Instruct** — new act: free text allowed, but FAIL-CLOSED on wearer
  attribution (no attributed signal ⇒ no instruction — a bystander injecting
  work is worse than a missed dictation), mandatory read-back + confirm
  (nod-or-yes dual channel), behind `--voice-instructions` which REQUIRES
  `--wearer-gate` (startup error otherwise, classifier-style).

## Program-plan corrections (verified against code)

1. **OpenCode cannot receive instructions in v1**: the plugin is strictly
   event→relay→reply (spawn per event, `OpenCodePluginSource.swift:86-129`);
   `OpenCodeHookShim.swift:216-217` records that OpenCode exposes no documented
   way to continue a finished turn. Capability = false, documented.
2. **Capability advertisement needs no wire change**: every shim is TapQ-owned,
   so a static `AgentCapabilities` table keyed by adapter identity replaces the
   planned per-connection advertisement. The wire keeps ONE addition —
   `instruction.submit` — because it is the device-adapter SDK seam and powers a
   `tapq instruct` debug command that makes this rung testable without hardware.

## Verified inventory (load-bearing facts)

- Wire: `WireProtocol.version = 4`, `previousAcceptedVersion = 3`
  (`WireMessages.swift` / `WireProtocol:19-53`); broker acceptance at
  `BrokerServer.swift:224-239`; `BrokerRequest` decode switch `:216-248` throws
  on unknown type; **no handshake** — one request line, one response line.
  `outboundVersion` gates only on `ApprovalSource` today and must gate on
  message type for v5. Old shims key-match responses and tolerate unknown
  shapes by failing open (`HookShim.swift:166-170` et al.), but
  `previousAcceptedVersion` must become 4 so installed v4 shims keep working.
- Claude delivery: stop-block `{"decision":"block","reason":…}` emitted at
  `HookShim.swift:283-292`, reason = broker reply from
  `StopQuestionCoordinator.reply` (:186-188); fires at end of turn and restarts
  it with the reason as the next instruction. **No `stop_hook_active` guard**
  (Codex has one at `CodexHookShim.swift:477-480`) — instruction-bearing blocks
  need their own loop cap. Deny-reason mid-turn steering exists but is NOT used
  for instructions in v1 (it would entangle instruction delivery with approval
  outcomes).
- The queue seam: `BrokerServer.onStopQuestion` → runtime closure at
  `AppleTapQRuntimeService.swift:600-602` → `StopQuestionCoordinator.handle`
  (:57-62 is the earliest return point, ahead of the repeat/cap/classifier
  guards). The coordinator is already `@MainActor` with per-session state — the
  queue's home. Broker's 5 s stop dedupe cache (`BrokerServer.swift:197-202`)
  sits in front and replays the same reply for identical duplicate stop events —
  idempotent for hook-retry duplicates, note in docs.
- Wearer gate: `WearerGatedVoice` wraps BOTH voice paths when `--wearer-gate`
  is on (backend freeform included: `AppleTapQRuntimeService.swift:243-252`,
  `VoiceBackendCommandProvider.swift:526-532`); fail-open branch at
  `WearerGatedVoice.swift:93-96`; trailing window `defaultAttributionWindow =
  2.0` (:28); `lastWearerSpeechAt` is private — a fail-closed consumer needs a
  new query API. Signal availability rule: `WearerSpeechSignalSource.swift:57-59`.
- Cursor: no text-bearing channel (`CursorHookShim.swift:250-276`) — capability
  false by construction.

## Ratified decisions

- **RC1 — Delivery is stop-boundary only, Claude + Codex.** A queued
  instruction for `sessionID` is returned as the stop reply (template: *"The
  user dictated a new instruction via TapQ hands-free: '⟨text⟩'. Proceed
  accordingly."*) from the head of `StopQuestionCoordinator.handle`, before all
  guards. One instruction drains per boundary. Deny-reason delivery is out of
  scope. OpenCode/Cursor: instructions unsupported; the voice UX says so
  honestly ("Instructions aren't supported for ⟨agent⟩.").
- **RC2 — `InstructionQueue`** (TapQContextBaseline): bounded per-session FIFO
  (cap 4, drop-oldest with diagnostic `instruction.dropped_capacity`), value
  struct + `@MainActor` owner pattern, speech-safe text only. Loop safety: at
  most 3 consecutive instruction-bearing blocks per session without an
  intervening non-instruction event (diagnostic + spoken notice on suppression);
  Codex additionally self-limits via `stop_hook_active`.
- **RC3 — Dictation flow (voice, windowed).** New matcher branches BEFORE the
  yes/no guards → `.beginInstruction` ("new instruction", "instruction for
  ⟨you/Claude⟩", "tell it to…"-prefix captures the remainder as instruction
  text when present). Flow inside an open window: prompt "Go ahead." → next
  free-form turn is captured as instruction text (not offered to Q&A) →
  read-back "Instruction: '⟨text⟩'. Nod or say yes to queue it." → confirm via
  the existing dual-channel mechanics → enqueue → "Queued for ⟨agent⟩." →
  window resumes exactly where it was (deadline untouched). Decline/timeout ⇒
  discarded, window resumes. Like Rung B recall, dictation is available only
  while a window is open (always-on arrives in Rung D); documented.
- **RC4 — Fail-closed attribution for instructions.** New
  `WearerAttributionChecking` query (exposing attributed-recently state from
  `WearerGatedVoice`'s tracking, window-based). `.beginInstruction` and the
  captured text are accepted ONLY when the signal is available AND attribution
  holds; otherwise a spoken refusal ("I can't confirm that was you — instruction
  discarded.") + diagnostic `instruction.rejected_unattributed`. Signal
  unavailable ⇒ refusal too (fail-closed — the inverse of approvals).
  `--voice-instructions` requires `--wearer-gate` at startup.
- **RC5 — Wire v5, minimal.** `version = 5`, `previousAcceptedVersion = 4`;
  new `instruction.submit` message (token, session_id, text, request_id) with
  `.ok`/`.error` ack; broker arm validates token/version and enqueues via the
  same `InstructionQueue`; `outboundVersion` gates on message type. No other
  message changes; adapters' emitted versions unchanged (they never send
  instructions). New CLI: `tapq instruct <session-id> <text>` (debug/SDK-seam
  command, clearly documented as such) speaking to the running broker.
- **RC6 — `AgentCapabilities`** (TapQContracts or ContextBaseline): static
  table {approvals, questions, notifications, instructions} per adapter
  identity; consumed by the dictation flow for honest refusals and by `tapq
  instruct` for a clear error. Documented in INTEGRATIONS.md.
- **RC7 — RA/RB invariants persist.** Approval sentences untouched; dictation
  can never authorize/deny/select; recall/Q&A unchanged except `.status` gains
  "1 instruction queued." when non-empty; store records instruction events
  (kind `instruction`, text) — speech-safe by construction.

## Work packages

### Track A — queue + delivery (TapQContextBaseline only)
`InstructionQueue.swift` (new) + `StopQuestionCoordinator` head-of-handle
delivery + reply template + loop cap + store event recording hook + tests
(bounds, drain-one-per-boundary, loop cap, dedupe-cache interaction documented
in a test comment, coordinator precedence over classifier guards).

### Track B — dictation + attribution (TapQContracts, TapQDetectionBaseline, TapQInteractionBaseline)
Enum cases + matcher branches (+ negation tests: "don't tell it anything" must
not begin dictation); the RC3 window state machine in both controllers via
injected closures (capabilities check, attribution check, enqueue), deadline
untouched; `WearerAttributionChecking` + `WearerGatedVoice` exposure + inverted
fail-closed branch for the instruction path only; tests incl. the full
dictate→confirm→resume cycle and both refusal paths.

### Track C — wire v5 + broker (TapQWireProtocol, TapQBrokerRuntime)
Message type, version bump per RC5, broker arm + ack, `outboundVersion`
message-type gating, version-matrix test updates (the pinned acceptance tests
WILL need sanctioned edits — list them in the report), round-trip tests.

### Integration (single writer)
`--voice-instructions` flag + requires-wearer-gate validation; runtime wiring
(queue shared by coordinator/dictation/broker arm; capabilities table; status
line addition); `tapq instruct` CLI command + help; docs (CLI.md section,
INTEGRATIONS.md capability matrix, RUNGC_SMOKE_CHECKLIST.md), CHANGELOG;
E2E tests in TapQDetectionE2ETests: attributed dictation queues + delivers as a
stop reply wire-to-wire; bystander dictation refused
(`instruction.rejected_unattributed`); `--voice-instructions` absent ⇒ grammar
inert.

## Execution rules

Both prior plans' rules apply verbatim (Rung A §Execution rules, Rung B
additions — D7 idiom mandatory). Baseline: the Rung B branch's final green
count. Wire-test edits are sanctioned ONLY for the version-matrix updates Track
C lists explicitly.

## Exit criteria

Full suite + boundary green; E2E: wire-to-wire instruction delivery and the
bystander refusal; fail-closed proven by test (signal unavailable ⇒ refusal);
flag absent ⇒ byte-identical behavior; v4 shims still accepted (matrix test);
loop cap enforced; no unsafe fields in queue/store/diagnostics.
