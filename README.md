<p align="center">
  <img src="assets/brand/tapq-mark.svg" alt="" width="96" height="96">
</p>

<h1 align="center">TapQ</h1>

<p align="center">
  <strong>Control your agents with gestures through AirPods</strong>
</p>

<p align="center">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-161617?logo=apple&logoColor=white">
  <img alt="Linux portable core" src="https://img.shields.io/badge/Linux-portable%20core-FCC624?logo=linux&logoColor=161617">
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache--2.0-C8F031?labelColor=161617"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick start</a> ·
  <a href="docs/CLI.md">CLI reference</a> ·
  <a href="#roadmap">Roadmap</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

TapQ turns natural head gestures, earbud taps, short voice commands, and compatible
AirPods stem swipes into approvals and selections and steerings for AI Agents while retaining the foundations of a Voice Agent. It runs as a
headless local broker with no application window or Dock icon. Claude Code is the first
supported agent with more agent adaptors coming soon.

> [!IMPORTANT]
> TapQ is an early open-source preview. The complete AirPods-backed runtime
> currently requires macOS 14 or newer. Its portable libraries, POSIX broker, Claude
> adapter, and management commands also build on Linux. Distribution is source-only for
> now: there is no published Homebrew formula, signed download, or stable release.

## What TapQ does

- **Hands-free approvals:** double-nod, double-tap, or speak a short response to approve
  or deny an agent request.
- **Question navigation:** move through a single-choice question with compatible AirPods
  stem swipes or voice, then confirm without returning to the keyboard.
- **Final-response routing:** optionally turn an explicit question in Claude Code’s final
  prose response into a short yes/no or option interaction.
- **Personal calibration:** save independent gesture and tap profiles without retaining
  raw calibration streams.
- **Voice Agent:** pure voice interaction is the foundation of TapQ and is available any time with better accuracy and lower latency thanks to TapQ's AirPods specific tuning.

### Controls

| Intent | Motion or hardware | Voice examples |
|---|---|---|
| Approve / yes | Double nod or double tap | `yes`, `approve`, `go ahead` |
| Deny / no | Shake | `no`, `deny`, `cancel` |
| Next option | Stem swipe down (volume down) | `next`, `move on` |
| Previous option | Stem swipe up (volume up) | `previous`, `go back` |
| Confirm option | Double nod or double tap | `select`, `this one`, `one`–`four` |
| Return to on-screen prompt | Shake | `skip`, `later`, `not sure` |

Stem navigation requires an AirPods model that exposes volume swipes. Voice recognition
currently uses an English (`en-US`) command grammar.

## Quick start

### Requirements

- Swift 6.0 or newer
- For the live hands-free runtime: macOS 14 or newer, Xcode 16 or a compatible Swift
  toolchain, and AirPods that expose headphone motion through CoreMotion
- For the bundled agent integration: Claude Code with hook support

Keep the AirPods connected, in-ear, and selected as the audio output. Quit any
other process using headphone motion before starting TapQ; competing CoreMotion clients
can attenuate or interrupt the stream.

### 1. Build and verify

From a source checkout:

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
stable identity. Gesture and tap profiles are saved independently. If only tap
calibration needs another attempt, run:

```bash
scripts/run-runtime-app.sh calibration run tap
```

### 3. Connect Claude Code

```bash
build/TapQRuntime.app/Contents/MacOS/tapq \
  integration claude install --permission-policy native
```

`native` is recommended for ordinary interactive use: TapQ handles supported permission
dialogs that Claude Code would otherwise show, while operations Claude Code recognizes as
read-only and existing allow rules continue normally. The CLI default is `strict`; pass
the desired policy explicitly during installation. See
[Claude Code permission policies](#claude-code-permission-policies).

### 4. Start TapQ

```bash
scripts/run-runtime-app.sh serve
```

Keep the foreground process running while using Claude Code. Set `TAPQ_DEBUG=1` for
detailed broker and input diagnostics, or pass `--no-voice` to use motion without
requesting microphone or Speech Recognition access.

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

If the checkout or app moves after the Claude hook is installed, run the integration
installer again so `~/.claude/settings.json` points to the new hook executable. Uninstall
the integration before deleting TapQ.

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
| `tapq integration claude` | Install, inspect, or remove Claude Code hooks | macOS, Linux |
| `tapq version` | Print the CLI and wire protocol version | macOS, Linux |

Examples:

```bash
tapq capture --duration 10 --format csv --output capture.csv
tapq calibration show --json
tapq integration claude status
tapq version --json
```

Capture output records timestamp, pitch, yaw, acceleration magnitude, and rotation
magnitude; it does not classify samples. See the [CLI reference](docs/CLI.md) for every
command, option, location, environment variable, and troubleshooting path.

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

## Questions in final responses

The Claude adapter examines a final assistant reply only when it contains `?`. It can
route explicit yes/no questions and questions with offered alternatives; open-ended,
rhetorical, and inconclusive questions remain on screen.

Without a cloud classifier, deterministic local heuristics handle structured
alternatives. When `ANTHROPIC_API_KEY` is present, TapQ sends up to the final 16,384
characters of the reply to Claude Haiku for classification and a shorter spoken
rendering. This optional service may incur API charges and can receive project or user
data contained in that reply. See [Privacy and security](#privacy-and-security).

## Platform support

| Capability | macOS 14+ | Linux |
|---|:---:|:---:|
| Detection, calibration, interaction, context, and wire libraries | ✓ | ✓ |
| Authenticated broker and Unix-socket bridge | ✓ | ✓ |
| Claude hook and integration management | ✓ | ✓ |
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
- [ ] **Cursor — next agent priority** — identify the most stable integration surface
  for permission requests, questions, and completion events, then connect it to the
  existing TapQ broker with native fail-through behavior.
- [ ] **Codex** — connect Codex lifecycle and approval hooks to the TapQ broker while
  preserving Codex’s native sandbox and approval policies.
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
- [ ] **Risk-aware confirmation** — require stronger or multi-step confirmation for
  destructive, external, or security-sensitive actions.
- [ ] **Personalization and accessibility** — configurable gesture mappings, per-device
  profiles, one-sided controls, and voice-only or haptic-only modes.
- [ ] **Local simulator and evaluation tools** — replay synthetic or user-authorized
  sensor streams to test adapters and recognition changes without requiring every
  supported device.
- [ ] **Pluggable local intelligence** — support interchangeable recognition and
  question-classification backends while preserving an offline, deterministic fallback.

Contributions and design discussion are welcome; see
[CONTRIBUTING.md](CONTRIBUTING.md).

## Privacy and security

- The broker is local-only and uses a user-private directory, socket, discovery record,
  and fresh bearer token. It is not a sandbox against untrusted processes running as the
  same operating-system user.
- Calibration saves tuned configuration and aggregate metrics, not raw motion samples.
  `tapq capture` writes raw motion only when the user explicitly chooses a destination.
- Voice input is active only during response windows. TapQ requests on-device English
  recognition when supported; otherwise Apple’s Speech framework may use Apple’s service.
- Anthropic classification is opt-in through `ANTHROPIC_API_KEY`. Motion and microphone
  audio are not sent to Anthropic, but the qualifying assistant reply is.
- Debug logs and Claude settings backups can contain sensitive operational data; review
  them before sharing.
- Broker, classifier, motion, and hook failures return control to the agent instead of
  fabricating an approval.

Read the complete [security policy](SECURITY.md). For common setup problems, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

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
