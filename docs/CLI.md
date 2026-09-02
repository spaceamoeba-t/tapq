# TapQ CLI Reference

The `tapq` executable is TapQ’s headless user interface. It runs the local
broker, manages calibration and agent integrations, and captures raw headphone
motion for diagnostics. There is intentionally no GUI and no end-user
`gesture analyze` command.

Examples use `tapq` as shorthand for the built executable. From a source
checkout, use `swift run tapq` for management commands such as version, profile
inspection, and integration status. Commands that need macOS privacy permissions
should run through `scripts/run-runtime-app.sh`. No system-wide installation is
published yet.

## Command overview

```text
tapq calibration   Run, inspect, or reset AirPods calibration
tapq calibrate     Shortcut for `tapq calibration run`
tapq capture       Capture raw headphone motion as JSONL or CSV
tapq replay        Replay a motion capture through detection backends offline
tapq bench         Score a stage-2 reasoner against a labeled scenario corpus
tapq serve         Run the local agent-neutral broker
tapq instruct      Queue an instruction for a session on a running broker (debug)
tapq integration   Manage agent integrations
tapq memory        Clear what TapQ remembers of its conversation with you
tapq policy        Show the auto-answer policy serving would use
tapq version       Print version information
```

Run `tapq help <command>` for built-in usage.

## Version

```bash
tapq version
tapq --version
tapq version --json
```

The JSON form includes the CLI version and wire protocol version:

```json
{"name":"tapq","version":"0.5.0-beta.2","wire_protocol":6}
```

The project is pre-1.0. Machine-readable formats are designed for automation,
but incompatible corrections may still occur before the first stable release.

## Runtime

Source-development examples:

```bash
scripts/run-runtime-app.sh serve
scripts/run-runtime-app.sh serve --no-voice
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 60
scripts/run-runtime-app.sh serve --steering
# With ANTHROPIC_API_KEY already present in the launcher environment:
scripts/run-runtime-app.sh serve --question-classifier anthropic
# With OPENAI_API_KEY already present in the launcher environment:
scripts/run-runtime-app.sh serve --question-classifier openai
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
# Speak nothing beyond what TapQ itself wrote, as before spoken summaries:
scripts/run-runtime-app.sh serve --speech-summarizer off
```

The underlying command syntax is `tapq serve [options]`.

### Runtime options

| Option | Meaning |
|---|---|
| `--broker-dir PATH` | Override the discovery and socket directory |
| `--gesture-profile PATH` | Override the gesture profile |
| `--tap-profile PATH` | Override the tap profile |
| `--timeout SECONDS` | Input timeout; default and maximum are 240 seconds, **minimum 35**. The minimum is not a taste: TapQ holds the microphone shut while it speaks, so a window has to outlast the longest prompt it might read *and* leave the wearer time to answer. Below it every approval and every selection of the run would be structurally unanswerable, which used to be accepted silently. The number is derived from the prompt lengths and the slower voice's speaking rate — see `SpokenPace` |
| `--no-voice` | Do not request microphone/Speech access or start voice input |
| `--speech-voice VOICE` | Voice used for spoken output: a language tag (`en-US`, `zh-CN`) or a macOS voice identifier. Default `en-US`; also settable with `TAPQ_SPEECH_VOICE`. Unrelated to `--no-voice`, which gates the microphone. **Apple engine only** — it does not reach `--voice-backend openai-realtime`, whose voice and speaking rate are `TAPQ_REALTIME_VOICE` and `TAPQ_REALTIME_SPEED` |
| `--no-announcements` | Suppress non-blocking waiting and completion announcements |
| `--steering` | Enable opt-in structured-question guidance for Claude Code and root Codex turns |
| `--encoder-model PATH` | Load a TapQ-1 encoder model (`.mlpackage` or `.mlmodelc`) exported by `ml/tapq1/export.py` |
| `--encoder-mode shadow\|primary` | `shadow` (default) records encoder detections as diagnostics while heuristics drive events; `primary` lets the encoder drive events with heuristic detections logged for comparison. Requires `--encoder-model`; a model that fails to load degrades to heuristics and reports it |
| `--reasoner PROVIDER` | Stage-2 risk reasoner backend: `off` (default) or `apple`, Apple's on-device Foundation Model |
| `--reasoner-mode shadow\|primary` | `shadow` (default) records reasoner decisions as diagnostics while confirmation requirements stay as the deterministic policy set them; `primary` lets a decision strengthen the requirement for that request. A reasoner can only ask for *more* confirmation — it can never approve, deny, or resolve a request, so every failure, timeout, or absent model leaves behavior exactly as it is today. Requires `--reasoner`; a device without the model keeps serving without risk escalation and reports it |
| `--question-classifier PROVIDER` | Select `auto`, `apple`, `anthropic`, `openai`, or `local`; default is `auto` |
| `--speech-summarizer PROVIDER` | Condense an agent's final reply into what TapQ says about it: `auto` (default), `apple`, `anthropic`, `openai`, `heuristic`, or `off`. `auto` uses Apple's on-device model when the device is eligible and the deterministic local reduction otherwise. `off` restores the spoken content TapQ had before summaries existed. See [Spoken summaries](#spoken-summaries) |
| `--voice-backend PROVIDER` | Speech pipe for voice commands: `apple` (default) or `openai-realtime` |
| `--wearer-gate` | IMU-based wearer-speech attribution gate (default: off). Voice commands must be attributed to the wearer's own jaw vibration; commands from bystanders or other audio sources are rejected. Fails open when the signal is unavailable or degraded. Uses `wearer-speech-calibration.json` when present, provisional thresholds otherwise |
| `--imu-turn-control` | IMU-based turn control (default: off). Endpointing: wearer speech-end commits the user turn after a short delay. Barge-in: wearer speech-onset during response audio interrupts playback. Both are additive to gesture/tap/timeout resolution. Shares one signal source with `--wearer-gate`. On `--voice-backend openai-realtime` it also decides who ends user turns: without it, or with no AirPods streaming, the backend's own voice activity detection does — see [Turn detection](#turn-detection) |
| `--voice-freeform` | Free-form voice answers for selections and multi-option stop questions (default: off). Requires `--voice-backend openai-realtime`. **Inert since 2026-08-28**: promoting an unmatched transcript is a transcript→intent step, and there are none left on that backend. Spoken selections are made with the `select_item` tool; spoken questions are answered by the model itself. See [Free-form voice answers](#free-form-voice-answers) |
| `--voice-instructions` | Dictated instructions to the agent (default: off). Requires `--wearer-gate` under `--voice-trust wearer`; passing it alone is a startup error there. "New instruction" or "tell it to ⟨…⟩" inside an open prompt opens a dictation, and the sentence is delivered at the agent's next turn boundary — read back and confirmed on `--voice-backend apple`, where a grammar guessed the intent; queued and announced on `openai-realtime`, where the model resolved it into a tool call. A leading "tell ⟨agent⟩ to ⟨…⟩" addresses another live session by name, and refuses out loud when the name is unknown or names more than one session. Fail-closed on wearer attribution — the inverse of every other voice path. Claude Code and Codex only. See [Dictated instructions](#dictated-instructions) |
| `--voice-session` | Hold the agent's turn boundary open and keep listening (default: off). Requires `--voice-instructions`. When a turn ends, the Stop hook waits on the broker instead of returning: TapQ says "Listening." and re-opens a command window until an instruction is queued (delivered as the Stop block, so the agent continues) or a gesture or tap ends the session. **Silence does not end it** — the boundary is held indefinitely. On `openai-realtime` no spoken input can end it; on `apple` the shipped end phrases still can. Inside a waiting window a dictated sentence needs no "tell it to" prefix. See [Voice sessions](#voice-sessions) |
| `--voice-trust wearer\|environment` | Whose voice may dictate an instruction (default: `wearer`). `wearer` is today's behavior byte for byte: dictation is fail-closed on IMU wearer attribution. `environment` trusts the microphone as the user — `--voice-instructions` then needs no `--wearer-gate`, the attribution check is skipped (recorded as `instruction.trusted_environment`), and read-backs stop asking for a nod where no nod can arrive. Approvals are untouched under either value. Whether a dictation is confirmed or announced is decided by the backend, not by this flag. See [Voice trust](#voice-trust) |
| `--auto-answer off\|routine` | Delegation filter (default: `off`). `routine` answers `allow` silently, without opening a window, when the stage-2 reasoner called the action routine, its confidence clears the policy floor, and the tool is not on the never-list. Requires `--reasoner` and `--reasoner-mode primary`; both are startup errors when missing. Approvals only. See [Auto-answered approvals](#auto-answered-approvals) |
| `--attention off\|imu` | Always-on attention (default: `off`). `imu` holds the motion subscription open between requests so an attributed wearer-speech onset opens a short command window that can answer questions and take dictation but can never approve, deny, or select. Requires `--wearer-gate`. Costs continuous IMU power. See [Attention windows](#attention-windows) |
| `--voice-processing` | Experimental, macOS-only (default: off). Enables Apple's voice-processing IO — echo cancellation and automatic gain control — on the capture input node. Half-duplex is unchanged. See [Voice processing (experimental)](#voice-processing-experimental) |
| `--quiet` | Quiet output (default: off). Attention-seeking speech becomes a short synthesized cue; anything the wearer asked for is still spoken, and nothing is suppressed from memory. See [Quiet output](#quiet-output) |

Selecting a reasoner also starts a local decision log at
`<broker-dir>/reasoner-log.jsonl` — one JSON line per reasoner-observed approval,
recording the tier, rationale code, disclosure-permitted confidence or abstention reason,
latency, the confirmation the decision implied, and what the user then decided. It is the
shadow-review artifact: comparing what a decision asked for against what the user
actually did is the only way to answer whether `primary` would have been safe.
The file is created `0600` inside the `0700` runtime directory, is capped at
roughly 5 MB with a single rotation to `reasoner-log.1.jsonl`, never leaves the
machine, and is never read back by TapQ. Deleting either file at any time is safe
and costs only review history.

Be aware of what a line can contain: the full command line, working directory,
adapter `detail`, and MCP argument values are deliberately absent. MCP rows additionally
omit the model's free-text note and confidence because either could echo an argument
value; they retain the interaction outcome and, for a decided row, constrained tier/code. The recorded
`summary` is the same text TapQ speaks aloud, and for a `Bash` request that summary is the
*front* of the command line (its first six words, capped at 64 characters). That
prefix can carry a real secret — a connection string, a header fragment, a token
passed as an early argument. Treat the log as the same class of local state as
`broker.json`.

Question classifier modes:

- `auto` uses Apple's on-device Foundation Model when available and otherwise uses the
  deterministic local heuristic. It never enables cloud processing.
- `apple` requires Apple Foundation Models to be available and fails at startup otherwise.
- `anthropic` requires `ANTHROPIC_API_KEY` and uses Claude Haiku, backed by the local
  heuristic when a request fails.
- `openai` requires `OPENAI_API_KEY` and uses GPT-5.6 Luna through the Responses API,
  backed by the local heuristic when a request fails.
- `local` uses only the deterministic structured-option heuristic.

The selected mode applies to every agent adapter connected to that runtime instance.

### Voice backend

`--voice-backend` selects the speech pipe behind voice commands. It is independent of
`--question-classifier`, which chooses how a *written* agent question is interpreted.

- `apple` is the default and is exactly the shipped composition: Apple's on-device
  recognizer, opened only inside a bounded response window. No status line is printed,
  because nothing changed.
- `openai-realtime` requires `OPENAI_API_KEY` in the runtime's environment and refuses to
  start without it, the same way `--question-classifier openai` does. It uses OpenAI's
  Realtime API — the GA API at `wss://api.openai.com/v1/realtime`, on the `gpt-realtime`
  model — in manual-turn mode wherever TapQ has a turn signal of its own. It also speaks
  every sentence TapQ says — see [One voice](#one-voice). The ready block reports
  `Voice backend: openai-realtime` followed by which of the two endpointers the run is
  starting with — see [Turn detection](#turn-detection):

  ```
  Voice backend: openai-realtime, all speech in this voice, turns ended by TapQ (IMU endpointing)
  Voice backend: openai-realtime, all speech in this voice, turns ended when the model judges you finished (no IMU turn signal)
  ```

**The backend you name is the whole voice pipe.** Nothing is composed underneath it, and it
never degrades into a different backend. If the specified backend fails after startup —
a session that cannot be opened, a drop mid-run, or response audio that cannot be played —
hands-free voice ends for the run rather than continuing on a different pipe. See
[When the backend fails](#when-the-backend-fails). Gesture, tap, timeout, and screen
resolution are unaffected in every case.

Window arbitration stays on TapQ's side in both modes, always: a window is resolved by a
matched transcript, a gesture, a tap, or its timeout, and by nothing else. The backend is
never allowed to answer a question, resolve an approval, or create a response nobody asked
for. Audio leaves the machine only while a response window is open, and the API key is sent
as a request header and is not logged.

Who ends a *user turn* — who decides the wearer stopped talking — depends on whether TapQ
has a turn signal of its own; see [Turn detection](#turn-detection) below.

#### One voice

**With a non-`apple` backend selected, that backend speaks everything.** Prompts, option
lists, read-backs, recall answers, `Listening.`, `Queued for Codex.`, `Voice session ended.`,
turn summaries, the no-AirPods notice, the motion-loss notice — every sentence TapQ says goes
out on the pipe you named. The local synthesizer is not used at all.

The exception is everything spoken once the backend is *dead*. The break notice —
"Hands-free voice is off. The voice backend failed." — is spoken locally, and so is every
sentence after it, because from that point there is no pipe left to route to and windows go
on opening and resolving by gesture, tap, and timeout. A prompt nobody could hear would make
those windows unanswerable. The gate is one-way and reads the run's break latch: it can only
open after a failure that has already been logged at error level and announced, and it never
closes, because the break never lifts. Startup refusals are local for the same reason — there
is no session yet to route them to.

Sentences TapQ wrote are sent as **out-of-band verbatim readings** — a `response.create` with
`conversation: "none"`, an empty `input`, and instructions to read the sentence between
markers word for word. Two things follow from that shape. The model is never given the job of
composing an approval sentence, so what the wearer hears is what TapQ wrote; and TapQ's own
prompts and notices are not appended to the conversation, so a later grounded answer is not
reasoning over TapQ's script. Grounded free-form answers still go out as ordinary responses,
because there the model *is* doing the composing.

Only one response can be in flight, so a sentence written while the pipe is busy waits its
turn (`speech.queued_for_backend`) and goes out at the next legal moment, in order. A
sentence written when no session is open opens one for itself
(`speech_session.opening`). Ordering with listening windows is explicit: TapQ speaks first
and the microphone opens after, so a window that comes due while a sentence is still being
read defers its user turn (`turn.deferred_scripted_speech`) instead of listening over
TapQ's own voice.

A sentence the backend cannot carry is **not** spoken in the local voice. It is a failure of
the pipe the operator named, so it is logged as `scripted_speech.undeliverable` at error
level and taken to [the break](#when-the-backend-fails): one local notice, and hands-free
voice off for the run. On `--voice-backend apple` and in every no-voice mode, nothing here
applies — the local synthesizer speaks exactly as it always has.

#### Turn detection

The `openai-realtime` session runs with server-side voice activity detection off
(`audio.input.turn_detection: null`) and TapQ commits each turn itself, from the IMU
endpoint that `--imu-turn-control` provides. That is the mode every run with working AirPods
uses.

With no IMU turn signal — `--imu-turn-control` not passed, or no AirPods streaming — TapQ
has nothing that can tell when an utterance ended, and on this pipe a transcript does not
exist until the audio is committed. Rather than leave the wearer talking into a buffer
nothing will commit until the window times out, TapQ switches the session to the backend's
own detection: `audio.input.turn_detection` set to `semantic_vad` with `create_response:
false` and `interrupt_response: false`. The service commits the audio where it judges the
wearer finished, so a transcript arrives; it still may not create a response, may not
interrupt playback, and may not resolve anything. The commit ends an utterance, not the
window — the microphone stays open and the wearer can keep talking.

**Semantic, not a silence timer** (2026-08-28). `semantic_vad` asks the model whether the
wearer sounds finished; the `server_vad` this replaced ended a turn after a fixed stretch of
silence, and a wearer dictating an instruction pauses to think inside their own sentence. On
the live no-AirPods path that timer cut sentences in half and the agent received the first
half. Eagerness defaults to **`low`** — the setting that waits longest before calling a
thought finished, chosen because this path is dictation-heavy and losing a sentence costs
more than waiting a beat for one. Override it for a run with `TAPQ_TURN_EAGERNESS`
(`low`, `medium`, `high`, or `auto`); the value is read once at startup, and anything else
falls back to `low` rather than failing the run. Only the endpointing *judgment* changed:
what commits, what may create a response, and who owns barge-in are exactly as before.

The mode is chosen at each window open from the live state of the motion signal, so AirPods
connecting or disconnecting mid-run switches it back and forth without a restart. The choice
is written to the diagnostic log as `turn_detection.native` or `turn_detection.manual` with
a reason, and a run that *starts* degraded says so on the ready block's `Voice backend:`
line. Later switches are logged and not spoken. The eagerness the run resolved is logged
once at startup as `turn_detection.configured`, whether or not the run ever leaves manual
turns — so a "it cut me off" report is diagnosable from the log file alone.

The privacy delta is real and worth stating plainly: in the degraded mode the remote endpoint
decides where the wearer's sentences end, and therefore learns the shape of their speech
timing — and, under semantic detection, reads what they are saying in order to decide it
rather than watching a silence timer. It reads only audio it was already being sent, and only
while a response window is open — the microphone rules are unchanged. Running with AirPods and
`--imu-turn-control` keeps that decision local; running a cloud backend without them is the
trade this mode makes explicit rather than silently failing.

Backend turn detection is a declared capability, not an OpenAI special case: a backend that
cannot do it (the Apple stack) is never asked, and a window there resolves exactly as it
always has, because Apple's recognizer finalizes transcripts from its own silence heuristic
and never needed a commit to produce one.

#### Conversation sessions

On the `openai-realtime` path, the backend session uses conversation-scoped persistence:
one WebSocket session outlives multiple response windows. A per-window session policy
(milestone one's behavior) would open and close a full WebSocket session on every mic
reopen — several times per approval — because `SpeechGatedVoice` stops and restarts the
voice provider every time TTS becomes busy. Conversation sessions eliminate that churn.

The session stays open across windows and is closed by an idle timer (60 seconds with no
window open) or by a serve shutdown. A new window opens a fresh user turn on the existing
session. A session that dies is not reopened: the first failure ends hands-free voice for
the run, so a dead network costs one handshake rather than one per mic reopen. See
[When the backend fails](#when-the-backend-fails).

The `apple` path is unchanged: `VoiceListener` opens and closes its recognizer per window,
exactly as before.

#### Microphone pump and playback

The `openai-realtime` backend is a pipe: it transmits and receives audio but does not own
the microphone or the speaker. Two macOS adapters bridge the gap:

- **Microphone pump** (`MicrophonePumpVoiceBackend`): opens the Mac's audio input on each
  user turn, converts captured buffers to the pipe's wire format (mono 24 kHz PCM16), and
  streams them through `sendAudio`. The microphone is opened only inside a user turn and
  never between windows. A mid-turn audio route change (e.g. Bluetooth disconnect) closes
  the mic and ends the session, which ends hands-free voice for the run.

- **Backend audio playback** (`BackendAudioPlayback`): receives response audio chunks from
  the cloud, converts them from the wire's mono 24 kHz PCM16 to deinterleaved Float32 —
  AVAudioEngine's standard format, and the only one a player node's output bus accepts —
  and plays them through `AVAudioEngine`. The engine starts lazily on the first chunk of
  each response and stops when drained; the mixer resamples 24 kHz to whatever the output
  device runs at.

The combined speech activity signal merges TTS activity and backend playback, so
`SpeechGatedVoice` holds the microphone closed while *either* the local synthesizer or
the cloud voice is speaking. This is the self-hearing guarantee: the mic and the speaker
are never simultaneously live.

##### When playback fails

An output route change costs the rest of the current response and nothing more: the audio
for that response is dropped, the transcript and the window are unaffected, and the next
response starts a fresh engine.

An engine that cannot start at all, or that refuses a buffer, is treated as the end of the
realtime session rather than as one lost response. The reason is what the alternative looked
like: the microphone kept pumping and transcripts kept matching while every sentence in the
backend's voice — which, under [One voice](#one-voice), is every sentence there is — was
silently inaudible, so a wearer with no screen had no way to learn the state of their own
session.
There is no per-utterance fallback to the local synthesizer, because restoring the audio for
one sentence would hide exactly that state change.

The session is terminated and the microphone closes with it, and the termination lands
exactly where a dropped socket lands: [the break](#when-the-backend-fails). Hands-free voice
ends for the run, the wearer is told once through the local synthesizer, and windows go on
resolving by gesture, tap, and timeout.

The termination is logged, at error level, as a cause and a consequence:
`playback.engine_start_failed` (or `playback.schedule_failed`) from the `Playback` category,
then `playback.unavailable` with `consequence=voice_disabled_for_run` and
`session.terminated` with `reason=playback_unavailable` from `VoicePlayback`, followed by the
break's own `voice.pipeline_failed` / `voice.disabled_for_run` pair.

##### When the backend fails

Any failure of the specified backend after startup ends hands-free voice for the run. There
is no severity ladder and no retry: a handshake that times out, a socket that drops
mid-sentence, a microphone route that goes away, a playback engine that cannot start, a
sentence the backend cannot be made to say, and — since intent moved to tool calling —
tool-call traffic TapQ cannot make sense of all arrive at the same place. The last one is the
mirror of the one before it: that is TapQ unable to be heard, this is the wearer unable to be
understood, and neither degrades into something else.

What happens, in order:

1. Two error-level diagnostics in the `Voice` category, cause then consequence:
   `voice.pipeline_failed` with `backend=` and `reason=`, then `voice.disabled_for_run`.
2. One sentence, spoken once, through TapQ's own synthesizer: "Hands-free voice is off. The
   voice backend failed." The local synthesizer is not a backend — the Apple *backend* is
   the recognizer — so saying this locally is not the cross-backend degrade the policy
   forbids. It is how a wearer with no screen learns the microphone stopped listening, and
   it is spoken even under `--no-announcements`, for the same reason the mid-window motion
   loss notice is.
3. Every held turn boundary is released, so a `--voice-session` Stop hook parked on one
   carries on immediately instead of waiting out its budget.
4. The pipe is never reopened. Each later window asks for a session, is refused before any
   traffic reaches the backend (`open.refused` with `reason=voice_disabled_for_run`), and
   runs without a microphone.

From there the run behaves like `--no-voice`: windows open, prompts are spoken — by the local
synthesizer, which from the break onwards is the only voice there is
(`utterance.spoken_locally_after_break`) — and they resolve by gesture, tap, or timeout. Approvals still fail open to the agent's on-screen
prompt exactly as they always have, dictation and free-form answers are unreachable because
nothing is listening, and the broker, the wire, and the instruction channel are untouched.
The runtime stays alive — a broken microphone is no reason to take approvals-by-gesture down
with it. Restarting the runtime is the only way back.

Why it works this way: a degraded run lies about what is being tested and about what the
wearer is talking to. The Apple pipe has different capabilities — no free-form, no grounded
answers, different endpointing — so swapping it in mid-run would silently change the contract
the wearer thinks they are speaking under. A configuration mistake is still a startup error
and not a break: `--voice-backend openai-realtime` without `OPENAI_API_KEY` refuses to start,
as it always has.

The AirPods voice-only degrade is unaffected, because it is not a backend swap: a run with no
motion signal loses gestures and keeps the same speech pipe it started with.

#### How intent is resolved on the OpenAI path

**There is no keyword grammar on this path.** Since 2026-08-28, what the wearer meant is
decided by the model that heard them, reported as a tool call, and executed by TapQ.
Transcripts still arrive and are still logged; nothing reads them for intent.

TapQ declares five tools on the session, and they are the whole vocabulary:

| tool | arguments | what it does |
| --- | --- | --- |
| `approve` | — | authorizes the request just read out |
| `deny` | — | refuses it |
| `select_item` | `index` (1-based) | picks an entry from the list TapQ just read |
| `queue_instruction` | `text`, optional `agent` | dictates to an agent, through the ordinary dictation flow — attribution, addressing, mailbox — which on this backend queues the sentence and announces it rather than asking for a second confirmation of an intent the model already resolved |
| `query_status` | `kind` — `waiting` or `changed` | answers a question about state; resolves nothing |

Ambiguity is a safe state for *acting*: a window that nothing resolves still ends by gesture,
tap, or its own deadline, exactly as on a run with no microphone, and nothing fires off a
fuzzy match. It is not a safe state for *answering* — see below.

##### Silence is never an answer

A request the wearer directs at TapQ that cannot be carried out is always answered out loud
(ratified 2026-08-28). Speech that was not directed at TapQ is not: chatter, thinking aloud,
and dictation meant for an agent are left alone, which is what keeps the rule from turning
TapQ into an interruption. The distinction is "did they ask TapQ for something", not "did
TapQ understand it".

Concretely, TapQ speaks the refusal itself, in its own words, on the same channel as every
other sentence it says:

| what the wearer did | what they hear |
| --- | --- |
| answered, chose, or approved with nothing waiting | "Nothing is waiting." |
| dictated, or asked for status, with nothing listening | "I wasn't listening just then — say it again." |
| picked an entry that is not on the list TapQ read | "I didn't catch which one — say the number." |
| dictated to an agent whose adapter takes no instructions | "Instructions aren't supported for ⟨agent⟩." |
| named an agent nothing answers to | "I don't know an agent called ⟨name⟩ — instruction discarded." |
| named an agent with two live sessions | "More than one ⟨agent⟩ session is active — say it from that session's window." |
| dictated on a run without `--voice-instructions` | "This run isn't set up to send instructions to agents." |

And when the request reached no tool at all, the model answers it: the standing instructions
require one short clarifying question or a plain can't-do, never nothing. TapQ's own refusals
never come from the model, because a tool result starts no response — what the wearer hears
about a tool is a sentence TapQ wrote.

The one exemption is the [broken-voice state](#when-the-backend-fails) after its single
notice: the microphone is gone, and nothing there can hear the wearer to refuse them.

Before each turn's microphone opens, TapQ restates the session instructions as its standing
rules **plus** the context the model needs to choose correctly — whether a window is open at
all, the last few sentences the wearer actually heard (which is where the read-back's
numbering comes from), and the display names of agents that can be addressed. That is the
whole of the context: a request's tool input, working directory, and permission mode are
never spoken aloud, so they never reach the model either. The standing rules are appended to,
never replaced by, the per-turn context — a session running on window context alone would
have no rule against firing a tool on a word it merely heard.

Two consequences worth naming:

- **No spoken input can end the voice session.** There is no tool for it, and `deny` from the
  voice channel no longer closes a `--voice-session` loop. See
  [Voice sessions](#voice-sessions).
- **Malformed tool traffic breaks the voice channel** rather than falling back to matching
  words — an undeclared tool, arguments that will not parse, or a call on a session with no
  tools declared all land on the same latch a dropped socket does. See
  [When the backend fails](#when-the-backend-fails).

The Apple backend is unaffected in every respect: it has no model to reason with, so its
transcript grammar, its end phrases, and its matcher are exactly what they were.

#### Transcript timing on the OpenAI path

On the OpenAI Realtime path, transcripts are not available until the audio buffer is
committed. The server creates the user conversation item — and starts input transcription —
only on commit, and the same commit is what asks the model to decide whether a tool applies.
This means there are no mid-turn partial results, and nothing can resolve a window before a
commit.

So something has to commit while the window is still open, and which something it is depends
on the mode described under [Turn detection](#turn-detection):

- **With `--imu-turn-control` and AirPods streaming**, the IMU endpoint commits roughly one
  second after the wearer stops speaking (0.6 s detector hangover plus a 0.4 s delay). The
  model reads the committed turn and calls a tool, or does not.
- **Without a live IMU turn signal**, the backend's own semantic detection commits where the
  model judges the wearer finished, and the turn is read the same way. Endpoint timing is the
  service's, not TapQ's, and the privacy delta above applies.

Either way, a window that nothing commits still resolves by gesture, tap, or timeout — those
paths never depended on a transcript. What the backend's own detection removes is the case
where voice was the *only* channel the wearer had and it silently did nothing until the
window ran out.

#### Wearer-speech features

`--wearer-gate` and `--imu-turn-control` share one `WearerSpeechSignalSource` when both
are active. The source is fed by the headphone motion stream (samples flow only while a
response window is open) and produces a speaking/quiet signal from the jaw- and
skull-borne vibration.

- **Wearer gate** (`--wearer-gate`): filters voice commands through IMU-based attribution.
  A command is passed through when the wearer spoke within a trailing attribution window;
  commands from bystanders or other audio sources are rejected. Fails open in every
  degraded state: no signal, a magnitude-only stream, or a stale analyzer reproduces
  today's behavior verbatim. Uses `wearer-speech-calibration.json` when present,
  provisional thresholds otherwise. With provisional thresholds the gate may pass bystander
  speech — the attribution window is generous by design until the capture study lands.

- **IMU turn control** (`--imu-turn-control`): two additive features on top of the normal
  gesture/tap/timeout resolution.

  - *Endpointing*: when the wearer stops speaking, the user turn is committed after a
    short delay (0.4 seconds on top of the detector's 0.6-second hangover). If the wearer
    resumes within the delay, the commit is cancelled. A false endpoint (jaw motion that is
    not speech) commits the turn early; the consequence is an unmatched transcript and a
    re-armed turn — degraded, not broken.
  - *Barge-in*: when the wearer starts speaking during response audio (TTS or backend
    playback), all playback is stopped immediately. The microphone then reopens through the
    normal gate machinery and the wearer speaks their answer on the next turn. The first
    ~0.3-0.5 seconds of the barge-in utterance are not captured (IMU onset latency plus
    mic-open latency); the UX answer is that barge-in stops the agent so the user can
    speak, not that it salvages the interrupting syllables. Barge-in uses `stopAll()`,
    which also drops any queued cross-session notifications.

  A dead or absent signal means neither feature fires: the window resolves by gesture,
  tap, timeout, or command match exactly as without the flag.

#### Free-form voice answers

`--voice-freeform` enables free-form spoken answers for selections and multi-option stop
questions. It requires `--voice-backend openai-realtime` because the Apple recognizer does
not produce transcripts through the backend command provider; passing `--voice-freeform`
with the Apple backend is a startup error.

The flow it enabled:

1. The wearer speaks an answer that matches no command.
2. TapQ reads back: "You said: '<text>'. Nod to send, shake to discard."
3. The wearer nods to confirm or shakes to discard and re-listen.

A confirmed free-text answer resolves the selection and reaches the agent through the wire
protocol (see below). Tool approvals and yes/no stop questions stay binary — a spoken
free-text answer can never authorize an agent action. The read-back confirmation is a
deliberate safety measure: a stray sentence becoming an agent instruction is worse than one
extra nod.

**Currently inert.** Promoting an unmatched transcript to an answer is itself a
transcript→intent step, and the 2026-08-28 decision removed every one of those from the
realtime path — which is the only path this flag runs on. Until a free-text answer is
reachable as a declared tool, a spoken selection is made with `select_item`, by naming the
entry the read-back numbered. Two things this does *not* cost: the wearer can still dictate
to the agent (`queue_instruction`), and spoken questions are answered out loud by the model
itself from the window context TapQ supplies per turn, which is what `--voice-freeform`'s
grounded-answer path used to do.

#### Voice trust

`--voice-trust` names whose voice may put an instruction into an agent's session. It is a
policy about *instructions only*: nothing in it reaches an approval, a selection, or a
deferral, under either value.

- `wearer` (default) is the posture every earlier build had. Dictation is fail-closed on
  IMU wearer attribution, so it needs `--wearer-gate` and it needs AirPods that are
  actually streaming.
- `environment` trusts the microphone as the user. It exists for the run this whole
  feature was unreachable in — earbuds in their case, laptop on a desk — and it makes the
  assumption explicit rather than leaving dictation silently refusing everything.

```bash
tapq serve --voice-backend openai-realtime --voice-trust environment --voice-instructions
```

Under `environment`:

- `--voice-instructions` no longer requires `--wearer-gate`.
- The attribution check is skipped rather than answered. The skip is recorded at both
  points the wearer-trust path would have checked (`instruction.trusted_environment`, with
  `stage=begin` and `stage=text`), so a log can always say which posture a queued
  instruction was accepted under. It is never silent.
- Read-backs stop naming gestures that cannot arrive: with no motion device, "Instruction:
  '⟨text⟩'. Say yes to queue it." and "You said: '⟨text⟩'. Say yes to send, or no to
  discard." The wording follows the live motion probe, so AirPods that appear mid-run get
  the nod offered again on the next read-back.
- The read-back confirmation stays wherever a *grammar* guessed at the intent — the Apple
  path. It catches mis-transcription, not just misattribution, and there it is the only
  thing between a misheard phrase and an agent's inbox. Under `--voice-backend
  openai-realtime` the model resolved the sentence into a `queue_instruction` call before
  TapQ saw it, so there is no guess to catch: the instruction is queued and *announced* —
  "Queued for ⟨agent⟩: '⟨text⟩'" — rather than read back and confirmed. See [Dictated
  instructions](#dictated-instructions).

The honest cost, stated once: under `environment`, **anyone audible to the microphone can
instruct** — and still cannot approve, deny, select, or defer anything. Approval grammar,
approval read-backs, and the fail-open-to-screen rule are identical in both postures, and
an instruction authorizes nothing in either. Use it in a room you would be comfortable
leaving your terminal unlocked in.

Attention windows are not affected: `--attention imu` still requires `--wearer-gate` under
either trust value, because a window that opens on a wearer-speech onset needs the signal
that says whose onset it was. Acoustic attention is a later rung.

The ready block prints `Voice trust: environment (…)` when the non-default posture is in
force. There is no line under `wearer` — nothing changed.

#### Dictated instructions

`--voice-instructions` lets the wearer say something *to* the agent rather than answer
what it asked. Under the default `--voice-trust wearer` it requires `--wearer-gate`;
passing it alone is a startup error there, because the attribution signal the whole
feature is fail-closed on comes from the gate. Under `--voice-trust environment` the
pairing is dropped — see [Voice trust](#voice-trust).

```bash
tapq serve --wearer-gate --voice-instructions
```

Inside any open prompt:

1. The wearer says "new instruction", "instruction for Claude", or dictates in one breath
   with "tell it to ⟨…⟩". The capturing forms take everything after the prefix as the
   instruction, in the wearer's own words.
2. Without captured text, TapQ says "Go ahead." and takes the next spoken turn as the
   instruction.
3. TapQ reads it back: "Instruction: '⟨text⟩'. Nod or say yes to queue it." — or "Say yes
   to queue it." where no gesture can arrive; see [Voice trust](#voice-trust).
4. A nod, a double tap, or "yes" queues it — "Queued for ⟨agent⟩." Anything else discards
   it — "Instruction discarded.", and so does silence: a read-back nobody answers says the
   same sentence rather than ending quietly. If queueing it pushed an older instruction out
   of a full mailbox, the confirmation says so: "Queued for ⟨agent⟩. This replaced the
   oldest waiting instruction." And in the rare case where the mailbox took nothing after
   all — the window closed underneath the confirmation — TapQ says that instead of claiming
   a delivery: "That wasn't queued after all — say it again."

Steps 3 and 4 are the *grammar* path: `--voice-backend apple`, where `.beginInstruction`
was guessed from a transcript and the read-back is what catches a wrong guess. Under
`--voice-backend openai-realtime` the wearer's sentence reached TapQ as a
`queue_instruction` tool call the model had already resolved, and there the sentence is
queued on the spot and announced — "Queued for Claude Code: '⟨text⟩'", with the same
drop-oldest clause and the same "That wasn't queued after all" when the mailbox took
nothing. Nothing waits for a second answer.

That difference is a fix, not a preference (2026-08-30, hardware). TapQ holds the
microphone closed while it speaks, so a read-back queued into the last two seconds of an
eight-second window ran the window out before the wearer could answer, and the instruction
was discarded for silence every single time. Where a confirmation *is* asked for, its
listen now covers the read-back's own playback plus a real answering window, so the
question outlives itself.


The prompt the wearer was answering is untouched by all of this. The confirming nod is
consumed inside the dictation, the request is still waiting when the flow ends, and the
window's deadline is never extended: dictating cannot buy more time to decide.

**Instructing fails closed; authorizing fails open.** Under `--voice-trust wearer`, a voice
TapQ cannot attribute to the wearer — including one where the signal cannot say whose it is
— is refused out loud ("I can't confirm that was you — instruction discarded.", diagnostic
`instruction.rejected_unattributed`). Voice *approvals* keep failing open in the same
state, because the agent's on-screen prompt is their backstop. A queued instruction has no
such backstop, so "we cannot tell who spoke" and "that was not the wearer" have the same
consequence. An instruction still authorizes nothing: whatever it asks the agent to do
goes through the same approval path as every other tool call, and no dictation can allow,
deny, select, or defer.

Delivery is at the agent's next turn boundary, one instruction per boundary, as the reply
to its stop event:

> The user dictated a new instruction via TapQ hands-free: '⟨text⟩'. Proceed accordingly.

Bounds, all deliberate:

- Four instructions per session; a fifth drops the oldest (`instruction.dropped_capacity`).
  The most recent sentence is the one the wearer meant. The displacement is announced in the
  read-back (see step 4) — the rule is unchanged, but it no longer happens behind the
  wearer's back. Which sentence was displaced is not read back: it would be their own words
  returned to them minutes late, and the remedy is the same either way.
- Three instruction-bearing boundaries in a row, then delivery pauses with a spoken notice
  until a boundary carries something else (`instruction.loop_cap.suppressed`). A stop reply
  restarts the agent's turn, and Claude's stop hook has no `stop_hook_active` flag to lean
  on. Stood down under `--voice-session`, where every boundary is meant to carry one; the
  four-deep queue bound is not.
- Claude Code and Codex only. Cursor and OpenCode have no turn boundary to deliver into,
  and dictating at one of them is refused by name: "Instructions aren't supported for
  OpenCode." See the [capability matrix](INTEGRATIONS.md#agent-capability-matrix).
- Dictation works only while a window is open, for the same reason recall does: the
  microphone is live only during a bounded response window.
- Nothing survives a restart. A queued, undelivered instruction is gone with the process.
- Delivery waits for a boundary the agent produces, so an instruction dictated to an idle
  agent waits for someone to type — unless the run is holding one open; see
  [Voice sessions](#voice-sessions).

##### Addressing another agent by name

A dictation normally goes to the agent whose window is open — or, in a wearer-initiated
window, to the last agent TapQ served. Naming an agent overrides that:

```
"tell Codex to run the integration tests"
"tell Codex: run the integration tests"
"tell Codex run the integration tests"
```

The accepted shape is a leading `tell ⟨agent⟩ to ⟨instruction⟩`, with a colon or nothing at
all in place of the `to`. The name is matched case-insensitively against the display names
TapQ already speaks, or the first word of one — "claude" reaches Claude Code. The address
is stripped before anything else happens, so the agent receives `run the integration
tests`, and the read-back and the queued notice both name the agent it is going to:
`"Instruction: 'run the integration tests.' Nod or say yes to queue it."` → `"Queued for
Codex."`

Everything else about the flow is unchanged. A sentence with no address behaves exactly as
it always has; the confirming nod is still spent inside the dictation; and a routed
instruction still authorizes nothing — approvals, selections, and stop answers always apply
to the window in front of the wearer and can never be addressed anywhere.

The three prefix forms that predate addressing — "tell it to ⟨…⟩", "tell Claude to ⟨…⟩",
"tell the agent to ⟨…⟩" — still mean "the agent in front of me" and are stripped before the
address is ever looked for, so nothing an existing user says changes meaning.

**One session per adapter.** The roster behind this is deliberately small: it remembers the
most recent session per agent, filled from traffic TapQ already handles (a window opening,
a notification arriving), and an entry expires after 30 minutes of silence — nothing on the
wire ever says a session ended, so silence is the only signal there is. Naming an agent
therefore names a session only while that assumption holds.

**When it does not hold, TapQ refuses rather than guesses.** Two live sessions for one
adapter make its name ambiguous, and the dictation is declined out loud: `"More than one
Claude Code session is active — say it from that session's window."` A name nothing live
answers to is declined the same way: `"I don't know an agent called Aider — instruction
discarded."` In both cases nothing is queued anywhere — the sentence does not quietly fall
back to the window's own agent, because a sentence delivered to the wrong session is the
one mistake the wearer cannot hear. Say it again from that session's own window, where the
addressee needs no name at all. Ambiguity clears on its own once the rival session has been
silent for the liveness window.

The per-adapter capability table still applies to whoever the sentence is going *to*, so
`"tell Cursor to …"` is refused with the same sentence an in-window dictation there would
have heard: `"Instructions aren't supported for Cursor."`

While instructions are waiting, "who's waiting?" says so: `"Claude Code: run the test
suite. 1 instruction queued."` Once delivered, "what changed?"
recalls it as work handed over — `"Claude Code was told to run the tests again."` — never
as work done.

Without the flag, nothing composes a queue: the grammar still matches the phrase, it
reaches nowhere, nothing is spoken, and the window goes on listening.

#### Voice sessions

`--voice-session` is the difference between dictating *into* a conversation and having one.
Without it, an instruction reaches the agent at its next turn boundary — and an idle agent
produces no boundaries, so a sentence spoken after it finished waits for someone to type.
With it, TapQ holds that boundary open and keeps listening.

```bash
tapq serve --voice-backend openai-realtime \
  --voice-trust environment --voice-instructions --voice-session
```

It requires `--voice-instructions`; passing it alone is a startup error, because a held
boundary exists so a dictated instruction can reach the agent and without the queue there
is nowhere for one to go. It works under either trust posture — the pairing above is the
one it was designed around, which is a desk, no earbuds, and no keyboard.

What happens at the end of a turn:

1. The agent finishes. Its Stop hook does what it always did — an intercepted question
   still runs its own interaction — and then, instead of returning, sends
   `instruction.wait` to the broker and waits.
2. TapQ announces the turn as usual ("Claude Code finished"), then says "Listening." and
   opens a command window. Windows re-open, silently, for as long as the boundary is held.
   Each is a minute long (the attention window after a notification stays at eight
   seconds); the length is how often the loop rotates, not how long you may speak.
3. Inside a waiting window, on the realtime backend: whatever the wearer says is understood
   by the model and turned into one of the five tools above. A question about state is
   answered; a sentence meant for the agent is read back — "Instruction: '⟨text⟩'. Say yes to
   queue it." — and a spoken yes queues it. On the Apple backend the same window runs the
   keyword grammar instead: `status`, `what changed`, and `repeat` answer as they always did,
   "tell it to ⟨…⟩" opens a dictation, and an unmatched sentence is treated as dictation
   directly.
4. A queued instruction releases the hook, which blocks the Stop with the usual reply, and
   the agent continues its turn with it. The next boundary is a moment away.
5. **Nothing the wearer says ends the loop on the realtime backend.** There is no tool for
   it, and a spoken "no" or "stop" is an intent about a request that does not exist — TapQ
   says "Nothing is waiting." and keeps listening. What ends it is a shake or a tap ("Voice
   session ended.", the hook released with nothing), a break in the voice pipeline, or
   stopping the runtime — and nothing else. On the Apple backend the shipped phrasings still work: "end voice session",
   "stop listening", or a spoken denial.
6. **Silence does not end it.** The held boundary is a renewable lease: the shim re-parks
   for as long as the runtime keeps saying "still held", indefinitely many times inside the
   one Stop hook. A session that has been quiet for four hours is in exactly the state it
   was in after four seconds. Ratified 2026-08-28.

Why (5) changed: negation words occur constantly in ordinary speech and in dictation. On
2026-08-28 a fragment of a dictated sentence matched as a denial and ended a live session
mid-test, and a mode that dies whenever someone says "no" is unusable. See
[How intent is resolved on the OpenAI path](#how-intent-is-resolved-on-the-openai-path).

Bounds and behavior, all deliberate:

- **The instruction loop cap does not apply.** Three instruction-bearing boundaries in a
  row is a loop everywhere else; here every boundary is *supposed* to carry one. The
  four-deep queue cap is unchanged.
- **Approvals are untouched.** An agent's tool call during a voice session opens the same
  approval window, resolved the same way this backend resolves everything, with the same
  fail-open-to-screen. Nothing about holding a boundary lets a sentence authorize anything
  it could not authorize outside one.
- **A window opening never cuts a sentence off.** Windows re-open on a clock, and a clock
  is not a reason to stop talking: a window that comes due while the backend is still
  speaking waits for the sentence to finish and opens its microphone on the response's own
  completion. Two things do stop a response the moment they happen, because both mean it
  has lost its audience — the wearer talking over it (`--imu-turn-control` barge-in), and
  the window that response belonged to being resolved by a match, a gesture, or a tap.
- **One session at a time.** Two agents can be held at once, but TapQ has one microphone:
  the listening loop addresses the boundary that started it, and a second held session
  stays held, silently, rather than being answered by a window that might be talking about
  the other one. Both are let go together when the wearer ends the session.
- **Claude Code only, for now.** The Codex adapter's Stop path does not long-poll yet.
- **Nothing survives a restart**, and a runtime that exits releases every waiting hook
  before it goes, so a killed `tapq serve` never leaves a hook parked. A hook that cannot
  reach the broker at all lets the Stop proceed, as it always has, and one whose runtime
  disappears mid-session discovers it on its next poll rather than hanging.
- **A broken voice pipeline ends it.** A boundary held indefinitely for a microphone that
  can no longer hear is the one failure this mode must not have, so the same latch that
  reports the break releases every hold and refuses to re-establish the ones already
  released.
- The terminal shows a hook in flight for as long as a boundary is held. That is the mode
  being visible, not a stall — typing into the session ends it the ordinary way.

Prefix-free dictation is meaningful only on `--voice-backend openai-realtime`, where the
model reports a dictated sentence as `queue_instruction` and its optional `agent` argument
routes it. On the Apple path a waiting window still hears the grammar and still needs a
prefixed "tell it to ⟨…⟩", which is the honest capability gap on a backend with no model in
it.

#### How a boundary is held indefinitely

The chain for a held boundary is its own, and it is a **renewable lease** rather than a
budget:

- The broker holds one poll for 60 s. If nothing has been queued and nobody has ended the
  session, it answers `renew` — "still held, come back" — instead of releasing.
- The shim's socket gives up at 75 s, so the broker's answer always arrives first, and the
  shim immediately re-polls with the same `lease_id`. There is no cap on the renewals.
- Between two polls there is no request in flight, so the broker keeps the boundary
  registered for a 30 s **grace**. That is what stops "Listening." being announced once a
  minute, and it is also what releases a boundary whose hook was killed: a lease that stops
  being polled is gone within 90 s.
- `tapq integration claude install` writes a `timeout` of **2 147 483 s (~24.9 days)** on
  the **Stop** entry only. That is the largest value Claude Code will honor — its settings
  schema accepts any positive number of seconds, but the value reaches a JavaScript timer,
  and a delay past `Int32.max` milliseconds is treated as an overflow and re-set to 1 ms,
  which would kill the hook immediately. This is the one clock TapQ cannot remove, and it
  is the agent's rather than TapQ's.

Reinstall the Claude hooks after upgrading — a Stop entry written by an older build carries
the older timeout and would kill a held boundary part-way through.

Polling rather than parking once forever is deliberate. Each poll is a fresh connection, so
a runtime that has exited or wedged is noticed within a minute instead of never; and on the
broker's side a hook that was killed stops renewing rather than parking a connection thread
for the life of the run.

The ready block prints
`Voice session: holding turn boundaries open until you end them with a tap or a gesture, or
the runtime stops; …` when the flag is on.

### Auto-answered approvals

`--auto-answer routine` lets TapQ say yes on your behalf to the approvals nobody would
want to be woken for. It requires a stage-2 reasoner in `primary` mode:

```bash
tapq serve --reasoner apple --reasoner-mode primary --auto-answer routine
```

Both dependencies are startup errors when missing. Without a reasoner there is no tier to
gate on; under `--reasoner-mode shadow` the operator has explicitly said not to act on the
model's decisions, and silently approving on the strength of one would be the largest
possible way to act on them.

An approval is answered without asking when **all four** hold:

1. The reasoner produced a decision at all — not an abstention, not a timeout.
2. That decision's `riskTier` is `routine`.
3. Its confidence is at least `minimum_confidence` (0.8 by default).
4. Its tool is not in `never_auto_tools`.

Anything else opens exactly the window it would have opened with the flag off. There is no
"deny" side and no way for the filter to make a request *harder* to approve — escalation
is the reasoner's job, and this is the only place user policy is applied.

**The reasoner still cannot approve anything.** `ReasonerDecision` has no approve case by
construction; what a model produces is the observation "this is routine", and turning that
observation into a yes is an act of delegation *you* perform by enabling the flag. A
confused or compromised reasoner's worst move is to call a sensitive action routine, which
is why the tier gate is paired with a confidence floor and a never-list the model can
neither see nor influence.

Scope, deliberately narrow:

- **Approvals only.** Stop questions and multi-option selections are conversations, and
  nothing auto-answers a conversation.
- **Silent.** No cue, no prompt, no window. That silence is the feature; the counterweight
  is the log below and the count in "who's waiting?".
- **Recorded twice.** Every auto-answer is a normal entry in session memory — "what
  changed?" recalls it like any other approval — and a line in
  `<broker-dir>/auto-answer-log.jsonl`.
- **Counted.** "Who's waiting?" gains a final clause: `"Auto-answered 4 this session."`

The audit log follows the reasoner log's discipline exactly: `0600` inside the `0700`
runtime directory, capped at roughly 5 MB with one rotation to
`auto-answer-log.1.jsonl`, never read back by TapQ, never leaving the machine, and safe to
delete at any time. It carries the same sensitivity — the recorded `summary` is what TapQ
would have spoken, and for a `Bash` request that is the front of the command line, which
can contain a secret passed as an early argument.

#### The policy file

`auto-answer-policy.json` lives beside the calibration profiles (`$TAPQ_CONFIG_DIR`, or
`~/Library/Application Support/TapQ`) and is optional:

```json
{
  "schema_version": 1,
  "minimum_confidence": 0.9,
  "never_auto_tools": ["Bash", "Write"]
}
```

With no file the strict defaults apply: confidence 0.8 and an empty never-list. The list is
empty by default because the `routine` tier is the gate — shipping a curated denylist would
imply the tier is not trusted while still letting everything not on the list through.
Matching is case- and whitespace-insensitive.

A file that does not parse, or that names an unknown `schema_version`, **aborts `serve`**,
exactly as a malformed calibration profile does. Falling back to defaults would be the more
forgiving choice and the wrong one: you wrote that file to *narrow* what gets answered, and
a typo must not silently widen it back out.

```bash
tapq policy show          # the effective policy, and whether it came from a file
tapq policy show --json
```

There is no `policy set`. Widening what TapQ may answer for you should take an editor.

### Attention windows

`--attention imu` lets the wearer start a conversation, rather than only answer one. It
requires `--wearer-gate`, because the onset that opens a window has to be attributable:

```bash
tapq serve --wearer-gate --attention imu
```

Between agent requests, an attributed wearer-speech onset opens a command window: TapQ says
"Yes?" and listens for eight seconds. The window accepts

- **"status" / "who's waiting?"** — `"Nothing is waiting."`, plus any queued instructions
  and this run's auto-answer count.
- **"what changed?"** — the last-served session's recent history, exactly as inside a
  prompt.
- **"repeat"** — the last thing the window said.
- **dictation**, under `--voice-instructions`, addressed to the agent whose request TapQ
  handled most recently.

**It cannot resolve anything.** A nod, a "yes", a "no", or a selection inside a command
window is answered `"Nothing is waiting."` and the window goes on listening. This is
structural rather than conditional: the window's result type carries three counters and has
no case a broker could act on, and the window runs inside the same interaction gate every
request window runs in — so a request being answered means an attention window has not
started.

A window opens only when nothing is queued at the gate. If a request is waiting, the wearer
speaking is a wearer answering *it*, and that request's own microphone is already live.

#### Battery

This is the flag with a running cost. `--attention imu` holds the AirPods motion
subscription open for the whole session instead of only during prompts, so the earbud IMU
streams continuously and the Mac wakes to process every sample. Expect materially shorter
AirPods runtime than a session that only samples during windows, and measurable extra Mac
power draw on battery — the exact figures are hardware-dependent and are on the
[Rung D smoke checklist](RUNGD_SMOKE_CHECKLIST.md) rather than quoted here, because no
number measured on one pair of AirPods is worth printing as if it were general. Leave the
flag off for long unattended sessions, and prefer it when you are actively working with an
agent and want to talk back between requests.

### Voice processing (experimental)

`--voice-processing` is a spike, macOS-only, and off by default. It turns on Apple's
voice-processing IO — acoustic echo cancellation plus automatic gain control — for the
capture input node, and tolerates the one `AVAudioEngineConfigurationChange` that enabling
the unit publishes (which the audio source otherwise treats, correctly, as a fatal route
change).

What it is **not**: barge-in. TapQ still closes the microphone while it speaks, and
`--imu-turn-control`'s IMU barge-in is unchanged. Acoustic barge-in ships only if hardware
testing shows the cancellation is good enough, because capture and playback currently run
on separate audio engines and voice processing can only cancel echo it has a reference for.
The bridge can host the playback player node on the capture engine for exactly that reason;
the runtime does not yet compose it.

Two caveats worth measuring before relying on the flag: AGC shifts the RMS envelope that
endpointing reads, and enabling the unit changes the input format the recognizer receives.
Both are on the smoke checklist. With the flag off the audio path is unchanged, engine for
engine.

### Quiet output

`--quiet` changes the channel TapQ uses to get your attention, not what it does:

```bash
tapq serve --quiet
```

| Utterance | Without `--quiet` | With `--quiet` |
|---|---|---|
| An approval prompt or question | Spoken | Rising two-tone cue |
| An agent notification | Spoken | One flat tone |
| "Deferring to the screen." | Spoken | One flat tone |
| "AirPods motion disconnected." | Spoken | One flat tone |
| "Status", "what changed", "details" | Spoken | **Spoken** |
| A dictation read-back | Spoken | **Spoken** |
| A command window's "Yes?" and its answers | Spoken | **Spoken** |

Everything the wearer asked for stays speech. A wearer who asks a question out loud and
hears a chime back has been given a worse answer than silence, because they cannot tell it
from a misheard question — so quiet mode silences the sentences that interrupt you and
keeps the ones that answer you. After a prompt cue, say "status" to hear what is waiting.

Resolution semantics are untouched: a chimed prompt is answered by the same nod, in the
same window, on the same deadline. The cues are synthesized sine bursts on a dedicated
audio engine, so no asset ships and no cue can perturb a response in flight.

**Quiet mode never suppresses recording.** Neither does `--no-announcements`. Both are
about audio; every notification, approval, and selection is recorded in session memory
whatever was played, so "what changed?" is complete in every mode. (Before Rung D,
`--no-announcements` skipped the recording along with the sound, which meant a wearer who
had asked for silence could then ask what happened and be told nothing had.)

The startup line — "No AirPods detected." — is still spoken under `--quiet`: it is a
one-time status line before any interaction, and a tone in its place would say nothing at
all. It continues to respect `--no-announcements`.

On macOS, `tapq serve`:

1. Loads independent gesture and tap calibration profiles.
2. Composes motion, speech, synthesis, and volume adapters with the portable
   detection and interaction layers.
3. Starts an authenticated Unix-domain-socket broker.
4. Publishes `broker.json` only after the socket is listening.
5. Removes discovery and socket files on normal shutdown.

The development script packages a signed, headless `LSUIElement` app and launches
it through LaunchServices. The app has no window, menu, or Dock icon; the bundle
provides a stable bundle identity and privacy descriptions for Motion, Speech
Recognition, and Microphone authorization. Development builds are ad-hoc signed,
and rebuilding can cause macOS to request authorization again. Control-C
terminates the launched process.

### Input behavior

The gesture, tap, and volume controls below are the same on every backend. The *voice* half
of them — the word lists — is the Apple backend's keyword grammar. On
`--voice-backend openai-realtime` there is no word list: the model decides what the wearer
meant and calls one of five tools, described under
[How intent is resolved on the OpenAI path](#how-intent-is-resolved-on-the-openai-path). The
same intents result either way, so the rest of this section reads the same from a window's
side.

For approvals and yes/no questions:

- Double nod, double tap, or an affirmative voice command approves. The affirmatives are
  `yes`, `yeah`, `yep`, `yup`, `approve`, `approved`, `sure`, `okay`, `ok`, `confirm`, and
  the phrases `do it`, `go ahead`, `go for it`.
- Double shake or a negative voice command denies. The denials are `no`, `nope`, `nah`,
  `deny`, `denied`, `cancel`, `stop`, `reject`, `don't`, and the phrase `do not`.
- `repeat` speaks the prompt again; `details` requests the longer spoken detail.

For option questions:

- Volume down or `next` moves forward.
- Volume up or `previous` moves backward.
- Double nod, double tap, `select`, an affirmative, or spoken numbers one through four
  confirms.
- Double shake, `skip`, or a denial returns control to the on-screen prompt.

The two lists are the whole approval grammar on the Apple backend, and they are the same list
in every window: an affirmative allows an approval, commits the option under the cursor in a
selection, and is told "Nothing is waiting." in a command window; a denial denies, hands a
selection back to the screen, and ends a held voice session. There is no per-window synonym
set.

The last of those — a denial ending a held voice session — is the one clause that is *not*
true on `--voice-backend openai-realtime`, where no spoken input ends a session at all. See
[Voice sessions](#voice-sessions).

A denial word inside a *dictated* sentence dictates rather than denies: dictation is matched
ahead of every other rule, so "tell Codex to deny the pull request" is queued for Codex
verbatim. A denial that governs the sentence still denies — "no, tell Codex to run the
tests" is a `no`, because a negator ahead of the trigger blocks the dictation branch.

Voice commands are recognized with an English (`en-US`) grammar. Voice input is
active only during a bounded response window. TapQ requires on-device recognition
when the selected recognizer supports it; otherwise Apple’s Speech framework may
use Apple’s service. Spoken output uses the macOS system speech synthesizer and
voice selection.

A command that decides something — both answers, `skip`, and the selection and
dictation families — is delivered only once the transcript stops changing (about
0.7 s, or immediately when the recognizer settles it), so the opening fragment of a
longer sentence is never mistaken for a whole answer. `repeat`, `details`, `status`,
and the what-changed question decide nothing and still answer on the first partial.

### Motion recovery and diagnostics

A single CoreMotion disconnect callback is treated as an interruption rather than
confirmed device loss. TapQ keeps the current response window open for a grace
period, resumes on a corresponding reconnect, and announces disconnection only
when samples do not recover. When a new prompt opens without motion, the runtime
retries for a bounded period.

A device that was never connected is not a disconnection. The bounded retry still
runs at every window, but when it finds nothing the window continues voice-only and
says nothing: the disconnect announcement is reserved for a device that has streamed
samples at some point in the run. Availability alone does not count — macOS reports
paired AirPods as available even while they sit disconnected in their case, so a
subscription that never produces a sample is treated as absence no matter what the
availability flag said. TapQ speaks one voice-only notice instead — at startup when
the device reports unavailable, or at the first window that discovers the stream is
mute — and never twice in a run. The motion channels re-arm by themselves at the
first window after AirPods connect. The `motion.lost` diagnostic carries a `reason`
field — `never_streamed`, `lost_while_streaming`, or `silent_stream` — which is what
the runtime branches on; a loss downgraded because the run never streamed keeps the
locally observed reason in a `local_reason` field.

Without motion, a request the stage-2 reasoner escalates to `gesture_and_voice`
cannot be collected: the gesture half never arrives, so the window times out to the
on-screen prompt, which is the fail-open path every unanswered window takes. This
only applies to `--reasoner-mode primary`, which is opt-in. A `double_gesture`
requirement stays collectable without motion — a second spoken "yes" counts as the
repeat allow.

Warnings and errors are printed by default. `TAPQ_DEBUG=1` adds broker, speech,
gesture, tap, selection, voice backend, playback, microphone pump, wearer gate, and
lifecycle events. Tap diagnostics include peak and threshold acceleration, rotation
limits, elevated-sample width, baseline return, candidate duration, pairing gap,
pending expiration, and listening-window reset. After `tap.pending`, a bounded 600 ms
trace records every delivered acceleration and rotation sample with its hardware
timestamp.

These diagnostics do not change detection policy. The bundled sink can record
tool names, request identifiers, option labels, lifecycle events, and motion
measurements. Normal CLI output can separately expose local paths. Review both
before sharing.

## Instruction submission (debug)

```bash
tapq instruct <session-id> <text> [--agent ID] [--broker-dir PATH]
```

A debug and device-adapter seam, not a way to drive an agent from a terminal. It sends the
wire's `instruction.submit` message to a running broker over the same socket client every
hook shim uses, which is what makes the channel exercisable without hardware — and it is
also the message a future TapQ device SDK would send.

None of the wearer path's safety applies to it. There is no attribution check, no
read-back, and no confirmation; the only thing standing in for them is that the caller can
already read the runtime's private discovery record, which is same-user-only by file
permission and not protection from a malicious process running under the same account.

```bash
tapq instruct 6f2c-1a run the tests again and push if they pass
tapq instruct 6f2c-1a --agent claude-code "open a pull request"
```

Options and errors:

- `--agent ID` — `claude-code`, `codex`, `cursor`, or `opencode`. Optional; when given, an
  agent that cannot receive instructions is refused before the socket is opened (exit 64).
- `--broker-dir PATH` — discovery directory of the target runtime, matching the
  `serve --broker-dir` it was started with.
- No running runtime: exit 69, "no running TapQ runtime found."
- A runtime started without `--voice-instructions`: the broker answers
  `instruction_unavailable` and the command exits 1.
- A runtime older than wire v5: refused locally, before anything is sent.

The broker validates the token and the wire version, requires non-empty text, and answers
`ok` only when the instruction was queued. It records the submission's length and request
id — never its text.

## Conversation memory

```bash
tapq memory clear [--broker-dir PATH] [--yes]
```

On `--voice-backend openai-realtime`, TapQ keeps its own record of the dialogue it has
with you — `wearer-conversation.jsonl` in the runtime directory. It holds what you said
(verbatim), what TapQ said back, how each request was resolved, and which instructions
reached which agent, each with a timestamp and an agent name. A bounded recent slice of it
joins the model's per-turn context, which is what lets "the thing I asked you earlier"
survive a dropped voice session or a restarted runtime.

Nothing else is in it, and that is structural rather than filtered: the file records only
what was spoken or heard on the voice channel, and a tool's input, a working directory,
and a permission mode are never spoken. The Apple voice backend composes no store at all
and writes no such file.

It bounds itself: entries older than 30 days are dropped, and the file is held under a
couple of megabytes — whichever comes first — by dropping the oldest and keeping the
newest. `0600` inside the `0700` runtime directory, never leaves the machine, and safe to
delete by hand at any time. This command is the on-demand wipe; it names the file, says
how many exchanges are about to go, and asks unless given `--yes`. There is no
`memory show`.

## Auto-answer policy

```bash
tapq policy show [--policy PATH] [--json]
```

Prints the auto-answer policy `serve --auto-answer routine` would run under, including
whether it came from a file or from the built-in defaults, and fails with the same error
`serve` would on a document it cannot read. See
[The policy file](#the-policy-file) for the fields.

## Raw capture

```bash
tapq capture --duration 10 --output capture.jsonl
tapq capture --duration 10 --format csv --output capture.csv
tapq capture --duration 5 --output -
tapq capture --duration 30 -o imu.jsonl --mic-envelope imu.envelope.jsonl
```

| Option | Default or behavior |
|---|---|
| `--duration SECONDS` | `10` |
| `--format jsonl\|csv` | `jsonl` |
| `--output PATH`, `-o PATH` | `-` for stdout |
| `--force`, `-f` | Off; existing files are preserved; also applies to `--mic-envelope` |
| `--mic-envelope PATH` | Off; co-record a microphone loudness envelope sidecar |

Progress and the final sample count go to stderr, keeping stdout pipe-safe. CSV
output begins with a header. Each record contains:

- `timestamp`: hardware motion timestamp in seconds
- `pitch`, `yaw`, and `roll`: attitude in radians
- `acceleration_magnitude`: user-acceleration magnitude in g
- `rotation_magnitude`: rotation-rate magnitude in radians per second
- `user_acceleration_x/y/z`: signed user acceleration in g, earbud frame
- `rotation_rate_x/y/z`: signed rotation rate in radians per second, earbud frame
- `gravity_x/y/z`: gravity direction in g, earbud frame

The first five CSV columns keep their pre-per-axis positions, so tooling written
against earlier captures keeps working; per-axis columns are appended.

Capture does not run gesture classification. It requires macOS, compatible
connected AirPods, and Motion permission. Linux returns an unavailable error.

### Microphone envelope sidecar

`--mic-envelope PATH` co-records a microphone loudness envelope alongside the motion
track. It is capture-study tooling for labeling wearer speech, not a runtime input: it
answers *when* someone was talking so an IMU-based wearer-speech detector can be scored
against something that actually heard the room.

No audio is retained. Each audio block is reduced to a root-mean-square and a peak value
and the samples themselves are discarded, so the sidecar cannot reconstruct what was said.
Using the flag requires Microphone permission and adds a microphone open to a command
that is otherwise motion-only.

The sidecar is always line-delimited JSON regardless of the motion track's `--format`,
because its header line has no CSV equivalent. The first line is the track header and
every following line is one block:

```json
{"block_frames":4800,"clock":"boottime","sample_rate":48000,"schema":"tapq-mic-envelope-v1"}
{"peak":0.0121,"rms":0.0034,"timestamp":13485.221}
```

`timestamp` is on the same seconds-since-boot clock CoreMotion stamps motion samples
with, so the two tracks overlay directly with no second alignment step. The envelope's own
rate is `sample_rate / block_frames` points per second. A reader that meets an unfamiliar
`schema` rejects the file rather than guessing at its samples.

Failure policy is deliberately fail-closed, unlike TapQ's runtime paths. A study session
whose label track never opened is not worth keeping, so if the microphone cannot start the
command exits `69` before any motion is recorded. If the audio route is invalidated
mid-capture — switching input devices, for instance — the motion capture still finishes
and is written, stderr reports that the sidecar is truncated, and the command exits `1`.

Select the Mac's built-in microphone as the system input before co-recording. Opening the
AirPods microphone switches Bluetooth into its headset mode, which degrades the audio
route mid-session and changes the very motion signal the study is trying to measure.

## Replay and evaluation

```bash
tapq replay --input capture.jsonl
tapq replay --input capture.jsonl --labels capture.labels.jsonl
tapq replay --input capture.jsonl --labels capture.labels.jsonl \
    --encoder-model models/tapq1.mlpackage --json
```

Replays a recorded capture through TapQ's detection backends, entirely offline
and on any platform — no AirPods or permissions required. This is the evaluation
harness for the capture study: record once, then measure every tuning or backend
change against the same data.

| Option | Default or behavior |
|---|---|
| `--input PATH`, `-i PATH` | Required; a `tapq capture` file |
| `--labels PATH` | Optional JSONL expectation segments (see below) |
| `--format jsonl\|csv` | Auto-detected from extension or content |
| `--tolerance SECONDS` | `1.0`; grace period after a segment in which its event may still fire |
| `--encoder-model PATH` | Also replay through a TapQ-1 encoder model (macOS only) |
| `--gesture-profile PATH` | Replay with a calibrated gesture profile instead of defaults |
| `--tap-profile PATH` | Replay with a calibrated tap profile instead of defaults |
| `--wearer-speech-profile PATH` | Replay with a calibrated wearer-speech profile instead of defaults |
| `--mic-envelope PATH` | Envelope sidecar to derive wearer-speech ground truth from |
| `--json` | Emit the machine-readable report |

Without labels, replay lists every emitted event with its offset. With labels,
it adds per-gesture true/false positives, misses, precision, recall, and false
positives per minute — run it on confounder recordings (typing, bud adjustments,
desk motion) with an empty label file to measure false-positive rates directly.

Each label line marks the complete command the wearer performed, in the
capture's own timestamp clock:

```json
{"start": 12.4, "end": 14.1, "label": "nod"}
```

Valid labels: `nod`, `shake`, `tilt_left`, `tilt_right`, `tap`, `swipe_up`,
`swipe_down`. Segments span the complete doubled gesture — a `nod` segment covers
the full double nod, `shake` the full double shake, `tap` the full double tap —
matching what the pipelines emit. Motion-swipe detection is
enabled during replay even though it ships disabled live, so experimental
channels can be evaluated from the same recordings. Magnitude-only captures from
before per-axis capture replay through the heuristic backend; the encoder
backend needs per-axis data.

### Wearer speech

Replay also scores wearer-speech detection — whether the IMU can tell that the person
wearing the earbuds is the one talking. Unlike a gesture, speech is interval-valued rather
than event-valued, so it is reported separately and scored by frame overlap rather than by
the event evaluator.

Ground truth comes from one of two places:

- a `wearer_speech` label segment, which marks a span the wearer was talking:

  ```json
  {"start": 3.0, "end": 8.5, "label": "wearer_speech"}
  ```

- or `--mic-envelope PATH`, a sidecar from `tapq capture --mic-envelope`, from which
  speech spans are derived by thresholding the envelope against the recording's own noise
  floor with hysteresis and a short-gap merge.

Labels win when both are supplied, and a note is printed to stderr. Without either, the
section is omitted entirely and the report is exactly the shape it had before wearer
speech existed. `--tolerance` doubles as the edge slack allowed on both sides of a
wearer-speech span, since the edges of an utterance are approximate in a way a nod's are
not.

The text report prints frame-level true/false positives and negatives, precision, recall,
and F1 at the capture's own sample rate, plus mean onset latency over matched segments and
false activations per minute. Under `--json` the same numbers appear as a `wearer_speech`
object with the keys `truth_source` (`labels` or `mic_envelope`), `frame_precision`,
`frame_recall`, `f1`, `onset_latency_mean_seconds`, `false_activations`,
`false_activations_per_minute`, `detected_intervals`, `truth_intervals`, and
`matched_intervals`.

Threshold defaults are provisional until the capture study, which is why the detector's
configuration lives in a calibration profile rather than in code.

## Reasoner bench

```bash
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson --limit 20
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson --json > run.json
```

Scores a stage-2 risk reasoner against a labeled scenario corpus. Each scenario's
`context` is handed to the reasoner once and the returned `ReasonerDecision` is
graded against the corpus labels. This is `tapq replay`'s counterpart for the
context layer: replay measures gesture detection against recorded motion, bench
measures risk assessment against recorded requests.

| Option | Default or behavior |
|---|---|
| `--scenarios PATH` | Required; a newline-delimited JSON corpus (`bench/reasoner-scenarios-v1.ndjson`) |
| `--reasoner apple` | Backend to measure (default: `apple`); `off` is rejected |
| `--limit N` | Assess only the first N scenarios, in file order |
| `--json` | Emit the machine-readable report, including every offender id |

Scenarios run sequentially. Concurrency would race one on-device model against
itself: the cached prompt prefix would thrash and reported latency would be
queueing delay rather than the time an assessment takes. Progress goes to stderr,
keeping stdout pipe-safe for a saved report.

Unlike `tapq serve`, which serves on when the model is unavailable because a
missing reasoner can only mean "no escalation", bench **fails** in that case: a
run of abstentions would print as a report and read as a result.

### Grading

The rules are `bench/README.md`'s, implemented as written:

- **Tier** — exact match against `expected_tier`. No partial or ordering credit.
- **Code** — `rationale.code` must be in the row's `acceptable_codes`. Reported
  separately from tier accuracy: a right tier with a wrong code is a code miss,
  not a tier miss. Routine rows escalate nothing, so their code is unused and
  they are excluded from the code-in-set rate.
- **Abstention** (`nil`, a decision below `ReasonerConfig.minConfidence`, or an
  answer that arrives after the runtime's outer deadline) — a miss on `sensitive`
  and `destructive` rows, so a reasoner cannot score well by refusing to answer;
  acceptable on `routine` rows, where it would not have changed what the user has
  to do. Routine recall therefore credits abstentions, and the report prints hits,
  abstentions, and the abstain rate separately so an always-abstaining reasoner is
  visible as one.

  Each assessment runs through the same bound the runtime applies — the reasoner's
  timeout plus a small grace — so an answer that took longer than the user would
  have waited for is graded as a timeout abstention rather than a hit. Bench
  measures the reasoner the user actually gets.
- **False escalation** — an emitted tier above the expected one, reported apart
  from accuracy because it is safe but costs the user extra confirmation. Two
  numbers, as `bench/README.md` defines them: `escalations_above_expected`, a
  count over all rows (so a `sensitive` row escalated to `destructive` is
  visible), and the benign false-escalation rate, whose denominator is the
  expected-`routine` rows — the work the corpus calls ordinary.
- **Under-escalation** — an emitted tier below the expected one. The risk metric.

The report prints overall counts, a routine/sensitive/destructive/abstain
confusion matrix, per-tier precision and recall, the headline rates, latency p50
and p95, per-category counts (the two lookalike categories separately — they are
the rows the corpus exists for), and a worst-offenders list of scenario ids for
missed destructive rows, false escalations on routine rows, and code misses.
Those ids are the review hook: each one is a labeled corpus line to read and
argue with. The text report shows up to ten ids per list; `--json` carries all of
them.

Corpus problems are reported with the line number the file shows, and a run stops
rather than skipping a row: a harness that silently dropped scenarios would
report a score for a corpus it did not run.

## Calibration

```bash
tapq calibration run
tapq calibration run gesture
tapq calibration run tap
tapq calibration run wearer-speech
tapq calibrate
tapq calibration show
tapq calibration show gesture
tapq calibration show tap
tapq calibration show wearer-speech
tapq calibration show --json
tapq calibration reset
tapq calibration reset tap
tapq calibration reset wearer-speech
```

For source development on macOS, substitute
`scripts/run-runtime-app.sh calibration …` for live calibration commands.

### Run options

| Option | Default |
|---|---|
| `--rest-seconds N` | 3 seconds |
| `--nod-seconds N` | 4 seconds |
| `--shake-seconds N` | 4 seconds |
| `--tap-seconds N` | 4 seconds |
| `--speak-seconds N` | 6 seconds |
| `--non-interactive` | Off; when supplied, skips the initial Return prompt |

The default `all` run advances through connection warmup, rest, nod, shake, tap,
and speak in one continuous motion session. A gesture-only run is 14 seconds by
default; a tap-only retry is 9 seconds. The timeline discards a one-second
connection warmup and one-second transitions.

Gesture, tap, and wearer-speech results are saved as three independent profiles.
Each usable profile is saved as soon as its phase is assessed, so a later failure
never discards an earlier success: if tap fails after a valid gesture sequence,
the gesture profile remains saved and only `tapq calibration run tap` needs
rerunning. The same holds for the speak phase.

The speak phase asks the wearer to read aloud at a normal volume with the head
still. It measures the jaw- and skull-borne vibration the earbud IMU picks up
during speech, which is a different quantity from anything the microphone hears
and is only meaningful against a resting baseline recorded in the same session.
It is longer than the other phases by default because the statistic is a median
over sustained vibration rather than a peak over discrete events.

Tap calibration evaluates a sharp acceleration spike against the resting
baseline. It accepts lower-amplitude hardware only when the captured peak is at
least `0.06 g` and four times the resting peak. The saved threshold remains at
least `0.05 g` and three times the resting peak. Runtime detection additionally
requires a brief spike, quiet head rotation, a return toward baseline, and two
distinct impacts inside the pairing window.

Profiles contain tuned configuration, timestamps, sample counts, and aggregate
quality metrics. They do not retain raw motion values. `calibration show --json`
emits one object keyed `gesture`, `tap`, and `wearer_speech`, with only the
profiles that exist present.

### Profile locations

| Platform | Default directory |
|---|---|
| macOS | `~/Library/Application Support/TapQ/` |
| Linux | `$XDG_CONFIG_HOME/tapq/`, or `~/.config/tapq/` |
| Override | `$TAPQ_CONFIG_DIR/` |

The filenames are `gesture-calibration.json`, `tap-calibration.json`, and
`wearer-speech-calibration.json`.

For a selected `gesture`, `tap`, or `wearer-speech` target, `--profile PATH`
overrides that one profile; it is rejected under `all`, where three documents are
in play. `--gesture-profile PATH`, `--tap-profile PATH`, and
`--wearer-speech-profile PATH` can override the paths individually for an `all`
run, show, or reset. `calibration reset` prompts unless `--yes` or `-y` is
supplied, and resetting one target never touches the other two.

Profile inspection and reset work on Linux; live acquisition does not.

## Claude Code integration

```bash
tapq integration claude install --permission-policy native
tapq integration claude install --permission-policy strict
tapq integration claude status
tapq integration claude uninstall
```

The installer merges TapQ-managed hook groups into
`~/.claude/settings.json`, keeps unrelated settings and hooks from the version it
reads, creates a restrictive timestamped backup, and atomically replaces the
settings file. Do not edit the file concurrently with installation. Reinstall
after moving the TapQ executable because the hook command is an absolute path.

The installed executable is named `tapq-hook` and is expected beside `tapq`.
Development and custom installations can pass `--hook PATH`; isolated setups and
tests can pass `--settings PATH`.

### Permission-policy matrix

| Event | `strict` | `native` |
|---|---|---|
| `PreToolUse` | `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `AskUserQuestion` | `AskUserQuestion` only |
| `PermissionRequest` | Not installed | `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` |
| `Notification` | `idle_prompt`, `permission_prompt` | Same |
| `Stop` | All | All |
| `UserPromptSubmit` | Installed but silent unless steering is enabled | Same |

`strict` is the CLI default and sends every matched pre-tool event to TapQ before
Claude Code’s permission engine. A strict request whose reported permission mode
contains `auto` preserves the legacy behavior of allowing without a gesture.

`native` handles only supported dialogs that Claude Code would otherwise show.
Recognized read-only Bash operations, existing allow rules, and
`bypassPermissions` can therefore bypass TapQ. Native hooks are intended for
interactive sessions and do not create an approval channel for non-interactive
`claude -p` runs.

Only one ordinary approval path is installed at a time. `AskUserQuestion`
currently supports exactly one single-select question. Multiple questions and
multi-select requests fail through to Claude Code’s interface.

When `--voice-freeform` is enabled, a free-text voice answer to an `AskUserQuestion`
selection is delivered to Claude as a deny reason containing the wearer’s spoken text:
the model sees the original question and the wearer’s own-words answer, and is asked to
proceed accordingly without re-asking. This is a best-effort delivery — Claude Code
receives the text as feedback, not as a structured selection, and may interpret it at its
discretion.

Wire protocol v4 records whether an approval came from `PreToolUse` or
`PermissionRequest`. The current wire is v6; the broker also accepts v5 and v4 requests,
because each bump since v4 has only *added* a message type — v5 `instruction.submit`, v6
`instruction.wait` — leaving every request shape an older shim knows about unchanged. An
installed older shim therefore keeps working against a newer runtime, and a current shim
never sends one of the newer messages to a runtime that predates it. Strict and shared
messages can temporarily use a discovered legacy wire protocol v2 runtime. Native
permission requests never downgrade to v2 and remain in Claude’s normal dialog when no
compatible runtime is available.

Renewable instruction leases (2026-08-28) did not move the version, for the same reason
the accepted-versions list exists: both halves are inert to a peer that does not know them.
`instruction.wait` gained an optional `lease_id` that an older broker ignores, and the reply
gained a `wait: "renew"` value an older shim can never provoke and would read as "nothing
arrived". A shim without a lease is given the one-shot ten-minute budget it was built
against.

The `Stop` entry is installed with an explicit `timeout` of 2 147 483 s (~24.9 days) —
wider than every other hook by orders of magnitude, because it is the one that holds a turn
boundary open for a [voice session](#voice-sessions), and such a boundary is not ended by
time. That figure is the ceiling Claude Code's timer will honor, not a chosen duration; see
[How a boundary is held indefinitely](#how-a-boundary-is-held-indefinitely). Reinstall after
upgrading: an entry written by an older build carries a shorter timeout and would kill a
held boundary part-way through. `tapq integration claude status` reports `partial` until it
is rewritten.

### Structured-question steering

Starting the runtime with `--steering` opts into a lightweight Claude Code
`UserPromptSubmit` instruction:

> When you need the user to choose between options or confirm a decision, ask via
> the AskUserQuestion tool rather than in plain text.

The hook adds this context only when it can read a live discovery record, the
wire version is compatible, and the runtime advertises steering. Missing, stale,
or incompatible discovery fails silently and injects nothing.

### Final-response questions

On a `Stop` event, the adapter reads the trailing assistant reply from Claude
Code’s local transcript. Replies without `?` are ignored. Explicit yes/no and
multi-option questions can be converted into a hands-free interaction; open-ended
or inconclusive questions pass through.

On macOS 26 or later, the runtime uses Apple's on-device Foundation Model when
Apple Intelligence reports it available. The model classifies supported prose
questions and shortens them for speech with a five-second provider timeout. If the
model is unavailable or fails, TapQ falls through to its deterministic structured-option
heuristic and then to Claude Code's normal UI.

When `--question-classifier anthropic` is passed and `ANTHROPIC_API_KEY` is present,
the runtime explicitly overrides the on-device model with
`claude-haiku-4-5-20251001` through Anthropic’s Messages API to
classify and shorten the reply. It sends up to the final 16,384 characters, returns
at most six cloud-extracted options, and uses a five-second provider timeout. API
failure or invalid output falls through to the deterministic local heuristic and
then to Claude’s normal UI.

The API key and submitted reply are not intentionally logged. The reply may
contain project or user data, and API use may incur charges. Restart with
`--question-classifier auto` or `local` to disable cloud processing. An inherited API
key alone does not activate the provider.

### Spoken summaries

> **On `--voice-backend openai-realtime` this whole section is inert at turn
> boundaries.** Since 2026-08-28 a narration model decides what that path speaks
> about an agent's final reply, and neither `--speech-summarizer` nor
> `--question-classifier` is consulted there. See
> [Spoken narration](#spoken-narration). Everything below describes
> `--voice-backend apple`, which is unchanged.

The classifier decides *whether* a reply holds a question and what the question is.
`--speech-summarizer` decides what TapQ says about the reply around it. It applies to
every adapter that sends final-response text, not only Claude Code.

With a summarizer configured, four things change:

- A yes/no stop question is introduced by one summary sentence:
  `"The agent: The importer now streams rows. Delete the old importer? Yes or no?"`
  The question itself is the classified question, unchanged.
- Asking for `details` during a stop question speaks the summary's longer text instead of
  `"No further details."`, which is what a stop question answered before.
- A multi-option stop question hears the sentence once, before the first option. It is not
  repeated when navigating between options or on an explicit `repeat`.
- Agent notifications say the short message their adapter already sends:
  `"The agent is waiting: Needs a decision on the retry policy."` No model is involved on
  this path — the text is the adapter's own, condensed deterministically — and a
  notification that arrives without one is spoken exactly as before.

The sentence is capped at 120 characters and one sentence, the detail at 320, by
truncation applied after the provider answers rather than by asking a model to be brief.
Every provider is composed over the deterministic local reduction: one that fails, times
out (five seconds), or returns nothing degrades to a plainer sentence taken from the reply
itself. When even that finds nothing speakable there is no summary at all, and every
utterance falls back to the words it had without one.

No summary ever reaches the wording that names what the user is authorizing. Tool-approval
prompts, confirmation cues, and the yes/no question itself are TapQ's own text in every
configuration; a summary can only precede them.

`--speech-summarizer off` composes no summarizer at all, and the spoken content of every
prompt, detail, and notification is byte for byte what it was before this feature existed —
including the notification summary, which is off with it even though it uses no model.

`--speech-summarizer` is independent of `--voice-backend`. The summarizer chooses the
words; the backend chooses the voice that says them. On `--voice-backend openai-realtime`
every utterance — approvals and question prompts included — is spoken by the realtime voice,
as a verbatim reading rather than a generated response, so the wording is still TapQ's;
see [One voice](#one-voice). That routing is wired to the realtime backend's presence alone
— it is unaffected by `--speech-summarizer`, including `off`.

`apple` requires an eligible device and refuses to start without one; `anthropic` and
`openai` require `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` and refuse to start without the
key, the same way the classifier does. An inherited key alone activates nothing.

With `--speech-summarizer anthropic` or `openai`, the agent's final reply is sent to that
provider to be summarized: at most its last 16,384 characters, cut to that length by the
adapter before the runtime ever sees the text. It is the same text the cloud classifier
sends. The reply may contain project or user data, and API use may incur charges. The API
key and the submitted reply are not intentionally logged, and the returned summary is
spoken but never written to disk. Nothing else about the session is sent: not the tool
input, the working directory, or the question the classifier found.
`auto`, `apple`, `heuristic`, and `off` send nothing off the machine.

### Spoken narration

On `--voice-backend openai-realtime`, what TapQ says at an agent's turn boundary is
decided by a model rather than by templates. There is no flag: the narration model is
composed with that backend and only with it.

At each boundary TapQ gathers what is pending for the wearer — the agent's final message
for the turn, plus any TapQ status lines that piled up behind it — and asks the narration
model for the one thing to say. The model chooses among four deliveries and reports which
it used:

- **verbatim** — read the message out as it is. This is the bias for anything already
  one or two spoken sentences long.
- **summary** — condense a long or structured message to the outcome.
- **question** — the message needs a decision from the wearer. The utterance becomes the
  question TapQ asks, answered by the same nod, tap, or spoken yes/no that answers a
  stop question, and the answer goes back to the agent through the same reply the
  heuristic path used.
- **combined** — several pending things said in one utterance.

The returned text is spoken **verbatim** on the run's one voice: TapQ does not
re-summarize it, re-punctuate it, or shorten it, and there is no character cap on it. The
guidance prompt tells the model to keep technical tokens exact — paths, commands, flags,
error codes, counts — because a wearer who cannot see a screen has only the utterance.

What narration does *not* touch: approval prompts, dictation read-backs, queue and status
read-backs, and TapQ's fixed confirmations are scripted sentences in every configuration.
Narration governs how an agent's output is delivered, never the wording that names what
the wearer is authorizing. A queued instruction still preempts everything at a boundary
and is delivered without a model in the loop.

**Model and cost.** `gpt-5.6-luna` over the OpenAI Responses API, authenticated with the
same `OPENAI_API_KEY` the realtime session uses, and *not* the realtime session itself —
it is a separate HTTPS request whose output text is then spoken. Set
`TAPQ_NARRATION_MODEL` to use another model id. One request per narrated boundary; API
use may incur charges. The key, the request body, and the returned utterance are not
intentionally logged: the diagnostics carry `narration.requested items=N`,
`narration.spoken length=N mode_hint=…`, the model id, and timings.

**What is sent.** Only speech-eligible surfaces — the agent's final message text (the
same text the cloud classifier and summarizer receive on the Apple path) and TapQ's own
status lines, plus the agent's display name. Never the tool input, the working directory,
the permission mode, or a session identifier.

**Failure.** A narration failure — HTTP error, timeout (15 seconds), empty output, a
response that does not decode — is a voice-pipeline failure, not a degraded mode. It
breaks the run's voice channel the same way a dropped realtime socket does: the wearer is
told once, the microphone is gone for the rest of the run, and TapQ does not fall back to
the summary templates, which are unreachable on this path. The agent is unaffected — the
turn boundary fails open and the agent carries on.

### Spoken recall and questions

TapQ remembers what each session asked and how it was answered, and will say it back. No
flag turns this on: it works on both voice backends — as grammar on the Apple one, as the
`query_status` tool on the realtime one — and it costs nothing when there is nothing to
recall.

Two questions are understood inside any open prompt. The phrasings below are the Apple
backend's; the realtime backend takes any wording of the same two questions.

- **"What changed?"** — also "what did you do", "what did you just do", "what have you
  done". TapQ speaks this session's last three resolved interactions, newest first:
  `"Claude Code approved run the test suite. Before that, denied delete the cache."`
- **"What's the status?"** — also "status", "who's waiting". TapQ names the request in
  hand and counts the queue behind it:
  `"Claude Code: run the test suite. 2 more waiting."` Counts and agent names only; a
  session identifier is never spoken.

Both are informational. They are matched ahead of the yes/no grammar, so an interrogative
can never be read as an answer, and they resolve nothing: the prompt is re-spoken and the
window is still waiting for the nod, shake, or word it opened for. With nothing recorded
yet, the answer is `"Nothing recorded yet."` — silence would be indistinguishable from a
question that was never heard.

**Recall works only while a window is open.** The microphone is live during a bounded
response window and at no other time, so there is no way to ask what changed between
prompts; the question has to be asked into a prompt that is already listening. That is the
same windowed-microphone rule every other voice command follows, and it is why recall
answers about the session whose prompt you are in rather than about the fleet at large.

What is remembered is bounded and speech-safe by construction: the last 16 events for each
of the last 8 sessions, holding the agent's display name, the spoken summary (and detail
for a stop question), the tool name, and the outcome. The tool input, the working
directory, and the permission mode have nowhere to live in a recorded event, so nothing
composed from one can leak them. Nothing is written to disk, and memory is per run — a
restarted runtime has forgotten everything.

#### Grounded questions on the realtime path

Since 2026-08-28 a spoken question on this backend is answered by the model directly, from
the grounding TapQ supplies before each turn: whether a window is open, the last few
sentences the wearer actually heard, and the live agent names. There is no separate
question-detection step and no answering budget, because there is no longer a free-form
transcript to detect one in.

What is unchanged is what may be sent and what may result:

- The grounding carries only speech-safe material — sentences TapQ has already spoken out
  loud. The tool input, the working directory, and the permission mode are never spoken, so
  they can never reach the model this way.
- An answer can never approve, deny, select, or defer. It is speech. Deciding anything takes
  a tool call, and every tool is refused when no window is open to receive it.
- On the Apple backend nothing here applies: there is no model to answer with, and the window
  behaves exactly as it always has.

The route this replaces — `--voice-freeform` promoting an unmatched transcript and TapQ
composing an answering instruction with a context digest — is gone with the rest of the
transcript→intent steps.

## Codex integration

```bash
tapq integration codex install [--hooks PATH] [--hook PATH]
tapq integration codex status [--hooks PATH] [--hook PATH]
tapq integration codex uninstall [--hooks PATH] [--hook PATH]
```

By default, the installer merges TapQ-managed hook groups into
`~/.codex/hooks.json`. When `CODEX_HOME` is set, the default becomes
`$CODEX_HOME/hooks.json`. It preserves unrelated top-level data, events, matcher groups,
and handlers; snapshots an existing file to a restrictive timestamped backup; and
atomically replaces the original. Do not edit the file concurrently with installation.
Reinstall after moving TapQ because the hook command is an absolute path. A direct
`install` repairs registrations at the current hook, the bare `tapq-codex-hook` command,
or recognized TapQ app/build paths; unfamiliar custom executable paths are preserved as
unrelated hooks. Users upgrading from the previous three-hook layout must rerun `install`
to add the fourth `UserPromptSubmit` registration, then review all changed definitions in
`/hooks`.

The installed executable is named `tapq-codex-hook` and is expected beside `tapq`.
Development and custom installations can pass `--hook PATH`; isolated setups and tests
can pass `--hooks PATH`.

Installation is not activation. Codex requires users to review and trust the exact
definition of every non-managed command hook. After installation, open an interactive
Codex session, run `/hooks`, inspect the four current TapQ registrations at the selected
hook path, and trust their definitions. Unrecognized custom-path hooks may remain as
unrelated data. Changed definitions receive a new hash and must be reviewed again. The
`status` command validates TapQ’s file layout and reports best-effort diagnostics for the
local Codex executable, version, and relevant feature values when available. It resolves
`codex` from the caller's `PATH`, then executes only `--version` and `features list` with
a minimal allowlisted environment containing process/configuration lookup,
temporary-directory, and locale values. A missing executable is reported as
`not found on PATH`; a resolved one
that cannot launch, complete, or drain within the probe bounds is reported as
`executable found, but diagnostics failed or timed out`. Neither condition changes status
exit semantics. Since the resolved path is executed with the user's authority, invoke
status with a trusted `PATH`. TapQ cannot inspect or change Codex’s trust decision;
`/hooks` remains authoritative. A parsed version below `0.142.5` produces a compatibility
warning.

### Supported Codex event slice

TapQ installs four lifecycle hooks:

| Event | Matcher | Current behavior |
|---|---|---|
| `PreToolUse` | `request_user_input` | Answers one supported root-agent single-choice question before Codex opens its native selector |
| `PermissionRequest` | `Bash`, `apply_patch`, `mcp__<server>__<tool>` | Answers only native approval prompts Codex was already going to show |
| `Stop` | All root turns | Sends completion and optionally routes an explicit final-response question |
| `UserPromptSubmit` | None | Adds a fixed root-turn `request_user_input` hint only while live compatible discovery advertises steering |

For `request_user_input`, TapQ supports exactly one question with two or three valid,
uniquely labelled options. A hands-free selection is delivered to the model through
Codex’s documented `PreToolUse` deny feedback, so the native selector does not also
open. Multiple questions, auto-resolving questions, unsupported option shapes,
secret questions, subagent calls, unanswered interactions, broker failures, and missing
runtimes emit no hook output; Codex then retains its native behavior, including its
free-form `Other` choice.

When `--voice-freeform` is enabled, a free-text voice answer to a `request_user_input`
question is delivered as a single-element `answers` array containing the wearer’s spoken
text. Whether Codex’s `request_user_input` tool accepts non-option answer strings is not
verifiable from this repository — the response JSON is a TapQ-fabricated model-visible
claim — so the model will see the text, but native-UI expectations may differ. The
milestone-two smoke checklist gates this with an explicit verification item.

In Codex CLI `0.146.0`, Plan mode is the reliable surface for
`request_user_input`. Default-mode exposure depends on Codex's
`default_mode_request_user_input` feature. Status reports the observed feature value when
Codex exposes it, but it cannot force the feature on or make an unavailable tool callable.

For `PermissionRequest`, an allow or deny becomes Codex’s documented event-specific
decision. A broker timeout, `.ask`, invalid reply, incompatible wire version, or missing
runtime emits no hook output, so Codex retains its native approval prompt. Existing
Codex rules, sandbox policy, and permission modes remain authoritative; an operation
that does not produce a native `PermissionRequest` does not reach TapQ. For MCP tools,
TapQ speaks a humanized server and operation name but never renders argument values in
the summary or detail. The original `tool_input` remains in the local broker request
context. If the on-device stage-2 reasoner is selected, complete inputs are rendered as
sorted JSON. Oversized inputs become key-balanced top-level excerpts spanning early and
late keys, with balanced head/tail excerpts of selected values. Non-ASCII scalars and
Unicode line separators are escaped before accounting, and all rendered input including
markers is at most 4,000 characters. MCP values are not spoken, diagnosed, or sent to a
cloud provider. MCP review rows omit the argument object, model note, and confidence but
retain outcome and, for a decided row, tier/code. A hook allow applies to that call only; persistent
connector rules, connector authentication, and MCP-generated elicitation remain in
Codex's native flow.

`UserPromptSubmit` steering is advisory rather than an approval path. The matcherless
hook applies only to root turns and returns the exact fixed additional context “When you
need the user to choose between options or confirm a decision, use request_user_input
when available rather than asking in plain text.” only when a live, wire-compatible TapQ
runtime advertises `--steering`. It reads discovery, then makes a bounded, EOF-only
Unix-socket connection to verify liveness, but sends no broker request or application data
and performs no request/response round-trip. Invalid input, subagent turns, missing or
incompatible discovery, and disabled steering emit no output, preserving Codex's native
prompt submission.

For `Stop`, Codex supplies the final text through `last_assistant_message`; TapQ does not
parse Codex transcript files. Replies without `?`, inconclusive classifications, and
unanswered interactions complete normally. A hands-free answer produces one continuation
prompt. On the subsequent `stop_hook_active` callback, TapQ skips question interception
to prevent a re-ask loop and reports completion.

For cloud classification on this path, start the runtime with
`--question-classifier openai` and provide `OPENAI_API_KEY`. TapQ uses `gpt-5.6-luna`
through OpenAI's Responses API with strict structured output, no reasoning effort, and a
five-second provider timeout. API failure, an incomplete or refused response, or invalid
output falls through to the deterministic local heuristic and then Codex's normal UI.
Because provider selection is runtime-wide, any Claude Code adapter connected to the
same instance also uses Luna in this mode.

The Codex adapter has no broad strict `PreToolUse` mode or generic notification-hook
equivalent. Completion notification is derived from `Stop`; these limitations are
intentional rather than installation errors.

Codex CLI `0.142.5` is TapQ’s tested lifecycle-hook contract floor. Versioned
`PermissionRequest` and `Stop` fixtures cover that floor; structured
`request_user_input`, MCP `PermissionRequest`, and `UserPromptSubmit` use versioned Codex
CLI `0.146.0` fixtures. Real hook-process-to-broker contracts cover supported decisions,
denial, and native fail-through for missing discovery and incompatible versions. They do
not launch Codex, authenticate, prove Codex consumes hook stdout, or prove a model follows
the returned decision/feedback. Those boundaries remain live manual release tests. Older
hook contracts are unsupported. This adapter targets local
Codex clients that load user lifecycle hooks; it does not attach to hosted Codex Cloud
tasks.

## Cursor integration

```bash
tapq integration cursor install [--hooks PATH] [--hook PATH]
tapq integration cursor status [--hooks PATH] [--hook PATH]
tapq integration cursor uninstall [--hooks PATH] [--hook PATH]
```

By default, the installer merges TapQ-managed entries into `~/.cursor/hooks.json`, the
user-level hook file Cursor reads for every project. It preserves unrelated top-level data,
events, and entries; snapshots an existing file to a restrictive timestamped backup; and
atomically replaces the original. It writes `"version": 1` only when the file does not
already declare a schema version. Do not edit the file concurrently with installation.
Reinstall after moving TapQ because the hook command is an absolute path. A direct
`install` repairs registrations at the current hook, the bare `tapq-cursor-hook` command,
or recognized TapQ app/build paths; unfamiliar custom executable paths are preserved as
unrelated hooks.

The installed executable is named `tapq-cursor-hook` and is expected beside `tapq`.
Development and custom installations can pass `--hook PATH`; isolated setups and tests can
pass `--hooks PATH`. Cursor accepts a command line rather than a bare executable path, so
the recorded command is shell-quoted and an install path containing spaces is safe.

Cursor requires no hook-trust step and reloads `hooks.json` when it changes, so a fresh
install is active immediately; restart Cursor if an already-open session does not pick it
up. Because Cursor exposes no local command that reports hook activation, `status`
validates TapQ's file layout and then states the documented client coverage instead of
executing a Cursor binary.

### Supported Cursor event slice

TapQ installs four managed entries:

| Event | Matcher | Current behavior |
|---|---|---|
| `beforeShellExecution` | None | Answers `allow` or `deny` for every non-sandboxed shell command |
| `preToolUse` | `Write` | Answers `allow` or `deny` before a file write |
| `preToolUse` | `Delete` | Answers `allow` or `deny` before a file delete |
| `stop` | None | Announces a turn Cursor reports as `completed` |

Cursor runs `beforeShellExecution` for every command rather than only when it would prompt,
so the Cursor adapter is strict-only: it has no equivalent of Claude Code's `native`
permission policy. Sandboxed executions are the one case TapQ skips, because Cursor does
not prompt for them.

Cursor documents `preToolUse` `tool_input` as an open object. TapQ forwards it unchanged to
the local broker, names the action from the tool type, and speaks a file path only when it
can resolve one from `file_path`, `path`, or `target_file`. Argument values — including a
proposed file body — are never spoken.

The `stop` payload carries a status and a loop count but no final assistant text, so the
Cursor adapter announces completion and never routes a final-response question or returns
`followup_message`. Cursor's agent also exposes no hookable question tool, so there is no
Cursor counterpart to Claude Code's `AskUserQuestion` or Codex's `request_user_input`.

Client coverage differs by surface: the Cursor desktop app fires every installed TapQ hook,
while `cursor-agent` does not fire `preToolUse`, leaving writes and deletes native there.
Cursor Cloud agents do not read the user-level hook file this installer manages. Every
failure path is silent: Cursor's documented default lets a crashed, timed-out, or non-JSON
hook proceed through its own permission flow, and TapQ never sets `failClosed`. Payload
shapes follow Cursor's published hook reference at <https://cursor.com/docs/agent/hooks>;
this adapter ships no versioned Cursor fixture corpus.

## OpenCode integration

```bash
tapq integration opencode install [--plugin PATH] [--hook PATH]
tapq integration opencode status [--plugin PATH] [--hook PATH]
tapq integration opencode uninstall [--plugin PATH] [--hook PATH]
```

OpenCode has no hook-registration file, so the installer writes one plugin TapQ owns end
to end. By default it goes to `<config>/plugins/tapq.js`, resolving `<config>` the way
OpenCode does: `$OPENCODE_CONFIG_DIR`, then `$XDG_CONFIG_HOME/opencode`, then
`~/.config/opencode`. A non-absolute value in either variable is ignored so the plugin
cannot land somewhere OpenCode will not scan. Isolated setups and tests can pass
`--plugin PATH`.

The installed executable is named `tapq-opencode-hook` and is expected beside `tapq`;
development and custom installations can pass `--hook PATH`. Its absolute path is written
into the plugin, so reinstall after moving TapQ.

`install` refuses to overwrite a file at the managed path that lacks TapQ's marker,
reporting it instead; `uninstall` likewise leaves such a file alone and removes only
TapQ's own plugin, so unrelated plugins in the same directory are never touched. A
mutation snapshots the previous file to a restrictive timestamped backup and replaces it
atomically. A rerun of `install` against a matching plugin is a byte-for-byte no-op that
creates no backup; against a stale or hand-edited TapQ plugin it repairs the file. Do not
edit the plugin concurrently with installation.

`status` reports `installed` for a current TapQ plugin, `incomplete` for a TapQ plugin
from another build or hook path, and `not installed` when the file is absent or was not
written by TapQ. OpenCode loads plugins at process start, so restart OpenCode after any
change before expecting new behavior.

### Supported OpenCode event slice

| Event | Current behavior |
|---|---|
| `permission.asked` | Answers only native permission prompts OpenCode was already going to show |
| `session.idle` | Sends completion, deduplicated against the `session.status` replacement event |

An allow becomes a one-time `once` reply and a deny becomes `reject` carrying TapQ’s
reason. The remembered `always` reply is never sent. A broker timeout, `.ask`, invalid
reply, incompatible wire version, or missing runtime applies no reply, so OpenCode’s
prompt stays on screen and answerable; existing OpenCode permission rules remain
authoritative and an operation that produces no prompt never reaches TapQ.

Speech for the `bash`, `edit`, and `webfetch` kinds comes from documented scalar metadata
— the command, the file path, and the request host only. Every other kind is spoken from
its name alone, and no permission `metadata` object is ever serialized into speech. The
original metadata stays in the local broker request context for the on-device stage-2
reasoner.

There is no question interception and no final-response continuation: OpenCode exposes no
structured single-select question tool and no documented way for a plugin to continue a
finished turn. These are intentional limitations, not installation errors.

The adapter targets OpenCode `1.18.15`. It uses the `permission.asked` bus event rather
than the `permission.ask` plugin hook, which is declared in `@opencode-ai/plugin` but
never triggered by OpenCode. Replies prefer `POST /permission/{requestID}/reply` and fall
back to the deprecated session-scoped route on the injected SDK client. Real
relay-process-to-broker contracts cover allow, deny, fail-through, completion, and
unauthorized discovery. They do not launch OpenCode, load the plugin into its runtime, or
prove that OpenCode accepted the reply; those boundaries remain live manual release tests.

## Environment variables and local data

| Name | Purpose |
|---|---|
| `TAPQ_DEBUG=1` | Enable verbose console diagnostics |
| `TAPQ_BROKER_DIR` | Override the runtime discovery/socket directory |
| `TAPQ_SPEECH_VOICE` | Voice used for spoken output when `--speech-voice` is not passed. Primary control for the packaged runtime app, which is launched through `open` and takes no flags |
| `TAPQ_CONFIG_DIR` | Override calibration profile storage, and the auto-answer policy document that sits beside it |
| `CODEX_HOME` | Select the Codex state directory whose `hooks.json` the integration command manages |
| `OPENCODE_CONFIG_DIR` | Select the OpenCode configuration directory whose plugin the integration command manages |
| `XDG_CONFIG_HOME` | Base for the default OpenCode configuration directory when `OPENCODE_CONFIG_DIR` is unset |
| `ANTHROPIC_API_KEY` | Authenticate classification requests selected with `--question-classifier anthropic`, and summarization requests selected with `--speech-summarizer anthropic` |
| `OPENAI_API_KEY` | Authenticate classification requests selected with `--question-classifier openai`, summarization requests selected with `--speech-summarizer openai`, and realtime voice sessions — plus the narration model that decides what they speak — selected with `--voice-backend openai-realtime` |
| `TAPQ_NARRATION_MODEL` | Override the narration model id used on `--voice-backend openai-realtime`. Defaults to `gpt-5.6-luna`. See [Spoken narration](#spoken-narration) |
| `TAPQ_TURN_EAGERNESS` | How readily the model ends a turn when there is no IMU turn signal on `--voice-backend openai-realtime`: `low` (default), `medium`, `high`, or `auto`. Read once at startup; an unrecognized value falls back to `low`. See [Turn detection](#turn-detection) |
| `TAPQ_REALTIME_VOICE` | Voice for `--voice-backend openai-realtime`: one of `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`, `marin`, `cedar`. Default `cedar`; read once at startup, and an unrecognized name falls back rather than failing the session. `--speech-voice` does not affect this path |
| `TAPQ_REALTIME_SPEED` | Speaking rate for `--voice-backend openai-realtime`, 0.25–1.5. Default `1.1`; values outside the range are clamped and a value that is not a number falls back. Sent on the opening frame only |
| `TAPQ_SIGN_IDENTITY` | Select a signing identity for the packaging script |

Default broker directories:

- macOS: `~/Library/Application Support/TapQ/runtime`
- Linux: `$XDG_RUNTIME_DIR/tapq`, falling back to
  `~/.local/state/tapq/runtime`

The runtime directory is `0700`; its discovery record and socket are `0600`; and
the bearer token is regenerated on each launch. The token demonstrates access to
the same-user discovery record. It is not protection from a malicious process
running under the same account.

## Exit status

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully |
| `1` | Execution failed |
| `64` | Invalid command or option |
| `69` | Requested platform or hardware service is unavailable |

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for privacy permissions,
AirPods acquisition, calibration, gesture diagnostics, voice, Claude Code and Codex hook
installation, hook trust, cloud classification, and Linux limitations.
