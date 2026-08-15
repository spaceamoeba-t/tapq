# Changelog

All notable changes to TapQ will be recorded in this file. The project uses
[Semantic Versioning](https://semver.org/) for tagged releases.

## [Unreleased]

### Added

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

- `TranscriptSummarizer` in the Claude adapter, which had no call site and no tests. The
  spoken-summary provider stack replaces the job it was written for.

### Fixed

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
