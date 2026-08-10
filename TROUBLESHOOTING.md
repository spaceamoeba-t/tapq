# Troubleshooting

TapQ’s live hands-free runtime depends on macOS privacy authorization, a stable
AirPods motion stream, a running local broker, and correctly installed agent
hooks. Start with the checks below before collecting verbose logs.

## The runtime has no Motion, Speech, or Microphone permission

Run TapQ through its headless app container rather than a changing SwiftPM build
path:

```bash
scripts/run-runtime-app.sh serve
```

Approve the requested access. Existing decisions can be reviewed under **System
Settings → Privacy & Security** in Motion & Fitness, Speech Recognition, and
Microphone. The exact labels vary by macOS version.

Use `--no-voice` when only motion input is needed. This prevents TapQ from
requesting microphone access or starting speech recognition.

## AirPods are connected but no motion samples arrive

Check that the AirPods are:

- Compatible with headphone motion.
- Connected, in-ear, and selected as the current audio output.
- Not simultaneously used for headphone motion by another TapQ instance or another
  process.

Then stop and restart the runtime. A competing CoreMotion session can attenuate
samples, interrupt the stream, or make a device appear disconnected even though
Bluetooth audio remains connected.

To isolate acquisition from gesture recognition, capture a short raw stream:

```bash
scripts/run-runtime-app.sh capture --duration 5 --output -
```

If capture produces no records, the problem is device acquisition or permission,
not the gesture classifier.

## No AirPods are connected at all

This is a supported configuration, not a failure. TapQ degrades to a plain voice
agent and says so once.

Expected behavior:

- The ready banner reads `AirPods motion: unavailable (voice-only; gestures return
  when AirPods connect)`.
- About a second and a half after startup, TapQ speaks one notice — "No AirPods
  detected. Running voice only." — and then stays quiet about it. `--no-announcements`
  suppresses the notice; prompts still speak.
- Every response window runs its bounded motion retry, finds nothing, and continues
  on voice. There is no per-prompt disconnect announcement: "AirPods motion
  disconnected." is reserved for a device that was present when the window opened.
- Gesture, tap, and tilt channels deliver nothing. Volume swipes are switched off
  rather than left attached to the built-in speaker, so volume keys change the volume
  instead of moving the selection.
- The first selection prompt teaches the controls that can answer it: "Say next,
  previous, or select."
- Connect AirPods mid-session and the next prompt has gestures and swipes back — no
  restart, no reconfiguration. Say `repeat` on a selection to hear the full controls.

The fallback voice is **not wearer-attributed.** Attribution is a claim about the
in-ear IMU, and with no IMU there is nothing to attribute with, so `--wearer-gate` and
`--imu-turn-control` fail open: every command the microphone hears passes, and turn
control is inert. Both flags are safe to leave on and do nothing.

## Tap calibration is too weak

Keep your head still and give the outside body of an earbud several quick,
distinct fingertip taps. Do not squeeze or press the stem: calibration looks for
a sharp acceleration spike that separates from the resting baseline.

Gesture and tap profiles are independent, so retry only tap:

```bash
scripts/run-runtime-app.sh calibration run tap
```

Inspect the saved result with:

```bash
swift run tapq calibration show tap
```

## Gestures stop responding during an interaction

Confirm that both profiles load when `tapq serve` starts. Then enable diagnostic
output:

```bash
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --no-voice
```

Look for motion availability, listening-window start and reset events, tap
candidate rejection reasons, and disconnect/reconnect events. After a recognized
first tap, TapQ emits a bounded sample trace that helps distinguish a missed
second impact from a timing or rotation rejection.

Experimenting with a slightly wider interval between taps can help determine
whether two impacts are merging at the AirPods motion sample cadence, but it does
not replace calibration or the detector’s configured pairing window.

## Voice commands do not match

TapQ currently uses an English (`en-US`) recognizer and keyword grammar. Try a
short command such as `yes`, `no`, `next`, `previous`, or `select`. Verify Speech
Recognition and Microphone authorization and check that the runtime was not
started with `--no-voice`.

Setting the system language to English is not required for TapQ’s command grammar:
the recognizer is pinned to `en-US` independently of the system language.

## Spoken prompts are garbled or mix two languages

TapQ speaks through the macOS system synthesizer with an `en-US` voice by default.
If prompts sound like a mix of English and another language, the runtime is
probably speaking through a non-English voice — check the `--speech-voice` value
and `TAPQ_SPEECH_VOICE`, and look for a `voice.unavailable` warning under
`TAPQ_DEBUG=1`, which means the requested voice is not installed and macOS fell
back to the system-language voice.

Note that this setting selects a *voice*, not a translation. TapQ’s own spoken
copy (“Approve?”, “Volume, then nod twice or double-tap.”) is English, so pointing
`--speech-voice` at another language makes that copy be pronounced by a voice that
does not speak it. Agent-supplied text is spoken verbatim as well, so an agent
replying in another language is still read by the selected voice.

Voice quality is a separate axis: downloading an enhanced or premium voice in the
macOS spoken-content settings usually improves output, and its identifier can be
passed to `--speech-voice` directly.

## Claude Code does not trigger TapQ

Check the installed hook and policy:

```bash
tapq integration claude status
```

Then confirm that `tapq serve` is running. Reinstall the integration after moving
the checkout or app because Claude’s settings contain an absolute hook path:

```bash
tapq integration claude install --permission-policy native
```

In native mode, TapQ receives only supported permission dialogs Claude Code
actually emits. Existing allow rules and `bypassPermissions` may legitimately
bypass TapQ. Use strict mode when every matched operation must reach the hook.

If status reports an incomplete installation or prompts appear twice, run
`uninstall`, then install the selected policy again. Avoid editing
`~/.claude/settings.json` while the installer is running.

## Codex does not trigger TapQ

Check TapQ’s file-level status first:

```bash
tapq integration codex status
```

The default file is `~/.codex/hooks.json`, or `$CODEX_HOME/hooks.json` when
`CODEX_HOME` is set. Reinstall after moving the checkout, runtime app, or executable
because the hook command stores the absolute path to `tapq-codex-hook`:

```bash
tapq integration codex install
```

A configured status does not mean Codex trusts the command. Open an interactive Codex
session, run `/hooks`, review the four current TapQ registrations at the selected path
(`PreToolUse`, `PermissionRequest`, `Stop`, and `UserPromptSubmit`), and trust their exact
definitions. Unrecognized custom-path hooks may remain as unrelated data. Codex
deliberately skips new or changed non-managed hooks until this step is complete. TapQ
cannot inspect trust state, so `/hooks` is authoritative. Also confirm that hooks have not
been disabled by local or managed Codex configuration.

The current adapter handles one root-agent, single-choice `request_user_input` call and
native `PermissionRequest` prompts for `Bash`, `apply_patch`, and canonical MCP tools.
Multiple or auto-resolving questions, unsupported option shapes, secret questions,
subagent calls, read-only commands, allow rules, permission modes, and sandboxed
operations can legitimately bypass TapQ. In Codex CLI `0.146.0`, Plan mode is the
reliable `request_user_input` surface; availability in default mode depends on
`default_mode_request_user_input`. Status reports the discovered Codex executable,
version, and relevant feature values on a best-effort basis. It resolves and executes
`codex` from the caller's `PATH` using fixed diagnostic arguments and a reduced
environment allowlist, so run status with a trusted `PATH`. “Not found on PATH” means resolution
failed; “executable found, but diagnostics failed or timed out” means resolution
succeeded but the bounded probe did not. Neither result changes hooks-file status. A
version below the tested `0.142.5` floor emits a compatibility warning.

If `--steering` is enabled, the matcherless `UserPromptSubmit` hook adds its fixed
`request_user_input` “when available” hint only for root turns while the TapQ discovery
record is live and wire-compatible. It opens an EOF-only Unix-socket connection to verify
liveness but sends no request bytes or application data and performs no broker
request/response round-trip. Disabled steering, subagents, missing discovery, or an
incompatible runtime silently preserve native prompt submission. There is no broad Codex
strict `PreToolUse` policy or generic notification hook parity. Codex CLI `0.142.5` is the
lifecycle contract floor; structured-question and MCP coverage is tested against
`0.146.0`.

If status is incomplete, run `tapq integration codex install` again; direct reinstall
repairs registrations at the current hook, the bare `tapq-codex-hook` command, and
recognized TapQ app/build paths while preserving unfamiliar custom executable paths as
unrelated hooks.
There is normally no need to uninstall first. Upgrading from the previous three-hook
layout requires this rerun to add `UserPromptSubmit`, followed by review in `/hooks`. Do
not edit `hooks.json` while the installer is running.

## A final-response question stays on screen

The Stop-hook classifier considers only final replies containing `?`. It handles yes/no
questions and questions that offer explicit alternatives; open-ended and inconclusive
questions intentionally fail through. Claude Code reads the text from its transcript;
Codex uses the hook’s stable `last_assistant_message` field. TapQ does not parse Codex
transcripts.

After TapQ answers one Codex Stop question, Codex calls the hook again with
`stop_hook_active:true`; TapQ intentionally skips a second question interaction and lets
the continued turn finish. If the broker is unavailable, times out, rejects the wire
version, or returns no answer, the hook emits no continuation and the final response
remains in Codex’s normal interface.

Cloud classification requires an explicit provider and its matching credential:
`--question-classifier anthropic` uses `ANTHROPIC_API_KEY`, while
`--question-classifier openai` uses `OPENAI_API_KEY`. An API key alone never enables
cloud processing. If a provider is selected without its key, TapQ exits with a
configuration error rather than silently selecting another provider. Never paste an API
key into an issue or diagnostic log.

## Linux reports that live commands are unavailable

This is expected. The package, broker, libraries, profile management, and Claude Code
and Codex integration management build on Linux, but the repository does not yet provide
Linux microphone, speech, system-volume, or headphone-motion adapters. Live
`serve`, `capture`, and `calibration run` therefore require macOS.

## Sharing diagnostics safely

Review all output before sharing it. Debug logs can contain tool names, request
identifiers, option labels, lifecycle data, and timestamped motion measurements;
normal CLI output can contain filesystem paths. Claude settings, Codex hooks files, and
their TapQ backups can contain sensitive commands, paths, or credentials and should not
be attached to a public issue without careful redaction.
