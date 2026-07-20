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

Speech output uses the macOS system synthesizer. Voice quality can be changed in
the macOS spoken-content or system-voice settings; downloading an enhanced
English voice usually improves output. Setting the system language to English is
not required for TapQ’s command grammar.

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
session, run `/hooks`, review the TapQ `PermissionRequest` and `Stop` entries, and trust
their exact current definitions. Codex deliberately skips new or changed non-managed
hooks until this step is complete. Also confirm that hooks have not been disabled by
local or managed Codex configuration.

The current adapter handles native `PermissionRequest` prompts for `Bash` and
`apply_patch` only. Read-only commands, allow rules, permission modes, or sandboxed
operations that Codex does not prompt for legitimately bypass TapQ. There is no Codex
strict `PreToolUse` policy, structured `request_user_input` interception, or generic
notification-hook parity yet. Codex CLI `0.142.5` is the tested contract floor.

If status is incomplete, run uninstall and install again. TapQ preserves unrelated hook
groups, but do not edit `hooks.json` while the installer is running.

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
