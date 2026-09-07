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
  <a href="docs/ROADMAP.md">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

AI scales. Your attention doesn't. Agents work in parallel, and keeping them moving
still pulls you back to a screen — to check, to answer, to approve.
**Checking fragments your focus:** which agent finished, which one is stuck.
**Every switch costs context:** open the tool, read the thread, find what needs you.
**Stepping away stops the work:** a question or an approval sits unanswered until you
return. You've delegated the work; staying in control still ties you to a screen.

Agents are the first software you don't operate but supervise, and supervision doesn't
need a screen — it needs a way to reach you. TapQ is that way. Works today with Claude
Code, Codex, Cursor, and OpenCode, on AirPods and macOS.

## What it does

TapQ is a voice agent that runs in the background all day, connected to your coding
agents through their hooks. It listens on-device, speaks only when an agent needs you or
you speak to it, and hears your answer through the earbuds. Four things:

- **Speaks every prompt.** When Claude Code, Codex, Cursor, or OpenCode stops for an
  approval, a question, or a choice, TapQ says it in your ear: `Claude Code: Run swift
  test. Approve?` You answer "yes", double-nod, or tilt and tap through the options.
  Prompts from every open session arrive as one spoken queue.
- **Reports a finished run and takes the next instruction.** "Claude Code finished the
  migration." — "Tell it to rerun the tests." — "Queued for Claude Code." An agent's
  turn ends in your ear, and the next one starts there.
- **Answers questions about the work.** "Who's waiting?" "What did Codex change?" TapQ
  reads the agents' own transcripts and answers in a sentence instead of a tab.
- **Takes goals and follow-ups.** "Run the tests and tell me if anything fails." "When
  Claude Code finishes, rerun the tests." With nothing running at all, "Hey TapQ, set up
  a Swift package for the parser" starts a session.

An afternoon with two agents:

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

Answering needs no wake word, nothing to open, nothing to look at. Anything TapQ cannot
answer — a multi-select prompt, a missed gesture, a failed voice pipe — falls back to
the agent's on-screen prompt exactly as if TapQ weren't installed. Everything TapQ does
unprompted is spoken and attributed, and none of it can approve anything.

## How it works

**Voice, because agents need you on their schedule.** They finish, fork, or doubt while
your eyes and hands are committed elsewhere — a meeting, a PR review, a kitchen. Voice
is the one channel that reaches you there and lets you answer in a full sentence, an
instruction rather than only an approval. Agents made the work asynchronous; TapQ makes
the human asynchronous.

**Gesture, for when you can't speak.** Double nod to approve, double shake to deny, tilt
to move through options, tap the stem to confirm — recognized on-device from the
earbuds' motion stream. Most agent decisions are one bit; a nod costs one, silently.

**A voice provably yours.** The same motion sensors register the vibration of your own
speech, so a colleague or a video cannot answer for you, and you and the agent speak in
turns. Nothing TapQ hears can approve an action except you answering that exact prompt.
A missed gesture falls through to the screen; a failed voice pipe says so out loud.

**One local broker, adapters on both sides.** Agents connect through adapters to one
broker on your Mac; devices connect the same way. New agents and devices are adapters,
not forks — Gemini CLI, Copilot CLI, and Apple Watch are on the
[roadmap](docs/ROADMAP.md). Gesture recognition and wearer attribution run on-device;
the conversational features use OpenAI's realtime API, and audio leaves the machine
only while a response window is open.

## Current support

TapQ works today with Claude Code (hook support), a local Codex CLI
(`0.142.5` or newer), Cursor (agent hooks), and OpenCode (`1.18.15` or newer,
through a TapQ-managed plugin), on macOS 14+, with any AirPods that expose head
motion — AirPods Pro (all generations), AirPods 3 and later, and AirPods Max; stem
swipes need AirPods Pro 2 or later. Linux runs the portable core and management
CLI. TapQ is pre-1.0 and source-only; Apple Watch is the next device on the
[roadmap](docs/ROADMAP.md).

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
features — instructions, questions about the work, goals, follow-ups — run on the
realtime voice backend and need `OPENAI_API_KEY` in the launcher's environment:

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime \
  --voice-instructions --voice-session --wearer-gate --attention wake
```

`--wearer-gate` is the attribution gate: an instruction is accepted only from a voice the
earbuds felt. `--voice-trust environment` replaces it when you trust the room, for
example on a Mac without AirPods. `scripts/run-runtime-app.sh serve` with no flags runs
the reactive loop alone — prompts spoken, answered by gesture or a fixed vocabulary —
with on-device speech and no API key.

That's the whole loop: the next time the agent stops to ask, you'll hear it.

For permission-policy details, the exact Codex hook and OpenCode plugin contracts,
question classifiers, the risk reasoner, and packaging, see the
[integration guide](docs/INTEGRATIONS.md); for every command and flag, see the
[CLI reference](docs/CLI.md).

## SDK

TapQ's gesture engine is being packaged as an embeddable SDK, so the same
recognition that drives agent approvals can drive your own app. It will let you
add calibrated AirPods gesture input — double-nod, shake, tilt, and tap events,
plus a raw motion tier for custom detection — to a Swift project with no agent
machinery attached, and build your own hands-free interactions or gesture-driven
agent frontends on top. It is in active development and will be available soon;
watch this repository for the first SDK release.

## Documentation

- [CLI reference](docs/CLI.md) — every command and flag, including `tapq capture`
  and `tapq replay` for recording motion and scoring gesture accuracy offline
- [Integration guide](docs/INTEGRATIONS.md) — permission policies, the Codex hook
  and OpenCode plugin contracts, question classifiers, the risk reasoner, and packaging
- [Roadmap](docs/ROADMAP.md) — agent integrations, wearables, and interaction
  capabilities, with what is built and what is next
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
