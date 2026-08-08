<p align="center">
  <img src="assets/brand/tapq-mark.svg" alt="" width="96" height="96">
</p>

<h1 align="center">TapQ</h1>

<p align="center">
  <strong>Control AI agents with gestures.</strong>
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
  <a href="#roadmap">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

AI agents need to interact with you for the best outcome. TapQ turns those
interactions into speech in your ear and your response into a gesture: nod to
approve, shake to deny, tilt and tap to choose an option — or say a word when
that's easier. It runs quietly in the background and works hands-free through
devices you already wear — AirPods today, with Claude Code, Codex, and OpenCode as
the first supported agents — so you never touch a keyboard or look at a screen to keep an
agent moving. You can also build your own gesture agent with [TapQ's SDK](#sdk).

## What it does

- **Stay in flow.** You're deep in a PR review while Claude Code refactors in another
  window. "Claude wants to run the test suite" arrives in your ears; you double-nod
  and never leave what you're reading.
- **In a meeting.** On a call, voice is off the table and reaching for the screen looks
  rude. The whole interaction works silently: nod to approve, shake to deny, swipe
  through options, tap to select.
- **Away from your desk.** You kick off a long migration and go make lunch. The prompt
  reaches you anywhere Bluetooth reaches; you answer by nod or voice, hands full.
- **Running agents in parallel.** Prompts from concurrent sessions funnel through one
  broker and arrive as a single spoken queue, so you clear a backlog with a few nods
  instead of polling terminals.

## Design principles

- **Gesture recognition at the sensor level.** TapQ reads the earbuds' motion
  stream directly and recognizes nod, shake, tilt, and tap on-device, so
  responding to an agent needs no screen, keyboard, or wake word.
- **IMU-augmented, wearer-attributed voice.** The earbuds' motion sensors
  register the vibration of the wearer's own speech, so TapQ knows the voice it
  hears is yours — not a colleague's or a video's — and runs the conversation
  half-duplex: you and the agent speak in turns, never over each other.
- **Fail-open.** Anything TapQ cannot answer stays in the agent's normal
  on-screen flow, exactly as if TapQ weren't installed. A missed gesture never
  blocks an agent or answers for you.
- **Agent-neutral, device-neutral.** Agents connect through adapters to one
  local broker, and prompts from parallel sessions arrive as a single spoken
  queue. New agents and devices are adapters, not forks.
- **Local by default.** Gesture detection runs on-device; question
  classification and risk assessment stay on-device unless a cloud provider is
  explicitly enabled.

## Current support

TapQ works today with Claude Code (hook support), a local Codex CLI
(`0.142.5` or newer), and OpenCode (`1.18.15` or newer, through a TapQ-managed
plugin), on macOS 14+, with any AirPods that expose head motion —
AirPods Pro (all generations), AirPods 3 and later, and AirPods Max; stem
swipes need AirPods Pro 2 or later. Linux runs the portable core and management
CLI. Cursor and Apple Watch are next on the [roadmap](#roadmap).

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
navigate, so a single lean never moves the selection. Voice commands currently use
an English (`en-US`) grammar.

TapQ handles one single-select question at a time. Anything it can't answer —
multi-select prompts, multiple questions, a missed gesture — stays in the agent's
normal on-screen flow.

## Quick start

TapQ is source-only for now — no Homebrew formula or signed download yet. You need
Swift 6, macOS 14 or newer with Xcode 16 (or a compatible toolchain), an AirPods
model with headphone motion (AirPods Pro, AirPods 3 or later, or AirPods Max —
tested on AirPods Pro), and Claude Code with hook support, a local Codex CLI
(`0.142.5` or newer), or OpenCode (`1.18.15` or newer). Keep the AirPods connected,
in-ear, and selected as the audio output.

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

# OpenCode — then restart OpenCode so it loads the TapQ plugin:
build/TapQRuntime.app/Contents/MacOS/tapq integration opencode install
```

**3. Start TapQ** and keep it running while you use the agent:

```bash
scripts/run-runtime-app.sh serve
```

That's the whole loop: the next time the agent stops to ask, you'll hear it.

For permission-policy details, the exact Codex hook and OpenCode plugin contracts,
question classifiers,
the risk reasoner, and packaging, see the
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

## Roadmap

TapQ aims to be an agent-neutral, device-neutral interaction layer for hands-free
computing. Next up, in priority order: a **Cursor** adapter, **Apple Watch** support
(wrist gestures, Digital Crown, haptics), a **quiet output mode** for meetings, and
**prompt filtering** so routine approvals are auto-answered under your policy and
only the prompts that deserve you reach you.

Device support depends on the APIs each platform and manufacturer exposes; the
items above describe product direction rather than committed dates. The full
roadmap — agent integrations, wearables, and interaction capabilities — lives in
[docs/ROADMAP.md](docs/ROADMAP.md).

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
