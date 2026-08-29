# Transcript context: full session history for cloud backends

Status: ratified by the maintainer 2026-08-28. Not yet implemented — plan
under review. Absorbed 2026-08-28 as Pillar B / milestone M1 of
TAPQ_AGENT_PLAN.md (TapQ as an agent); this doc remains the detailed spec
for the transcript pillar.
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
   TranscriptStore, wire field, docs.
2. **Phase 2 (deferred):** Codex rollout files; narration enrichment;
   retrieval quality (embeddings) if plain slicing proves insufficient.
