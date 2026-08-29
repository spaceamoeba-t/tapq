# Changelog

All notable changes to TapQ will be recorded in this file. The project uses
[Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

### Added

- **Ask about the work out loud** (`--voice-backend openai-realtime` only). "What did the
  tests say?", "what command did you run?", "what did it decide about the migration?" —
  TapQ reads the agent's own session transcript and answers, in one sentence, spoken in the
  run's voice. Claude Code's hooks already carry the path to their session file; the shim now
  forwards it as an optional wire field (no protocol bump, inert to older peers), and the
  runtime tails the file from a byte offset, tolerating the rewrites compaction performs. The
  answer is one call to the narration model over slices selected by recency and by the words
  of the question, capped per answer, and it is spoken word for word. Selecting a cloud voice
  backend is the consent for TapQ to read those transcripts: on the Apple path there is no
  store, the tool is never declared, and the forwarded path reaches nothing. Two failure
  classes, kept apart — a transcript TapQ cannot read is said out loud and the session
  carries on; a failed cloud call breaks the run's voice rather than producing a half-answer.
  See [`docs/TRANSCRIPT_CONTEXT_PLAN.md`](docs/TRANSCRIPT_CONTEXT_PLAN.md).

- **Silence is never an answer** (ratified 2026-08-28). A request the wearer directs at TapQ
  that cannot be carried out is now always answered out loud; speech that was not directed at
  TapQ — chatter, thinking aloud, a sentence meant for an agent — is still left alone. Saying
  "approve", "no", or "the second one" with no request waiting used to be answered to the
  model and to nobody else; it now says **"Nothing is waiting."** So do the refusals for a
  list entry TapQ never numbered, a dictation that captured nothing, and a status TapQ does
  not keep. The realtime session's standing instructions carry the matching rule: when the
  wearer addressed a request to TapQ and no tool fits it, the model must answer with one
  short clarifying question or a plain can't-do, and never with nothing. Two silent losses
  found in the same audit are fixed with it — a dictation confirmed into a window that closed
  underneath it was called "Queued for ⟨agent⟩" while reaching no agent at all, and a run
  without `--voice-instructions` swallowed a whole dictated sentence without a word. See
  [`docs/AUDIBLE_REFUSAL_PLAN.md`](docs/AUDIBLE_REFUSAL_PLAN.md), whose sweep table lists
  every refusal branch a voice act can reach.
- **The instruction mailbox says when it displaced something.** It holds four instructions per
  session and drops the oldest to make room for a fifth, which it did in silence: the wearer
  heard "Queued" five times and the agent received four. The read-back now says so —
  "Queued for Claude Code. This replaced the oldest waiting instruction." The rule itself is
  unchanged; only the wearer's ignorance of it is.

- Name-addressed dictation: "tell Codex to run the tests" queues for Codex rather than for
  whichever agent's window the wearer is standing in. The accepted shape is a leading
  `tell ⟨agent⟩ to ⟨…⟩` (a colon, or nothing, may stand in for the `to`), matched
  case-insensitively against display names TapQ already speaks — "claude" reaches Claude
  Code. The address is stripped before the read-back, and the read-back and the queued
  notice both name the resolved agent. A sentence with no address behaves exactly as it did
  before. Only the instruction channel is routable: approvals, selections, and stop answers
  still apply to the open window, always.
- The roster behind it assumes **one live session per adapter**, remembers the most recent
  session per agent from traffic TapQ already handles, and expires an entry after 30 minutes
  of silence. When the assumption breaks it fails closed and says so rather than guessing: a
  second live session for one adapter makes its name ambiguous ("More than one Claude Code
  session is active — say it from that session's window."), and a name nothing live answers
  to is refused by name. Neither queues anything anywhere. Ambiguity clears once the rival
  session ages out. The per-adapter capability table follows the addressee, so a route to
  Cursor is refused exactly as an in-window dictation there would be. See the
  [CLI reference](docs/CLI.md#dictated-instructions).

- Voice sessions, behind `--voice-session` (which requires `--voice-instructions`). When an
  agent finishes a turn, its Stop hook waits on the broker instead of returning: TapQ says
  "Listening." and re-opens a command window until an instruction is queued — delivered as
  the Stop block, so the agent continues — or a tap or gesture ends the session. Inside a
  waiting window an unmatched sentence needs no "tell it to" prefix: it is read back and
  queued on a spoken yes. That closes the last gap in the instruction channel, where a
  sentence dictated to an *idle* agent waited for someone to type. See the
  [CLI reference](docs/CLI.md#voice-sessions).
- **A voice session is not ended by time** (ratified 2026-08-28). The held boundary is a
  renewable lease rather than a long poll with a deadline: the broker answers `renew` when a
  60 s poll elapses with nothing to deliver, the shim re-parks with the same `lease_id`, and
  there is no cap on the renewals. A session that has been quiet for four hours is in the
  state it was in after four seconds. It is let go by a tap or a gesture, by a break in the
  voice pipeline, or by stopping the runtime — and by nothing else. The broker keeps the
  boundary registered across the gap between polls (a 30 s grace), which is both what stops
  "Listening." being re-announced every minute and what releases a boundary whose hook was
  killed: a lease that stops being polled is gone within 90 s.
- Wire protocol v6 adds one message, `instruction.wait`: identity in, an instruction or
  nothing out. v5 and v4 peers remain accepted — each bump since v4 has only added a type,
  leaving every older request shape byte-identical — so an installed shim keeps working
  against a v6 runtime, and a v6 shim never sends a wait to a runtime that predates it.
  Renewable leases did not move the version: `instruction.wait` gained an optional
  `lease_id` an older broker ignores, and the reply gained a `wait: "renew"` value an older
  shim can never provoke and would read as "nothing arrived". A shim that presents no lease
  is given the one-shot ten-minute budget it was built against.
- `tapq integration claude install` now writes a `timeout` of **2 147 483 s (~24.9 days)**
  on the **Stop** hook entry only. That is not a chosen duration but the ceiling Claude Code
  will honor: its settings schema accepts any positive number of seconds, but the value
  reaches a JavaScript timer, and a delay past `Int32.max` milliseconds is treated as an
  overflow and re-set to 1 ms — which would kill the hook immediately rather than never. It
  is the one clock TapQ cannot remove, and it belongs to the agent. **Reinstall the Claude
  hooks after upgrading**: a Stop entry written by an older build carries a shorter timeout
  and would kill a held boundary part-way through.
- The instruction loop cap stands down in a voice session, where every boundary is meant to
  carry an instruction. The four-deep queue cap is unchanged, approvals are untouched, and a
  runtime that exits releases every waiting hook before it goes — a killed `tapq serve`
  never leaves a hook parked.

- `--voice-trust wearer|environment` (Rung E), naming whose voice may dictate an
  instruction. `wearer` is the default and is today's behavior byte for byte. `environment`
  trusts the microphone as the user for the run this feature was previously unreachable in
  — AirPods in their case — so `--voice-instructions` no longer requires `--wearer-gate`
  there, and the fail-closed attribution check is skipped rather than answered. The skip is
  recorded at both stages the wearer path would have checked
  (`instruction.trusted_environment`), so it is never silent.
- **Trust says who may instruct, and nothing else.** Approval grammar, approval read-backs,
  the fail-open-to-screen rule, and "an instruction authorizes nothing" are identical under
  both values. The docs state the cost in one sentence: under `environment` anyone audible
  to the microphone can instruct, and still cannot approve, deny, select, or defer.
  `--attention imu` still requires `--wearer-gate` under either value — a window that opens
  on a wearer-speech onset needs the signal that says whose onset it was.
- Read-backs that stop naming gestures nobody can make: where no motion device is present,
  the dictation and free-form confirmations become "Say yes to queue it." and "Say yes to
  send, or no to discard." The wording follows the live motion probe, so AirPods appearing
  mid-run get the nod offered again on the next read-back. Only composed under
  `--voice-trust environment`, which is what keeps every default-flag run's spoken output
  byte-identical. See the [CLI reference](docs/CLI.md#voice-trust).

- A delegation filter, behind `--auto-answer routine` (which requires `--reasoner` and
  `--reasoner-mode primary`; serving refuses to start without both). An approval is
  answered `allow` silently — no window, no prompt, no sound — when the stage-2 reasoner
  produced a decision, called the action `routine`, cleared the user's confidence floor,
  and named a tool that is not on the never-list. Every other tier, every abstention,
  every timeout, and every sub-threshold decision opens exactly the window it would have
  opened with the flag off. Approvals only: stop questions and selections are
  conversations and are never auto-answered. See the
  [CLI reference](docs/CLI.md#auto-answered-approvals).
- **The reasoner still cannot approve anything.** `ReasonerDecision` has no approve case
  by construction; what a model produces is the observation "this is routine", and turning
  that into a yes is a delegation the *user* performs by enabling the flag. A confused or
  compromised reasoner's worst move is to call a sensitive action routine, which is why the
  tier gate is paired with a confidence floor and a never-list the model can neither see
  nor influence.
- `auto-answer-policy.json`, beside the calibration profiles: `minimum_confidence` (0.8 by
  default) and `never_auto_tools` (empty by default — the routine tier is the gate). Absent
  means the strict defaults; a file that does not parse, or that names an unknown
  `schema_version`, aborts `serve` exactly as a malformed calibration profile does, because
  the file exists to *narrow* what gets answered and a typo must not widen it back out.
  `tapq policy show [--json]` prints the effective policy and says whether it came from a
  file. There is deliberately no `policy set`.
- `auto-answer-log.jsonl` beside the runtime socket, to `ReasonerShadowLog`'s exact
  discipline (`0600` inside the `0700` runtime directory, ~5 MB with one rotation, never
  read back, never leaving the machine, swallowed write failures). An auto-answer is the
  one thing TapQ does with no witness, so this file is the only place a user can find out
  what was said yes to while they were not asked. "Who's waiting?" gains a final clause,
  `"Auto-answered N this session."`, and an auto-allowed approval is recorded in session
  memory like any other, so "what changed?" recalls it.
- Always-on attention, behind `--attention imu` (which requires `--wearer-gate`). A
  refcounted hold keeps the motion subscription running between windows, so an attributed
  wearer-speech onset can open a **command window**: "Yes?", then eight seconds in which
  "status", "what changed", "repeat", and — under `--voice-instructions` — a dictation are
  answered. It opens only when nothing is queued at the interaction gate; if a request is
  waiting, the wearer speaking is a wearer answering it.
- **A command window can never resolve an agent request.** Its result type carries three
  counters and has no case a broker could act on, and it runs inside the same interaction
  gate every request window runs in. A nod, a "yes", or a selection inside one is answered
  "Nothing is waiting." and the window goes on listening. Continuous motion is a real
  battery cost, documented in the [CLI reference](docs/CLI.md#battery) and measured by the
  [Rung D smoke checklist](docs/RUNGD_SMOKE_CHECKLIST.md).
- Quiet output, behind `--quiet`: attention-seeking speech becomes a short synthesized cue
  — a rising two-tone for a prompt, one flat tone for a notification, a deferral, or a
  motion-loss notice — while everything the wearer asked for is still spoken. A wearer who
  asks a question out loud and hears a chime back has been given a worse answer than
  silence, so recall answers, detail read-outs, dictation read-backs, and everything a
  command window says stay speech. Resolution semantics are untouched: a chimed prompt is
  answered by the same nod, in the same window, on the same deadline. Cues are synthesized
  sine bursts on a dedicated audio engine — no assets, and no cue can perturb a response in
  flight. See the [CLI reference](docs/CLI.md#quiet-output).
- `--voice-processing`, an experimental macOS-only spike: Apple's voice-processing IO
  (echo cancellation and AGC) on the capture input node, plus tolerance for the single
  `AVAudioEngineConfigurationChange` that enabling the unit publishes. It is plumbing and
  validation, not barge-in — TapQ still closes the microphone while it speaks, and acoustic
  barge-in ships only if hardware testing shows the cancellation is good enough. With the
  flag off the audio path is unchanged, engine for engine.
- `docs/RUNGD_SMOKE_CHECKLIST.md`, the ladder's largest hardware list: auto-answer
  live-fire against real agent traffic (read every logged row and say whether you would
  have approved it), chime audibility in three environments, always-on battery cost as a
  measured delta, and the AEC verdict that decides whether duplex is ever built.
- Dictated instructions, behind `--voice-instructions` (which requires `--wearer-gate`;
  serving refuses to start without it). Inside any open prompt, "new instruction" or "tell
  it to ⟨…⟩" opens a dictation: TapQ reads the sentence back, queues it only on a nod or a
  spoken yes, says "Queued for ⟨agent⟩.", and hands it to the agent at its next turn
  boundary as a stop reply — "The user dictated a new instruction via TapQ hands-free:
  '⟨text⟩'. Proceed accordingly." The window the wearer was in is untouched throughout:
  the confirming "yes" is consumed inside the flow, and the request they were asked about
  is still waiting when it ends. See the
  [CLI reference](docs/CLI.md#dictated-instructions).
- **Instructing fails closed on wearer attribution, the inverse of authorizing.** A voice
  TapQ cannot prove is the wearer's — including a signal that cannot say whose it is — is
  refused out loud ("I can't confirm that was you — instruction discarded.") and recorded
  as `instruction.rejected_unattributed`. Approvals keep failing *open*, because the
  agent's on-screen prompt is their backstop; a queued instruction has none. Instructions
  authorize nothing: whatever one asks for still goes through the same approval path every
  other tool call goes through, and dictation can never allow, deny, select, or defer.
- A bounded per-session instruction queue (`InstructionQueue` / `InstructionMailbox`): at
  most 4 waiting per session, dropping the oldest at capacity
  (`instruction.dropped_capacity`), one delivered per turn boundary, and at most 3
  instruction-bearing boundaries in a row before delivery pauses with a spoken notice
  (`instruction.loop_cap.suppressed`). Delivered instructions are recorded in session
  memory and recalled as work handed over — "Claude Code was told to run the tests
  again." — never as work done, and "who's waiting?" gains "N instruction(s) queued."
  while any are undelivered.
- `AgentCapabilities`, a static per-adapter table of {approvals, questions, notifications,
  instructions}. Only Claude Code and Codex have a turn boundary TapQ can deliver into;
  dictating at a Cursor or OpenCode session is refused by name ("Instructions aren't
  supported for OpenCode.") rather than silently dropped. See the
  [integration guide](docs/INTEGRATIONS.md#agent-capability-matrix).
- Wire protocol v5 adds one message, `instruction.submit` (token, session id, text,
  request id), acknowledged with `ok` or `error`. v4 peers remain accepted, so every
  installed shim keeps working; adapters emit no instructions and their versions are
  unchanged. A v5 message is never stamped onto a peer that predates it.
- `tapq instruct <session-id> <text>`, a debug and device-adapter seam that submits that
  message to a running broker over the existing socket client. It is documented as such:
  the wearer path's attribution, read-back, and confirmation do not apply to it, and the
  only thing standing in for them is that the caller can already read the runtime's
  private discovery record. Clear errors for a runtime that is not running, one that
  predates the channel, one started without `--voice-instructions`, and an agent that
  cannot be instructed.
- Spoken recall: "what changed?" and "who's waiting?" are answered out loud inside any
  open prompt, on both voice backends and behind no flag. "What changed" speaks this
  session's last three resolved interactions, newest first, composed deterministically
  from what TapQ already said out loud — no model is in the path. "Status" names the
  request in hand and counts the queue behind it ("Claude Code: run the test suite. 2 more
  waiting."), in display names and counts only. Both are matched ahead of the yes/no
  grammar, so a question can never be read as an answer, and neither resolves anything:
  the prompt is re-spoken and the window is still waiting. With nothing recorded, the
  answer is "Nothing recorded yet." Recall is only reachable while a window is open,
  because the microphone is live only then. See the
  [CLI reference](docs/CLI.md#spoken-recall-and-questions).
- A bounded, speech-safe per-session memory behind that recall (`SessionContextStore`,
  `SessionRecall`, and the runtime's `ConversationMemory`): the last 16 events for each of
  the last 8 sessions, holding the agent's display name, the spoken summary and detail,
  the tool name, and the outcome. `toolInput`, `cwd`, and `permissionMode` are structurally
  absent from a recorded event, so no sentence composed from one can carry them. Nothing
  is written to disk and nothing survives a restart.
- `SessionWaitRegistry`, wrapped around the four interaction-gate call sites, so the
  runtime knows who is queued for the wearer's attention rather than only who is being
  spoken to. It is what "who's waiting?" counts.
- Grounded spoken questions on the realtime path, with `--voice-backend openai-realtime`
  and `--voice-freeform`: a question asked inside a tool-approval window is answered in
  the realtime voice from a TapQ-authored instruction — an answering preamble, a digest of
  speech-safe session context, and the question. At most three answers per window
  (`qa.budget_exhausted`), never an approval, a denial, or a selection, and dead on the
  Apple backend or without `--voice-freeform`, where the window behaves exactly as before.
- One short standing instruction on every realtime session (`session.update`): speak
  TapQ's text verbatim, answer briefly from provided context, invent nothing about agent
  state.

- Spoken summaries of an agent's final reply, behind
  `--speech-summarizer auto|apple|anthropic|openai|heuristic|off` (default `auto`: Apple's
  on-device model when the device is eligible, the deterministic local reduction
  otherwise). A yes/no stop question is introduced by one summary sentence before the
  question the user answers; `details` on a stop question now speaks the summary's longer
  text instead of "No further details."; a multi-option question hears the sentence once,
  before the first option and never on navigation or repeat. The sentence is capped at 120
  characters and one sentence, the detail at 320, by truncation applied after the provider
  answers rather than by asking a model to be brief; every provider is composed over the
  deterministic local reduction, so a failure or a five-second timeout costs a plainer
  sentence, and only a reply with nothing speakable in it produces no summary at all — in
  which case every utterance falls back to the words it had without one. `anthropic` and `openai` send the reply to that provider and refuse to start
  without `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`, as the classifier does. No summary
  reaches the wording that names what the user is authorizing: approval prompts,
  confirmation cues, and the question itself stay TapQ's own text in every configuration.
  `off` restores the spoken content of every prompt, detail, and notification byte for
  byte. See the [CLI reference](docs/CLI.md#spoken-summaries).
- Agent notifications say the short message their adapter already sent — "The agent is
  waiting: Needs a decision on the retry policy." — condensed to 12 words. No model is
  involved; the text is the adapter's own. A notification that arrives without one is
  spoken exactly as before, and the whole behavior is off under `--speech-summarizer off`.
- `BackendPreferredSpeech`, a `SpeechPresenting` decorator that offers notification
  utterances to the realtime voice backend and falls back to on-device synthesis whenever
  the session cannot take them. It is composed on the presence of a duplex backend, not on
  the summarizer flag. Only `.notification` priority is routed: the realtime path renders
  text by generating a response from it and may paraphrase, which is acceptable for a
  status line and never for a sentence that names what is being authorized.
- A spoken-summary provider stack in `TapQContextBaseline` mirroring the question
  classifier: `SpokenSummarizing`, `SpokenSummary`, `SpeechSummarizerFactory`, and
  heuristic, Foundation Models, Claude Haiku, and GPT-5.6 Luna providers.

- A one-time spoken startup notice when no AirPods are connected: "No AirPods detected.
  Running voice only." — or "Prompts will use the screen." when voice is unavailable too.
  It is polled on the detector's own bounded availability cadence, so headphones that are
  merely slow to appear never draw a spurious notice, and unlike the mid-window disconnect
  announcement it is a status line and respects `--no-announcements`.
- `MotionGatedSwipes`, a gating decorator beside `SpeechGatedVoice` and `WearerGatedVoice`
  that attaches the volume-swipe channel only while a motion device is present.
  `VolumeSwipeDetector` reads the default output device's volume, so without AirPods it was
  reading the built-in speaker and turning volume-key presses into selection navigation.
  Eligibility is re-read per window, which is also the recovery path: AirPods connected
  mid-session restore swipes on the next prompt.
- An availability-aware selection hint. `SelectionController` takes a `controlsHint`
  provider, consulted when a hint is actually spoken, so a voice-only window teaches
  `SelectionController.voiceOnlyControlsHint` — "Say next, previous, or select." — rather
  than naming volume swipes and nods that cannot resolve the question. The default provider
  keeps the existing wording, and reading it per prompt means "repeat" after AirPods
  connect re-teaches the full controls.
- The ready banner's motion line now says what a session without AirPods is rather than
  what it lacks: `unavailable (voice-only; gestures return when AirPods connect)`.
- An end-to-end detection-path test suite. Generated 25 Hz IMU traces (and transcript
  strings for voice) run through the real, fully composed stack — pipeline, analyzers,
  arbiters, controllers, voice grammar, wearer gate, turn coordinator, and broker — and the
  tests assert on what comes out the far end: a decision, a selection, or response bytes on
  the wire. It covers the core approval and selection loops, the false-positive rejections
  (ambient motion, rotation-contaminated taps, swipe staying off by default), and the
  wearer-attribution and turn-control paths. It is a regression net for wiring, config and
  decision logic only: every trace is shaped by construction, so the capture study remains
  the accuracy gate for every IMU default.

**Cursor adapter**

- `tapq integration cursor install|status|uninstall` manages TapQ-owned
  entries in `~/.cursor/hooks.json`, and the new `tapq-cursor-hook` executable answers
  Cursor's `beforeShellExecution` for non-sandboxed commands, `preToolUse` for the `Write`
  and `Delete` file tools, and `stop` for completion announcements. Unrelated hook data is
  preserved, an existing file is backed up before it changes, and every failure path emits
  no hook output so Cursor's own permission and turn flow stays in control. Cursor exposes
  no hookable question tool and no final assistant text on `stop`, so clarifying and
  final-response questions stay in Cursor's interface. See the
  [integration guide](docs/INTEGRATIONS.md) and
  [manual test plan](docs/CURSOR_ADAPTER_MANUAL_TEST_PLAN.md).

**OpenCode adapter**

- A new `TapQOpenCodeAdapter` module and `tapq-opencode-hook` executable connect OpenCode
  to the existing agent-neutral broker. OpenCode has no hook-registration file, so the
  adapter installs one plugin TapQ owns end to end at `<config>/plugins/tapq.js`,
  resolving `<config>` the way OpenCode does (`OPENCODE_CONFIG_DIR`, then
  `XDG_CONFIG_HOME/opencode`, then `~/.config/opencode`). The plugin relays OpenCode's
  own `permission.asked` prompts and its session-idle completion event to the hook
  executable and applies the hands-free answer through OpenCode's permission API; all
  policy, broker authentication, and speech rendering stay in Swift.
- `tapq integration opencode install|status|uninstall`, with `--plugin PATH` and
  `--hook PATH` for isolated setups. Install refuses to overwrite a file at the managed
  path that TapQ did not write, uninstall removes only TapQ's own plugin, mutations
  snapshot the previous file to a restrictive timestamped backup, and rerunning install
  repairs a plugin left stale by a moved checkout or a hand edit while a matching plugin
  is a byte-for-byte no-op.
- The supported slice is deliberately narrow: allow becomes a one-time `once` reply and
  deny becomes `reject`; the remembered `always` reply is never sent. `bash`, `edit`, and
  `webfetch` get kind-specific speech from documented scalar metadata — a web-fetch URL
  contributes only its host — and every other permission kind is spoken from its name
  alone, so a permission's `metadata` object is never serialized into speech. Broker
  absence, timeout, an incompatible wire version, or no hands-free answer applies no
  reply at all, leaving OpenCode's on-screen prompt pending and usable. There is no
  question interception and no final-response continuation, because OpenCode exposes no
  equivalent surface.
- The adapter targets OpenCode `1.18.15` and deliberately does not use the
  `permission.ask` plugin hook, which is declared in `@opencode-ai/plugin` but never
  triggered by OpenCode ([opencode#7006](https://github.com/anomalyco/opencode/issues/7006)).
  Replies prefer `POST /permission/{requestID}/reply` and fall back to the deprecated
  session-scoped route on the SDK client OpenCode injects into plugins.

### Changed

- **Turn detection without an IMU signal is now semantic, not a silence timer** (ratified
  2026-08-28). On `--voice-backend openai-realtime` with no AirPods turn signal, TapQ hands
  end-of-speech detection to the service; that mode ran `server_vad`, which ends a turn after
  a fixed stretch of silence, and a wearer dictating an instruction pauses to think inside
  their own sentence. Live, it cut sentences in half and the agent received the first half.
  The session now asks for `semantic_vad`, where the model judges whether the wearer sounds
  finished, with eagerness **`low`** — the setting that waits longest — because this path is
  dictation-heavy and losing a sentence costs more than waiting a beat. Override per run with
  `TAPQ_TURN_EAGERNESS` (`low`, `medium`, `high`, `auto`); an unreadable value falls back
  rather than failing the run. Nothing else about the mode moved: `create_response: false`
  and `interrupt_response: false` still hold, TapQ still asks for the response itself, and
  barge-in still belongs to the IMU. Runs *with* an IMU turn signal are untouched. The ready
  line reads "turns ended when the model judges you finished (no IMU turn signal)". See the
  [CLI reference](docs/CLI.md#turn-detection).

- **Model-decided spoken narration on `--voice-backend openai-realtime`** (ratified
  2026-08-28). What TapQ says about an agent's finished turn is no longer assembled from
  templates. At each boundary everything pending for the wearer — the agent's final message,
  plus any TapQ status lines that piled up behind it — goes to a narration model, which
  returns the single utterance to speak and says which of four deliveries it chose: read it
  word for word, summarize it, turn it into a question for the wearer, or merge several
  pending things into one. The returned text is spoken verbatim on the run's one voice, with
  no cap and no re-summarizing, and the guidance prompt biases toward verbatim for short
  content and requires paths, commands, and numbers to be reproduced exactly.
  A narrated *question* runs through the same answer machinery a stop question always did —
  same request, same nod/tap/yes-no, same reply back to the agent — so only the detection and
  the phrasing moved to the model. `gpt-5.6-luna` over the OpenAI Responses API on the same
  `OPENAI_API_KEY`, overridable with `TAPQ_NARRATION_MODEL`; it is a side call and never the
  realtime session. See the [CLI reference](docs/CLI.md#spoken-narration).

- **A dictated instruction is never clipped** (ratified 2026-08-28). The instruction queue
  capped the wearer's own words at 320 characters on the way in, which meant the sentence
  read back for confirmation and the sentence the agent received could differ — and they
  differed at the end, where the qualifying clause lives: a wearer confirmed "run the tests
  but not the slow ones" and the agent was told "run the tests but". The cap is gone on every
  backend, including Apple's; only whitespace is collapsed. The read-back is still shortened
  for speech and still ends in an ellipsis when it is, because what the wearer hears and what
  the agent receives were never the same string.
- On `--voice-backend openai-realtime`, `--speech-summarizer` and `--question-classifier` no
  longer affect turn boundaries: the narration model decides delivery there, and the summary
  templates and the question-mark gate are unreachable. Both flags are unchanged on
  `--voice-backend apple`. A narration failure — HTTP error, 15 s timeout, empty or
  undecodable output — is a voice-pipeline failure that breaks the run's voice channel like a
  dropped realtime socket, with no silent fall back to the removed heuristics; the agent's
  turn still proceeds.
- **Wearer intent on `--voice-backend openai-realtime` is resolved by the model, not by
  keywords.** TapQ declares five tools on the realtime session — `approve`, `deny`,
  `select_item(index)`, `queue_instruction(text, agent?)` and `query_status(kind)` — and the
  model calls one when it understands the wearer to have asked for it. `VoiceCommandMatcher`
  and every other transcript→intent step is gone from that path: the grammar, the "tell
  ⟨agent⟩ to …" prefix rule, the free-form promotion of unmatched sentences, and the
  end-of-session phrase list. Transcripts are still produced and still logged
  (`transcript.observed`); nothing reads them to decide anything. Speech that matches no
  tool does nothing, or draws one short clarifying question — silence and ambiguity are safe
  states, and a window nothing resolves still ends by gesture, tap, or its own deadline.
  Ratified 2026-08-28 after a fragment of ordinary dictation matched the word "no" and ended
  a live session mid-test. **The Apple backend is untouched**: no model to reason with, so
  its grammar, its end phrases, and its matcher are exactly what they were. See
  [docs/REALTIME_INTENT_PLAN.md](docs/REALTIME_INTENT_PLAN.md) and the
  [CLI reference](docs/CLI.md#how-intent-is-resolved-on-the-openai-path).
- **No spoken input can end a voice session on the realtime path.** A spoken "no", "stop",
  "end voice session" or "stop listening" is now an intent about a request that does not
  exist — TapQ says "Nothing is waiting." and keeps listening. A `--voice-session` loop is
  let go by a shake or a tap, by a break in the voice pipeline, or by stopping the runtime —
  never by time. The
  window reads which channel resolved it rather than the intent alone, so the gesture and tap
  endings are unaffected. Both spoken endings still work on `apple`.
- Before each turn's microphone opens, the realtime session's instructions are replaced with
  the context the model needs to choose a tool: whether a window is open, the last few
  sentences the wearer actually heard, and the display names of agents that can be addressed.
  Nothing else — a request's tool input, working directory, and permission mode are never
  spoken aloud, so they cannot reach the model this way either.
- An addressed dictation reaches Rung E's resolver through `queue_instruction`'s `agent`
  argument instead of a spoken prefix, and behaves identically: the same read-back, the same
  fail-closed wearer attribution, and the same spoken refusals for a name nothing answers to
  or a name two sessions answer to.
- Committing the wearer's turn now asks the realtime backend for a response, because a tool
  call is an item inside one. The commit still asks for nothing on the Apple path, and every
  sentence TapQ says still goes out verbatim on its own channel — what comes back is a tool
  call, silence, or one clarifying question.
- Malformed tool-call traffic — an undeclared tool, arguments that will not parse, a call on
  a session with no tools declared — ends hands-free voice for the run through the same latch
  a dropped socket reaches, with a new `tool.protocol_failed` diagnostic. It never falls back
  to matching words: the mirror of "a sentence the backend cannot say is a pipeline failure",
  applied to the wearer's side of the channel.
- `--voice-freeform` is inert on the realtime path for now. Promoting an unmatched transcript
  to an answer is itself a transcript→intent step. Spoken selections are made with
  `select_item` by naming the entry the read-back numbered, and spoken questions are answered
  out loud by the model from the grounding above — which is what the flag's grounded-answer
  path did. A free-text answer to a selection has no tool yet.

- **A non-Apple voice backend now speaks everything TapQ says.** Prompts, option lists,
  read-backs, recall answers, "Listening.", "Queued for Codex.", "Voice session ended.",
  turn summaries and degrade notices all go out on the pipe named by `--voice-backend`;
  the local synthesizer is not used at all while that pipe is alive. Previously only
  notification-priority lines were offered to the backend and everything else — including
  every sentence a busy session declined — was spoken by the local `AVSpeechSynthesizer`, so
  a realtime run alternated between two voices. Worse, the local voice played into the same
  room as the backend's open microphone: on hardware it was transcribed as wearer speech and
  a false `command.matched command=no` ended a session.
- **Sentences TapQ wrote are sent as out-of-band verbatim readings** — `response.create`
  with `conversation: "none"`, an empty `input`, and instructions to read the sentence
  between markers word for word. That is what keeps an approval prompt the wearer's own
  wording rather than a model's paraphrase (the reason the old split existed), and it keeps
  TapQ's script out of the conversation state a grounded free-form answer reads. Grounded
  answers are unchanged: there the model *is* doing the composing.
- **A sentence the backend cannot say is a pipeline failure, never a second voice.** One
  response is in flight at a time, so a sentence written while the pipe is busy queues and
  goes out in order (`speech.queued_for_backend`), and a sentence with no session open opens
  one for itself (`speech_session.opening`). TapQ speaks before it listens: a window that
  comes due mid-sentence defers its user turn (`turn.deferred_scripted_speech`) instead of
  opening a microphone over TapQ's own voice. When delivery is genuinely impossible — the
  session cannot be opened, it dies with sentences waiting, or the queue overflows — the run
  logs `scripted_speech.undeliverable` at error level and takes the existing break:
  `voice.pipeline_failed`, `voice.disabled_for_run`, one local notice, voice off for the
  run. From the break onwards the local synthesizer speaks again
  (`utterance.spoken_locally_after_break`), because windows still open and resolve by
  gesture, tap, and timeout and a prompt nobody can hear makes them unanswerable. The ready
  block's backend line now says `all speech in this voice`. `--voice-backend apple` and every
  no-voice mode are unchanged, engine for engine. See the
  [CLI reference](docs/CLI.md#one-voice).

- The CLI reference now lists the approval grammar word for word instead of saying "an
  affirmative voice command". `approve` and `deny` were always in it — a wearer who reads
  the old wording and guesses has no way to know that, and one who guessed right and was
  re-prompted anyway had no way to tell the grammar apart from the window. The list is the
  same in every window, and the docs now say so, along with what each side does in an
  approval, a selection, and a held voice session, and what happens to a denial word inside
  a dictated sentence.

- **A specified voice backend never degrades into a different one.** `--voice-backend
  openai-realtime` used to be composed with the Apple stack underneath it, so a session that
  could not be opened, or that dropped mid-window, silently continued on-device. That is
  gone. The named backend is now the whole of the voice pipe, and any failure of it after
  startup — a handshake that times out, a socket that drops, a microphone route that goes
  away, response audio that cannot be played — ends hands-free voice for the run. The reason
  is that a cross-backend degrade lies about what the wearer is talking to: the two pipes
  have different capabilities (no free-form, no grounded answers, different endpointing), so
  swapping one in mid-run changes the contract the wearer thinks they are speaking under and
  changes what a test run was measuring halfway through it.
- **What the break does**, in order: two error-level diagnostics naming cause then
  consequence (`voice.pipeline_failed` with `backend=` and `reason=`, then
  `voice.disabled_for_run`); one sentence spoken once through TapQ's own synthesizer
  ("Hands-free voice is off. The voice backend failed."), which is not a backend and so not
  the swap the policy forbids; every held turn boundary released, so a `--voice-session` Stop
  hook carries on instead of waiting out its budget; and a pipe that is never reopened —
  later windows are refused a session before any traffic reaches the backend
  (`open.refused`). From there the run behaves like `--no-voice`: windows open, are spoken,
  and resolve by gesture, tap, or timeout, with approvals still failing open to the agent's
  on-screen prompt. The runtime stays alive; restarting it is the only way back.
- The ready block's `Voice backend:` line drops its `(fail-through: apple)` suffix, which
  was telling operators that a second backend would catch a failure. Nothing else about the
  line changes, including the endpointer it names. Startup refusals are unchanged:
  `--voice-backend openai-realtime` without `OPENAI_API_KEY` is still a command-line error,
  not a break. The AirPods voice-only degrade is unchanged too — it loses gestures and keeps
  the pipe it started with, which is not a backend swap. `FailThroughVoiceBackend` and its
  sticky-skip machinery (`primary.skipped_sticky`, `fallback.opened`, `fallback.turn_resumed`)
  are removed. See the [CLI reference](docs/CLI.md#when-the-backend-fails).
- The `openai-realtime` voice path no longer needs AirPods to be usable. Its only endpoint
  was the IMU one behind `--imu-turn-control`, and on that pipe a transcript does not exist
  until the audio is committed — so a wearer without AirPods spoke into a buffer nothing
  committed until the window timed out, silently. When TapQ has no live wearer turn signal,
  the session is now switched to the backend's own end-of-speech detection
  (`turn_detection: server_vad`, `create_response: false`, `interrupt_response: false`) so
  a transcript arrives and the window resolves through the ordinary match path. The mode is
  chosen at each window open from the live motion state, so AirPods connecting or
  disconnecting mid-run switches it back without a restart, and an IMU-armed run behaves
  exactly as it did before. Declared as a backend capability rather than an OpenAI special
  case. See the [CLI reference](docs/CLI.md#turn-detection).
- **What the backend still may not do.** A native commit ends an *utterance*, not TapQ's
  turn and never a window: the microphone stays open, and only a matched transcript, a
  gesture, a tap, or the timeout resolves anything. The service is configured never to
  create a response and never to interrupt playback, and a commit it makes with the mode
  off is still a protocol violation that ends the session. The honest cost is that in the
  degraded mode the remote endpoint decides where the wearer's sentences end — from audio
  it was already being sent, and only while a window is open.
- An endpointed voice turn that matched no command no longer asks the backend for a reply.
  Committing the turn used to hand the whole utterance to the realtime model and let it
  answer, which was the one path where TapQ spoke a sentence nothing in TapQ wrote. The
  commit now happens without creating a response; every response-suppression path is kept
  exactly as it was, so a grounded reply can be re-enabled once TapQ authors the text it
  asks to have spoken.
- `ApprovalRequest` and `SelectionRequest` carry an optional `spokenPreamble`: one spoken
  sentence of context, said before the prompt and never instead of it. It is presentation
  state and in-process only — no wire message carries it, so a request from an agent
  adapter always has `nil` — and `nil` is the pre-summary wording, word for word.
- Serving with no AirPods connected degrades to a plain voice agent instead of announcing
  a disconnection that never happened. Every response window used to end its bounded motion
  retry by speaking "AirPods motion disconnected. Deferring to the screen.", cancelling
  both arbiters — which took the live voice window down with the dead gesture one — and
  then speaking "Deferring to the screen." a second time from the cancel path. Such a
  window now continues silently on voice and resolves by voice or by its ordinary timeout.
  Voice I/O already followed the system default route, so prompts speak on the Mac's
  speaker and answer through its microphone with no audio change.
- The mid-window disconnect announcement is trimmed to "AirPods motion disconnected." The
  cancel path it triggers already ends in "Deferring to the screen."; the contract is
  otherwise unchanged, including that this one announcement still ignores
  `--no-announcements` because an inaudible state change mid-interaction strands the user.
- `HeadGestureDetector.onMotionLost` carries a `MotionLossReason` — `.neverStreamed`,
  `.lostWhileStreaming`, or `.silentStream` — which is what the host branches on, and the
  `motion.lost` diagnostic gains the matching `reason` field. A pre-1.0 source break for
  anything outside this repository that assigns the callback. `isMotionCurrentlyAvailable`
  is the accompanying instance probe: it asks the detector's own source rather than
  building a throwaway `CMHeadphoneMotionManager`, so availability can be consulted per
  response window without a second manager competing for the headphones.

### Removed

- `FailThroughVoiceBackend`, the two-backend composition wrapper, together with
  `FailThroughStickiness` and the `failThroughStickiness:` parameter on
  `VoiceBackendFactory.select`. Nothing composed it within a single backend, so it is
  deleted rather than narrowed. A pre-1.0 source break for anything outside this repository
  that built one.
- `TranscriptSummarizer` in the Claude adapter, which had no call site and no tests. The
  spoken-summary provider stack replaces the job it was written for.

### Fixed

- **The realtime session's standing rules survive grounding.** Every turn replaces the
  session instructions with what the model needs to know about the window in front of it, and
  because the OpenAI session object restates the whole `instructions` field, the first
  grounded turn of every session was overwriting the standing rules with that window brief.
  From then on the session ran with no rule against firing a tool on a word it merely heard,
  no rule against narrating its own tool results, and no rule about what to do when nothing
  fits. The per-turn context is now appended to the standing rules rather than substituted for
  them, which is what the assembly function this repo already had was written to guarantee —
  nothing had been calling it. Found while wiring the audible-refusal policy, which the same
  gap would have silently discarded.

- **TapQ's own sentence is no longer discarded by the window it is about.** On hardware
  (2026-08-28, `--voice-backend openai-realtime --voice-session`) the wearer asked TapQ to
  hand an instruction to an agent that was not in the run. TapQ refused correctly, wrote the
  refusal, and sent it on its verbatim channel — and the wearer heard nothing at all. Three
  separate mechanisms treated "a window ended" as licence to throw away a response, and none
  of them could tell TapQ's voice from the model's:
  - The match-resolved suppression mark was **response-anonymous**: armed while a response
    was pending, it cancelled whatever produced audio next, which on this path could be
    TapQ's own scripted sentence rather than the answer it was aimed at. It now binds to the
    response it means to abandon — the provider's own response epoch, cross-checked against
    the peer's `response.created` id, newly readable as `VoiceBackend.activeResponseIdentity`
    — and a mark whose response settled first is dropped unfired
    (`response.suppression_skipped_settled`) instead of inherited by the next one.
  - It was armed **twice**, by both paths that resolve a tool-called window: `deliver`, which
    closes the window before handing the command over, and the `stop()` the interaction layer
    makes a beat later. The second ending of one window is now a recorded no-op
    (`window.end_skipped_already_ended`, debug).
  - A response carrying a sentence TapQ wrote is now **categorically unsuppressable** by that
    mechanism: never armed against (`response.suppression_skipped_scripted`), never cancelled
    by a window resolving, never flushed out of the player by one
    (`playback.flush_skipped_scripted`), and its audio is no longer gated on a window being
    open — which is what silenced every notice spoken between windows, the whole point of
    opening a session for a sentence. Barge-in is untouched and still cuts TapQ off the
    instant the wearer talks over it: that cancel is the wearer's, not a window's.
  Suppression still does the one job it exists for — a window resolved while the model was
  answering the wearer abandons that answer, immediately if it has started speaking
  (`response.suppressed_match_resolved`) and on its first audio if it has not
  (`response.suppressed_on_first_audio`) — and both now name the response in the log, as does
  `response.suppression_armed`.
- Cancelling a response TapQ had already cancelled no longer kills the run. The mirror of
  the tombstone fix below: that one absorbs the peer's late `response.done`, this one
  absorbs TapQ's own second cancel. Both come from the same shape — a cancel does not stop
  the frames the peer had already produced, and one of those straggler audio chunks re-arms
  the provider's response-in-flight tracking, so a response retired by one path still looks
  live to another. Live on 2026-08-27: the match-resolved suppression cancelled a dictation
  read-back, the voice session's next listening window cancelled it again, and the turn
  state machine's `noResponseInFlight` latched the no-degradation break — a correct reaction
  to a bogus trigger, with no user input anywhere in it. A cancel with nothing in flight is
  now a recorded no-op (`response.cancel_skipped_idle`) that puts no frame on the wire and
  leaves the first cancel's bookkeeping — tombstone or pending ack — untouched. Exactly one
  violation is absorbed: a cancel against a backend that cannot barge in, a cancel into a
  session that no longer exists, and every peer-side violation are unchanged.
- A window opening no longer chops a sentence off mid-word. Under `--voice-session` the loop
  re-opens a listening window every eight seconds, and the window used to cancel whatever
  the backend was saying on the way in — a spoken summary cut mid-word with nobody having
  spoken, nothing having been asked for, and a clock as the only event
  (`response.cancelled_for_new_window`, now gone). A window that comes due while a response
  is in flight now waits for it: the turn is deferred (`turn.deferred_response_in_flight`)
  and opens on the response's own completion (`turn.started_after_deferred`), which the peer
  always sends, so nothing here is timer-bound. The two cancels that mean something are
  unchanged and still immediate, because both mean the sentence has lost its audience — the
  wearer talking over it (`response.cancelled_by_coordinator`, which now also opens the
  deferred turn on the spot rather than a completion later) and the window that response
  belonged to being resolved (`response.suppressed_match_resolved`,
  `response.suppressed_on_first_audio`). Every cancellation still goes through the tombstone
  path.
- A voice session no longer dies on its own first listening window. Cancelling a response
  did not end it on the wire: the realtime peer still delivered every frame it had already
  produced and then that response's own `response.done`, and the adapter — which had
  forgotten the response at the cancel — read the late completion as one TapQ never
  requested, failed the session, and degraded the run to the Apple backend for the rest of
  its life. Under `--voice-session` that was every turn end, with no user input involved
  anywhere: TapQ speaks the finish notice through the backend voice, the agent's Stop opens
  the listening window in the same breath, and the window cancels the still-streaming
  notice. A cancelled response is now tombstoned by the id the peer gave it in
  `response.created` rather than forgotten, its tail is drained against that tombstone
  (`response.cancelled_done_drained`), and the tombstone is retired by the one
  `response.done` it was owed. The strict check is unchanged for every other case — a
  completion for a response that is neither in flight nor tombstoned still ends the
  session. Tombstones survive turn boundaries (the window opening is the race, not an
  anomaly), end with the session, and are capped at four, the oldest dropped with a
  diagnostic, so a peer that never answers a cancel cannot grow the record without end. A
  peer that names no responses keeps the older "the next terminal frame is the ack"
  bookkeeping, which now also survives the turn boundary.
- Backend response audio is audible again on the `openai-realtime` path. The playback
  engine connected its player node to the mixer in the wire's own interleaved PCM16, and a
  player node's output bus does not accept an integer format: AVFAudio raised
  `kAudioUnitErr_FormatNotSupported` (-10868) out of `connect:to:format:`, so the engine
  never started. The node is now connected in AVAudioEngine's standard deinterleaved
  Float32 at the wire's sample rate — the mixer was always the thing resampling 24 kHz to
  the output device, and that part was never the problem — and each PCM16 chunk is
  deinterleaved and scaled to match before it is scheduled. The shared-engine hosting path
  used for echo cancellation is fixed the same way.
- A playback engine that cannot start no longer leaves a half-alive run. The failure used
  to fail open per response, so the microphone kept pumping and transcripts kept matching
  while every sentence routed to the backend's voice — free-form answers, and
  `Voice session ended.` itself — was silently inaudible; a wearer with no screen had no
  way to learn the state of their own session. An engine that cannot start, or that refuses
  a buffer, now ends the session instead, and the termination lands where every other
  failure of the specified backend lands: hands-free voice ends for the run, loudly and
  once. The verdict lasts the run — a machine that cannot play 24 kHz audio now will not a
  minute from now — so nothing is re-probed at the next window. There is deliberately no
  per-utterance re-speak through the local synthesizer: it would restore the sound and hide
  the state change. The termination is logged at error level as a cause and a consequence
  (`playback.unavailable` with `consequence=voice_disabled_for_run`, then
  `session.terminated` with `reason=playback_unavailable`) ahead of the break's own
  `voice.pipeline_failed` / `voice.disabled_for_run`. An output *route* change is unchanged:
  it still costs one response and nothing more. See the
  [CLI reference](docs/CLI.md#when-playback-fails).
- `--voice-backend openai-realtime` works again. OpenAI retired the Realtime Beta API on
  2026-08-27 and every session open began failing with "The Realtime Beta API is no longer
  supported", silently degrading every run to the Apple backend. The adapter now speaks the
  GA protocol: the `OpenAI-Beta: realtime=v1` header is gone (it, not the URL, is what
  routed the connection to the retired API), the session object carries `type: "realtime"`
  and `output_modalities`, audio settings moved under `audio.input` / `audio.output`, an
  encoding is an object (`{"type":"audio/pcm","rate":24000}`) rather than the string
  `"pcm16"`, and turn detection moved under `audio.input.turn_detection`, where *off* is a
  literal `null` rather than `{"type":"none"}`. The wire audio format is unchanged — 24 kHz
  is the only rate GA accepts for PCM — so the microphone pump and playback are untouched.
  Both turn-detection modes, the manual commit path, and the handshake-ack criterion behave
  exactly as before; `response.output_audio.delta` and `response.done` are now the only
  spellings accepted for response audio and completion, the Beta names having no API left
  to arrive from.
  macOS answers `isDeviceMotionAvailable == true` for AirPods sitting in their closed
  case, so the no-AirPods degrade path — window continues voice-only, says nothing —
  was unreachable in the most common no-AirPods state: every window ran the sampleless
  startup watchdog to exhaustion, announced "AirPods motion disconnected.", cancelled
  the live voice window, and deferred the approval to the screen. The detector now
  reports `never_streamed` for any loss on a source that has never delivered a sample
  in the run, whatever availability claimed, and reserves `silent_stream` /
  `lost_while_streaming` — the reasons the host treats as a disconnection worth
  announcing and cancelling over — for sources that have streamed before. A downgraded
  loss keeps what the watchdog saw locally in a `local_reason` diagnostic field. The
  one-time "No AirPods detected. Running voice only." notice now also has a second
  trigger behind its once-per-run flag: the first `never_streamed` loss, which is the
  moment a run whose availability poll was lied to finds out it is voice-only. `--no-announcements` skipped the session
  memory recording along with the announcement, so a wearer who had asked for silence could
  then ask "what changed?" and be told nothing had. Recording is now unconditional at the
  notification chokepoint and the audio decision is made afterwards, which holds for both
  suppression flags — `--no-announcements` and `--quiet` change what is played and never
  what is remembered.
- Permission modes are read as the modes agents actually send. Both the auto-allow gate
  in the broker and the stop-question opt-out in the Claude hook tested for the substring
  "auto", which matches none of `default`, `acceptEdits`, `plan`, `dontAsk`, or
  `bypassPermissions` — so both were dead code. The new `AgentPermissionMode` contract
  reads them exactly: `dontAsk` and `bypassPermissions` auto-allow under the strict policy
  and skip stop questions; `acceptEdits` auto-allows the edit tools only (`Write`, `Edit`,
  `MultiEdit`, `NotebookEdit`) and still asks its stop questions, because accepting edits
  is not accepting commands; `default` and `plan` get no automatic behavior, as does any
  mode TapQ does not recognize.
- The broker's accept loop survives a transient socket error. Any errno other than `EINTR`
  ended the loop for good, leaving `tapq serve` running and apparently healthy while every
  hook call stalled to its timeout. A recoverable state — an aborted connection, an
  exhausted descriptor table, a momentary buffer shortage — now records an
  `accept.retry` diagnostic, backs off from 10 ms to a 200 ms ceiling, and keeps
  accepting; a dead listener records `accept.stopped` and ends the loop as before.
- A second `tapq serve` no longer takes the socket from the first. Startup unlinked the
  socket path unconditionally, which left the running broker bound to a name no hook could
  reach. Startup now probe-connects an existing path: a live broker fails the second
  instance with "Another TapQ broker is already listening on …", while a socket a crashed
  run left behind is unlinked and rebound. Shutdown removes only a path the instance
  itself bound, and the discovery record is protected the same way.

## [0.5.0-beta.2] - 2026-08-08

*(Replaces 0.5.0-beta.1, which was never released: its tag was cut against a commit
that did not land on `main`, and the repository's tag-protection rules make pushed
tags immutable. The stray `v0.5.0-beta.1` tag should be ignored.)*

TapQ's voice path becomes a live conversation loop. The earbud IMU now yields a
wearer-speech signal — jaw- and skull-borne vibration only the wearer can produce — with
the calibration, capture, and replay tooling to study it, and the cloud voice backend
gained the transport to use it live: TapQ hears through a real microphone pump, speaks
through backend audio playback, and, behind default-off flags, ends the turn when the
wearer stops talking, lets them interrupt the agent mid-sentence, attributes commands to
the wearer, and carries free-form spoken answers back to the agent.

### Added

**Wearer-speech detection and study tooling**

- Wearer-speech detection from head motion. A portable analyzer turns the 25 Hz IMU stream
  into a speaking/quiet signal from the jaw- and skull-borne vibration the earbud picks up
  while its wearer talks, using a differenced-acceleration envelope with hysteresis, a
  hangover hold, a rotation-quiet gate that separates speech from nods and shakes, and a
  minimum duration that separates it from taps. Every threshold lives in a calibration
  profile, so retuning after the capture study is a data change rather than a code change.
- A third calibration profile, `wearer-speech`, alongside gesture and tap. `calibration
  run|show|reset` accept the `wearer-speech` target, `--wearer-speech-profile PATH`, and
  `--speak-seconds N`; a read-aloud phase is appended to the `all` timeline, which now
  covers all three profiles. The document is `wearer-speech-calibration.json`. Each usable
  profile is saved as its phase is assessed, so a failed speak phase keeps a good gesture
  or tap profile, and resetting one target never touches the other two.
- `tapq capture --mic-envelope PATH` co-records a microphone loudness envelope sidecar
  time-aligned to the motion track's own boot clock. It is capture-study tooling for
  labeling wearer speech: no audio is retained, only per-block RMS and peak, written as
  line-delimited JSON behind a `tapq-mic-envelope-v1` header. Unlike TapQ's runtime paths
  this one is fail-closed — a microphone that cannot start aborts before any motion is
  recorded, and a mid-capture route change finishes and writes the motion track, reports
  the truncated sidecar, and exits nonzero.
- `tapq replay` scores wearer-speech detection as an interval rather than an event.
  Ground truth comes from `wearer_speech` label segments or from a `--mic-envelope`
  sidecar, with labels winning when both are present; `--wearer-speech-profile PATH`
  replays a calibrated profile. The report adds frame-level precision, recall, and F1 at
  the capture's sample rate, mean onset latency, and false activations per minute, as a
  text section and as a `wearer_speech` object under `--json`. Existing label files parse
  unchanged and a replay without the new flags produces exactly its previous output.
- `WearerGatedVoice`, a composition wrapper that attributes a matched voice command to the
  wearer using the motion speech signal, passing a command through when the wearer spoke
  within a trailing attribution window. It fails open in every degraded state: no signal,
  a magnitude-only stream, or a wedged analyzer reproduces today's shipped behavior
  verbatim. Not wired into the live runtime yet — live promotion awaits the capture study.
- A `VoiceBackend` contract in `TapQContracts` covering both half- and full-duplex speech
  pipes, with turn arbitration held permanently on TapQ's side: a backend is a speech pipe
  and never ends a turn, an invariant enforced mechanically by a pure turn state machine
  that adapters run internally. Ships with `VoiceBackendCommandProvider`, which adapts any
  backend into the existing `VoiceCommandProviding` composition.
- `tapq serve --voice-backend apple|openai-realtime`. `apple` is the default and is
  byte-for-byte today's composition. `openai-realtime` requires `OPENAI_API_KEY` and
  refuses to start without it, runs the Realtime API in manual-turn mode with server-side
  voice activity detection disabled, and is always composed with the Apple stack beneath
  it — a session that cannot open or that drops mid-window continues on-device instead of
  leaving the window without voice. The ready block reports the composition.
**Live voice loop**

- Conversation-scoped sessions for the `openai-realtime` backend. The WebSocket session
  outlives individual response windows, eliminating the per-window reconnect churn caused
  by `SpeechGatedVoice` stopping and restarting the voice provider on every TTS transition.
  An idle timer (60 seconds with no window open) closes the session; the next window
  reopens from scratch. Fail-through to the Apple backend is sticky per conversation: once
  the primary fails, subsequent windows skip the primary until the conversation resets on
  idle-close reopen, preventing a 5-second handshake timeout at every mic reopen when the
  network is down.
- Response-audio playback for `openai-realtime`. Cloud voice output is played through
  `AVAudioEngine` on macOS. The engine starts lazily on the first chunk of each response,
  stops when drained, and fails open on any playback error — the transcript and the window
  are unaffected. A combined speech activity signal merges TTS and backend playback so the
  microphone is held closed while either source is active, maintaining the strict
  half-duplex guarantee without acoustic echo cancellation.
- Microphone pump for `openai-realtime`. The pipe backend now actually hears the wearer:
  `MicrophonePumpVoiceBackend` opens the Mac's audio input on each user turn, converts
  captured buffers to the pipe's wire format (mono 24 kHz PCM16), and streams them via
  `sendAudio`. The microphone is opened only inside a user turn and never between windows.
  A mid-turn audio route change triggers fail-through to the Apple backend. This closes the
  milestone-one gap where the `openai-realtime` flag transmitted no audio and voice could
  only resolve through fail-through.
- `tapq serve --wearer-gate`. Filters voice commands through IMU-based wearer-speech
  attribution: a command is passed through when the wearer spoke within a trailing
  attribution window. Commands from bystanders or other audio sources are rejected. Default
  off. Fails open in every degraded state — no signal, a magnitude-only stream, or a stale
  analyzer reproduces today's behavior verbatim. Uses `wearer-speech-calibration.json` when
  present, provisional thresholds otherwise.
- `tapq serve --imu-turn-control`. Endpointing: when the wearer stops speaking, the user
  turn is committed after a short delay (0.4 seconds on top of the detector's 0.6-second
  hangover), making voice resolution possible on the `openai-realtime` path before the
  window timeout. Barge-in: when the wearer starts speaking during response audio, playback
  is stopped immediately so the wearer can speak their answer on the next turn. Both are
  additive — gesture, tap, timeout, and command-match resolution continue to work as
  fallback. A dead or absent signal means neither feature fires (fail-open). Default off.
- `tapq serve --voice-freeform`. Free-form spoken answers for selections and multi-option
  stop questions. Requires `--voice-backend openai-realtime`. An unmatched final transcript
  is offered as a free-text reply with mandatory read-back confirmation: the wearer hears
  their answer spoken back and nods to send or shakes to discard. The confirmed text reaches
  Claude Code as a deny reason and Codex as a `request_user_input` answer. Tool approvals
  and yes/no stop questions stay binary — a spoken free-text answer can never authorize an
  agent action.
- Live wearer-speech signal producer. The headphone motion stream feeds a
  `WearerSpeechMonitor` through a fan-out hook on the gesture detector, producing a
  speaking/quiet signal for the attribution gate and the turn coordinator. The signal flows
  only while a response window is open; between windows it goes stale and both consumers
  fail open by design. Multiple consumers get independent handles through a multicast child
  pattern.

### Changed

- The broker wire protocol is now version 4. The `selection` response gains an optional
  `free_text` field for free-form voice answers. The broker accepts both v4 and v3
  requests — request shapes are identical and the only change is the additive response
  field. Shims built against v3 continue to work and simply never see the `free_text`
  field. The v2 legacy bridge is unchanged.
- `VoiceCommand` and `InputIntent` gain a `.freeform(String)` case for free-form voice
  answers. This is the one contract-shape change of the milestone; every consumer switch
  is compiler-audited. Existing composition paths never produce it, so default behavior is
  unchanged.
- The `openai-realtime` composition now uses conversation-scoped sessions with sticky
  fail-through, a microphone pump, and response-audio playback. The default `apple` path
  is unchanged. Without the new flags, `tapq serve --voice-backend openai-realtime`
  resolves windows by gesture, tap, or timeout exactly as before — the only behavioral
  difference is that the pipe actually transmits audio and the cloud voice is audible.

### Fixed

- A spoken refusal can no longer approve. The voice grammar matched `do it` as raw text,
  so "don't do it" and "do not do it" contained an affirmative and were answered before
  the denial rule ran; typographic apostrophes ("don’t", as recognizers actually emit
  them) matched no denial at all, and "not okay" approved on `okay`. Approval is now
  guarded on the whole transcript: any negator — the "no" family, bare "not", "cannot",
  and the contracted forms in any apostrophe spelling — makes `yes` unreachable however
  the words are arranged. Clear refusals answer no; a negated transcript with no outright
  denial ("not okay", "sure, why not") matches nothing and falls back to the agent's
  on-screen prompt. Every rule now matches whole words or runs of adjacent words, so
  "undo items" no longer reads as "do it".

### Compatibility

- Installed hook shims keep working. The broker accepts wire versions 3 and 4, so shims
  built from 0.4.0-beta.1 lose nothing and simply never see `free_text`. Reinstall the
  hooks (`tapq integration claude install` / `tapq integration codex install`) to speak
  v4 and receive free-form answers; a v4 shim speaks v3 to an older broker.
- The flagless default path is unchanged: `tapq serve` without the new flags behaves
  byte-for-byte as 0.4.0-beta.1 apart from the voice-grammar fix above. Every IMU-driven
  feature and free-form voice ships default-off behind explicit flags with provisional
  thresholds until the capture study lands.

## [0.4.0-beta.1] - 2026-08-03

### Added

- Opt-in Codex `UserPromptSubmit` steering for root turns. The matcherless hook emits one
  fixed instruction to use `request_user_input` “when available” only while a live,
  wire-compatible TapQ runtime advertises `--steering`. After reading discovery it makes
  a bounded EOF-only Unix-socket connection to verify liveness, without sending a broker
  request or application data and without a request/response round-trip. It otherwise
  emits nothing, preserving native prompt submission. Existing three-hook installations
  must rerun `tapq integration codex install` to add this fourth hook, then review it in
  `/hooks`.
- Root-agent structured `request_user_input` interception through Codex `PreToolUse`.
  TapQ handles exactly one non-secret, non-auto-resolving single-choice question with two
  or three uniquely labelled options; a selection is returned through Codex's documented
  deny-feedback contract so the native selector does not also open. Unsupported shapes,
  subagents, unanswered interactions, and broker failures emit no hook output and stay in
  Codex's native flow.
- Codex native `PermissionRequest` coverage for canonical MCP connector tools. TapQ
  forwards the original tool name and arguments to its local broker while spoken
  summaries identify only the humanized server and operation, never arbitrary argument
  values. Existing Codex permission rules and native fail-through behavior remain
  authoritative. Existing users must rerun `tapq integration codex install`, then review
  and trust the changed hook definition with `/hooks`.
- Best-effort `tapq integration codex status` diagnostics for the discovered Codex
  executable, version, lifecycle-hook feature, and
  `default_mode_request_user_input`. Plan mode is the reliable structured-question
  surface in Codex CLI `0.146.0`; default-mode availability follows that Codex feature.
  Status resolves and executes fixed `codex --version` and `codex features list` probes
  from the caller's `PATH` under a minimal allowlisted environment; it distinguishes a
  missing executable from a resolved probe that fails or times out. A detected version
  below the tested `0.142.5` lifecycle floor produces a warning. Probe results do not
  change hooks-file status, and trust remains inspectable only in Codex's `/hooks` view.
- Versioned Codex CLI `0.142.5` fixtures for `PermissionRequest` and `Stop`, alongside
  `0.146.0` structured-question, MCP, and `UserPromptSubmit` fixtures. Hook-process-to-
  broker contracts now exercise supported denial and native fail-through for missing
  discovery and incompatible versions; authenticated model-level Codex execution
  remains a manual release boundary.

### Changed

- The in-process reasoner context now carries the exact canonical argument object for a
  Codex MCP call. At the model prompt boundary, complete inputs use sorted JSON and
  oversized inputs use key-balanced excerpts spanning early and late top-level keys,
  with balanced head/tail excerpts of selected values. Non-ASCII scalars and Unicode line
  separators are escaped before budgeting, and the full rendered input including markers
  stays within 4,000 characters. Connector values are not spoken, diagnosed, cloud-sent,
  or persisted in the reasoner review log. MCP review rows also omit the model's free-text
  note and confidence so neither can echo an argument value; constrained tier/code remain
  when the model decided, and outcome remains for every row.
- The default voice now prefers a downloaded high-quality Samantha. The generic English
  selection (`en-US`/`en`, including the default) resolves to premium or enhanced
  Samantha when one is installed and only falls back to the compact system pick — Eddy
  on a bare machine — when the user never downloaded a voice. Regional tags (`en-GB`)
  and explicit voice identifiers are never redirected, so a deliberate Eddy pin still
  gets Eddy. A future cloud or custom local TTS provider will slot in ahead of this
  preference; today the chain is downloaded Samantha, then the system default.
- The broker wire protocol remains at version 3. Hooks and brokers built against version
  0.3.0 remain wire-compatible, but existing Codex installations must reinstall and trust
  the expanded hook definitions to activate the new event coverage.
- Project documentation now leads with the user workflow, with detailed integration and
  roadmap material moved into dedicated guides for easier navigation.

### Fixed

- Voice capture now survives Bluetooth input-route and media-services changes by using a
  fresh audio engine for each listening window, validating the current hardware format,
  and containing AVFAudio Objective-C exceptions at a narrow bridge boundary. A route
  that is still unavailable disables voice for that window instead of crashing TapQ;
  the next window retries with fresh route state.
- Codex activation probes now drain bounded standard output and error concurrently and
  use nonblocking, ordered timeout cleanup. Status diagnostics no longer hang on inherited
  pipe descriptors or crash during Linux process teardown.

## [0.3.0] - 2026-07-29

### Added

- `tapq serve --reasoner off|apple [--reasoner-mode shadow|primary]`: a stage-2 risk
  reasoner that reads the context of a pending approval — tool name, command text,
  working directory, agent, and the summary TapQ speaks — and answers inside the versioned
  `tapq1-decision-v1` contract with a risk tier, a rationale code from a closed set, a
  bounded note, and a confidence. `off` is the default, so gaining the capability never
  gains a reasoner. `shadow` is the mode default and records decisions as diagnostics while
  the confirmation actually demanded stays exactly what deterministic policy set; `primary`
  lets a decision raise the requirement for that request. A reasoner can only ask for
  *more* confirmation — it can never approve, deny, resolve, or weaken a request — so an
  abstention, a confidence below threshold, a timeout, a backend error, and an absent
  model all leave behavior exactly as it is without a reasoner. Every assessment runs under
  a hard 2.25-second wall-clock bound (a 2-second backend budget plus a quarter-second
  backstop), after which the answer is discarded whether or not it arrives. A reasoner that
  cannot be built degrades to no reasoner and reports it rather than refusing to serve.
- Apple Foundation Models as the first reasoner backend, selected with `--reasoner apple`.
  It runs entirely on device, constrains decoding to the contract's own tier and code
  vocabulary, and builds a fresh session per request so one approval's text cannot reach
  the next one's prompt. It requires macOS 26 or newer and a device where Apple
  Intelligence reports the model available; ineligible hardware, Apple Intelligence
  switched off, and assets still downloading are ordinary states that produce no decision
  rather than an error.
- A local shadow-review log at `<broker-dir>/reasoner-log.jsonl`, started whenever a
  reasoner is selected. One JSON line per reasoner-observed approval records the risk tier,
  rationale code, bounded note, confidence or abstention reason, latency, the confirmation
  the decision implied, whether an escalation was actually applied, and what the user then
  decided. Comparing what a decision asked for against what the user did is the only way to
  answer whether `primary` would have been safe. The file is created `0600` inside the
  `0700` runtime directory, is capped at roughly 5 MB with a single rotation to
  `reasoner-log.1.jsonl`, never leaves the machine, and is never read back by TapQ.
- Question fusion: a question routed out of an agent's final response is assessed by the
  same reasoner as a tool approval. Question requests carry the synthetic tool name
  `AgentQuestion` — a value no adapter can produce — so a prompt, a corpus row, and a log
  line all name a question the same way. A question has no command line, no working
  directory, and no detail, so those rows put strictly less in front of the model, and into
  the log, than a `Bash` row does. Multi-option selections are not assessed: a selection
  result is a choice rather than an allow/deny, so there is nothing there for a
  confirmation requirement to raise.
- `tapq bench reasoner --scenarios PATH [--reasoner apple] [--limit N] [--json]`: scores a
  reasoner against a labeled scenario corpus, grading tier as an exact match and rationale
  code as membership in the row's acceptable set, and reporting abstentions, false
  escalation, and p50/p95 latency separately so an always-abstaining reasoner is visible as
  one. The tracked corpus `bench/reasoner-scenarios-v1.ndjson` holds 170 labeled cases
  across destructive, sensitive, routine, and two lookalike slices, with summaries produced
  by the real adapter renderers including their six-word truncation. Unlike `serve`, which
  serves on without a model because a missing reasoner can only mean "no escalation", bench
  fails when the backend is unavailable: a run of abstentions would print as a report and
  read as a result.
- `docs/TAPQ1_STAGE2.md`, the stage-2 design document: what the shipped track measures and
  what it cannot measure on ineligible hardware, the near-term local open-weights backend,
  the continuous-projection track and the paired data it would need, and the go/no-go gates
  in dependency order.
- `ApprovalRequest` carries the request context a reasoner needs to judge an action:
  `toolInput` (the tool's arguments exactly as the agent sent them, holding the full
  command line for `Bash`), `cwd`, `permissionMode`, and `approvalSource`. The broker fills
  them from the hook payload and rejects an approval that names no source. The context
  stays in process — it does not reach diagnostics, the debug sink, or spoken output, and
  both `description` and `debugDescription` are redacted to identifying fields.
- `tapq serve --speech-voice VOICE` and `TAPQ_SPEECH_VOICE` select the voice used for
  spoken output, accepting either a BCP-47 language tag (`en-US`, `zh-CN`) or a macOS
  voice identifier. The environment variable is the practical control for the packaged
  runtime app, which is launched through `open` and takes no flags. A selection that
  matches no installed voice is reported as a `voice.unavailable` warning instead of
  silently falling back; a regional substitution inside the requested language (`en-GB` →
  `en-US`) is accepted, a cross-language one never is, regardless of which way the host's
  AVFoundation happens to fall back. This selects a voice, not a translation: TapQ's spoken
  scaffolding is still English regardless of the value.

### Changed

- `TapQRuntimeServing.serve` takes a `reasonerLoader` parameter alongside the
  configuration, because a loader is a closure while the configuration is portable data. A
  nil loader is not an error: the host reports an unavailable reasoner and serves without
  one. This is a source-breaking change for anything outside this repository that
  implements the protocol, which is why the release is 0.3.0 rather than 0.2.1.
- `JSONValue` and `ApprovalSource` moved from `TapQWireProtocol` to `TapQContracts` so
  `ApprovalRequest` can carry a tool's arguments and its originating hook event with the
  module dependency still running wire → contracts only. `TapQWireProtocol` re-exports both
  declarations, so `import TapQWireProtocol` alone remains sufficient and existing source
  keeps compiling. The encodings are the declarations' own and the bytes are unchanged.
- Auto-mode requests stay exempt from the reasoner. The broker still answers a strict
  `PreToolUse` request whose reported permission mode contains `auto` with allow before an
  `ApprovalRequest` is built, so no such request is assessed, escalated, or logged. This is
  deliberate — it preserves the compatibility shortcut described under strict policy — and
  is worth revisiting once shadow-log field data says what those requests contain.
- Multi-option selection no longer re-teaches its controls on every question. "Volume, then
  nod twice or double-tap." is spoken on the session's first selection and whenever the user
  asks to repeat, and is dropped from every other prompt — the controls do not change
  between questions, and the suffix was a third of the opening utterance. Navigation
  announcements were already terse and are unaffected.
- Spoken output no longer follows the system language. `SpeechEngine` left
  `AVSpeechUtterance.voice` unset, so AVFoundation resolved a voice from the system
  language and never from the text — on a Chinese-language Mac every English prompt was
  read by a Chinese voice, mixing English and Chinese phonology and rendering the readout
  barely intelligible. Synthesis now pins to `en-US` by default, matching the en-US pin
  `VoiceListener.grammarLocale` already applied to recognition.
- `SpeechEngine.voiceIdentifier` is replaced by `SpeechEngine.voiceSelection`, which also
  accepts language tags and is resolved once on assignment rather than per utterance. The
  old property accepted only voice identifiers and no supported configuration path ever
  set it.
- `TapQRuntimeConfiguration` carries `speechVoice`; hosts must apply it to their
  synthesizer.
- The broker wire protocol is unchanged at version 3. Hooks and brokers built against the
  previous release remain compatible with this runtime.

### Security

- The stage-2 reasoner is on-device only in this release. Apple's Foundation Models
  framework runs the assessment locally and no request text — command line, patch text,
  working directory, or spoken summary — is sent anywhere. Selecting a reasoner enables no
  network processing of any kind; cloud processing remains the separate, explicit
  `--question-classifier anthropic|openai` choice.
- A reasoner is shown more than the question classifier is: the established command/path
  context for the request it is judging, rather than assistant reply text alone. All of it
  stays on the machine.
- `reasoner-log.jsonl` is new local state of the same sensitivity class as `broker.json`.
  It omits the full command line, the working directory, and the adapter's detail, but the
  `summary` it records is the text TapQ speaks aloud, and for a `Bash` request that summary
  is the *front* of the command line, which can carry a secret passed as an early argument.
  Deleting the file at any time is safe. See [SECURITY.md](SECURITY.md).

## [0.2.0] - 2026-07-27

### Added

- Per-axis headphone motion throughout the portable pipeline: `HeadMotionSample` now
  carries roll attitude and signed 3-axis user acceleration, rotation rate, and gravity
  alongside the existing magnitudes. `tapq capture` writes the new fields in both JSONL
  and CSV; the original five CSV columns keep their positions, and records captured
  before this change still decode.
- Double roll-tilt navigation: two quick same-direction lateral tilts (ear toward
  shoulder) select the next (right) or previous (left) option. Tilt detection is
  roll-dominant with pitch/yaw crosstalk gates and double-tilt pairing, so nods, shakes,
  and single leans never navigate — the structural collisions that forced the original
  pitch-based tilt out of the runtime.
- An experimental motion-swipe analyzer that recognizes sustained gentle drags on the
  earbud or ear from per-axis acceleration, with gravity-referenced up/down direction.
  Disabled by default (`MotionGesturePipeline.swipeDetectionEnabled`) pending capture
  study validation on real AirPods streams.
- TapQ-1 stage-1 encoder infrastructure: a versioned feature contract
  (`EncoderFeatureLayout`, 9 channels × 32 samples at 25 Hz), a window builder, a
  `MotionWindowScoring` backend protocol, and an `EncoderMotionPipeline` decision layer
  that converts per-window class scores into the same doubled commands as the heuristic
  pipeline. `CoreMLMotionScorer` runs exported models on Core ML and refuses any model
  whose embedded contract metadata disagrees with the runtime. The deterministic
  heuristics always keep running as the offline fallback.
- `tapq replay`: stream a recorded capture through the detection backends offline.
  With a JSONL label file it reports per-gesture precision/recall and false positives
  per minute, and `--encoder-model` adds a side-by-side TapQ-1 encoder run — the
  evaluation yardstick for the capture study and for backend comparison.
- `tapq serve --encoder-model PATH [--encoder-mode shadow|primary]`: attach a TapQ-1
  model in shadow mode (detections recorded as diagnostics while heuristics keep
  driving events) or promote it to primary (heuristic detections logged for
  comparison). A model that fails to load degrades to heuristics and says so.
- `ml/`: the TapQ-1 training pipeline — LIMU-BERT-style masked-reconstruction
  pretraining, supervised joint-head training with time-warp/rotation/noise
  augmentation, Core ML export that embeds the contract metadata, and a synthetic
  smoke test covering train → export → load with no captured data.
- `tapq serve --question-classifier auto|apple|anthropic|openai|local`: choose which
  backend classifies questions in a final agent response. Apple Foundation Models and
  OpenAI GPT-5.6 Luna join the existing Claude Haiku option. `auto` never enables cloud
  processing — it uses the on-device Apple model when available and otherwise the
  deterministic local heuristic. Cloud providers require their API key in the runtime
  environment and fall back to the local heuristic when a request fails.

### Changed

- Denying an approval now requires a double shake, so a single head turn can no longer
  deny a request. `HeadGestureConfig` gains `doubleShakeWindowSeconds` and
  `minDoubleShakeGap`; profiles saved before this change still decode and take the
  defaults.
- Response windows are considerably longer: the interaction budget total moved from 105
  to 245 seconds, and the `tapq serve --timeout` default and maximum from 100 to 240,
  keeping the interaction total inside the shim socket and hook timeouts.
- `TiltCommand` cases are now `tiltLeft`/`tiltRight`; the pitch-based
  `tiltUp`/`tiltDown` tilt and its displacement analyzer are retired. Together with the
  new roll-based `TiltAnalyzer.detect` signature, this is a source-breaking change for
  code consuming `TapQContracts` or `TapQDetectionBaseline` as libraries.
- The TapQ-1 encoder backend pairs shake detections the same way the heuristics do, so
  both backends turn the same physical motion into the same command. Replay label
  segments span the complete doubled gesture accordingly: a `shake` segment covers the
  full double shake, as a `nod` segment covers the full double nod.
- The broker wire protocol is unchanged at version 3. Hooks and brokers built against
  pre-0.2 builds remain compatible with this runtime.

The Codex adapter in version `0.2.0` did not yet provide structured
`request_user_input`, `UserPromptSubmit` steering, MCP approvals, or activation
diagnostics; those capabilities arrive in `0.4.0-beta.1`.

## Pre-0.2 development (never released)

### Added

- Portable Swift packages for motion detection, calibration, interaction,
  context classification, wire messages, and agent-neutral broker behavior.
- A headless macOS runtime for AirPods motion, voice, and volume input.
- A cross-platform CLI for runtime management, calibration profiles, motion
  capture, Claude Code integration, Codex integration, and version reporting.
- Strict and native Claude Code permission policies with fail-through behavior.
- Explicitly enabled Claude Haiku classification of questions in final agent responses,
  with deterministic local classification as the default.
- A stable Codex lifecycle-hook adapter and `tapq-codex-hook` executable, tested against
  the Codex CLI 0.142.5 hook contract. The initial slice handles native
  `PermissionRequest` approvals for `Bash` and `apply_patch`, plus `Stop` completion and
  final-response questions through `last_assistant_message` with native fail-through.
- `tapq integration codex install`, `status`, and `uninstall` commands for merging TapQ
  hooks into `~/.codex/hooks.json` or `$CODEX_HOME/hooks.json` while preserving unrelated
  entries and backing up existing configuration.
- macOS and Linux CI definitions and public-boundary checks.

### Changed

- Agent identity, runtime presentation, and documentation now distinguish Claude Code
  and Codex requests without changing wire protocol v3.
- The macOS runtime now uses the `ai.tapq.cli` bundle identifier associated with
  [tapq.ai](https://tapq.ai). Existing development installs may be asked for Motion,
  Speech Recognition, and Microphone permissions again after rebuilding.
- Documentation now identifies Wavo as TapQ's internal pre-release codename, and the
  brand policy permits ordinary source-code forks used for contributions.

### Security

- Codex installation leaves exact-definition hook trust to Codex. Users must review and
  trust new or changed TapQ command hooks through `/hooks`; TapQ does not bypass or write
  Codex trust state.

[Unreleased]: https://github.com/spaceamoeba-t/tapq/compare/v0.5.0-beta.2...HEAD
[0.5.0-beta.2]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.5.0-beta.2
[0.4.0-beta.1]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.4.0-beta.1
[0.3.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.3.0
[0.2.0]: https://github.com/spaceamoeba-t/tapq/releases/tag/v0.2.0
