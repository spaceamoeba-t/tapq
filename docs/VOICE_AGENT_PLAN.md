# TapQ Voice Agent Plan — Rungs A–D

*Draft 2026-08-14. Written against `origin/main` @ `9520f69` (post PR #25). Companion to
`docs/CORE_USER_SCENARIOS.md` scenario 5 (delegation mode) — this is the engineering
staging for its "filter → free-form voice → duplex + proactive" arc, extended to cover
the SDK consequences at each step.*

---

## 0. End state (what Rung D buys, in plain words)

You put in your AirPods, start your agents, and stop watching the screen. Routine
questions get answered automatically the way you would have answered them, and logged.
When something genuinely needs you, a voice tells you what is going on in plain words
and does not wait to be polled. You talk back like on a phone call: ask what changed,
ask for the downside, say "go ahead, and run the tests again after" — and that becomes
the agent's next instruction. You can interrupt it mid-sentence. It only obeys your
voice, because the earbuds feel your head move when you speak. In a meeting the same
conversation runs silently on nods, shakes, tilts, and taps. Risky actions still
require explicit confirmation, and every failure path still lands on the screen.

Today TapQ is a remote control. After Rung D it is a chief of staff in your ear, and
gestures are the silent way to say the same things.

## 1. Starting point (verified 2026-08-14)

What exists and works: four hook adapters (Claude, Codex, Cursor, OpenCode) over the
authenticated v4 broker; deterministic 9-command voice grammar over two interchangeable
backends; a real live audio loop behind `--voice-backend openai-realtime` (mic pump,
conversation session, playback); mechanical half-duplex (`VoiceTurnStateMachine`) with
a self-hearing gate; IMU endpointing and barge-in (`--imu-turn-control`); IMU wearer
attribution (`--wearer-gate`, fail-open); free-form spoken answers to selections
(`--voice-freeform`); no-AirPods voice-only degrade (PR #24).

Seams already built and waiting:

- `VoiceBackend.requestResponse(text:)` — implemented in all three backends, **zero
  callers**. The designed "TapQ decides what the voice says" API.
- `stop.question` carries the agent's full final reply (≤16 KB); the classifier LLM
  plumbing (Foundation Models / Anthropic / OpenAI / heuristic, provider pattern +
  flag) is exactly the shape a summarizer needs.
- `AgentNotification.summary` rides the wire and is dropped by the presenter.
- `TranscriptSummarizer` (Claude adapter) — dead code, no call site.
- `MicrophonePumpVoiceBackend.onInputLevel` — inert hook for an acoustic endpointer.
- `SelectionResult.freeText` + wire v4 `free_text` — the confirm-then-send read-back
  pattern, reusable for instructions.

The three structural gaps: (1) nothing turns agent output into speakable prose;
(2) no conversation state — the runtime holds per-request data only; (3) no channel
for user→agent instructions — free-form only ever *answers* a question the agent
asked, the wire has no "user says X" type, and hooks are reactive.

One live hazard to retire early: on the realtime path, an endpointed unmatched turn
sends `response.create` with `instructions: nil` — the cloud model replies
conversationally with zero context about the coding agent.

SDK position: TapQGestures SDK v1 is **implemented but unmerged** on
`worktree-tapq-gestures-sdk` (5 commits, base `373b498` — pre-M1). Its plan already
contains the M1/M2 merge-resolution map. Every rung below adds contract churn; the
rebase cost compounds the longer it waits.

## 2. Program shape

- One rung = one shippable milestone with its own plan doc, flags, smoke checklist,
  and CI green — same discipline as M1/M2.
- Flags-first: every capability lands off by default; promotion to default is a
  separate, data-backed decision (the capture study remains the accuracy gate for
  every IMU threshold).
- The security invariant is *refined*, never silently weakened: spoken free text
  never **authorizes** an action. Rung C introduces a distinct act — *instructing* —
  with its own, stricter gate.
- Each rung states its SDK impact; §7 consolidates the SDK thread.

## 3. Rung A — speak the agent, not a template

*Goal: everything TapQ says about the agent is real content. Turns "Claude is
waiting." into "Tests fail on the second package; it wants to pin the version."*

Scope:

1. **`SpokenSummaryProvider`** contract in `TapQContextBaseline`, mirroring the
   classifier's provider pattern: `heuristic` (first-sentence/trim, always available),
   `apple` (Foundation Models), `anthropic`, `openai`. Flag
   `--speech-summarizer auto|apple|anthropic|openai|heuristic|off`, default `auto` =
   on-device if eligible, else heuristic. Cloud is opt-in only (local-by-default
   principle); a privacy-docs line states what leaves the machine when it is chosen.
2. **Notifications:** stop dropping `AgentNotification.summary` — speak a bounded
   summarized form after the template lead-in.
3. **Stop replies:** summarize the ≤16 KB final text into one or two spoken
   sentences before the extracted question; "details" expands to a longer form.
   Fold `TranscriptSummarizer` into the provider or delete it.
4. **Approvals — hard line to ratify:** the sentence that names *what you are
   authorizing* stays deterministic (shim gloss), never LLM-paraphrased. An LLM that
   misdescribes a command turns a correct "yes" into a wrong approval. Summarization
   may only *add* (detail expansion), never replace the authorization sentence.
5. **First `requestResponse(text:)` caller:** on the realtime path, TapQ-authored
   utterances are spoken by the backend voice (TTS fail-through unchanged). The
   ungrounded `response.create` is suppressed (`expectingResponse: false`
   everywhere) until Rung B grounds it.

Exit: real summaries spoken across all four adapters; no ungrounded cloud replies;
approval sentences byte-identical to today; suite + E2E green (the E2E harness
asserts spoken strings, so it pins the invariant).

SDK impact: none on the TapQGestures surface. Summarizer types are agent-domain and
must stay out of the gesture contracts (the v1 split makes that boundary real —
another reason to land it first). `requestResponse` semantics get their first
consumer, effectively freezing that contract before any SDK exposure of
`TapQVoiceBackends`.

## 4. Rung B — conversation memory and spoken Q&A

*Goal: "what did it just do?" has an answer.*

Scope:

1. **`SessionContextStore`** (portable, in-memory, bounded ring per agent session):
   recent approvals with their summaries and verdicts, last stop summary, pending
   request, counters. No transcript retention beyond the bound; nothing persisted.
2. **Recall intents:** grammar additions (`status`, `what changed`, plus existing
   `repeat`/`details` widened) answered deterministically from the store — works on
   the Apple path with zero cloud dependency.
3. **Grounded free-form Q&A** (realtime path): an unmatched utterance during an
   open window that is a *question* gets a grounded answer — `response.create` now
   carries instructions + a context digest from the store. This legitimizes the
   Rung-A-suppressed reply instead of deleting the capability.
4. **Fleet recall:** "which sessions are waiting?" reads the multi-session queue —
   the voice face of fleet triage (scenario 4).

Decision to ratify: context digests go to the cloud only on the explicitly chosen
cloud backend; document the flow.

Exit: recall intents work on both backends; free-form questions get grounded answers
on realtime; store bounded and covered by portable tests.

SDK impact: the store's read API is designed as if external from day one — it is the
exact surface a display device (the Watch PoC) needs to render "pending question +
recent context". Grammar enums grow additively (v1 already chose non-frozen enums —
no break). This rung starts the *device-adapter SDK's data model* without shipping it.

## 5. Rung C — the instruction channel

*Goal: "go ahead, and run the tests again after" reaches the agent's session.*

**Policy first (the renegotiation, to ratify explicitly):** two distinct acts —

- *Authorize* — unchanged forever: never by free text, only matched commands and
  gestures, wearer gate fail-open (screen is the backstop).
- *Instruct* — new: free text allowed, but **fail-closed on wearer attribution**
  (no attributed signal → no instruction; the opposite polarity of approvals,
  because a bystander injecting instructions is worse than a missed one), plus
  mandatory read-back confirm (the existing free-form pattern: confirm by nod or
  "yes"), behind `--voice-instructions` (off by default; requires `--wearer-gate`).

Scope:

1. **Wire v5:** `instruction.submit` (session-scoped, targeted like fleet-triage
   answers) and **capability advertisement** — each adapter declares which of
   {approvals, questions, notifications, instructions} it supports, so the voice UX
   can be honest per agent.
2. **Delivery per agent** (the genuinely hard part):
   - *Claude Code / Codex:* queued delivery at turn boundaries — the Stop-block
     `reason` is today's only injection point, so instructions queue and land at the
     next boundary; TapQ says "queued for Claude". Mid-turn hook injection does not
     exist; we accept the latency rather than resort to PTY tricks. If an
     instruction contradicts a *pending* approval, deny that approval with the
     instruction as the reason — immediate steering within existing semantics.
   - *OpenCode:* the TapQ-owned plugin runs inside the host with API access — verify
     against source whether it can post a real user message; likely the best
     delivery of the four.
   - *Cursor:* no text channel exists (no question tool, no stop text) —
     capability `instructions: false`; the voice says so instead of pretending.
3. **Dictation UX:** dictate → read-back → confirm → queued/delivered → spoken
   acknowledgment when the agent's next turn shows it landed.

Exit: end-to-end dictation on Claude + OpenCode behind flags; unattributed audio
can never become an instruction (E2E-tested with the bystander trace from the
existing suite); capability matrix honest across adapters.

SDK impact — this rung *creates* two SDK surfaces:

- **Device-adapter SDK:** the internal API that submits an instruction/answer into a
  live interaction is the same seam the Watch PoC study chose ("parallel resolver
  raced at the runtime callback"). Design it once, as the seam external devices will
  use — voice dictation and a watch keyboard are siblings behind it.
- **Agent-adapter SDK:** the capability matrix becomes the adapter contract's core;
  third-party adapters declare what they support instead of TapQ hardcoding it.
- **TapQGestures:** wearer attribution graduates from experimental raw tier to a
  curated *trust primitive* ("this input came from the wearer") — the first SDK
  feature other voice products cannot copy without an IMU. Gated on the capture
  study validating the thresholds.

## 6. Rung D — always-on, duplex, proactive

*Goal: the end state in §0. Four legs, each separately shippable.*

1. **Delegation filter live** (can start right after B): resurrect the dead
   auto-mode gate (the `contains("auto")` check matches no real permission mode —
   2026-07-24 launch-review critical), promote the reasoner from shadow for the
   *routine* tier only — auto-answer under user policy with an audit log ("TapQ
   answers what you would have answered"). Escalation-only semantics stay: the
   reasoner still cannot approve anything the policy would not.
2. **Always-on attention:** IMU-first wake — motion streams continuously (battery
   documented); the mic still opens in windows, but a head gesture or wearer-speech
   onset *opens* a window instead of only the agent doing so. This keeps attribution
   warm between windows (today it goes stale by design) without an always-open mic
   or a wake word.
3. **Duplex:** spike Apple voice-processing I/O (system AEC) — if it holds up, the
   mic can stay open during playback and barge-in becomes acoustic rather than
   IMU-only; the inert `onInputLevel` hook becomes the acoustic endpointer,
   complementing IMU endpointing. Graceful degrade to today's half-duplex when AEC
   is unavailable. (M2 explicitly deferred this as its own hardware story — it is.)
4. **Proactive speech + quiet output:** notifications become conversational openers
   under filter control, paired with the scenario-2 quiet-output mode (chime +
   on-demand summary) so proactivity never becomes spam; priority and interruption
   rules extend the existing `PrioritySpeechQueue`.

Reliability prerequisites (fix before or during D — daemon-grade always-on demands
them): the broker accept-loop permanently exiting on a transient errno, and the
second-`serve`-instance socket unlink, both from the launch review.

Exit: the §0 narrative demoable end to end on one Mac; filter audit log reviewed
against a week of real use; battery and privacy documented.

SDK impact: `GestureSession` gains a continuous mode (the M2 observer fan-out seam
already supports N consumers — the API extension is natural); the policy/filter
engine is portable and becomes the agent-adapter SDK's premium module ("bring
TapQ's filter to your own agent"); the sidecar NDJSON protocol tier (SDK-as-protocol
for non-Swift consumers) becomes viable once the runtime is a long-lived daemon —
but instruction submission over it inherits the Rung C trust gates, so it ships
after them or read-only. The always-on loop also widens the shadow-log corpus of
(motion, decision, context) triples — the alignment-data flywheel — under the same
consent and local-by-default rules.

## 7. The SDK thread, consolidated

- **Land TapQGestures v1 first** (recommendation): rebase `worktree-tapq-gestures-sdk`
  over current main using its own M1/M2 resolution map, merge, tag 0.5.0 per its
  plan. Rung A barely touches it; Rungs B/C churn contracts it splits. Waiting past
  B multiplies conflicts for no benefit.
- **Boundary discipline is the SDK strategy:** every rung adds agent-domain types;
  the v1 contracts split plus `check-public-boundary.sh` keep gesture consumers from
  transitively importing the agent world. Each rung's plan gets an explicit "which
  side of the split" table.
- **Three SDK directions get their substance from specific rungs:** embeddable
  gestures (v1, exists) gains the attribution trust primitive in C and continuous
  mode in D; the device-adapter SDK is born as Rung C's submission seam plus Rung
  B's context read model; the agent-adapter SDK is born as Rung C's capability
  matrix plus Rung D's filter module.
- **The capture study is an SDK gate too:** attribution cannot be sold as a trust
  primitive on provisional thresholds.

## 8. Cross-cutting gates and open decisions

| # | Decision / gate | Recommended | Needed by |
|---|---|---|---|
| 1 | Approval sentences never LLM-paraphrased | Ratify as invariant | A |
| 2 | Summarizer default + cloud privacy line | `auto` on-device-first | A |
| 3 | SDK v1 rebase + merge timing | Before B | A/B boundary |
| 4 | Authorize vs instruct policy split; instructions fail-closed on attribution | As §5 | C |
| 5 | Claude/Codex delivery = queued-at-boundary (accept latency) | Yes; revisit if hook APIs grow | C |
| 6 | Wake strategy: IMU-gated windows vs always-open mic | IMU-gated | D |
| 7 | Launch-review fixes: auto-mode gate, accept loop, socket unlink | Schedule with B (small, independent) | D leg 1 |
| 8 | Capture study scheduling | Before C's attribution promotion | C/D defaults |

Risks worth naming: hook APIs may change under us (four adapters, three vendors) —
the capability matrix is the containment; cloud summarization tension with the
local-first principle — contained by `auto` defaults and one honest privacy doc;
scope creep toward a general voice assistant — contained by the rule that every
spoken sentence is either about an agent session or a control acknowledgment.

## 9. Sequencing

```
A (summaries)  ──────►  B (memory/Q&A)  ──────►  C (instructions)  ──────►  D
   │                        │                        ▲                      ▲
   ├─ SDK v1 rebase+merge ──┘ (before B)             │                      │
   ├─ launch-review fixes (parallel, small) ─────────┼── D leg 1 dep        │
   └─ capture study (parallel, human) ───────────────┴── gates C promotion ─┘
```

A is independent and highest perceived-value-per-effort. B needs A's summarizer.
C needs B's store (read-back + acknowledgment draw on it) and the policy decision.
D's filter leg can start after B; its duplex/always-on legs are last. Hardware
smoke checklists (M2's, plus each rung's) remain user-run gates before promotion.
