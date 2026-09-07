<p align="center">
  <img src="assets/brand/tapq-mark.svg" alt="" width="96" height="96">
</p>

<h1 align="center">TapQ</h1>

<p align="center">
  <strong>Computing is leaving the screen.</strong><br>
  TapQ puts your AI agents in your ear and takes your answer as a word or a nod,
  through the earbuds you already wear.
</p>

<p align="center">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-161617">
  <img alt="Linux portable core" src="https://img.shields.io/badge/Linux-portable%20core-FCC624">
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache--2.0-C8F031?labelColor=161617"></a>
</p>

<p align="center">
  <a href="https://tapq.ai">Website</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/CLI.md">CLI reference</a> ·
  <a href="#status">Status</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

AI scales. Your attention doesn't. Agents work in parallel, and keeping them moving
still pulls you back to a screen — to check, to answer, to approve.
**Checking fragments your focus:** which agent finished, which one is stuck.
**Every switch costs context:** open the tool, read the thread, find what needs you.
**Stepping away stops the work:** a question or an approval sits unanswered until you
return. You've delegated the work; staying in control still ties you to a screen.

TapQ is the other way round. Agents are the first software you don't operate but
supervise, and supervision doesn't need a screen — it needs a way to reach you. TapQ
speaks each prompt in your ear the moment an agent stops, and takes your answer as a
sentence, a word, or a nod. Works today with Claude Code, Codex, Cursor, and OpenCode,
on AirPods and macOS.

## What it does

1. **An agent stops to ask.** Claude Code pauses on a permission prompt before running
   the test suite.
2. **TapQ speaks it in your ear.** `Claude Code: Run swift test. Approve?` Spoken, not
   displayed. Between prompts it stays silent, listening on-device.
3. **You answer.** "Yes." Or a double nod. Or tilt and tap through the options.

A day with several agents sounds like this:

```
Claude Code: Run swift test. Approve?
  "yes"
Codex: Run python migrate.py. Approve?
  "no, tell Codex to keep the old table names"
  Queued for Codex.
  "who's waiting?"
  Nothing is waiting. Claude Code finished the migration.
  "when Claude Code finishes the changelog, rerun the tests"
  After Claude Code finishes: rerun the tests — noted.
```

What holds throughout:

- Answering a prompt needs no wake word, nothing to open, nothing to look at. TapQ is
  already listening when it asks.
- With always-on attention enabled, TapQ listens all day on-device and speaks only when
  an agent needs you or you speak to it.
- Anything TapQ cannot answer — a multi-select prompt, a missed gesture, a failed voice
  pipe — falls back to the agent's on-screen prompt exactly as if TapQ weren't
  installed. TapQ never adds a step to an agent's flow; it only removes them.

## How it works

### Presence

Agents need you on their schedule: when they finish, fork, or doubt. A screen only
lets you answer on yours — back at the desk, in that window, with that terminal
focused. Voice is the one channel that reaches someone whose eyes and hands are already
committed, in a meeting or a PR review or a kitchen, and lets them answer in a full
sentence: an instruction, not just an approval. Agents made the work asynchronous; TapQ
makes the human asynchronous too.

### Gesture, for when you can't speak

Double nod to approve, double shake to deny, tilt to move through options, tap the stem
to confirm. TapQ recognizes them on-device from the earbuds' motion stream, so a
one-bit decision costs one nod — silently, in a meeting, hands full. Gesture is the
silent mode of the same product, not a separate one; the full mapping is under
[Controls](#controls).

### One voice for every agent

Every prompt from every session funnels into one spoken queue, conducted by name.

- **Always on, locally.** Between prompts TapQ keeps listening on-device; the earbuds
  register your own speech, so no wake word is needed to answer. When nothing at all is
  running, "hey tapq" opens a window and a plain sentence starts a session.
- **Every agent, by name.** Claude Code, Codex, Cursor, and OpenCode at once. "Tell
  Claude Code to start on the changelog." — "Queued for Claude Code." "What did Codex
  run?" is answered in a sentence from its own transcript instead of a tab.
- **Remembers.** TapQ's conversation with you survives sessions and restarts, so "do
  the thing I asked you about earlier" still resolves. Stored locally; wiped with
  `tapq memory clear`.
- **Delegates under your policy.** Routine approvals can be answered silently under a
  policy you write, judged by an on-device risk reasoner that can always demand more
  confirmation — a tap — and never less. Approvals only; nothing auto-answers a question.
- **Carries goals and follow-ups.** "Run the tests and tell me if anything fails."
  "When Claude Code finishes, rerun the tests."

Everything TapQ does unprompted is spoken and attributed — and none of it can approve
anything.

## Trust model

Zero friction requires zero doubt: if an agent ran a command because a voice said yes,
whose voice was it?

1. **Gestures at the sensor.** Recognized on-device from the motion stream, never from
   a camera or a cloud.
2. **A voice provably yours.** The earbuds' motion sensors register the vibration of
   your own speech, so a colleague or a video cannot answer for you. You and the agent
   speak in turns, never over each other.
3. **Authority stays with you.** Nothing TapQ hears can approve an action except you
   answering that exact prompt. A missed gesture falls through to the on-screen prompt.
   A failed voice pipe says so out loud. Failures are announced, never silent.

## Current support

TapQ works today with Claude Code (hook support), a local Codex CLI
(`0.142.5` or newer), Cursor (agent hooks), and OpenCode (`1.18.15` or newer,
through a TapQ-managed plugin), on macOS 14+, with any AirPods that expose head
motion — AirPods Pro (all generations), AirPods 3 and later, and AirPods Max; stem
swipes need AirPods Pro 2 or later. Linux runs the portable core and management
CLI. Apple Watch is the next device; see [Status](#status).

## Controls

| Intent | Motion or hardware | Voice examples |
|---|---|---|
| Approve / yes | Double nod or double tap | `yes`, `approve`, `go ahead` |
| Deny / no | Double shake | `no`, `deny`, `cancel` |
| Next option | Stem swipe down (volume down) or double tilt right | `next`, `move on` |
| Previous option | Stem swipe up (volume up) or double tilt left | `previous`, `go back` |
| Confirm option | Double nod or double tap | `select`, `this one`, `one`–`four` |
| Return to on-screen prompt | Double shake | `skip`, `later`, `not sure` |

A tilt is a lateral ear-toward-shoulder lean; two quick tilts to the same side
navigate, so a single lean never moves the selection. With the realtime voice backend,
anything beyond these words — an instruction, a question, a goal — is understood as a
sentence; the on-device backend matches the English (`en-US`) grammar above.

TapQ handles one single-select question at a time. Anything it can't answer —
multi-select prompts, multiple questions, a missed gesture — stays in the agent's
normal on-screen flow.

## Quick start

TapQ is source-only for now — no Homebrew formula or signed download yet. You need
Swift 6, macOS 14 or newer with Xcode 16 (or a compatible toolchain), an AirPods
model with headphone motion (AirPods Pro, AirPods 3 or later, or AirPods Max —
tested on AirPods Pro), and Claude Code with hook support, a local Codex CLI
(`0.142.5` or newer), Cursor, or OpenCode (`1.18.15` or newer). Keep the AirPods
connected, in-ear, and selected as the audio output.

Without AirPods, `tapq serve` still runs. TapQ says so once and degrades to a plain
voice agent on whatever the system's default input and output are — prompts spoken on
the Mac's speaker, answered by voice — with gestures, taps, tilts, and volume swipes
inert. Connect AirPods mid-session and the next prompt has them back.

```bash
git clone https://github.com/spaceamoeba-t/tapq.git
cd tapq
swift build && swift test
```

**1. Calibrate** — builds and launches the locally signed headless app container so
macOS can grant Motion, Speech, and Microphone permissions to a stable identity:

```bash
scripts/run-runtime-app.sh calibration run
```

**2. Connect an agent:**

```bash
# Claude Code (native policy recommended for interactive use):
build/TapQRuntime.app/Contents/MacOS/tapq integration claude install --permission-policy native

# Codex — then open Codex, run /hooks, and trust the TapQ hooks:
build/TapQRuntime.app/Contents/MacOS/tapq integration codex install

# Cursor — restart Cursor if an already-open session does not pick the hooks up:
build/TapQRuntime.app/Contents/MacOS/tapq integration cursor install

# OpenCode — then restart OpenCode so it loads the TapQ plugin:
build/TapQRuntime.app/Contents/MacOS/tapq integration opencode install
```

**3. Start TapQ** and keep it running while you use the agent. The conversational
features — instructions, questions about the work, goals, follow-ups, the fleet — run
on the realtime voice backend and need `OPENAI_API_KEY` in the launcher's environment:

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime \
  --voice-instructions --voice-session --wearer-gate --attention wake
```

`--wearer-gate` is the attribution gate: an instruction is accepted only from a voice the
earbuds felt. `--voice-trust environment` replaces it when you trust the room, for
example on a Mac without AirPods.

`scripts/run-runtime-app.sh serve` with no flags runs the reactive loop alone — prompts
spoken, answered by gesture or a fixed vocabulary — with on-device speech and no API
key.

That's the whole loop: the next time the agent stops to ask, you'll hear it.

For permission-policy details, the exact Codex hook and OpenCode plugin contracts,
question classifiers, the risk reasoner, and packaging, see the
[integration guide](docs/INTEGRATIONS.md); for every command and flag, see the
[CLI reference](docs/CLI.md).

## Architecture

Agents connect through adapters to one local broker; devices connect the same way.
Every adapter translates its agent's native hook or plugin events into the same small
set of requests — an approval, a question, a notification, a finished run — and the
broker turns them into one spoken queue, attributes the answer, and returns it through
the same adapter. Adding an agent is an adapter, not a fork; Gemini CLI and Copilot CLI
are on the roadmap on that side. Adding a device is an adapter too: Apple Watch (wrist gestures,
Digital Crown, haptics) is next, with glasses and rings to follow as their APIs allow.

The portable core — gesture recognition, question classification, the interaction and
voice state machines — has no Apple dependency and is what runs and tests on Linux.
The existing adapters under `Sources/` are the reference for writing a new one; the
[integration guide](docs/INTEGRATIONS.md) documents the contracts they implement, and
the public adapter SDKs are on the [roadmap](docs/ROADMAP.md).

Coding agents are the starting point, not the boundary: they are where the most people
supervise agents today, already wearing earbuds, already in terminals.

## SDK

TapQ's gesture engine is being packaged as an embeddable SDK, so the same
recognition that drives agent approvals can drive your own app. It will let you
add calibrated AirPods gesture input — double-nod, shake, tilt, and tap events,
plus a raw motion tier for custom detection — to a Swift project with no agent
machinery attached, and build your own hands-free interactions or gesture-driven
agent frontends on top. It is in active development and will be available soon;
watch this repository for the first SDK release.

## Status

TapQ is pre-1.0 and source-only. Built is not shipped; this is what is where.

**On `main`, passing CI:**

- The reactive loop: prompts spoken in-ear, answered by gesture, tap, or voice, with
  fail-open to the on-screen prompt.
- Wearer-attributed voice: the earbuds' motion stream registers your own speech; you
  and the agent speak in turns.
- Always-on attention windows opened by your own speech (`--attention imu`) or by the
  wake word (`--attention wake`), which answer status questions and take instructions.
  Approvals are answered only when the prompt itself is being spoken.
- Name-addressed routing across live sessions, one spoken queue, spoken summaries and
  narration, questions answered from the agents' own transcripts.
- Conversation memory that survives restarts; goals (`start_task`); one-shot
  follow-ups (`set_followup`); policy-bound auto-answer of routine approvals.
- A wake word that starts a Claude Code or Codex session from nothing.

The last two milestones — follow-ups and the wake word — are tested in CI; their
hardware smoke checklists are still open.

**Not built:**

- One spoken goal spanning several agents as a single task ("have Codex review what
  Claude Code wrote").
- Standing rules for the deliberation loop beyond one-shot follow-ups.
- Apple Watch, non-Apple earbuds, glasses, rings; the public adapter SDKs.

**Costs to know about:** always-on attention keeps a sensor open between prompts and
costs AirPods battery today. The conversational features need OpenAI's realtime API;
the on-device path covers the reactive loop only.

The full roadmap — agent integrations, wearables, and interaction capabilities —
lives in [docs/ROADMAP.md](docs/ROADMAP.md).

## Privacy and data flow

- Gesture recognition, wearer attribution, and the wake-word recognizer run on-device.
  Nothing leaves the machine while TapQ is idle.
- With the realtime voice backend, audio leaves the machine only while a response
  window is open. The session receives your speech, the sentences TapQ speaks, and a
  short context: which agents are live, what is waiting, and a recent slice of your
  conversation with TapQ. The API key travels as a request header and is not logged.
- Conversation memory is a local file in the runtime directory, `0600`, rotated at 30
  days or a couple of megabytes, and cleared on demand with `tapq memory clear`. It
  records only what was spoken or heard; tool inputs, working directories, and
  permission modes are never spoken.
- The risk reasoner's decision log stays local and never leaves the machine.

Details, including what each optional cloud provider receives, are in the
[CLI reference](docs/CLI.md#environment-variables-and-local-data).

## Documentation

- [CLI reference](docs/CLI.md) — every command and flag, including `tapq capture`
  and `tapq replay` for recording motion and scoring gesture accuracy offline
- [Integration guide](docs/INTEGRATIONS.md) — permission policies, the Codex hook
  and OpenCode plugin contracts, question classifiers, the risk reasoner, and packaging
- [Roadmap](docs/ROADMAP.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Contributing](CONTRIBUTING.md) — includes the build/test/boundary checks to run
  before submitting a change
- [Release process](RELEASING.md) — signed source tags, qualification gates, and
  source-only GitHub publication
- [Changelog](CHANGELOG.md)

## License

TapQ source code and documentation are licensed under the
[Apache License 2.0](LICENSE); see [NOTICE](NOTICE) for attribution. The license does
not grant rights to the TapQ name or marks, and the artwork in `assets/brand/` is
separately reserved; see [TRADEMARKS.md](TRADEMARKS.md).

---

Terminal → Mouse → Touchscreen → TapQ. The screen was where computers made us come to
them. Agents don't need that. TapQ is how they come to you.
