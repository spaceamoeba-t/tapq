# Transcript context: full session history for cloud backends

Status: ratified by the maintainer 2026-08-28. **Phase 1 implemented
2026-08-29** — see "As built" at the end for what the code does that this
plan did not say. Hardware smoke still pending: everything below is verified
against fixture transcripts, the scripted realtime peer, and a fake HTTP
transport, not against a live session. Absorbed 2026-08-28 as Pillar B /
milestone M1 of TAPQ_AGENT_PLAN.md (TapQ as an agent); this doc remains the
detailed spec for the transcript pillar.
Companions: REALTIME_INTENT_PLAN.md (how the wearer's intent reaches TapQ),
NARRATION_MODEL_PLAN.md (how TapQ speaks). This plan is what TapQ *knows*.

## The rule

When the user has selected a **cloud voice backend** (`openai-realtime`
today, any model-backed backend later), TapQ may read each connected agent
session's full transcript — every user message, assistant message, and tool
call with its input and output — and use it to answer wearer questions.

The maintainer's reasoning, recorded: selecting a cloud backend implies the
user trusts cloud model providers, and the agent's data already lives on a
provider's servers. Selecting the cloud backend IS the consent; there is no
additional flag. (Note recorded for honesty: this moves agent-session
content across providers — e.g. Claude Code transcripts into OpenAI calls.
Maintainer accepted this explicitly, 2026-08-28.)

The Apple/local path is untouched: event-level memory only, structural
redaction exactly as today. The redaction contract is not weakened there —
it is *scoped*: it remains the rule for local surfaces and for what TapQ
speaks unprompted; cloud-model *reading* under a cloud backend is exempt.

## Acquisition, per adapter

- **Claude Code (phase 1).** Every hook invocation already carries
  `transcript_path` — the session's full JSONL on local disk; the shim
  already opens it for the final assistant message. The shim forwards the
  path as a new **optional** wire field on events it already sends (inert to
  old peers, no version bump — the `lease_id` pattern). The runtime tails
  the file incrementally: byte-offset checkpoint per session, tolerant of
  truncation/rotation (compaction rewrites), re-syncing from the top when
  the offset is invalid.
- **Codex (phase 2).** Codex writes session rollout files under
  `$CODEX_HOME/sessions`; same tail-and-index approach once the shim can
  name the file. Not in scope for phase 1.
- **Cursor / OpenCode.** No transcript surface is handed to hooks; they stay
  at event-level visibility. Documented in the capability table.

## Storage and indexing

`TranscriptStore` (portable, Linux-testable): per-session parsed entries
(role, text, tool name, tool input/output, timestamp), a bounded in-memory
tail (recent entries), and on-demand re-read from disk for older ranges.
TapQ persists nothing itself — the agent's transcript file is the store;
TapQ keeps offsets and a lightweight index. Entries die with the runtime.

## Answering questions with it

A new realtime tool, `ask_about_work(question, agent?)`, joining the five
from REALTIME_INTENT_PLAN.md:

1. The wearer asks something about the work; the realtime model calls the
   tool (its descriptions steer work-history questions here, generic
   what-is-pending questions to `query_status`).
2. TapQ selects transcript slices — recency-weighted plus simple relevance,
   capped (~100k chars per answer; log what was dropped) — no embeddings in
   v1; the answer model is capable of reading generous slices.
3. One call to the narration-family model (`gpt-5.6-luna`, same
   `OpenAINarrationModel` client, Responses API, strict schema) with a
   written guidance prompt: answer only from the provided history, quote
   technical tokens exactly, say plainly when the history doesn't contain
   the answer, keep it speech-shaped.
4. The answer text is spoken verbatim on the scripted-speech channel
   (single-voice rule), and enters per-turn grounding like every spoken
   sentence, so follow-ups cohere.

Deliberately NOT: piping the transcript into the realtime session's
instructions (size, cost-per-turn, and it would pollute the conversation
the intent model reasons over). Grounding stays lean; retrieval is
per-question and out-of-band.

Boundary narration keeps its current inputs (final message, notices). A
later phase may enrich it with transcript context; not in scope now.

## Read vs. speak

Cloud models may **read** transcript content; TapQ still never *volunteers*
it — transcript content is spoken only as the answer to a wearer question.
The answer-model prompt instructs it never to recite credential-shaped
strings (keys, tokens) even when asked to read output verbatim — best-effort
and documented as such; the structural guarantee remains only where it
always was (local path, event memory, unprompted speech).

## Failure posture

Two distinct failure classes, one clean line between them:

- **Cloud call fails** (HTTP error, timeout, refusal): same model family and
  endpoint as narration, so the same posture — voice-pipeline failure →
  VoiceBrokenState break. No degraded half-answer.
- **Transcript unreadable** (path missing, parse error, permissions): NOT a
  voice break — the voice pipe is intact and killing the session over a
  rotated file is disproportionate. Error-level diagnostics
  (`transcript.unavailable reason=…`), and the tool result says so, so the
  model tells the wearer out loud that session history is not visible.
  Loud, never silently pretending; but alive.

## Gating and composition

- Composed only on the cloud-backend branch in `AppleTapQRuntimeService`
  (the `.openaiRealtime` arm, where the narrator is composed). Apple branch:
  no TranscriptStore, no tool declared, shim field ignored — structurally
  absent, not disabled.
- `ask_about_work` is declared to the realtime session only when a
  TranscriptStore exists.
- Diagnostics: `transcript.attached session=… `, `transcript.tailed
  bytes=…` (throttled), `ask.requested`, `ask.answered latency_ms=…
  slices=…` — lengths and counts only, never content, never the key.

## Verification sketch

- TranscriptStore unit tests against fixture JSONL (growth, truncation,
  rotation, malformed lines).
- Tool round-trip with the scripted realtime server + fake HTTP transport:
  question → slices → answer spoken; unavailable-transcript refusal;
  cloud-failure → break latch.
- Redaction/scoping tests: apple composition declares no tool and reads no
  file; event memory unchanged on both paths.
- Linux per-suite as always; macOS build.

## Phasing

1. **Phase 1 (this plan):** Claude Code transcripts, `ask_about_work`,
   TranscriptStore, wire field, docs. **Implemented 2026-08-29.**
2. **Phase 2 (deferred):** Codex rollout files; narration enrichment;
   retrieval quality (embeddings) if plain slicing proves insufficient.

## As built (2026-08-29)

Where the implementation is more specific than the plan, or differs from it.

- **The wire field rides three messages, not all of them.** `approval.request`,
  `notification.event`, and `stop.question` carry an optional
  `transcript_path`; `selection.request` and `instruction.wait` do not. The
  three that do cover every session that ever asks for anything and every
  session that merely finishes a turn (a Stop is a notification), so a fourth
  carrier would add a code path and no coverage. No version bump, on the
  `lease_id` reasoning, pinned by `TranscriptWireFieldTests`.
- **The broker's seam is a callback, not a contract field.** Adding
  `transcriptPath` to `ApprovalRequest`/`AgentNotification` would have put a
  filesystem path on the types the whole interaction layer passes around, for
  one reader. `BrokerServer` takes an optional
  `onTranscriptPath(BrokerTranscriptAttachment)` instead — session id, agent,
  path — and the Apple composition passes `nil`, so the field arrives, decodes,
  and reaches nothing.
- **`ask_about_work` needs no open window.** The plan grouped it with the five,
  and the five all refuse when nothing is listening because delivering them
  *is* a window's flow. A question delivers no command: there is nothing for a
  window to receive, and refusing an answer because a prompt closed a beat
  earlier would only leave the wearer's question unanswered. It also resolves
  nothing — the window it arrived inside is left exactly as it was found, which
  is what keeps a question from resolving an approval by accident.
- **The peer waits for the answer.** Every other tool result goes back before
  anything happens; this one goes back after, because the result says what TapQ
  *did*, and until the answer exists TapQ has not done it. The call is bounded
  by the answer model's own 15 s timeout, the same bound narration runs under.
- **One client, two prompts.** `OpenAINarrationModel` gained a second method
  and conforms to `WorkQuestionAnswering`. Same endpoint, same key, same
  strict-schema decoding, same timeout race — and, the part that matters, the
  same failure posture, rather than a second client that could learn to degrade
  on its own. Diagnostics are prefixed `narration.` or `ask.` so an operator can
  tell which call failed.
- **Slice selection is recency-first, then relevance.** Always take the newest
  ~20 entries, then rank the rest by how many of the question's own words they
  contain, all under a 100k-character budget with a per-entry cap of 8k so one
  enormous tool output cannot evict the twenty lines around it. Everything
  dropped is reported as counts and lengths (`ask.dropped entries=… chars=…`).
- **Which session a question is about.** M1 answers about the session TapQ has
  most recently read from, which is exact with one agent connected and is the
  seam rung F's roster plugs into. A wearer who names an agent TapQ cannot route
  to is therefore answered about the active session rather than refused; the
  name is still passed to the answer model, which sees it in the prompt.
- **Failure hooks are three, not two.** `onWorkAnswerFailed` joins
  `onScriptedSpeechUndeliverable` and `onIntentPipelineFailed` on the same
  latch. Separate because an operator reading the log has to know whether TapQ
  could not be heard, could not understand the wearer, or could not answer a
  question.
- **Verification.** `TranscriptStoreTests` (growth, a half-written line,
  truncation, a rewrite that leaves the file *longer*, window clamping,
  malformed lines, the three unavailable reasons, tail bound),
  `TranscriptQuestionAnswererTests` + `TranscriptSliceSelectionTests`,
  `AskAboutWorkTests` (declaration scoping, round trip, window untouched,
  unavailable spoken, cloud failure breaks and says nothing),
  `TranscriptWireFieldTests`, `HookShimTranscriptPathTests`,
  `TranscriptAttachmentTests` (the Apple path's `nil` callback).
