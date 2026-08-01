<p align="center">
  <img src="assets/brand/tapq-mark.svg" alt="" width="96" height="96">
</p>

<h1 align="center">TapQ</h1>

<p align="center">
  <strong>Control your agents with gestures through AirPods</strong>
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

TapQ turns natural head gestures, earbud taps, short voice commands, and compatible
AirPods stem swipes into approvals, option selections, and steering inputs for AI agents.
It runs as a headless local broker with no application window or Dock icon. Bundled
adapters currently support Claude Code and a stable native-hook slice for Codex, with
more agent adapters planned.

> [!IMPORTANT]
> TapQ is an early open-source preview. The complete AirPods-backed runtime
> currently requires macOS 14 or newer. Its portable libraries, POSIX broker, Claude
> Code and Codex adapters, and management commands also build on Linux. Distribution is
> source-only for now: there is no published Homebrew formula, signed download, or stable
> release.

## What TapQ does

- **Hands-free approvals:** double-nod, double-tap, or speak a short response to approve
  or deny an agent request.
- **Question navigation:** move through a single-choice question with compatible AirPods
  stem swipes or voice, then confirm without returning to the keyboard.
- **Final-response routing:** optionally turn an explicit question in a supported agent’s
  final prose response into a short yes/no or option interaction.
- **Personal calibration:** save independent gesture and tap profiles without retaining
  raw calibration streams.
- **Voice fallback:** during an active request, use a short spoken command whenever a
  gesture or hardware control is inconvenient.

### Controls

| Intent | Motion or hardware | Voice examples |
|---|---|---|
| Approve / yes | Double nod or double tap | `yes`, `approve`, `go ahead` |
| Deny / no | Double shake | `no`, `deny`, `cancel` |
| Next option | Stem swipe down (volume down) or double tilt right | `next`, `move on` |
| Previous option | Stem swipe up (volume up) or double tilt left | `previous`, `go back` |
| Confirm option | Double nod or double tap | `select`, `this one`, `one`–`four` |
| Return to on-screen prompt | Double shake | `skip`, `later`, `not sure` |

A tilt is a lateral ear-toward-shoulder lean; two quick tilts to the same side
navigate, so a single lean never moves the selection. Tilt navigation works on
every AirPods model that exposes headphone motion, including models without
stem volume swipes.

Stem navigation requires an AirPods model that exposes volume swipes. Voice recognition
currently uses an English (`en-US`) command grammar.

Development testing currently covers the maintainer's AirPods Pro setup. Other AirPods
models that expose headphone motion may work, but are not yet part of TapQ's tested
compatibility set.

## Quick start

### Requirements

- Swift 6.0 or newer
- `ripgrep` (`rg`) for the public-boundary check
- For the live hands-free runtime: macOS 14 or newer, Xcode 16 or a compatible Swift
  toolchain, and AirPods that expose headphone motion through CoreMotion
- For an agent integration: Claude Code with hook support, or a local Codex client with
  stable lifecycle hooks. The lifecycle floor is tested against Codex CLI `0.142.5`;
  structured `request_user_input` interception is tested against `0.146.0`

Keep the AirPods connected, in-ear, and selected as the audio output. Quit any
other process using headphone motion before starting TapQ; competing CoreMotion clients
can attenuate or interrupt the stream.

### 1. Build and verify

Clone the source and enter the checkout:

```bash
git clone https://github.com/spaceamoeba-t/tapq.git
cd tapq
```

Then build and run the automated checks:

```bash
swift build
swift test
scripts/check-public-boundary.sh
```

### 2. Calibrate on macOS

```bash
scripts/run-runtime-app.sh calibration run
```

The script builds and launches TapQ’s locally signed, headless development app container
so macOS can associate Motion, Speech Recognition, and Microphone permissions with a
stable bundle identity and path. Development rebuilds can still cause macOS to request
authorization again. Gesture and tap profiles are saved independently. If only tap
calibration needs another attempt, run:

```bash
scripts/run-runtime-app.sh calibration run tap
```

### 3. Connect an agent

For Claude Code:

```bash
build/TapQRuntime.app/Contents/MacOS/tapq \
  integration claude install --permission-policy native
```

`native` is recommended for ordinary interactive use: TapQ handles supported permission
dialogs that Claude Code would otherwise show, while operations Claude Code recognizes as
read-only and existing allow rules continue normally. The CLI default is `strict`; pass
the desired policy explicitly during installation. See
[Claude Code permission policies](#claude-code-permission-policies).

For Codex:

```bash
build/TapQRuntime.app/Contents/MacOS/tapq integration codex install
```

Then open Codex, run `/hooks`, review the TapQ command hooks, and trust their exact
current definitions. Codex skips new or changed non-managed hooks until this explicit
trust step is complete. See [Codex stable hook integration](#codex-stable-hook-integration).

### 4. Start TapQ

```bash
scripts/run-runtime-app.sh serve
```

Keep the foreground process running while using the connected agent. Set `TAPQ_DEBUG=1`
for detailed broker and input diagnostics, or pass `--no-voice` to use motion without
requesting microphone or Speech Recognition access.

To use Anthropic instead of the on-device question classifier, provide the API key only
to the TapQ process and select the provider explicitly:

```bash
# ANTHROPIC_API_KEY must already be present in the launcher environment.
scripts/run-runtime-app.sh serve --question-classifier anthropic
```

For Codex final-response classification with GPT-5.6 Luna:

```bash
# OPENAI_API_KEY must already be present in the launcher environment.
scripts/run-runtime-app.sh serve --question-classifier openai
```

## Installation

TapQ is currently distributed from source. Build optimized command-line binaries with:

```bash
swift build -c release
.build/release/tapq version
```

On macOS, package the supported live host with:

```bash
scripts/package-runtime-app.sh release
```

The result is `build/TapQRuntime.app`. It is ad-hoc signed for local development by
default; it is not notarized or prepared for redistribution. Set `TAPQ_SIGN_IDENTITY` to
use another local signing identity.

If the checkout or app moves after an agent hook is installed, run that integration’s
installer again so `~/.claude/settings.json` or the active Codex `hooks.json` points to
the new hook executable. Uninstall integrations before deleting TapQ.

## CLI

Commands below use `tapq` as shorthand. From a source checkout, use
`swift run tapq` for management commands and `scripts/run-runtime-app.sh` for
live commands that need macOS privacy permissions.

| Command | Purpose | Platforms |
|---|---|---|
| `tapq serve` | Run the local broker and hands-free interaction host | macOS |
| `tapq calibration run` | Calibrate gesture and tap profiles together or separately | macOS |
| `tapq calibration show/reset` | Inspect or remove saved profiles | macOS, Linux |
| `tapq capture` | Stream raw headphone motion as JSONL or CSV | macOS |
| `tapq replay` | Replay a capture through detection backends offline, with accuracy reporting against labels | macOS, Linux |
| `tapq bench reasoner` | Score a stage-2 risk reasoner against a labeled scenario corpus | macOS |
| `tapq integration claude` | Install, inspect, or remove Claude Code hooks | macOS, Linux |
| `tapq integration codex` | Install, inspect, or remove stable Codex hooks | macOS, Linux |
| `tapq version` | Print the CLI and wire protocol version | macOS, Linux |

Examples:

```bash
tapq capture --duration 10 --format csv --output capture.csv
tapq replay --input capture.jsonl --labels capture.labels.jsonl
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson
tapq calibration show --json
tapq integration claude status
tapq integration codex status
tapq version --json
```

Capture output records timestamp, full attitude (pitch, yaw, roll), acceleration and
rotation magnitudes, and signed per-axis user acceleration, rotation rate, and gravity;
it does not classify samples. Replay streams a recorded capture back through the
detection pipelines offline — with a label file it reports per-gesture precision,
recall, and false positives per minute, and `--encoder-model` compares a trained
TapQ-1 encoder (see [ml/README.md](ml/README.md)) against the deterministic baseline
on the same data. See the [CLI reference](docs/CLI.md) for every command, option,
location, environment variable, and troubleshooting path.

## Claude Code permission policies

TapQ installs one of two mutually exclusive approval paths and does not alter Claude
Code’s own permission rules.

| Policy | Hook behavior | Best fit |
|---|---|---|
| `native` | `PermissionRequest` for `Bash`, `Write`, `Edit`, `MultiEdit`, and `NotebookEdit`; `AskUserQuestion` remains `PreToolUse` | Normal interactive sessions with fewer interruptions |
| `strict` | `PreToolUse` for those tools plus `AskUserQuestion`, before Claude’s permission engine | Workflows where every matched operation should reach TapQ |

Both policies also install `Notification`, `Stop`, and opt-in `UserPromptSubmit`
handling. Only one ordinary approval path is installed at a time.

```bash
tapq integration claude install --permission-policy native
tapq integration claude install --permission-policy strict
```

Important behavior:

- Native mode sees only permission dialogs Claude Code chooses to emit. Existing allow
  rules and `bypassPermissions` can therefore proceed without a TapQ interaction.
- Strict mode receives every matched event. For compatibility with the original runtime,
  TapQ returns allow without waiting for a gesture when Claude reports an auto permission
  mode; Claude Code’s own deny and ask rules still apply.
- TapQ handles one single-select `AskUserQuestion` at a time. Multi-select and
  multiple-question calls remain in Claude Code’s on-screen interface.
- If the hook cannot obtain a valid answer, Claude Code retains control of the normal
  on-screen flow.

## Codex stable hook integration

```bash
tapq integration codex install
tapq integration codex status
tapq integration codex uninstall
```

The installer writes only TapQ-managed groups in `~/.codex/hooks.json`, or in
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set. It points to the
`tapq-codex-hook` executable installed beside `tapq`, preserves unrelated hook data, and
creates a restrictive backup before changing an existing file. Custom installations can
pass `--hooks PATH` and `--hook PATH`. Rerun `install` directly to repair missing or stale
registrations whose command is the current hook, the bare `tapq-codex-hook` command, or a
recognized TapQ app/build path. Unfamiliar custom executable paths are preserved as
unrelated hooks. Users upgrading from the earlier three-hook layout must rerun `install`
to add `UserPromptSubmit`, then review the changed definitions in `/hooks`.

Installation does not grant hook trust. After every new or changed definition, open
Codex and use `/hooks` to review and trust the four current TapQ registrations at the
selected hook path. Unrecognized custom-path hooks may also remain as unrelated data.
`status` verifies the recognized layout and reports best-effort local Codex compatibility
diagnostics, but Codex remains the authority for trust state; that state is not inspectable
by TapQ.

The current supported slice is deliberately narrow:

- `PreToolUse` handles root-agent `request_user_input` calls containing one
  single-select question with two or three listed options. A TapQ selection is returned
  to the model without opening Codex’s selector.
- `PermissionRequest` handles native approval prompts for `Bash`, `apply_patch`, and
  canonical `mcp__<server>__<tool>` connector calls. Operations that Codex does not
  prompt for never reach TapQ. MCP speech identifies the server and operation without
  reading argument values; the original arguments remain in the local broker request
  context and are not spoken. When the on-device stage-2 reasoner is enabled, it sees
  complete sorted JSON when the argument object fits. Oversized objects become
  key-balanced excerpts across early and late top-level keys, with the start and end of
  each selected value retained. Non-ASCII text, including Unicode line separators, is
  escaped before budgeting, and the complete rendered input including truncation markers
  stays within 4,000 characters. MCP values are not spoken, diagnosed, or cloud-sent.
  MCP review rows omit the arguments, model note, and confidence while retaining the
  interaction outcome and, for a decided row, the closed tier/code.
- `Stop` reports completion and can route an explicit final-response question using
  Codex’s stable `last_assistant_message` field. It does not parse Codex transcripts.
- Matcherless `UserPromptSubmit` provides one fixed root-turn steering hint when a live,
  wire-compatible TapQ runtime advertises `--steering`: use `request_user_input` “when
  available” for choices or confirmation. It reads discovery and opens a bounded,
  EOF-only Unix-socket connection to verify broker liveness, but sends no broker request
  or application data and performs no request/response round-trip. Otherwise it emits
  nothing so Codex keeps its native behavior.
- Broker absence, timeout, an incompatible wire version, invalid data, or no hands-free
  answer emits no hook decision, leaving Codex’s normal selector, approval, or turn flow
  in control. Multiple questions, auto-resolving questions, unsupported option shapes,
  secret questions, and subagent calls also stay native.
- There is no broad Codex strict `PreToolUse` policy or generic notification-hook parity.

In Codex CLI `0.146.0`, Plan mode is the reliable surface for
`request_user_input`. Availability in default mode depends on Codex's
`default_mode_request_user_input` feature. `tapq integration codex status` resolves
`codex` from the caller's `PATH`, reports that executable, and runs only `--version` and
`features list` under a minimal allowlisted environment. A missing executable is distinct
from a resolved executable whose probe fails or times out; neither changes file-status
exit semantics. Because status executes the resolved path, use a trusted `PATH`. Use Codex's
`/hooks` view for the authoritative activation and trust result. A parsed version below
`0.142.5` produces a compatibility warning without changing status exit semantics.

TapQ’s lifecycle-hook contract floor is Codex CLI `0.142.5`. Versioned
`PermissionRequest` and `Stop` fixtures cover that floor; versioned
`request_user_input`, MCP `PermissionRequest`, and `UserPromptSubmit` fixtures target
Codex CLI `0.146.0`. Real hook-process-to-broker contracts cover supported decisions and
native fail-through,
but are not an authenticated model-level Codex end-to-end test. The adapter targets local
Codex clients that load user lifecycle hooks; hosted Codex Cloud tasks are outside this
integration surface.

## Questions in final responses

The Claude Code and Codex adapters examine a final assistant reply only when it contains
`?`. Claude Code obtains that text from its transcript; Codex supplies it directly as
`last_assistant_message`. TapQ can route explicit yes/no questions and questions with
offered alternatives; open-ended, rhetorical, and inconclusive questions remain on
screen.

On macOS 26 or later, TapQ uses Apple's on-device Foundation Model when Apple
Intelligence reports it available. It classifies supported prose questions and produces
a shorter spoken rendering without sending the reply over the network. A deterministic
local heuristic handles structured alternatives when the model is unavailable.

The `--question-classifier` runtime option selects `auto`, `apple`, `anthropic`,
`openai`, or `local`. `auto` is the default and never enables a cloud provider: it uses
Apple's model when available and otherwise uses the local heuristic. Selecting
`anthropic` requires `ANTHROPIC_API_KEY` and uses Claude Haiku. Selecting `openai`
requires `OPENAI_API_KEY` and uses `gpt-5.6-luna` through OpenAI's Responses API. Either
cloud provider may receive up to the final 16,384 characters of the assistant reply for
classification and shortening, which may incur API charges and expose project or user
data contained in that reply. The selection applies to every agent adapter connected to
that runtime instance. See the [security policy](SECURITY.md).

## Risk-aware confirmation

TapQ can ask a stage-2 risk reasoner how consequential a pending action is and require
more confirmation when it looks destructive. The `--reasoner` runtime option selects `off`
(the default) or `apple`, Apple's on-device Foundation Model, and `--reasoner-mode` selects
`shadow` or `primary`.

```bash
scripts/run-runtime-app.sh serve --reasoner apple
scripts/run-runtime-app.sh serve --reasoner apple --reasoner-mode primary
```

`shadow` is the default: decisions are recorded as diagnostics while the confirmation
actually demanded stays exactly what deterministic policy set. `primary` lets a decision
strengthen the requirement for that request. A reasoner can only ask for *more*
confirmation — it can never approve, deny, or resolve a request — so an abstention, a
timeout, a backend error, or an absent model leaves behavior exactly as it is without one.
A device where the model is unavailable keeps serving without risk escalation and reports
it. Strict-policy requests that Claude reports in an auto permission mode are allowed
before an approval is built, so they are never assessed.

Assessment is on-device only. For canonical Codex MCP calls, the reasoner receives
complete sorted JSON when it fits. Oversized objects are represented by key-balanced
top-level excerpts; all rendered input, including truncation markers, is capped at 4,000
characters after non-ASCII and line-separator escaping. Other supported tools keep their
established command/path context. MCP argument values are never spoken, diagnosed, or
cloud-sent. Their review rows also omit the model's free-text note and confidence,
retaining the interaction outcome and, for a decided row, constrained tier/code metadata. Selecting a
reasoner starts a local shadow-review log at `<broker-dir>/reasoner-log.jsonl`, which
records what each decision asked for against what the user then did; see the
[security policy](SECURITY.md) for what a line can contain, and the
[CLI reference](docs/CLI.md) for the full option list.
`tapq bench reasoner` scores a reasoner against the labeled corpus in
[bench/](bench/README.md), and [docs/TAPQ1_STAGE2.md](docs/TAPQ1_STAGE2.md) documents the
design.

## Platform support

| Capability | macOS 14+ | Linux |
|---|:---:|:---:|
| Detection, calibration, interaction, context, and wire libraries | ✓ | ✓ |
| Authenticated broker and Unix-socket bridge | ✓ | ✓ |
| Claude Code and Codex hook integration management | ✓ | ✓ |
| Profile inspection and reset | ✓ | ✓ |
| Full motion, voice, volume, and speech runtime | ✓ | — |
| AirPods capture and live calibration | ✓ | — |
| CoreMotion, Speech, AVFoundation, and CoreAudio adapters | ✓ | — |

Linux CI is configured for Swift 6 on Ubuntu. Linux does not yet include microphone,
speech, volume, or headphone-motion adapters, so the bundled `serve`, `capture`, and live
`calibration run` commands return an explicit unavailable error. Windows, iOS, and other
Apple platforms are not currently supported.

## Roadmap

TapQ’s goal is to become an agent-neutral, device-neutral interaction layer for
hands-free computing. Items within each track are ordered by priority. They describe
product direction rather than committed dates; device support depends on the APIs
exposed by each platform and manufacturer.

### Agent integrations

- [x] **Claude Code** — approvals, denials, option selection, notifications, and
  questions in final responses.
- [x] **Codex supported slice** — structured single-choice `request_user_input`,
  native `PermissionRequest` approvals for `Bash`, `apply_patch`, and MCP connector
  tools, opt-in root-turn prompt steering, plus `Stop` completion and final-response
  questions with fail-through.
- [ ] **Cursor — next agent priority** — identify the most stable integration surface
  for permission requests, questions, and completion events, then connect it to the
  existing TapQ broker with native fail-through behavior.
- [ ] **Codex expanded parity** — add a generic notification equivalent when its
  contract is stable enough to preserve native fallback behavior.
- [ ] **Gemini CLI and GitHub Copilot CLI** — build adapters around their native hook
  systems and reuse the agent-neutral TapQ wire protocol.
- [ ] **OpenCode and additional agents** — extend support to OpenCode, Windsurf,
  Cline/Roo Code, Aider, and other popular coding agents according to user demand and
  the stability of their extension or approval interfaces.
- [ ] **Public agent-adapter SDK** — provide templates, capability negotiation,
  conformance tests, and documentation so the community can add agents without
  modifying the TapQ runtime.

### Wearables and input devices

- [x] **AirPods on macOS** — head motion, earbud taps, compatible stem swipes, voice
  commands, and spoken feedback.
- [ ] **Apple Watch — next device priority** — add wrist-motion gestures, touch and
  Digital Crown navigation, haptic feedback, and a secure local companion transport to
  the Mac runtime.
- [ ] **Non-Apple earbuds and watches** — begin with standard Bluetooth media and
  control events, then add richer motion, touch, voice, and haptic support through
  platform and manufacturer SDKs.
- [ ] **Smart glasses** — support head gestures, temple controls, microphones, speakers,
  and visual or audio feedback where manufacturer APIs permit.
- [ ] **Smart rings** — support discreet taps, swipes, motion gestures, and haptic
  confirmation where real-time device APIs are available.
- [ ] **Public device-adapter SDK** — define common capabilities for motion, discrete
  controls, voice, connection health, and haptic, audio, or visual feedback after the
  first several device integrations have validated the abstraction.

### Interaction capabilities

- [ ] **Cross-device sensor fusion** — combine signals from earbuds, watches, rings, and
  glasses to reduce false positives and improve gesture confidence.
- [ ] **Automatic device handoff** — continue an interaction on the best available
  device when another device disconnects or becomes unavailable.
- [ ] **Multi-agent request inbox** — identify the requesting agent and session, queue
  simultaneous requests, and route each response to the correct agent.
- [ ] **Richer hands-free controls** — pause or interrupt an agent, repeat or expand a
  summary, request details, retry an action, and switch between pending requests.
- [ ] **Free-form voice responses** — dictate answers to open-ended questions, hear a
  concise readback, and confirm before sending.
- [x] **Risk-aware confirmation** — the TapQ-1 stage-2 risk reasoner: a versioned decision
  contract (`tapq1-decision-v1`), a backend protocol with an Apple Foundation Models
  adapter, shadow/primary serve modes, `tapq bench reasoner` against a labeled scenario
  corpus, and an escalation-only contract under which a decision can raise the confirmation
  bar and can do nothing else. Promotion out of shadow awaits field data.
- [ ] **Local open-weights reasoner backend** — `--reasoner local`: run a user-supplied
  sub-4B instruct model through MLX Swift with generation constrained to the same decision
  contract, so stage-2 quality can be measured on hardware Apple Intelligence declines to
  run on. See [docs/TAPQ1_STAGE2.md](docs/TAPQ1_STAGE2.md).
- [ ] **Personalization and accessibility** — configurable gesture mappings, per-device
  profiles, one-sided controls, and voice-only or haptic-only modes.
- [x] **Local replay and evaluation tools** — `tapq replay` streams user-authorized
  motion captures through the detection backends offline with per-gesture accuracy
  reporting; broader adapter simulation remains open under the device-adapter SDK.
- [x] **Pluggable local intelligence** — the TapQ-1 encoder backend: a window-scorer
  protocol with a Core ML adapter, shadow/primary serve modes, a training pipeline in
  `ml/`, and the deterministic heuristics preserved as the always-available offline
  fallback. Training a production model awaits the capture study.

Contributions and design discussion are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Development

Before submitting a change, run:

```bash
swift build
swift test
scripts/check-public-boundary.sh
```

Keep changes in the smallest owning target, preserve the portable-to-platform dependency
direction, and test behavior through hardware-independent seams. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Documentation

- [CLI reference](docs/CLI.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Security policy](SECURITY.md)
- [Contributing](CONTRIBUTING.md)
- [Changelog](CHANGELOG.md)

## License

TapQ source code and documentation are licensed under the
[Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution. That license
does not grant rights to use the TapQ name or marks. The logo, icon, and other
artwork in `assets/brand/` are separately copyright-reserved; see
[TRADEMARKS.md](TRADEMARKS.md) and the
[brand asset notice](assets/brand/LICENSE).
