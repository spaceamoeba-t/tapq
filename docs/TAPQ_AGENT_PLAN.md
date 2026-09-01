# TapQ as an agent: memory, transcript context, and the loop

Status: direction ratified by the maintainer 2026-08-28 ("TapQ itself will
become a small agent with its own agent loop, and this agent will be
controlling other agents such as Claude Code"). **Milestones M1 and M2
implemented 2026-08-29** (M1: both pillars; M2: `start_task`, the loop, its
seven internal tools, `ask_about_work` folded in — see the "As built"
sections and the answered open questions below); M3–M4 not started.
Everything here is
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
  "tell Codex to do what Claude just did", "run the tests and let me know
  if anything fails". The goal is handed to the TapQ loop and the wearer
  hears an acknowledgment. (A pure work-history *question* — "what did the
  tests say?" — stays on `ask_about_work`, which since M2 runs through the
  loop's bounded question lane anyway; the original example here predated
  M1 shipping that tool.)

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
  case. The rejected alternative was answering the peer immediately and speaking
  later, which would leave the realtime model free to talk over TapQ's own answer.
  **Maintainer call wanted** if 35 s is too long.
- **The evidence is pre-fetched, so the typical question is one model call again
  (2026-08-30).** Measured live, every `ask_about_work` cost two sequential
  `gpt-5.6-luna` calls — ~1.1 s to decide to read the transcript, then ~1.2–3.8 s
  to write the answer — roughly double M1's single call, with the wearer standing
  there. Both lookups are *local reads over the question itself*, so the first
  call was deciding nothing the loop could not do without it. The lane now runs
  `read_transcript` (the question, the named agent) and `search_memory` (the
  question) through the same two surfaces the model would have called, before the
  first turn, and hands both to it as `WearerTaskTurnRequest.evidence` — rendered
  apart from the step history, because a model told it already called a tool it
  never called will not call it when it should. This is not a new cap: the 3-step
  and 20 s bounds are untouched, and a model whose pre-fetched evidence does not
  answer may still spend a turn on a sharper `search_memory` or a different
  agent's transcript. Pre-fetch failures keep the two classes apart exactly as
  mid-lane failures do — an unreadable history is loud, honest to the model,
  spoken, and survivable; a memory read that fails is loud and the lane answers
  from the transcript anyway, and never speaks about TapQ's own record in place of
  an answer about the agent's work. `task.question_answered` now carries
  `latency_ms`, `model_calls`, `slices`, and `memories` so the improvement is
  readable on hardware.
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
- **A goal no tool reaches is refused out loud, not forwarded (2026-08-30).**
  Live, the wearer's goal was "start a new session in Claude Code". Nothing
  composed here can start a session — that is rung F / M4 — and the loop, having
  no ending for it, queued the goal *verbatim* into the Claude Code session that
  was already running, where it combined with unrelated context and surfaced
  minutes later as an approval request the wearer could make no sense of. The fix
  is an eighth tool, `cannot_do(spoken)`, and the prompt that steers to it: goals
  about TapQ itself, about starting/stopping/switching agent sessions, or
  otherwise outside the agents already connected end with a spoken can't-do that
  names the limit ("I can't start or stop agent sessions — I can only instruct
  ones already connected"), and `queue_instruction` is stated to be for work the
  *target agent* should do, never a way to relay a goal the loop could not act on.
  No keyword matching: the model decides, per the 2026-08-28 no-heuristics ruling,
  and the instruction text is pinned in `WearerTaskContractTests`. The outcome
  vocabulary gained a sixth word, `refused` — `finished` would tell a wearer
  asking tomorrow that TapQ did it, and `could not finish` is a task that ran out
  of turns trying. Task lane only; the question lane keeps its three read-only
  tools and its own honest-miss rule.
- **Every ending is audible except the two where nobody is listening.** `finish`
  speaks its summary; `cannot_do` speaks the limit; the step cap speaks "I
  couldn't finish: …"; an `ask_wearer`
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
  dangling `started`, the queued-instruction announcement, the spoken can't-do
  that queues nothing and records `refused`), `WearerTaskQuestionLaneTests`
  (M1's three outcomes preserved, three-tool declaration, the two failure classes
  apart at the pre-fetch as well as mid-lane, the one-call typical answer, a
  second lookup still available inside the bounds, the step bound, a question
  answered while a task runs), `WearerTaskContractTests` (including the pinned
  refusal and pre-fetch instruction text), `WearerMemorySearchTests`,
  `OpenAITaskTurnTests`.

### Initiative (M3, the guarded step)

Spec revised 2026-08-31 after a three-way design review (blast-radius map
of this repo; standing-order patterns from automation systems and the
mixed-initiative literature; a survey of proactive behavior in shipped
voice-agent stacks). The shape held up — a boundary event injected into
the one conversation loop, deliberation on the cloud model — but the
original text leaned on two things that are not true of this codebase and
one thing nobody has shipped; the corrections are folded in below.
Deliberately deferred, not forgotten: an interactive ask rung, a
preference-learning path, and any inspection surface beyond voice
listing. Live directives have to earn those.

**Directives.** A standing directive is a wearer sentence — "watch the
build and tell me if it fails" — recorded as a `directive` entry in
Pillar A. At creation TapQ compiles it into an envelope stored alongside
the sentence: event class, a cheap predicate over the boundary summary,
the permitted acts, a cooldown/dedup key, and a time-to-live. Before the
directive goes live TapQ reads back one canonical paraphrase ("I'll speak
up when a build fails after a turn; I won't touch approvals; say 'drop
that' to cancel") — the verbal-order pattern; people mis-model even
two-clause rules they wrote themselves, and one sentence is the cheapest
correction available. Directives are listable and cancellable by voice;
cancellation is a tombstone append (the store stays append-only) and
"live" is a fold over the record. At most three directives are live at
once — past that, "one instruction per boundary" stops being a rate limit
and becomes a lottery among rules.

**Firing: gate first, model second.** A turn-finished event with live
directives runs the envelope gate before any model call: predicate match,
cooldown/dedup (a flaky build re-running is one fact, not three), TTL —
and four structural refusals: the boundary was caused by TapQ's own
queued instruction (the provenance loop-breaker: automation's own events
never re-trigger the automation), the voice latch is broken (no
deliberation on a dead pipe), the task slot is busy, or the directive was
suspended. Every gate refusal is silent and logged with its reason —
"why didn't it fire" must be answerable without a transcript dig. Only a
boundary that passes the gate invokes the loop, in a third
`WearerTaskMode` (boundary review) whose tool set is narrowed the same
structural way the question lane's is: the read-only surfaces plus
`speak`, `queue_instruction`, `finish`, `cannot_do` — no `ask_wearer`.
The directive's sentence is the model's brief; the model decides what to
say or do, never whether the gate should have fired. (Every surveyed
product decides *whether* declaratively and asks the model only *what*;
the one benchmark of model-decided silence found systematic
over-triggering.)

**Acts and the voice channel.** A review ends one of three ways: silent
(recorded), spoken, or one queued instruction. Review speech does not
enter the channel through the loop's direct speech path — it routes
through `NotificationPolicy` as a deferrable producer, so an open command
window defers it exactly as it defers an agent notification. The review
is a third producer of unprompted speech and obeys the same lock as the
other two; anything else re-opens the drain-and-deferral defect class
from a new door. A queued instruction is announced first, and delivery to
the held boundary waits out the announcement plus a short grace so a
spoken "cancel" retracts it before it lands — announce-then-act with
reversal, the after-the-fact form of approval.

Guardrails, non-negotiable:

- **Initiative can never authorize.** Approvals are wearer-only, forever;
  the loop's `queue_instruction` output goes through the same
  no-authority instruction channel as dictation, and whatever the
  instruction causes still hits the approval gate.
- **Every autonomous act is audible and attributed.** An instruction
  queued by the loop is announced ("I told Claude Code to rerun the
  failing suite — you asked me to watch the build."), recorded in Pillar
  A, and carries an origin tag — loop-originated, not dictated — end to
  end, so the record, the caps, and the delivery template can all tell
  whose sentence it was.
- **Budgets, origin-aware.** At most one autonomous instruction per
  boundary. Loop-originated instructions get their own 3-in-a-row cap
  with its own counter: the dictation cap is deliberately stood down in
  voice sessions (`suppressesLoopCap`) — exactly M3's configuration — so
  "the existing cap applies" was never satisfiable by composition, and
  the autonomous counter must be one the stand-down does not cover.
- **Quality suspends; time and contact expire.** Two wearer rejections or
  corrections of the same directive suspend it, audibly — a rule that
  misfires twice is wrong no matter how few times it has fired. A
  directive also expires at its TTL, renewable by voice; wearer contact
  resets nothing by count (five correct firings during a heads-down hour
  are no reason to interrupt; two ignored wrong ones are the thing worth
  catching).
- **The injection boundary.** Boundary content is untrusted agent output.
  It can never create, modify, re-confirm, or cancel a directive — only
  wearer speech can — and the directive's sentence reaches the model
  separately labelled from the boundary's content.
- No directive, no initiative: without a live standing directive the loop
  never self-invokes — no timer, no ambient watching.

### As built (M3 kernel, 2026-08-31)

The maintainer scoped M3 to its kernel: **one-shot follow-ups**, not the
standing-rules layer above. "When Claude Code finishes, rerun the tests" —
held one per agent, fired once at that agent's next finished boundary,
then gone. The directive store, envelope compilation, TTLs, the three-live
cap, and quality-keyed suspension all remain unbuilt, deliberately: a
one-shot dies with its firing, so most of the standing-rules guardrail
set has nothing to guard yet. What was built, in the ratified build
order:

- **Instruction origin, end to end.** `QueuedInstruction` carries
  `InstructionOrigin` (`dictated`/`loop`); every loop-composed instruction
  is tagged `.loop`, delivered with an agent-visible attribution, and
  bounded by its own 3-in-a-row cap in `StopQuestionCoordinator` — a
  second counter, checked ahead of `suppressesLoopCap`, because the
  dictation cap stands down in voice sessions and the review found the
  original "the existing cap applies" unsatisfiable by composition.
- **Loop speech as a deferrable producer.** `NotificationPolicy.routeLoopSpeech`
  holds the review lane's sentences while a command window is open, replays
  in arrival order alongside agent announcements, and drops-with-record at
  the same 60s bound (distinct diagnostic, expiry hook). The task lane's
  direct speech path is unchanged — its sentences answer a wearer who is
  mid-conversation. `--no-announcements` structurally cannot reach loop
  speech. **Amended after the second hardware run (2026-09-01):** a voice
  session re-opens its windows with no gap, so a held loop sentence never
  saw a close and the follow-up's result expired unspoken; the wearer had
  to ask. `NotificationPolicy` now takes an `idleListening` seam — the open
  window is the session's idle wait, nothing in hand — and loop speech is
  said into an idle wait (on arrival, or released from the queue when the
  wait resumes). Agent notifications keep their deferral and bound.
- **The book and the third lane.** `WearerFollowupBook` (one promise per
  agent, replace-audibly, cancel-by-voice, consume-on-fire, every
  lifecycle event recorded as a `followup` entry), `WearerFollowupScheduler`
  (one owner for every sentence the wearer hears about a promise; rung E's
  resolver is the name authority), and `WearerTaskLoop.runFollowup` — a
  third `WearerTaskMode` with 4 steps / 60s, no `ask_wearer`, silent
  refusals returned as dispositions rather than spoken (`busyNotice`
  addressed to nobody was the reviewed defect). Realtime tools
  `set_followup` / `cancel_followup`, plus the loop-surface twin so a
  running task can register its own continuation — the M4 seam.
- **The firing, gated then graced.** At a `finished` boundary: cheap gate
  (pending? latch alive? slot free? — a busy slot leaves the promise
  armed), consume, announce through the deferral, then a short grace so a
  spoken cancel retracts before anything acts (`claim()` is the atomic
  check; an announcement that expires undelivered aborts the firing —
  acted-on-unheard would break announce-everything). Consume-before-
  announce is what makes the provenance loop structural: nothing is left
  in the book for the firing's own instruction to re-trigger.
- **A turn ending is not the work ending.** First hardware run (2026-09-01):
  the agent launched the suite with `run_in_background`, its turn ended at
  once, the follow-up fired against a suite still running, and the result
  was never reported. Now `SessionContextStore` remembers a session whose
  approved tool call carried `run_in_background`, settles it at that
  session's next `finished` boundary (`TurnEnding.leftWorkRunning`, consumed
  once), and the gate holds the promise on such a boundary instead of
  consuming it — recorded as `held: work still running`, spoken as "left
  work running in the background — your follow-up is still waiting". It
  fires at the following boundary, which in Claude Code is the turn the
  task notification wakes. The one edge: a task that completes inside the
  turn that launched it holds one boundary too long, audibly, and the
  wearer can cancel or ask for status.
- **Not persistent, and honestly so.** A follow-up does not survive a
  runtime restart; session end, channel break, and shutdown all expire the
  book audibly into the record, where the `expired` entry is the trace.

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
  the guardrail set above. **Spec revised 2026-08-31 after design review;
  kernel built the same day** (see "As built (M3 kernel)"): the two
  cross-cutting legs — origin-tagged instructions with their own cap, and
  review speech through `NotificationPolicy` — landed first as ordered,
  then one-shot follow-ups instead of the standing-rules layer, which
  stays deferred until repeated one-shots prove it is missed.
- **M4 (with FLEET_ROSTER_PLAN rung F):** the loop conducting multiple
  named agents — cross-agent tasks ("have Codex review what Claude wrote")
  become single goals.

## Open questions for the maintainer

1. ~~Memory retention default~~ — **answered 2026-08-29: 30 days rotating,
   plus `tapq memory clear` for the on-demand wipe.** Built as asked; the
   size cap (2 MB) is a second bound and whichever binds first, binds.
2. ~~M3 initiative budgets~~ — **answered 2026-08-31: one autonomous
   instruction per boundary stays; the count-of-5 re-confirm is replaced.**
   Counts were the wrong metric — every mature system keys on quality,
   time, or presence, not firings. As revised: two rejections suspend a
   directive audibly, a TTL expires it (renewable by voice), and the
   loop-originated 3-in-a-row cap gets its own counter that
   `suppressesLoopCap` does not stand down.
3. ~~Verbatim wearer utterances in the recent window, or summaries?~~ —
   **answered 2026-08-29: verbatim, they are short.** Built as asked. The
   window quotes them, and the only bound on one is a 480-character cap
   against a recognizer that ran away with a nearby conversation.
