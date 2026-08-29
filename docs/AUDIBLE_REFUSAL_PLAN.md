# Audible refusal: silence is never an answer

Status: ratified by the maintainer 2026-08-28. **Implemented 2026-08-28**, on
top of the suppression fix whose scripted-speech invariant it depends on. See
[As built](#as-built) for where the implementation reads differently from the
sketch, and [The sweep](#the-sweep) for the audit item 4 asked for.

## The rule

When the wearer directs a request at TapQ and it cannot be done — unknown
agent, nothing waiting, unsupported adapter, capability off, model could
not map the words to an action — TapQ says so out loud. The maintainer's
words: "make sure TapQ answers when user told it to do something [that]
can't be done, silence isn't perceived good to users."

Distinction that keeps this sane: **directed requests speak; ambient speech
does not.** Dictation that becomes an instruction, an answer to a question,
or chatter the model maps to nothing with no directive intent stays
non-annoying (dictation already gets a read-back; true chatter gets
nothing). The rule targets the case where the wearer *asked for an act* and
the act did not happen.

## Known silent spots to fix (audit found 2026-08-28)

1. **`approve`/`deny`/`select_item` with no open window** are refused via
   tool result with no speech (REALTIME_INTENT_PLAN "As built" chose
   silence for the race case). Change: speak a short refusal ("Nothing is
   waiting.") — the race the silence protected against is rare, and a
   wearer who says "approve" into a quiet room deserves an answer.
2. **A directed request the model cannot map** can end in a no-tool,
   no-question response. Strengthen the standing instructions: when the
   wearer addressed TapQ with a request and no tool fits, the model must
   answer audibly — one clarifying question or an explicit "I can't do
   that" — never nothing.
3. **Mailbox drop-oldest**: queueing a 5th instruction silently discards
   the oldest. Announce the displacement in the queue read-back ("Queued —
   this replaced the oldest waiting instruction.").
4. **Anything else the audit turns up**: sweep every refusal/no-op branch
   reachable from a wearer-directed act (instruction to Cursor/OpenCode,
   capability-gated paths, broken-state reopens, loop caps) and verify each
   either speaks or is unreachable from voice. Broken-voice state is exempt
   after its one notice — the mic is dead and nothing can hear the wearer.

## Interaction with the suppression fix

The suppression bug (2026-08-28) silenced refusals that were *meant* to be
spoken. That fix restores the pipe; this plan guarantees every can't-do has
a sentence to send down it. The scripted-speech-unsuppressable invariant
from that fix is a precondition.

## Verification sketch

Table-driven tests: every wearer-directed refusal path × asserts a spoken
utterance is enqueued. E2E: no-window approve speaks; unknown agent speaks
(exists); unmappable directed request yields clarification or can't-do.

## As built

Where the implementation reads differently from the sketch above, and why.

- **`Resolution.refused` lost its optional.** The plan described adding speech to
  three refusals. What shipped changed the type: `refused(output:speak:)` takes a
  non-optional `speak`, so *every* refusal has a sentence and a new one cannot be
  added silently. The `output`/`speak` split stays — they are written for
  different readers — and a test asserts they are never the same string.
- **The model cannot voice a refusal, so it never gets the chance.** Item 2 asked
  the standing instructions to make the model answer when no tool fits. That is
  in, but the audit turned up why it could not have covered the tool refusals as
  well: `sendToolResult` starts no response, so anything a tool output told the
  model to say would never be said. Two tool outputs used to end in "Ask the
  wearer …" and were therefore dead letters; they now state what TapQ has already
  told the wearer, and the sentence itself goes out on the scripted channel. The
  standing instructions cover exactly the case they can: a directed request that
  reached no tool at all.
- **Two "nothing is listening" sentences, not one.** `approve`/`deny`/
  `select_item` with no window say **"Nothing is waiting."**; `queue_instruction`
  and `query_status` keep **"I wasn't listening just then — say it again."** The
  remedy differs: repeating a dictation is useful, repeating "yes" into the same
  silence is not.
- **Drop-oldest is announced as a clause, not a replacement.** The plan's example
  was "Queued — this replaced the oldest waiting instruction." What ships appends
  to the existing confirmation: **"Queued for Claude Code. This replaced the
  oldest waiting instruction."** The agent's name is load-bearing on a routed
  dictation and dropping it to make room for the new clause would lose more than
  it gained. Which sentence was displaced is deliberately not read back — it would
  be the wearer's own words returned to them minutes late.
- **Item 2 could not have worked as written, and the reason was a wiring gap.**
  The standing rules were never reaching a live session. `updateInstructions` is
  called once per turn with the window brief, and GA restates the whole
  `instructions` field, so the first grounded turn of every session overwrote the
  base instructions and the tool policy with the brief. The function written to
  prevent exactly that — `RealtimeDefaults.instructions(grounding:)`, whose doc
  comment says grounding "is appended rather than substituted so a session can
  never end up running on window context with the standing rules missing" — had
  no production caller. The realtime adapter now assembles there, which is the
  only layer that can: the provider is portable and cannot see `RealtimeDefaults`.
  Strengthening the prompt without this would have changed nothing.
- **Three defects the sweep turned up were fixed with it**, all the same shape as
  the ones the plan names:
  - A dictation confirmed into a window that closed underneath it was queued
    nowhere while TapQ said "Queued for ⟨agent⟩" — silence would have been bad,
    an untrue confirmation is worse. `InstructionDictating` now answers
    `InstructionQueueOutcome`, and the sentence is composed after the mailbox
    replies rather than before. `.notQueued` speaks "That wasn't queued after
    all — say it again."
  - A run without `--voice-instructions` had no mailbox, so the dictation flow
    exited silently. But `queue_instruction` is declared on every model-backed
    session regardless of the flag, so a wearer could dictate a whole sentence
    into that run and hear nothing. It now speaks "This run isn't set up to send
    instructions to agents."

## The sweep

Item 4's audit. Every refusal or no-op branch a wearer-directed voice act can
reach, and what each one does about it. "Exempt" is the broken-voice state after
its one notice: the mic is dead and nothing can hear the wearer.

| Branch | Verdict |
|---|---|
| `approve` / `deny` / `select_item`, no window | **speaks** — "Nothing is waiting." (new) |
| `queue_instruction` / `query_status`, no window | **speaks** — "I wasn't listening just then — say it again." |
| `select_item` index below 1 | **speaks** — "I didn't catch which one — say the number." (new) |
| `queue_instruction` with nothing to queue | **speaks** — "I didn't catch that — say it again." (new) |
| `query_status` with a kind TapQ does not keep | **speaks** — "I can't answer that — ask what's waiting, or what's changed." (new) |
| Malformed arguments / undeclared tool | **exempt** — a pipeline failure, which breaks the voice channel and speaks its one break notice |
| Tool call on a session with no tools declared | **unreachable** — no shipped composition declares tool calling with grammar intent; also breaks the channel |
| Tool call from a cancelled/tombstoned response | **covered** — the response was cancelled *because* the window resolved, and that resolution speaks its own outcome; announcing the race as well would double-speak the normal path |
| Instruction to Cursor / OpenCode / any agent whose adapter takes none | **speaks** — "Instructions aren't supported for ⟨agent⟩." (in-window and name-routed alike) |
| Instruction to an unknown agent name | **speaks** — "I don't know an agent called ⟨name⟩ — instruction discarded." |
| Instruction to an ambiguous name | **speaks** — "More than one ⟨agent⟩ session is active — say it from that session's window." |
| Unattributed voice at either dictation stage | **speaks** — "I can't confirm that was you — instruction discarded." |
| Dictation declined at the read-back | **speaks** — "Instruction discarded." |
| Dictation with no mailbox (`--voice-instructions` absent) | **speaks** — new; see As built |
| Confirmed dictation the mailbox did not take | **speaks** — new; see As built |
| Mailbox at capacity, oldest displaced | **speaks** — new; the confirmation gains a clause |
| Selection index out of range | **speaks** — "Option N is not available. There are M options." |
| Window loop cap (6 turns) or deadline | **covered** — the window's own residual sentence is spoken as it ends, and every exit that resolves nothing speaks its deferral |
| Voice cannot end the session (`--voice-session`) | **speaks** — falls through to the window's "Nothing is waiting." |
| Backend declined the model turn (`requestModelTurn` false) | **exempt** — only reachable through a turn-state violation, which fails the session into the break notice |
| Model turn skipped, response already in flight | **covered** — the wearer hears the response that is already speaking, and the segment is read with the next turn |
| Scripted sentence undeliverable (queue overflow, dead session) | **exempt** — reported as the run's voice break, one notice |
| Every backend call after the break | **exempt** — one notice already given |
| Grounded answer declined (no session, turn open, budget spent) | **grammar path only** — unreachable from the model path, where the model answers questions itself; the window re-speaks its prompt |
| Unmatched final transcript, grammar path | **grammar path only** — the Apple recognizer has no model to ask, and the window re-prompts |
| Held-boundary lease expiry, second concurrent boundary | **not a wearer-directed act** — the agent's hook stopped coming back; nothing was asked of TapQ |
| Wire `instruction.submit`, `tapq instruct` refusals | **unreachable from voice** — CLI/adapter paths, answered on stderr and on the wire |
