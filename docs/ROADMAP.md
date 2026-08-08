# TapQ roadmap

TapQ’s goal is to become an agent-neutral, device-neutral interaction layer for
hands-free computing. Items within each track are ordered by priority. They describe
product direction rather than committed dates; device support depends on the APIs
exposed by each platform and manufacturer.

## Agent integrations

- [x] **Claude Code** — approvals, denials, option selection, notifications, and
  questions in final responses.
- [x] **Codex supported slice** — structured single-choice `request_user_input`,
  native `PermissionRequest` approvals for `Bash`, `apply_patch`, and MCP connector
  tools, opt-in root-turn prompt steering, plus `Stop` completion and final-response
  questions with fail-through.
- [x] **OpenCode supported slice** — a TapQ-owned OpenCode plugin that relays native
  `permission.asked` prompts and the session-idle completion event to the broker and
  applies the hands-free answer through OpenCode's permission API, with fail-through to
  OpenCode's own on-screen prompt. Structured questions and final-response continuation
  stay unsupported until OpenCode exposes an equivalent surface.
- [ ] **Cursor — next agent priority** — identify the most stable integration surface
  for permission requests, questions, and completion events, then connect it to the
  existing TapQ broker with native fail-through behavior.
- [ ] **Codex expanded parity** — add a generic notification equivalent when its
  contract is stable enough to preserve native fallback behavior.
- [ ] **Gemini CLI and GitHub Copilot CLI** — build adapters around their native hook
  systems and reuse the agent-neutral TapQ wire protocol.
- [ ] **Additional agents** — extend support to Windsurf, Cline/Roo Code, Aider, and
  other popular coding agents according to user demand and the stability of their
  extension or approval interfaces.
- [ ] **Public agent-adapter SDK** — provide templates, capability negotiation,
  conformance tests, and documentation so the community can add agents without
  modifying the TapQ runtime.

## Wearables and input devices

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

## Interaction capabilities

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
  run on. See [TAPQ1_STAGE2.md](TAPQ1_STAGE2.md).
- [ ] **Personalization and accessibility** — configurable gesture mappings, per-device
  profiles, one-sided controls, and voice-only or haptic-only modes.
- [ ] **Wearer voice attribution** — decide from head motion whether the person wearing
  the earbuds is the one talking, so a nearby voice cannot answer an agent's question.
  The analyzer, its calibration profile, interval-level replay scoring, and the fail-open
  `WearerGatedVoice` composition wrapper have landed; the wrapper is not yet in the live
  runtime and its thresholds are provisional, both pending the human capture study.
- [x] **Pluggable voice backends** — a duplex-capable `VoiceBackend` contract under which
  turn arbitration stays on TapQ's side and a backend is only ever a speech pipe, with
  Apple's on-device recognizer as the default and an OpenAI Realtime adapter in
  manual-turn mode selected by `--voice-backend`. Any remote backend is always composed
  with the on-device stack beneath it, so an outage costs latency rather than the voice
  channel.
- [x] **Local replay and evaluation tools** — `tapq replay` streams user-authorized
  motion captures through the detection backends offline with per-gesture accuracy
  reporting, plus frame-level precision and recall for wearer speech against labeled
  spans or a co-recorded microphone envelope; broader adapter simulation remains open
  under the device-adapter SDK.
- [x] **Pluggable local intelligence** — the TapQ-1 encoder backend: a window-scorer
  protocol with a Core ML adapter, shadow/primary serve modes, a training pipeline in
  `ml/`, and the deterministic heuristics preserved as the always-available offline
  fallback. Training a production model awaits the capture study.

Contributions and design discussion are welcome; see
[CONTRIBUTING.md](../CONTRIBUTING.md).
