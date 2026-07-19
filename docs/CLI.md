# TapQ CLI Reference

The `tapq` executable is TapQ’s headless user interface. It runs the local
broker, manages calibration and agent integrations, and captures raw headphone
motion for diagnostics. There is intentionally no GUI and no end-user
`gesture analyze` command.

Examples use `tapq` as shorthand for the built executable. From a source
checkout, use `swift run tapq` for management commands such as version, profile
inspection, and integration status. Commands that need macOS privacy permissions
should run through `scripts/run-runtime-app.sh`. No system-wide installation is
published yet.

## Command overview

```text
tapq calibration   Run, inspect, or reset AirPods calibration
tapq calibrate     Shortcut for `tapq calibration run`
tapq capture       Capture raw headphone motion as JSONL or CSV
tapq serve         Run the local agent-neutral broker
tapq integration   Manage agent integrations
tapq version       Print version information
```

Run `tapq help <command>` for built-in usage.

## Version

```bash
tapq version
tapq --version
tapq version --json
```

The JSON form includes the CLI version and wire protocol version:

```json
{"name":"tapq","version":"0.1.0","wire_protocol":3}
```

The project is pre-1.0. Machine-readable formats are designed for automation,
but incompatible corrections may still occur before the first stable release.

## Runtime

Source-development examples:

```bash
scripts/run-runtime-app.sh serve
scripts/run-runtime-app.sh serve --no-voice
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 30
scripts/run-runtime-app.sh serve --steering
```

The underlying command syntax is `tapq serve [options]`.

### Runtime options

| Option | Meaning |
|---|---|
| `--broker-dir PATH` | Override the discovery and socket directory |
| `--gesture-profile PATH` | Override the gesture profile |
| `--tap-profile PATH` | Override the tap profile |
| `--timeout SECONDS` | Input timeout; default and maximum are 100 seconds |
| `--no-voice` | Do not request microphone/Speech access or start voice input |
| `--no-announcements` | Suppress non-blocking waiting and completion announcements |
| `--steering` | Enable opt-in Claude structured-question guidance |

On macOS, `tapq serve`:

1. Loads independent gesture and tap calibration profiles.
2. Composes motion, speech, synthesis, and volume adapters with the portable
   detection and interaction layers.
3. Starts an authenticated Unix-domain-socket broker.
4. Publishes `broker.json` only after the socket is listening.
5. Removes discovery and socket files on normal shutdown.

The development script packages a signed, headless `LSUIElement` app and launches
it through LaunchServices. The app has no window, menu, or Dock icon; the bundle
provides a stable bundle identity and privacy descriptions for Motion, Speech
Recognition, and Microphone authorization. Development builds are ad-hoc signed,
and rebuilding can cause macOS to request authorization again. Control-C
terminates the launched process.

### Input behavior

For approvals and yes/no questions:

- Double nod, double tap, or an affirmative voice command approves.
- Shake or a negative voice command denies.
- `repeat` speaks the prompt again; `details` requests the longer spoken detail.

For option questions:

- Volume down or `next` moves forward.
- Volume up or `previous` moves backward.
- Double nod, double tap, `select`, or spoken numbers one through four confirms.
- Shake or `skip` returns control to the on-screen prompt.

Voice commands are recognized with an English (`en-US`) grammar. Voice input is
active only during a bounded response window. TapQ requires on-device recognition
when the selected recognizer supports it; otherwise Apple’s Speech framework may
use Apple’s service. Spoken output uses the macOS system speech synthesizer and
voice selection.

### Motion recovery and diagnostics

A single CoreMotion disconnect callback is treated as an interruption rather than
confirmed device loss. TapQ keeps the current response window open for a grace
period, resumes on a corresponding reconnect, and announces disconnection only
when samples do not recover. When a new prompt opens without motion, the runtime
retries for a bounded period.

Warnings and errors are printed by default. `TAPQ_DEBUG=1` adds broker, speech,
gesture, tap, selection, and lifecycle events. Tap diagnostics include peak and
threshold acceleration, rotation limits, elevated-sample width, baseline return,
candidate duration, pairing gap, pending expiration, and listening-window reset.
After `tap.pending`, a bounded 600 ms trace records every delivered acceleration
and rotation sample with its hardware timestamp.

These diagnostics do not change detection policy. The bundled sink can record
tool names, request identifiers, option labels, lifecycle events, and motion
measurements. Normal CLI output can separately expose local paths. Review both
before sharing.

## Raw capture

```bash
tapq capture --duration 10 --output capture.jsonl
tapq capture --duration 10 --format csv --output capture.csv
tapq capture --duration 5 --output -
```

| Option | Default or behavior |
|---|---|
| `--duration SECONDS` | `10` |
| `--format jsonl\|csv` | `jsonl` |
| `--output PATH`, `-o PATH` | `-` for stdout |
| `--force`, `-f` | Off; existing files are preserved |

Progress and the final sample count go to stderr, keeping stdout pipe-safe. CSV
output begins with a header. Each record contains:

- `timestamp`: hardware motion timestamp in seconds
- `pitch` and `yaw`: attitude in radians
- `acceleration_magnitude`: user-acceleration magnitude in g
- `rotation_magnitude`: rotation-rate magnitude in radians per second

Capture does not run gesture classification. It requires macOS, compatible
connected AirPods, and Motion permission. Linux returns an unavailable error.

## Calibration

```bash
tapq calibration run
tapq calibration run gesture
tapq calibration run tap
tapq calibrate
tapq calibration show
tapq calibration show gesture
tapq calibration show tap
tapq calibration show --json
tapq calibration reset
tapq calibration reset tap
```

For source development on macOS, substitute
`scripts/run-runtime-app.sh calibration …` for live calibration commands.

### Run options

| Option | Default |
|---|---|
| `--rest-seconds N` | 3 seconds |
| `--nod-seconds N` | 4 seconds |
| `--shake-seconds N` | 4 seconds |
| `--tap-seconds N` | 4 seconds |
| `--non-interactive` | Off; when supplied, skips the initial Return prompt |

The default `all` run advances through connection warmup, rest, nod, shake, and
tap in one continuous motion session. A gesture-only run is 14 seconds by
default; a tap-only retry is 9 seconds. The timeline discards a one-second
connection warmup and one-second transitions.

Gesture and tap results are saved as independent profiles. If tap fails after a
valid gesture sequence, the gesture profile remains saved; rerun only
`tapq calibration run tap`.

Tap calibration evaluates a sharp acceleration spike against the resting
baseline. It accepts lower-amplitude hardware only when the captured peak is at
least `0.06 g` and four times the resting peak. The saved threshold remains at
least `0.05 g` and three times the resting peak. Runtime detection additionally
requires a brief spike, quiet head rotation, a return toward baseline, and two
distinct impacts inside the pairing window.

Profiles contain tuned configuration, timestamps, sample counts, and aggregate
quality metrics. They do not retain raw motion values.

### Profile locations

| Platform | Default directory |
|---|---|
| macOS | `~/Library/Application Support/TapQ/` |
| Linux | `$XDG_CONFIG_HOME/tapq/`, or `~/.config/tapq/` |
| Override | `$TAPQ_CONFIG_DIR/` |

The filenames are `gesture-calibration.json` and `tap-calibration.json`.

For a selected `gesture` or `tap` target, `--profile PATH` overrides that
profile. `--gesture-profile PATH` and `--tap-profile PATH` can override both
paths for an `all` run, show, or reset. `calibration reset` prompts unless
`--yes` or `-y` is supplied.

Profile inspection and reset work on Linux; live acquisition does not.

## Claude Code integration

```bash
tapq integration claude install --permission-policy native
tapq integration claude install --permission-policy strict
tapq integration claude status
tapq integration claude uninstall
```

The installer merges TapQ-managed hook groups into
`~/.claude/settings.json`, keeps unrelated settings and hooks from the version it
reads, creates a restrictive timestamped backup, and atomically replaces the
settings file. Do not edit the file concurrently with installation. Reinstall
after moving the TapQ executable because the hook command is an absolute path.

The installed executable is named `tapq-hook` and is expected beside `tapq`.
Development and custom installations can pass `--hook PATH`; isolated setups and
tests can pass `--settings PATH`.

### Permission-policy matrix

| Event | `strict` | `native` |
|---|---|---|
| `PreToolUse` | `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit`, `AskUserQuestion` | `AskUserQuestion` only |
| `PermissionRequest` | Not installed | `Bash`, `Write`, `Edit`, `MultiEdit`, `NotebookEdit` |
| `Notification` | `idle_prompt`, `permission_prompt` | Same |
| `Stop` | All | All |
| `UserPromptSubmit` | Installed but silent unless steering is enabled | Same |

`strict` is the CLI default and sends every matched pre-tool event to TapQ before
Claude Code’s permission engine. A strict request whose reported permission mode
contains `auto` preserves the legacy behavior of allowing without a gesture.

`native` handles only supported dialogs that Claude Code would otherwise show.
Recognized read-only Bash operations, existing allow rules, and
`bypassPermissions` can therefore bypass TapQ. Native hooks are intended for
interactive sessions and do not create an approval channel for non-interactive
`claude -p` runs.

Only one ordinary approval path is installed at a time. `AskUserQuestion`
currently supports exactly one single-select question. Multiple questions and
multi-select requests fail through to Claude Code’s interface.

Wire protocol v3 records whether an approval came from `PreToolUse` or
`PermissionRequest`. Strict and shared messages can temporarily use a discovered
legacy wire protocol v2 runtime. Native permission requests never downgrade to v2
and remain in Claude’s normal dialog when no wire protocol v3 runtime is available.

### Structured-question steering

Starting the runtime with `--steering` opts into a lightweight Claude Code
`UserPromptSubmit` instruction:

> When you need the user to choose between options or confirm a decision, ask via
> the AskUserQuestion tool rather than in plain text.

The hook adds this context only when it can read a live discovery record, the
wire version is compatible, and the runtime advertises steering. Missing, stale,
or incompatible discovery fails silently and injects nothing.

### Final-response questions

On a `Stop` event, the adapter reads the trailing assistant reply from Claude
Code’s local transcript. Replies without `?` are ignored. Explicit yes/no and
multi-option questions can be converted into a hands-free interaction; open-ended
or inconclusive questions pass through.

When `TAPQ_QUESTION_CLASSIFIER=anthropic` and `ANTHROPIC_API_KEY` are both present,
the runtime uses `claude-haiku-4-5-20251001` through Anthropic’s Messages API to
classify and shorten the reply. It sends up to the final 16,384 characters, returns
at most six cloud-extracted options, and uses a five-second provider timeout. API
failure or invalid output falls through to the deterministic local heuristic and
then to Claude’s normal UI.

The API key and submitted reply are not intentionally logged. The reply may
contain project or user data, and API use may incur charges. Unset either variable
to disable cloud processing.

## Environment variables and local data

| Name | Purpose |
|---|---|
| `TAPQ_DEBUG=1` | Enable verbose console diagnostics |
| `TAPQ_BROKER_DIR` | Override the runtime discovery/socket directory |
| `TAPQ_CONFIG_DIR` | Override calibration profile storage |
| `TAPQ_QUESTION_CLASSIFIER=anthropic` | Explicitly enable Anthropic final-response classification |
| `ANTHROPIC_API_KEY` | Authenticate classification requests after explicit opt-in |
| `TAPQ_SIGN_IDENTITY` | Select a signing identity for the packaging script |

Default broker directories:

- macOS: `~/Library/Application Support/TapQ/runtime`
- Linux: `$XDG_RUNTIME_DIR/tapq`, falling back to
  `~/.local/state/tapq/runtime`

The runtime directory is `0700`; its discovery record and socket are `0600`; and
the bearer token is regenerated on each launch. The token demonstrates access to
the same-user discovery record. It is not protection from a malicious process
running under the same account.

## Exit status

| Code | Meaning |
|---:|---|
| `0` | Command completed successfully |
| `1` | Execution failed |
| `64` | Invalid command or option |
| `69` | Requested platform or hardware service is unavailable |

## Troubleshooting

See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for privacy permissions,
AirPods acquisition, calibration, gesture diagnostics, voice, hook installation,
cloud classification, and Linux limitations.
