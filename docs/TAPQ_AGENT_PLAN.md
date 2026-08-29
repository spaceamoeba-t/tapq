# TapQ as an agent: memory, transcript context, and the loop

Status: direction ratified by the maintainer 2026-08-28 ("TapQ itself will
become a small agent with its own agent loop, and this agent will be
controlling other agents such as Claude Code"). **Milestone M1 implemented
2026-08-29** (both pillars; see the "As built" sections and the answered
open questions below); **M2's loop built 2026-08-29** (engine, internal
tools, `ask_about_work` folded in, composition — see "As built (Pillar C,
M2)"); M3–M4 not started. Everything here is
**cloud-backend-only** — composed on the
`.openaiRealtime` branch (and future model-backed backends); the Apple path
keeps today's reactive, event-level behavior, structurally absent not
disabled.

Companions: REALTIME_INTENT_PLAN.md (live intent), NARRATION_MODEL_PLAN.md
(speech), TRANSCRIPT_CONTEXT_PLAN.md (absorbed here as Pillar B / milestone
M1), FLEET_ROSTER_PLAN.md (rung F multi-agent roster — orthogonal, plugs in
at M3).

## What already exists (built 2026-08-27/28, the agent's organs)

- Perception: hook events; per-turn grounding; SessionContextStore skeleton.
- Intent: the realtime tool-calling path — a model with five tools.
- Actuators: approve/deny, `queue_instruction` into agents, questions to the
  wearer through the approval machinery.
- Voice: single backend voice, both directions.
- **A standing command channel:** indefinite lease-held Stop boundaries mean
  TapQ can deliver to Claude Code at any moment, not only when a hook
  happens to be open. This is what makes an agent loop *actionable*.

What is missing is what this plan adds: durable self-owned memory (Pillar
A), the agents' full history (Pillar B), and a reasoning loop with bounded
initiative (Pillar C).

## Pillar A — TapQ's own memory

**Implemented 2026-08-29 for milestone M1** — record, persist, recent-window
grounding, `tapq memory clear`. See "As built (Pillar A, M1)" below for what
the code does that this section did not say. Per-question retrieval of older
history stays M2; standing directives stay M3.

`WearerConversationStore` (portable): an append-only local JSONL under the
runtime's application-support dir, recording the dialogue TapQ itself has
with the wearer:

- wearer utterances (final transcripts) and TapQ's spoken sentences,
- decisions and their subjects ("approved Bash for Claude Code: swift test"),
- delivered instructions (full text), narrated boundaries, question answers,
- standing directives (see Pillar C), timestamps, agent names.

Properties:

- **Speech-safe by construction**: it records only what was spoken or heard
  on the voice channel — surfaces already cleared for speech — so the
  structural redaction guarantee (no toolInput/cwd/permissionMode) carries
  over without a filter.
- **Durable**: survives realtime-session recycling and runtime restarts.
  Size-bounded by rotation (keep ~30 days / a few MB); `tapq memory clear`
  wipes it on demand.
- **Consumed two ways**: a bounded recent window joins the realtime model's
  per-turn grounding (so "the thing I asked you earlier" resolves even after
  a session recycle), and older history is retrieved per-question inside the
  loop, same slicing approach as transcripts.
- Composed only on the cloud branch: on the Apple path nothing records and
  nothing reads — symmetry with every other pillar.

### As built (Pillar A, M1, 2026-08-29)

Where the implementation is more specific than the plan above, or differs.

- **Two files, one target.** `WearerConversationStore` (entries, durability,
  rotation) and `WearerConversationRecall` (the deterministic rendering of a
  window) live in `Sources/TapQContextBaseline`, split the way
  `SessionContextStore` and `SessionRecall` are and for the same reason: what
  is remembered and what is said about it are different things to test.
- **It is not the conversation-memory rung, and the doc comments say so.**
  `SessionContextStore` / `SessionRecall` / `ConversationMemory` remember the
  *agents' requests* — bounded, in memory, per agent session, gone at exit.
  This remembers *the conversation* — what the wearer said and what TapQ said
  back, on disk, across sessions and restarts. They overlap on decisions and
  instructions by design; neither is a cache of the other, and nothing reads
  one to answer the other's question.
- **The entry schema is open at two seams, which is what "no migration for M3"
  means.** `WearerDialogueKind` is a string newtype rather than an `enum`, so a
  `directive` entry written by an M3 build round-trips through an M1 one and
  renders as itself; and every field but the kind and the timestamp decodes
  with a default, so a line gains fields without breaking older readers. One
  unreadable line is skipped and dropped at the next rewrite rather than
  costing the wearer their month.
- **Rotation compacts in place.** `AutoAnswerLog` and `ReasonerShadowLog` move
  a generation aside to `.1.jsonl`, which is right for a file a person reads
  after the fact. This one is read by TapQ *on the next turn*, so a rotation
  that emptied the live file would erase the wearer's recent history at the
  moment it got interesting. The oldest entries are dropped and the survivors
  rewritten atomically, past the cap rather than to it (75%) so the next append
  does not rotate again. Bounds: 30 days and 2 MB, whichever binds first.
- **The file is mirrored in memory**, because the recent window is read on the
  per-turn grounding path immediately before the microphone opens and must not
  touch the disk. The whole file is loaded once at construction; writes are
  appends, and a full rewrite happens only at a rotation.
- **The recording surface is three hooks and two call sites**, all of them
  speech-cleared by construction. `VoiceBackendCommandProvider.onSpokenToWearer`
  fires from the provider's existing `noteSpoken` — which already returns early
  off a model-backed session — so every sentence TapQ speaks is recorded and
  nothing on the grammar path can reach the store even if a host wires it.
  `onTranscriptFinal` carries the wearer's finals, which on this path decide
  nothing. Decisions are recorded where `resolveApproval` already records the
  session event, and instructions where the stop coordinator already reports a
  delivery. No request object reaches the store; the API takes strings TapQ has
  already said.
- **The window joins the grounding last.** `wearerMemoryGrounding` is a closure
  returning a rendered block, read inside `currentGrounding()` after the window
  brief and the agent names, so the open question stays the most prominent
  thing about *now* with the history behind it. Its heading says the tail may
  repeat the sentences the brief lists separately, because it does.
- **`tapq memory clear` is the only memory verb.** No `show`: the file is the
  wearer's own spoken history, and a supported way to print it is not something
  this feature should add. It confirms like `calibration reset` (and `--yes`
  skips), names the path, and says how many exchanges are about to go.

## Pillar B — transcript context (absorbed from TRANSCRIPT_CONTEXT_PLAN.md)

**Phase 1 implemented 2026-08-29** (TranscriptStore, the optional
`transcript_path` wire field, `ask_about_work` answered by `gpt-5.6-luna`);
see that doc's "As built" for where the code is more specific than the plan.
Hardware smoke pending.

Unchanged in substance; see that doc for full detail. Summary: cloud-backend
selection is consent for TapQ to read connected agents' full transcripts.
Claude Code phase 1 via the hook-supplied `transcript_path`, forwarded as an
optional wire field, tailed incrementally into a `TranscriptStore`.
Cross-provider flow explicitly accepted by the maintainer. Cloud-call
failure → break; unreadable file → loud but alive.

One revision now that the loop exists: `ask_about_work` ships in M1 as a
direct tool (as planned), and in M2 becomes a *loop task* — the loop gains
transcript retrieval as an internal tool, so answers can combine transcript
slices with TapQ's own memory.

## Pillar C — the agent loop

### Two tiers, split by latency

- **Reflex tier (exists today, unchanged):** the realtime intent model
  handles latency-critical, single-step intents directly — approve, deny,
  select_item, plain queue_instruction, query_status. No loop in the path;
  a spoken "approve" must stay instant.
- **Deliberation tier (new):** the realtime model gains one tool,
  `start_task(goal)`, for anything that needs knowledge or multiple steps —
  "what did the tests say?", "tell Codex to do what Claude just did",
  "run the tests and let me know if anything fails". The goal is handed to
  the TapQ loop and the wearer hears an acknowledgment.

### The loop itself

A bounded tool-executing loop (max ~6 steps/task, one task at a time)
reasoning with the narration-family model (`gpt-5.6-luna` via the existing
`OpenAINarrationModel` client — the realtime session stays dedicated to live
voice). Internal tools:

- `search_memory(query)` — Pillar A retrieval,
- `read_transcript(agent, query)` — Pillar B retrieval,
- `get_status()` — roster + waits + queues (existing surfaces),
- `queue_instruction(agent, text)` — the existing path, including rung E
  name resolution and its fail-closed refusal,
- `speak(text)` — scripted-speech channel, verbatim,
- `ask_wearer(question)` — the existing question/approval machinery,
- `finish(summary)`.

The loop runs off the voice turn (async), speaks progress only when it has
something to say, and can pause on `ask_wearer` and resume with the answer.
Task state is held in memory (Pillar A), so a restart mid-task loses the
loop but not the record of what was asked.

### As built (Pillar C, M2, 2026-08-29)

Where the implementation is more specific than the plan above, or differs.
Engine and composition only; the realtime `start_task` tool is its own half
and lands with it.

- **One engine, two lanes, split by who is waiting.** `WearerTaskLoop`
  (`Sources/TapQContextBaseline`) has a *task lane* — `start_task`, six steps,
  runs off the voice turn — and a *question lane*, which is `ask_about_work`
  folded in. They are not the same shape because the question lane runs
  *inside* the realtime peer's tool call while the task lane runs with nobody
  parked, and one set of bounds could not serve both.
- **The question lane costs one bound, and it is the M1 hold.** M1 answered in
  one model call under a 15 s timeout. The lane takes at most 3 calls and stops
  asking for another past a 20 s wall clock, so the peer's hold is ~35 s worst
  case against a typical two calls. The rejected alternative was answering the
  peer immediately and speaking later, which would leave the realtime model free
  to talk over TapQ's own answer. **Maintainer call wanted** if 35 s is too long.
- **The question lane keeps M1's wearer-facing behavior and widens one case.**
  `answered` / `unavailable` / `failed` still mean what they meant, the answer is
  still the model's words spoken verbatim, and the two failure classes are still
  apart. The widening: `unavailable` now also carries "I couldn't work that out
  in time" for a lane that ran out of steps. That is the right *handling* —
  spoken, error-logged, session alive — and `failed` would break the voice over a
  slow think, which the ratified posture reserves for cloud calls that failed.
- **The question lane does not take the task slot.** `.busy` governs `start_task`
  only. The lane resolves nothing, declares three read-only tools (`search_memory`,
  `read_transcript`, `finish` — it cannot speak, ask, or queue), and refusing to
  answer a question because a background task was running would regress M1 for no
  safety gained.
- **`read_transcript` returns excerpts, not an answer.** That is what the fold-in
  buys: one sentence composed from the agent's history *and* TapQ's own memory.
  `TranscriptQuestionAnswerer` gained `excerpts(question:agentDisplayName:)` —
  session resolution, the tail, the on-demand re-read, selection, the three
  unavailability sentences — and its `answer(_:)` now calls it. The direct path is
  kept, not deleted: it is the one-call shape and the composition's fallback.
- **`search_memory` is relevance-first, the mirror of the transcript selector.**
  `WearerMemorySearch` ranks the whole retained record by how many of the query's
  words an entry carries — over its text, outcome, agent, *and* tool name — with
  recency only breaking ties, because the recent window is already in the realtime
  grounding and the loop's job is the older history. A query whose every word is a
  stop word falls back to the recent past; a query with real words that matched
  nothing says so, because handing back unrelated dialogue is how a loop invents a
  memory. No embeddings, same as transcripts.
- **`queue_instruction` requires a name and announces itself.** Two differences
  from the dictation flow, both deliberate. A name is required because the loop is
  not standing in a window and "the agent that just asked me something" does not
  exist off one; the model calls `get_status` (which lists the addressable names)
  first. And what was sent is spoken, because a sentence delivered in the wearer's
  name while they are not listening has to be audible. Rung E's resolver, its
  ambiguity case, and its fail-closed refusal are reused unchanged.
- **`ask_wearer` deliberately skips `resolveApproval`.** It builds the same
  `ApprovalRequest(kind: .question)` the narrated-boundary path builds and runs it
  through the same gate, but not through the approval *wrapper*: that wrapper opens
  a session window, which would put "TapQ" in the roster as an agent the loop could
  then address, and it runs the stage-2 assessment and the delegation filter —
  which could auto-answer TapQ's own question without the wearer. The durable
  record is written at the loop's call site instead.
- **Every ending is audible except the two where nobody is listening.** `finish`
  speaks its summary; the step cap speaks "I couldn't finish: …"; an `ask_wearer`
  nobody answered speaks "I asked you something and didn't hear back…" and stops.
  A cloud failure speaks nothing (the latch has its own notice, and a second
  sentence would be the degraded half-agent). A cancellation speaks nothing
  because both its causes — the wearer ending the voice session, the runtime
  shutting down — take away the channel a sentence would go out on.
- **The `ask_wearer` bound is the question machinery's own.** A window nobody
  answers inside `InteractionBudget.total` (245 s) resolves `.ask`, and the loop
  ends the task there rather than resuming into a turn the wearer is not listening
  to. First unanswered question ends it; there is no second ask.
- **The record is two entries, and the pair is the point.** `WearerDialogueKind`
  gained `.task` — one `static let` plus one recorder, exactly the M3 migration
  story that type documented — written once at the start with outcome `started`
  and once at the end with the ending. A runtime that dies mid-task leaves a
  `started` with no ending, which is the honest record: the loop is gone, the
  request is not. Only speech-cleared text: the goal (read back out loud on
  acceptance, same provenance as a dictated instruction) and one outcome word.
- **One client family, a third method.** `OpenAINarrationModel` now also conforms
  to `WearerTaskReasoning`. Same endpoint, key, timeout race, and failure posture;
  the transport was split out of `perform` because a loop turn reads a
  `function_call` item where the other two read `output_text`. Responses API flat
  function tools with `tool_choice: "required"`, `reasoning.effort: none`,
  `store: false` — so the rendered step history *is* the loop's memory of itself
  and no second copy of the task exists at the vendor. A turn that comes back as
  prose, as a refusal, or as two calls at once is a protocol failure and breaks
  the voice, the same answer an undeclared realtime tool gets.
- **Composition.** `.openaiRealtime` arm only; the Apple path builds no loop, so
  there is nothing to disable and no flag. `onLoopBroken` is the fourth sibling on
  the `VoiceBrokenState` latch, named separately so an operator can tell "could not
  think" from "could not be heard" / "could not understand" / "could not answer".
  The loop is cancelled on runtime shutdown, on the wearer ending the voice
  session, and on the voice pipe breaking. The `start_task` hookup is one line,
  marked `// M2 hookup:`.
- **Verification.** `WearerTaskLoopTests` (multi-step, progress speech, busy
  refusal, empty goal, step cap spoken, last-turn wording, `ask_wearer`
  pause/resume, unanswered bound, cloud break latch, local-file loudness,
  cancellation, the two-entry record across a reopen, an interrupted task's
  dangling `started`, the queued-instruction announcement), `WearerTaskQuestionLaneTests`
  (M1's three outcomes preserved, three-tool declaration, the two failure classes
  apart, the step bound, a question answered while a task runs),
  `WearerTaskContractTests`, `WearerMemorySearchTests`, `OpenAITaskTurnTests`.

### Initiative (M3, the guarded step)

Standing directives — wearer sentences like "watch the build and tell me if
it fails" — are stored as directive entries in Pillar A, listable and
cancellable by voice. A turn-finished event with at least one live directive
invokes the loop with a boundary-review goal: the loop reads the boundary
(and transcript if needed), and either stays silent, speaks, or queues a
follow-up instruction.

Guardrails, non-negotiable:

- **Initiative can never authorize.** Approvals are wearer-only, forever;
  the loop's `queue_instruction` output goes through the same
  no-authority instruction channel as dictation, and whatever the
  instruction causes still hits the approval gate.
- **Every autonomous act is audible.** An instruction queued by the loop is
  announced ("I told Claude Code to rerun the failing suite — you asked me
  to watch the build."), and recorded in Pillar A.
- **Budgets:** per-boundary at most one autonomous instruction; the existing
  3-in-a-row loop cap applies to loop-originated instructions exactly as to
  dictated ones; a directive that fires repeatedly without wearer contact
  (5 times) re-confirms itself before continuing.
- No directive, no initiative: without a standing directive the loop never
  self-invokes.

## Failure posture (consistent with everything ratified)

- Cloud model call failures anywhere in the loop → VoiceBrokenState break
  (same latch, no degraded half-agent).
- Local file problems (memory store, transcript) → loud diagnostics, spoken
  honesty, session alive.
- A task that hits its step cap finishes with a spoken "I couldn't finish:
  …" — never silent abandonment.

## Milestones

- **M1 — perception + memory:** WearerConversationStore (record, persist,
  recent-window grounding, `tapq memory clear`) + Pillar B phase 1
  (TranscriptStore, wire field, direct `ask_about_work`). Independently
  shippable and useful with zero loop. **Both pillars built 2026-08-29.**
- **M2 — the loop, wearer-initiated only:** `start_task`, internal tools,
  `ask_about_work` folded in as a loop task, pause/resume on `ask_wearer`.
  **Engine and composition built 2026-08-29** (see "As built (Pillar C, M2)");
  the realtime `start_task` tool is the other half and lands with it. Hardware
  smoke pending, as for M1.
- **M3 — initiative:** standing directives, boundary-review invocation,
  the guardrail set above.
- **M4 (with FLEET_ROSTER_PLAN rung F):** the loop conducting multiple
  named agents — cross-agent tasks ("have Codex review what Claude wrote")
  become single goals.

## Open questions for the maintainer

1. ~~Memory retention default~~ — **answered 2026-08-29: 30 days rotating,
   plus `tapq memory clear` for the on-demand wipe.** Built as asked; the
   size cap (2 MB) is a second bound and whichever binds first, binds.
2. M3 initiative budgets (proposed: one autonomous instruction per
   boundary, re-confirm after 5 unattended firings) — tune?
3. ~~Verbatim wearer utterances in the recent window, or summaries?~~ —
   **answered 2026-08-29: verbatim, they are short.** Built as asked. The
   window quotes them, and the only bound on one is a 480-character cap
   against a recognizer that ran away with a nearby conversation.
