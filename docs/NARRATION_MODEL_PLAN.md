# Spoken narration: no truncation, model-decided delivery

Status: ratified by the maintainer 2026-08-28. **Implemented 2026-08-28** — see
"As built" at the end for what the code does that this plan did not say.
Companion to REALTIME_INTENT_PLAN.md (inbound intent) — this is the outbound
half: what TapQ speaks to the wearer, and what it forwards to agents.

## The two rules

1. **Wearer input is never clipped.** A dictated instruction or question is
   queued, carried over the wire, and delivered to the agent intact and full.
   The `SpokenSummary.detailCharacterLimit` truncation at
   `InstructionQueue` construction (and any other cap on wearer-authored
   text) is removed from the delivery path. The maintainer's words: "you must
   not clip or truncate user inputs, it needs to be intact and full."

2. **Heuristic summarization is removed; a cloud model decides delivery.**
   The rule-based spoken-summary machinery (combining heuristics, templates
   that shorten agent output before speaking) is dropped on model-backed
   backend paths. Per boundary, a narration model receives what is pending
   for the wearer (agent final message, turn outcome, queued notices —
   possibly several) and decides, per item or combined:
   - read it out word for word,
   - summarize it,
   - turn it into a question to ask the wearer,
   - or merge multiple pending items into one utterance.
   The decision is guided by a written system prompt, not code heuristics.

## Model selection

Fast and cheap, per backend family, configurable. For the `openai-realtime`
backend the narration model is `gpt-5.6-luna` (maintainer-specified,
2026-08-28), called over the standard OpenAI REST API with the same
`OPENAI_API_KEY`. The realtime session itself is not used for narration
decisions — narration is a side call whose *output text* is then spoken
verbatim on the scripted-speech channel (single-voice rule holds).

## Failure posture

Consistent with the no-degradation policy (VOICE_BACKEND_FAILURE_PLAN.md):
a narration-model failure on the realtime path is a voice-pipeline failure →
VoiceBrokenState break. No silent fallback to the removed heuristics.

## Scope

- Apple-only path: unchanged (no cloud available there); it keeps today's
  behavior. The no-truncation rule (rule 1) is universal — wire and queue
  caps on wearer text are removed everywhere.
- Redaction is unchanged: the narration model may only see speech-eligible
  surfaces (the same fields TapQ is already allowed to speak — never
  toolInput, cwd, permissionMode).
- Approval prompts and TapQ's fixed confirmations remain scripted verbatim
  sentences; narration governs agent-output delivery and multi-item
  boundaries, not the safety-critical read-backs.

## As built (2026-08-28)

Where the implementation is more specific than the plan, or differs from it.

### Rule 1

One truncation existed and it is gone: `QueuedInstruction.init` capped the
wearer's text at `SpokenSummary.detailCharacterLimit` (320). It now only
collapses whitespace — a newline would break the stop-hook delivery template,
and a dictation transcript has no line structure worth keeping. The rest of the
path was audited and was already clean: the wire (`instruction.submit`,
`stop.question`) has no length validation and no frame cap, `BrokerServer`
trims and logs a length but never shortens, and `StopQuestionCoordinator.instructionReply`
interpolates the whole string.

The read-back in `InstructionDictation.run` still condenses to 24 words / 160
characters and was left alone: it already queued the *full* sentence while
speaking a shortened one ending in an ellipsis, which is the behavior the rule
asks for. Session memory (`SessionContextStore`) still caps its recorded detail,
because that field is a spoken recall surface and not the agent's copy.

`QueuedInstruction.textCharacterLimit` is removed rather than raised. A cap that
exists is a cap a future edit can lower.

### Rule 2

- **Endpoint**: the OpenAI **Responses** API (`/v1/responses`), not chat
  completions. Two reasons: it is what `OpenAILunaSummarizer` and
  `OpenAILunaQuestionClassifier` already speak, so the request shape, the strict
  `text.format.json_schema` block, and the `status`/`incomplete_details`/`refusal`
  decoding are reused rather than reinvented; and strict structured output is
  load-bearing, because TapQ speaks `utterance` verbatim and *branches* on `mode`.
  `reasoning.effort: none` is set for latency.
- **Model**: `OpenAINarrationModel.defaultModel = "gpt-5.6-luna"`, overridable by
  `TAPQ_NARRATION_MODEL`. No CLI flag — the model id is an operational detail of a
  path the operator already chose with `--voice-backend openai-realtime`, and the
  environment-key convention matches `TAPQ_SPEECH_VOICE`.
- **Timeout**: 15 s, deliberately generous. The call runs while a Stop-hook
  boundary is held and its lease renews, so slowness costs latency only, while a
  tight bound would break the run's voice pipe over a busy minute at the provider.
- **Call site**: `StopQuestionCoordinator.narrateBoundary`, reached from `handle`
  *after* instruction delivery and the two loop guards and *instead of* the
  classifier and summarizer. The guards (repeat, answer-chain cap) are loop
  safety and were kept on both paths; everything else below the fork is heuristic
  and is unreachable with a narrator composed.
- **Multi-item**: the loop-cap notice, which used to be spoken on its own, is
  buffered into the same boundary's narration call instead of racing the narrated
  utterance. `noteNarrationNotice(_:session:)` is the seam; the buffer is bounded
  at four per session and drains once.
- **Question mode**: builds the same `ApprovalRequest` the heuristic yes/no branch
  built (`kind: .question`, `toolName: "StopQuestion"`), runs it through the same
  `runApproval`, and returns the same `reply(question:answer:)` string. Only the
  detection and the phrasing moved to the model. `spokenPreamble` is `nil` and
  `detail` is `""`: those two fields existed to reassemble a question out of a
  summary, which is now one string.
- **Failure**: `StopQuestionCoordinator.onNarrationFailed` is wired in
  `AppleTapQRuntimeService` to `VoiceBrokenState.noteBackendFailed`, the same latch
  `onScriptedSpeechUndeliverable` and `onIntentPipelineFailed` reach. A parallel
  hook rather than a reuse, because the failure originates in the coordinator and
  not in `VoiceBackendCommandProvider`. The boundary still fails open to the agent:
  TapQ going quiet must not also stop the agent.
- **Apple path**: `boundaryNarrator` is `nil` there, so the narration fork is never
  entered. There is no flag to read and nothing to disable.
