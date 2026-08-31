# Realtime intent policy: no keyword matching, no voice kill

Status: ratified by the maintainer 2026-08-28, during live no-AirPods testing.
Applies to the `openai-realtime` backend (and any future model-backed backend).
**Implemented 2026-08-28.** Hardware smoke still pending — everything below is
verified against the scripted realtime peer and the portable suites, not yet
against the live service.

## The two rules

1. **No voice-initiated termination.** No spoken input may end the voice
   session or the runtime on the realtime path. Negation words ("no", "kill",
   "stop") occur naturally in conversation and dictation; a session that dies
   whenever one appears is unusable. Live evidence 2026-08-28: a transcript
   fragment matched `command=no` → `voice_session.ended by=deny` mid-test.
   The voice session ends only by: the session budget expiring, gesture/tap
   resolution, or shutting down the runtime. Approving or denying an *agent
   request* remains a voice action — only termination leaves the voice channel.

2. **No keyword matching or heuristics anywhere on the realtime path.** The
   maintainer's words: "for the entire openai-realtime path, don't do any
   keyword matching or heuristic." Transcript string-matching
   (VoiceCommandMatcher grammar: approve/deny synonyms, "tell ⟨agent⟩ to …",
   "who's waiting?", item words) is removed from the realtime pipeline. Wearer
   intent is resolved by the realtime model itself via tool calling.

The Apple backend is unaffected: it has no model to reason with, so its
transcript grammar remains, including its existing end phrases.

## Mechanism: realtime tool calling

Declare TapQ's actions as tools in `session.update`; the model calls a tool
only when the wearer's meaning is unambiguous, and TapQ executes it.

- `approve` / `deny` — resolve the open approval window.
- `select_item(index)` — pick from a read-back list.
- `queue_instruction(agent, text)` — dictated instruction, optionally
  addressed by name; feeds the existing InstructionAddressing resolver
  (unknown agent → the same spoken refusal as today, via the tool result).
- `query_status(kind)` — "who's waiting?", "what changed?" style queries,
  answered from the same context TapQ uses today.
- `start_task(goal)` — added by milestone M2 of `TAPQ_AGENT_PLAN.md`, and
  declared only where a deliberation loop is composed (its own gate, the same
  shape as `ask_about_work`'s). Everything above it is the reflex tier and is
  unchanged: single-step intents resolve directly, with no loop in the path.
  This one hands the wearer's goal across the `WearerTaskStarting` seam and
  speaks the sentence that comes back — an acknowledgment, or that TapQ is
  busy — verbatim on the scripted channel. It resolves nothing, needs no open
  window, and starts nothing the wearer will not still be asked to approve.

Contract details:

- Tool calls arrive as response function-call items; TapQ executes, returns
  the tool result, and lets the model voice the confirmation (single-voice
  rule, see VOICE_BACKEND_FAILURE_PLAN.md addendum).
- Speech that matches no tool with confidence does nothing, or the model asks
  one clarifying question. Silence and ambiguity are safe states; no action
  fires off a fuzzy match.
- Window context (what is being approved, the read-back list, known agent
  names) is supplied per-window via session/response instructions so the
  model grounds its tool choice.
- Transcript events become logging/diagnostics only. The intent path never
  reads them.
- Fail-loud posture unchanged: malformed tool-call protocol traffic or a
  failed tool round-trip is a pipeline failure → VoiceBrokenState break. No
  degradation to transcript matching.

## What is removed on the realtime path

- VoiceCommandMatcher and every transcript→intent branch in
  VoiceBackendCommandProvider's realtime composition.
- All spoken end-of-session triggers ("no"/deny-in-listening-window ends the
  session, "stop listening"), and any other keyword-fired state transition.

## What is kept

- The window/arbiter/broker machinery: tools resolve to the same intents
  windows already consume; only the recognizer→intent step changes.
- Rung E name routing semantics (fail-closed unknown-agent refusal), now fed
  by `queue_instruction`'s `agent` argument instead of the "tell ⟨x⟩ to" prefix
  rule.
- The Apple path, gesture/tap resolution, budgets, and the no-degradation
  break policy.

## As built

Where the implementation reads differently from the sketch above, and why.

- **Confirmations are spoken by TapQ, not narrated by the model.** The plan said
  "return the tool result, let the model voice the confirmation". What ships
  sends the `function_call_output` item and starts no response after it: the
  wearer hears TapQ's own sentence, verbatim, on the scripted-speech channel
  every other TapQ utterance already uses. The single-voice rule holds either way
  — all speech is backend-voiced — and this way a refusal is not paraphrased and
  an outcome TapQ already announces is not announced twice. A clarifying question
  is unaffected: the model produces it as ordinary response audio on the wearer's
  own turn.
- **`queue_instruction` and `query_status` need an open window too.** The plan
  listed them as valid with no window open. They are not, and the reason is that
  delivering either one *is* the window's flow: dictation carries the read-back,
  the fail-closed wearer-attribution check, and the confirm; a status answer is
  spoken into the window that asked. Executing them window-free would be the
  instruction path with its confirmation removed. All five tools are therefore
  refused through the tool result when nothing is listening; the two
  wearer-initiated ones say so out loud ("I wasn't listening just then — say it
  again"). In practice the case is defensive: the model only produces a call
  inside a response to a committed wearer turn, and turns exist only inside
  windows.

  **Amended 2026-08-28 — the three answers no longer stay silent.** They did,
  and the reasoning was that the question an `approve` answers is already
  resolved, so announcing the race would report it to somebody who never saw one.
  The audible-refusal decision (`docs/AUDIBLE_REFUSAL_PLAN.md`) overturned that:
  the wearer this path exists for has no screen, and saying "approve" into a
  quiet room and hearing nothing is indistinguishable from a dead microphone.
  `approve`, `deny`, and `select_item` with no window now speak **"Nothing is
  waiting."** — a different sentence from the dictation one, because there is
  nothing to repeat. The race the silence protected against is rare and now costs
  one short sentence. `Resolution.refused` no longer has an optional `speak` at
  all, so a refusal added later cannot be silent by omission.

  The same amendment closes a gap this paragraph's sibling above creates: because
  `sendToolResult` starts no response, a tool output that told the model to say
  something was never said. Every refusal's wearer-facing sentence therefore goes
  out on the scripted channel, and the outputs that used to end in "Ask the wearer
  …" now state what TapQ has already told them.
- **The address is re-attached to the sentence.** `queue_instruction(agent:text:)`
  is delivered as `.beginInstruction("tell ⟨agent⟩ to ⟨text⟩")` through
  `InstructionAddress.compose`, the documented inverse of the parser the dictation
  flow already runs. It is not a grammar — nothing reads a transcript, and the name
  arrived as a structured tool argument — and it is what keeps Rung E's resolver,
  read-back, and unknown-agent refusal at exactly one implementation.
- **The wearer's turn now asks for a response.** A tool call is an item inside a
  response, so `endActiveTurn` commits with `expectingResponse: true` on this path
  (it still asks for nothing on the Apple path). What comes back is a tool call,
  silence, or one clarifying question — the standing instructions say so in as
  many words, and every TapQ sentence still goes out verbatim on its own channel.
- **Grounding is the sentences TapQ just spoke.** Per turn, immediately before the
  microphone opens, the session instructions are replaced with three things:
  whether a window is open, the last few sentences the wearer actually heard, and
  the live agent display names. Nothing else. Because every one of those sentences
  was already sent to the backend to be read aloud, the redaction rule holds by
  construction — tool input, working directories, and permission modes are never
  spoken, so they cannot reach the model this way.
- **A tool call from a cancelled response is dropped.** Barge-in and
  match-resolved suppression tombstone a response, and the tail it still owes can
  contain a completed call. Executing it would authorize something the wearer had
  already talked over. It is dropped, left unanswered (nothing is parked — TapQ
  cancelled the response it belonged to), and logged as
  `tool.call_dropped_cancelled`.
- **A second failure hook.** `VoiceBackendCommandProvider.onIntentPipelineFailed`
  is the mirror of `onScriptedSpeechUndeliverable` and is wired to the same
  `VoiceBrokenState` latch: that one fires when TapQ cannot be heard, this one when
  the wearer cannot be understood. Neither degrades.
