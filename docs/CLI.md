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
{"name":"tapq","version":"0.5.0-beta.2","wire_protocol":4}
```

The project is pre-1.0. Machine-readable formats are designed for automation,
but incompatible corrections may still occur before the first stable release.

## Runtime

Source-development examples:

```bash
scripts/run-runtime-app.sh serve
scripts/run-runtime-app.sh serve --no-voice
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 30
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
| `--timeout SECONDS` | Input timeout; default and maximum are 240 seconds |
| `--no-voice` | Do not request microphone/Speech access or start voice input |
| `--speech-voice VOICE` | Voice used for spoken output: a language tag (`en-US`, `zh-CN`) or a macOS voice identifier. Default `en-US`; also settable with `TAPQ_SPEECH_VOICE`. Unrelated to `--no-voice`, which gates the microphone |
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
| `--imu-turn-control` | IMU-based turn control (default: off). Endpointing: wearer speech-end commits the user turn after a short delay. Barge-in: wearer speech-onset during response audio interrupts playback. Both are additive to gesture/tap/timeout resolution. Shares one signal source with `--wearer-gate` |
| `--voice-freeform` | Free-form voice answers for selections and multi-option stop questions (default: off). Requires `--voice-backend openai-realtime`. An unmatched final transcript is offered as a free-text reply with mandatory read-back confirmation. Tool approvals and yes/no stop questions stay binary |
| `--voice-instructions` | Dictated instructions to the agent (default: off). Requires `--wearer-gate`; passing it alone is a startup error. "New instruction" or "tell it to ⟨…⟩" inside an open prompt opens a read-back-and-confirm dictation, and the confirmed sentence is delivered at the agent's next turn boundary. Fail-closed on wearer attribution — the inverse of every other voice path. Claude Code and Codex only. See [Dictated instructions](#dictated-instructions) |

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
  Realtime API in manual-turn mode. The ready block reports
  `Voice backend: openai-realtime (fail-through: apple)`.

There is no OpenAI-only mode. The realtime backend is always composed with the Apple stack
underneath it, so a session that cannot be opened — or that drops mid-window — continues
on-device rather than leaving the window without a voice channel. Gesture, tap, and
timeout resolution are unaffected in every case.

Turn arbitration stays on TapQ's side in both modes: server-side voice activity detection
is disabled (`turn_detection: none`) and TapQ commits each turn itself, so a remote
endpoint can never decide the wearer has finished speaking. Audio leaves the machine only
while a response window is open, and the API key is sent as a request header and is not
logged.

#### Conversation sessions

On the `openai-realtime` path, the backend session uses conversation-scoped persistence:
one WebSocket session outlives multiple response windows. A per-window session policy
(milestone one's behavior) would open and close a full WebSocket session on every mic
reopen — several times per approval — because `SpeechGatedVoice` stops and restarts the
voice provider every time TTS becomes busy. Conversation sessions eliminate that churn.

The session stays open across windows and is closed by an idle timer (60 seconds with no
window open) or by a serve shutdown. A new window opens a fresh user turn on the existing
session. Fail-through is sticky per conversation: once the primary backend fails (network
death, handshake timeout), subsequent windows go straight to the Apple fallback with no
primary traffic until the conversation resets on idle-close reopen. This prevents a 5-second
handshake timeout at every mic reopen when the network is down.

The `apple` path is unchanged: `VoiceListener` opens and closes its recognizer per window,
exactly as before.

#### Microphone pump and playback

The `openai-realtime` backend is a pipe: it transmits and receives audio but does not own
the microphone or the speaker. Two macOS adapters bridge the gap:

- **Microphone pump** (`MicrophonePumpVoiceBackend`): opens the Mac's audio input on each
  user turn, converts captured buffers to the pipe's wire format (mono 24 kHz PCM16), and
  streams them through `sendAudio`. The microphone is opened only inside a user turn and
  never between windows. A mid-turn audio route change (e.g. Bluetooth disconnect) closes
  the mic and triggers fail-through to the Apple backend.

- **Backend audio playback** (`BackendAudioPlayback`): receives response audio chunks from
  the cloud, converts them to `AVAudioPCMBuffer`, and plays them through `AVAudioEngine`.
  The engine starts lazily on the first chunk of each response and stops when drained. Any
  playback failure drops audio for the rest of the response and fails open: the transcript
  and the window are unaffected.

The combined speech activity signal merges TTS activity and backend playback, so
`SpeechGatedVoice` holds the microphone closed while *either* the local synthesizer or
the cloud voice is speaking. This is the self-hearing guarantee: the mic and the speaker
are never simultaneously live.

#### Transcript timing on the OpenAI path

On the OpenAI Realtime path, transcripts are not available until the audio buffer is
committed. Under `turn_detection: none`, the server creates the user conversation item —
and starts input transcription — only on commit. This means there are no mid-turn partial
transcripts, and the milestone-one "match on partial transcript" resolution path never
fires before a commit.

Without `--imu-turn-control`, the only turn-ending events are a command match after the
window-teardown commit, gesture, tap, or timeout. **`--imu-turn-control` is effectively
required for natural voice resolution on the `openai-realtime` path**, because it commits
the turn when the wearer stops speaking, which is what makes transcripts — and therefore
voice resolution — possible before the window timeout.

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

When enabled, an unmatched final transcript (one that does not match any keyword in the
grammar) is offered as a free-text reply with mandatory read-back confirmation:

1. The wearer speaks an answer that matches no command.
2. TapQ reads back: "You said: '<text>'. Nod to send, shake to discard."
3. The wearer nods to confirm or shakes to discard and re-listen.

A confirmed free-text answer resolves the selection and reaches the agent through the wire
protocol (see below). Tool approvals and yes/no stop questions stay binary — a spoken
free-text answer can never authorize an agent action. The read-back confirmation is a
deliberate safety measure: a stray sentence becoming an agent instruction is worse than one
extra nod.

#### Dictated instructions

`--voice-instructions` lets the wearer say something *to* the agent rather than answer
what it asked. It requires `--wearer-gate`; passing it alone is a startup error, because
the attribution signal the whole feature is fail-closed on comes from the gate.

```bash
tapq serve --wearer-gate --voice-instructions
```

Inside any open prompt:

1. The wearer says "new instruction", "instruction for Claude", or dictates in one breath
   with "tell it to ⟨…⟩". The capturing forms take everything after the prefix as the
   instruction, in the wearer's own words.
2. Without captured text, TapQ says "Go ahead." and takes the next spoken turn as the
   instruction.
3. TapQ reads it back: "Instruction: '⟨text⟩'. Nod or say yes to queue it."
4. A nod, a double tap, or "yes" queues it — "Queued for ⟨agent⟩." Anything else discards
   it — "Instruction discarded." Silence discards it without a word.

The prompt the wearer was answering is untouched by all of this. The confirming nod is
consumed inside the dictation, the request is still waiting when the flow ends, and the
window's deadline is never extended: dictating cannot buy more time to decide.

**Instructing fails closed; authorizing fails open.** A voice TapQ cannot attribute to the
wearer — including one where the signal cannot say whose it is — is refused out loud ("I
can't confirm that was you — instruction discarded.", diagnostic
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
  The most recent sentence is the one the wearer meant.
- Three instruction-bearing boundaries in a row, then delivery pauses with a spoken notice
  until a boundary carries something else (`instruction.loop_cap.suppressed`). A stop reply
  restarts the agent's turn, and Claude's stop hook has no `stop_hook_active` flag to lean
  on.
- Claude Code and Codex only. Cursor and OpenCode have no turn boundary to deliver into,
  and dictating at one of them is refused by name: "Instructions aren't supported for
  OpenCode." See the [capability matrix](INTEGRATIONS.md#agent-capability-matrix).
- Dictation works only while a window is open, for the same reason recall does: the
  microphone is live only during a bounded response window.
- Nothing survives a restart. A queued, undelivered instruction is gone with the process.

While instructions are waiting, "who's waiting?" says so: `"Claude Code: run the test
suite. Nothing else waiting. 1 instruction queued."` Once delivered, "what changed?"
recalls it as work handed over — `"Claude Code was told to run the tests again."` — never
as work done.

Without the flag, nothing composes a queue: the grammar still matches the phrase, it
reaches nowhere, nothing is spoken, and the window goes on listening.

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

For approvals and yes/no questions:

- Double nod, double tap, or an affirmative voice command approves.
- Double shake or a negative voice command denies.
- `repeat` speaks the prompt again; `details` requests the longer spoken detail.

For option questions:

- Volume down or `next` moves forward.
- Volume up or `previous` moves backward.
- Double nod, double tap, `select`, or spoken numbers one through four confirms.
- Double shake or `skip` returns control to the on-screen prompt.

Voice commands are recognized with an English (`en-US`) grammar. Voice input is
active only during a bounded response window. TapQ requires on-device recognition
when the selected recognizer supports it; otherwise Apple’s Speech framework may
use Apple’s service. Spoken output uses the macOS system speech synthesizer and
voice selection.

### Motion recovery and diagnostics

A single CoreMotion disconnect callback is treated as an interruption rather than
confirmed device loss. TapQ keeps the current response window open for a grace
period, resumes on a corresponding reconnect, and announces disconnection only
when samples do not recover. When a new prompt opens without motion, the runtime
retries for a bounded period.

A device that was never connected is not a disconnection. The bounded retry still
runs at every window, but when it finds nothing the window continues voice-only and
says nothing: the disconnect announcement is reserved for a device that was present
when the window opened. TapQ speaks one notice at startup instead, and the motion
channels re-arm by themselves at the first window after AirPods connect. The
`motion.lost` diagnostic carries a `reason` field — `never_streamed`,
`lost_while_streaming`, or `silent_stream` — which is what the runtime branches on.

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
`PermissionRequest`. The broker accepts both v4 and v3 requests; v3 shims continue to
work and simply never see the `free_text` response field. Strict and shared messages can
temporarily use a discovered legacy wire protocol v2 runtime. Native permission requests
never downgrade to v2 and remain in Claude’s normal dialog when no compatible runtime is
available.

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
words; the backend chooses the voice that says them. On `--voice-backend openai-realtime`,
notification utterances are offered to the realtime voice and fall back to on-device
synthesis whenever the session cannot take them; approval and question prompts always use
on-device synthesis, because the realtime path renders text by generating a response from
it and may paraphrase. That routing is wired to the realtime backend's presence alone — it
is unaffected by `--speech-summarizer`, including `off`.

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

### Spoken recall and questions

TapQ remembers what each session asked and how it was answered, and will say it back. No
flag turns this on: it is part of the grammar, it works on both voice backends, and it
costs nothing when there is nothing to recall.

Two questions are understood inside any open prompt:

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

With `--voice-backend openai-realtime` **and** `--voice-freeform`, a question spoken into a
tool-approval window that matches no command is answered by the realtime voice. TapQ writes
the instruction that produces the answer: a short answering preamble, a context digest, and
the wearer's question. The digest carries only speech-safe material — the open request's
summary and detail, and up to five recent events from the same session, the same fields
recall speaks. Nothing else about the session is sent, and the model is told to answer only
from what it was given.

Limits, all deliberate:

- At most three answers per window; the fourth question is dropped
  (`qa.budget_exhausted`), and the window is still waiting for its answer.
- A grounded answer can never approve, deny, select, or defer. It is speech.
- A transcript is only treated as a question if it ends in `?` or opens with an
  interrogative word. A statement overheard mid-window is ignored, as before.
- On the Apple backend, or without `--voice-freeform`, no free-form transcript is ever
  produced, so the whole path is dead and the window behaves exactly as it did before.

Selection and multi-option stop questions keep their existing free-form read-back
behavior, unchanged: there a spoken sentence is an answer, not a question.

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
| `TAPQ_CONFIG_DIR` | Override calibration profile storage |
| `CODEX_HOME` | Select the Codex state directory whose `hooks.json` the integration command manages |
| `OPENCODE_CONFIG_DIR` | Select the OpenCode configuration directory whose plugin the integration command manages |
| `XDG_CONFIG_HOME` | Base for the default OpenCode configuration directory when `OPENCODE_CONFIG_DIR` is unset |
| `ANTHROPIC_API_KEY` | Authenticate classification requests selected with `--question-classifier anthropic`, and summarization requests selected with `--speech-summarizer anthropic` |
| `OPENAI_API_KEY` | Authenticate classification requests selected with `--question-classifier openai`, summarization requests selected with `--speech-summarizer openai`, and realtime voice sessions selected with `--voice-backend openai-realtime` |
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
