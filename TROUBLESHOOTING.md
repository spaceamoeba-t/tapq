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

## A final-response question stays on screen

The Stop-hook classifier considers only final replies containing `?`. It handles
yes/no questions and questions that offer explicit alternatives; open-ended and
inconclusive questions intentionally fail through.

Cloud classification requires both `TAPQ_QUESTION_CLASSIFIER=anthropic` and
`ANTHROPIC_API_KEY` in the environment of the running TapQ process. Without the
explicit TapQ setting, only the deterministic local heuristic is used. Never paste
an API key into an issue or diagnostic log.

## Linux reports that live commands are unavailable

This is expected. The package, broker, libraries, profile management, and Claude
integration management build on Linux, but the repository does not yet provide
Linux microphone, speech, system-volume, or headphone-motion adapters. Live
`serve`, `capture`, and `calibration run` therefore require macOS.

## Sharing diagnostics safely

Review all output before sharing it. Debug logs can contain tool names, request
identifiers, option labels, lifecycle data, and timestamped motion measurements;
normal CLI output can contain filesystem paths. Claude settings and their TapQ
backups can contain credentials and should not be attached to a public issue
without careful redaction.
