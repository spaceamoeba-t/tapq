<p align="center">
  <img src="assets/brand/tapq-mark.svg" alt="TapQ" width="96">
</p>

<h1 align="center">TapQ</h1>

<p align="center">
  <a href="https://github.com/spaceamoeba-t/tapq/actions/workflows/ci.yml"><img alt="CI status" src="https://github.com/spaceamoeba-t/tapq/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/spaceamoeba-t/tapq/tags"><img alt="Latest tag" src="https://img.shields.io/github/v/tag/spaceamoeba-t/tapq?label=release&include_prereleases&color=C8F031&labelColor=161617"></a>
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6.0-2A2B2E?labelColor=161617">
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-2A2B2E?labelColor=161617">
  <img alt="Linux portable core" src="https://img.shields.io/badge/Linux-portable%20core-2A2B2E?labelColor=161617">
  <a href="LICENSE"><img alt="Apache 2.0 license" src="https://img.shields.io/badge/license-Apache--2.0-C8F031?labelColor=161617"></a>
</p>

TapQ lets you work with your coding agents by voice. You speak to Claude Code or Codex by
name; TapQ relays your words into the agent's session, reads its permission requests and
questions aloud, takes your spoken answer, and speaks its replies. The agents run in your
project folder as they would in a terminal. TapQ is the voice between you and them.

This repository is `tapq-kernel`, that loop: a command-line program for macOS, written in
Swift, that runs on your own OpenAI API key.

> **0.6.0 replaces the earlier TapQ.** The broker and its hooks, the Cursor and OpenCode
> integrations, AirPods gestures, on-device speech and the wake word are gone. Their last
> state is kept under the [`legacy-final`](https://github.com/spaceamoeba-t/tapq/tree/legacy-final)
> tag.

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Command line](#command-line)
- [Configuration](#configuration)
- [Privacy and data](#privacy-and-data)
- [How it works](#how-it-works)
- [Development](#development)
- [Community](#community)
- [License](#license)

## What it does

- **Speak to an agent by name.** "Claude, add a test for the parser." "Codex, why is the
  build failing?" A small text model reads the whole sentence, with both agents' state, and
  turns it into one action for one agent. When a bare "yes" could be for either, TapQ asks
  "Claude Code or Codex?".
- **Hear what needs you.** Permission requests and questions are read aloud as they arrive.
  A shell command is described in words rather than read out symbol by symbol. An answer
  counts only for a request you have heard in full.
- **Answer by voice.** Say yes, no, "no, use the other file", or pick an option. Ask not to
  be asked again, and TapQ takes the agent's own offer to stop asking, where it makes one.
- **Hear the reply.** A short reply is read as it is. One over 120 characters, or with code
  or a link in it, is summarized in a sentence or two; "read it all" reads the original.
- **Ask where things stand.** "What is Codex doing?" gets a spoken status.
- **Move between conversations.** "Claude, list my conversations" reads five at a time, and
  "more" reads the rest. "Switch to the second one" or "start a new conversation" goes there.
- **Lose one agent, not both.** An agent that fails stops alone, and TapQ says so; the other
  carries on.
- **Pick up after a restart.** Each folder keeps a journal. A restarted `tapq-kernel` says
  what was cut off and resends nothing.

## Requirements

- macOS 14 or newer, with a microphone and a speaker or a headset. TapQ listens for as long
  as it runs and treats everything it hears as yours, so in a shared room use a headset or
  your earbuds' voice isolation.
- Swift 6.0 or newer: Xcode 16, or the Command Line Tools.
- An OpenAI API key with access to the Realtime API.
- At least one agent on your `PATH`, signed in: Claude Code 2.1.260 through 2.1.293, or
  Codex 0.161. Listing Claude Code's conversations needs 2.1.283 or newer.

## Quick start

```bash
git clone https://github.com/spaceamoeba-t/tapq.git
cd tapq
swift build -c release
```

```bash
export TAPQ_OPENAI_API_KEY=sk-...
.build/release/tapq-kernel run --workspace ~/code/my-project
```

The first run asks for the microphone on behalf of your terminal app. Then speak: "Claude,
what does this project do?" Stop with Ctrl-C or Ctrl-D.

## Command line

```text
tapq-kernel run --workspace <abs-dir> [options]
tapq-kernel clear --workspace <abs-dir>
tapq-kernel --help
```

`run` listens and relays until you stop it. `clear` deletes what TapQ kept for the folder:
its journal, the agents' session ids and its diagnostics. The agents' own history is theirs
and is not touched.

| Option | What it does |
|---|---|
| `--workspace <abs-dir>` | The folder the agents work in. Required, absolute. |
| `--language <code>\|auto` | The language you speak, as an ISO 639-1 code (default `en`). `auto` lets the service tell each sentence's language, for a user who mixes two. |
| `--permission-mode acceptEdits\|manual` | How Claude Code asks (default `acceptEdits`). `bypassPermissions` is refused: approvals would never reach you. |
| `--auto-mode` | Each agent approves what it judges safe, Claude Code in its auto permission mode and Codex through its `auto_review` reviewer; TapQ asks you the rest. Off by default. |
| `--subscription claude` | Claude Code signs in with your claude.ai subscription instead of an API key from the environment. Checked at start. Off by default; Anthropic's terms govern using a subscription login through another tool, so check them first. |
| `--agents <agents>` | Only these agents may start: `claude`, `codex`. Both by default. |
| `--realtime-endpoint <ws-url>` | A server that speaks OpenAI's Realtime wire, for the voice sessions. |
| `--openai-base-url <http-url>` | A base URL for the text models instead of `https://api.openai.com/v1`. |

Exit status: 0 is a clean stop, 64 a usage error (nothing started), and 70 a fatal or a
refused start, with one `tapq-kernel: fatal in <subsystem>: <reason>` line on standard
error.

Standard output carries one JSON status line per change, for a program that hosts the
kernel. Standard input is that host's lifeline: its end of file stops the kernel.

## Configuration

| Variable | Default | |
|---|---|---|
| `TAPQ_OPENAI_API_KEY` | none | Required. Every voice session and text-model call runs on it. |
| `TAPQ_CLAUDE_MODEL` | `claude-haiku-5-5` | The model Claude Code is started on, whatever your own settings say. |
| `TAPQ_CODEX_MODEL` | `gpt-5.6-luna` | The model Codex's threads use. |
| `TAPQ_INTENT_MODEL`, `TAPQ_SUMMARY_MODEL`, `TAPQ_COMMAND_MODEL`, `TAPQ_PROGRESS_MODEL`, `TAPQ_TITLER_MODEL`, `TAPQ_PICKER_MODEL` | `gpt-5.6-luna` | TapQ's own text models: routing, reply summaries, command descriptions, status, conversation titles, and which conversation your words carry on. |
| `TAPQ_STT_MODEL` | `gpt-4o-transcribe` | Speech to text. |
| `TAPQ_TTS_MODEL`, `TAPQ_TTS_VOICE` | `gpt-realtime-2.1-mini`, `cedar` | TapQ's voice. |
| `TAPQ_DEBUG` | off | `1` puts every diagnostic on standard error, not only warnings and errors. |
| `TAPQ_ALLOW_UNSUPPORTED_AGENT_VERSIONS` | off | `1` runs an agent outside the supported range, with a warning. |
| `TAPQ_BROKER_DIR` | see below | Where TapQ keeps its state. |

TapQ keeps each folder's state in `~/Library/Application Support/TapQ/runtime/kernel/`,
in a directory named by a hash of the folder's path and created `0700`: the journal (what
you said to each agent, verbatim, and what came of it), the agents' session ids, and
`diagnostics.log`.

## Privacy and data

- **Your voice goes to OpenAI.** Microphone audio streams to OpenAI's Realtime API for
  transcription for as long as `tapq-kernel run` runs, and TapQ's sentences are voiced there.
- **So do the words around it.** What you say, and what the agents ask and reply, goes to
  OpenAI's Responses API for routing, summaries, command descriptions, status and
  conversation titles.
- **All of it on your key**, under your OpenAI account's terms. TapQ talks to no other
  service unless you name one with `--realtime-endpoint` or `--openai-base-url`, opens no
  network port, and keeps no copy of the audio.
- **The agents stay on their own accounts.** Claude Code and Codex run as they would in your
  terminal, started without TapQ's variables or its key.
- **Nothing is approved without you.** An approval comes only from your answer to a request
  you heard, unless you turn on `--auto-mode`, where the agents' own reviewers decide first.

## How it works

The kernel is one loop. Speech comes in as utterances; a text model turns each into one
action for one agent; a deterministic gate lets an answer through only for a request the
user heard; the agent runs as a child process; what it asks and says is queued and spoken.
Each step is written to the folder's journal, so a restart can say what was lost.

| Target | What it holds |
|---|---|
| `TapQKernel` | The loop: the journal, the gate, every sentence TapQ speaks, the status channel. No Apple framework, network or subprocess. |
| `TapQKernelClaude` | Claude Code as a stream-json delegate. |
| `TapQKernelCodex` | Codex as a JSON-RPC delegate over `codex app-server`. |
| `TapQOpenAI` | The text models, over the Responses API. |
| `TapQVoiceIO`, `TapQVoiceBackends` | Speech in and out over OpenAI's Realtime API. |
| `TapQAudioIO`, `TapQAudioCaptureBridge` | Microphone capture and playback (macOS). |
| `TapQPOSIXSupport` | Child processes in their own process groups, and line channels. |
| `TapQContracts` | Types and protocols the targets share. |
| `tapq-kernel` | The executable: command line, startup checks, composition. |

Everything but the audio targets builds and tests on Linux; `tapq-kernel run` needs macOS.

## Development

```bash
swift build
swift test
scripts/check-release-version.sh
scripts/check-public-boundary.sh   # needs ripgrep
```

On a Mac with only the Command Line Tools there is no XCTest, so `swift test` cannot run.
Build with `swift build --build-system native`, then use `scripts/typecheck-tests.sh` and
`scripts/host-test.sh <TestTarget> ...` instead. [CONTRIBUTING.md](CONTRIBUTING.md) has the
rest, and [TROUBLESHOOTING.md](TROUBLESHOOTING.md) covers a start that fails.

## Community

- **Found a bug?** Open an [issue](https://github.com/spaceamoeba-t/tapq/issues) with the
  TapQ version, macOS version, and the agent and its version.
- **Found a vulnerability?** Report it privately, as the [security policy](SECURITY.md)
  describes. Please do not open a public issue for it.
- **Questions and ideas** go to
  [Discussions](https://github.com/spaceamoeba-t/tapq/discussions).

## License

TapQ source code and documentation are licensed under the
[Apache License 2.0](LICENSE); see [NOTICE](NOTICE) for attribution. The license does
not grant rights to the TapQ name or marks, and the artwork in `assets/brand/` is
separately reserved; see [TRADEMARKS.md](TRADEMARKS.md).
