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
tapq replay        Replay a motion capture through detection backends offline
tapq bench         Score a stage-2 reasoner against a labeled scenario corpus
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
{"name":"tapq","version":"0.3.0","wire_protocol":3}
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
# With ANTHROPIC_API_KEY already present in the launcher environment:
scripts/run-runtime-app.sh serve --question-classifier anthropic
# With OPENAI_API_KEY already present in the launcher environment:
scripts/run-runtime-app.sh serve --question-classifier openai
```

The underlying command syntax is `tapq serve [options]`.

### Runtime options

| Option | Meaning |
|---|---|
| `--broker-dir PATH` | Override the discovery and socket directory |
| `--gesture-profile PATH` | Override the gesture profile |
| `--tap-profile PATH` | Override the tap profile |
| `--timeout SECONDS` | Input timeout; default and maximum are 240 seconds |
| `--no-voice` | Do not request microphone/Speech access or start voice input |
| `--speech-voice VOICE` | Voice used for spoken output: a language tag (`en-US`, `zh-CN`) or a macOS voice identifier. Default `en-US`; also settable with `TAPQ_SPEECH_VOICE`. Unrelated to `--no-voice`, which gates the microphone |
| `--no-announcements` | Suppress non-blocking waiting and completion announcements |
| `--steering` | Enable opt-in structured-question guidance for adapters that support it (currently Claude Code) |
| `--encoder-model PATH` | Load a TapQ-1 encoder model (`.mlpackage` or `.mlmodelc`) exported by `ml/tapq1/export.py` |
| `--encoder-mode shadow\|primary` | `shadow` (default) records encoder detections as diagnostics while heuristics drive events; `primary` lets the encoder drive events with heuristic detections logged for comparison. Requires `--encoder-model`; a model that fails to load degrades to heuristics and reports it |
| `--reasoner PROVIDER` | Stage-2 risk reasoner backend: `off` (default) or `apple`, Apple's on-device Foundation Model |
| `--reasoner-mode shadow\|primary` | `shadow` (default) records reasoner decisions as diagnostics while confirmation requirements stay as the deterministic policy set them; `primary` lets a decision strengthen the requirement for that request. A reasoner can only ask for *more* confirmation — it can never approve, deny, or resolve a request, so every failure, timeout, or absent model leaves behavior exactly as it is today. Requires `--reasoner`; a device without the model keeps serving without risk escalation and reports it |
| `--question-classifier PROVIDER` | Select `auto`, `apple`, `anthropic`, `openai`, or `local`; default is `auto` |

Selecting a reasoner also starts a local decision log at
`<broker-dir>/reasoner-log.jsonl` — one JSON line per reasoner-observed approval,
recording the tier, rationale code, confidence or abstention reason, latency, the
confirmation the decision implied, and what the user then decided. It is the
shadow-review artifact: comparing what a decision asked for against what the user
actually did is the only way to answer whether `primary` would have been safe.
The file is created `0600` inside the `0700` runtime directory, is capped at
roughly 5 MB with a single rotation to `reasoner-log.1.jsonl`, never leaves the
machine, and is never read back by TapQ. Deleting either file at any time is safe
and costs only review history.

Be aware of what a line can contain: the full command line, the working directory,
and the adapter's `detail` are deliberately absent, but the recorded `summary` is
the same text TapQ speaks aloud, and for a `Bash` request that summary is the
*front* of the command line (its first six words, capped at 64 characters). That
prefix can carry a real secret — a connection string, a header fragment, a token
passed as an early argument. Treat the log as the same class of local state as
`broker.json`.

Question classifier modes:

- `auto` uses Apple's on-device Foundation Model when available and otherwise uses the
  deterministic local heuristic. It never enables cloud processing.
- `apple` requires Apple Foundation Models to be available and fails at startup otherwise.
- `anthropic` requires `ANTHROPIC_API_KEY` and uses Claude Haiku, backed by the local
  heuristic when a request fails.
- `openai` requires `OPENAI_API_KEY` and uses GPT-5.6 Luna through the Responses API,
  backed by the local heuristic when a request fails.
- `local` uses only the deterministic structured-option heuristic.

The selected mode applies to every agent adapter connected to that runtime instance.

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
- Double shake or a negative voice command denies.
- `repeat` speaks the prompt again; `details` requests the longer spoken detail.

For option questions:

- Volume down or `next` moves forward.
- Volume up or `previous` moves backward.
- Double nod, double tap, `select`, or spoken numbers one through four confirms.
- Double shake or `skip` returns control to the on-screen prompt.

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
- `pitch`, `yaw`, and `roll`: attitude in radians
- `acceleration_magnitude`: user-acceleration magnitude in g
- `rotation_magnitude`: rotation-rate magnitude in radians per second
- `user_acceleration_x/y/z`: signed user acceleration in g, earbud frame
- `rotation_rate_x/y/z`: signed rotation rate in radians per second, earbud frame
- `gravity_x/y/z`: gravity direction in g, earbud frame

The first five CSV columns keep their pre-per-axis positions, so tooling written
against earlier captures keeps working; per-axis columns are appended.

Capture does not run gesture classification. It requires macOS, compatible
connected AirPods, and Motion permission. Linux returns an unavailable error.

## Replay and evaluation

```bash
tapq replay --input capture.jsonl
tapq replay --input capture.jsonl --labels capture.labels.jsonl
tapq replay --input capture.jsonl --labels capture.labels.jsonl \
    --encoder-model models/tapq1.mlpackage --json
```

Replays a recorded capture through TapQ's detection backends, entirely offline
and on any platform — no AirPods or permissions required. This is the evaluation
harness for the capture study: record once, then measure every tuning or backend
change against the same data.

| Option | Default or behavior |
|---|---|
| `--input PATH`, `-i PATH` | Required; a `tapq capture` file |
| `--labels PATH` | Optional JSONL expectation segments (see below) |
| `--format jsonl\|csv` | Auto-detected from extension or content |
| `--tolerance SECONDS` | `1.0`; grace period after a segment in which its event may still fire |
| `--encoder-model PATH` | Also replay through a TapQ-1 encoder model (macOS only) |
| `--gesture-profile PATH` | Replay with a calibrated gesture profile instead of defaults |
| `--tap-profile PATH` | Replay with a calibrated tap profile instead of defaults |
| `--json` | Emit the machine-readable report |

Without labels, replay lists every emitted event with its offset. With labels,
it adds per-gesture true/false positives, misses, precision, recall, and false
positives per minute — run it on confounder recordings (typing, bud adjustments,
desk motion) with an empty label file to measure false-positive rates directly.

Each label line marks the complete command the wearer performed, in the
capture's own timestamp clock:

```json
{"start": 12.4, "end": 14.1, "label": "nod"}
```

Valid labels: `nod`, `shake`, `tilt_left`, `tilt_right`, `tap`, `swipe_up`,
`swipe_down`. Segments span the complete doubled gesture — a `nod` segment covers
the full double nod, `shake` the full double shake, `tap` the full double tap —
matching what the pipelines emit. Motion-swipe detection is
enabled during replay even though it ships disabled live, so experimental
channels can be evaluated from the same recordings. Magnitude-only captures from
before per-axis capture replay through the heuristic backend; the encoder
backend needs per-axis data.

## Reasoner bench

```bash
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson --limit 20
tapq bench reasoner --scenarios bench/reasoner-scenarios-v1.ndjson --json > run.json
```

Scores a stage-2 risk reasoner against a labeled scenario corpus. Each scenario's
`context` is handed to the reasoner once and the returned `ReasonerDecision` is
graded against the corpus labels. This is `tapq replay`'s counterpart for the
context layer: replay measures gesture detection against recorded motion, bench
measures risk assessment against recorded requests.

| Option | Default or behavior |
|---|---|
| `--scenarios PATH` | Required; a newline-delimited JSON corpus (`bench/reasoner-scenarios-v1.ndjson`) |
| `--reasoner apple` | Backend to measure (default: `apple`); `off` is rejected |
| `--limit N` | Assess only the first N scenarios, in file order |
| `--json` | Emit the machine-readable report, including every offender id |

Scenarios run sequentially. Concurrency would race one on-device model against
itself: the cached prompt prefix would thrash and reported latency would be
queueing delay rather than the time an assessment takes. Progress goes to stderr,
keeping stdout pipe-safe for a saved report.

Unlike `tapq serve`, which serves on when the model is unavailable because a
missing reasoner can only mean "no escalation", bench **fails** in that case: a
run of abstentions would print as a report and read as a result.

### Grading

The rules are `bench/README.md`'s, implemented as written:

- **Tier** — exact match against `expected_tier`. No partial or ordering credit.
- **Code** — `rationale.code` must be in the row's `acceptable_codes`. Reported
  separately from tier accuracy: a right tier with a wrong code is a code miss,
  not a tier miss. Routine rows escalate nothing, so their code is unused and
  they are excluded from the code-in-set rate.
- **Abstention** (`nil`, a decision below `ReasonerConfig.minConfidence`, or an
  answer that arrives after the runtime's outer deadline) — a miss on `sensitive`
  and `destructive` rows, so a reasoner cannot score well by refusing to answer;
  acceptable on `routine` rows, where it would not have changed what the user has
  to do. Routine recall therefore credits abstentions, and the report prints hits,
  abstentions, and the abstain rate separately so an always-abstaining reasoner is
  visible as one.

  Each assessment runs through the same bound the runtime applies — the reasoner's
  timeout plus a small grace — so an answer that took longer than the user would
  have waited for is graded as a timeout abstention rather than a hit. Bench
  measures the reasoner the user actually gets.
- **False escalation** — an emitted tier above the expected one, reported apart
  from accuracy because it is safe but costs the user extra confirmation. Two
  numbers, as `bench/README.md` defines them: `escalations_above_expected`, a
  count over all rows (so a `sensitive` row escalated to `destructive` is
  visible), and the benign false-escalation rate, whose denominator is the
  expected-`routine` rows — the work the corpus calls ordinary.
- **Under-escalation** — an emitted tier below the expected one. The risk metric.

The report prints overall counts, a routine/sensitive/destructive/abstain
confusion matrix, per-tier precision and recall, the headline rates, latency p50
and p95, per-category counts (the two lookalike categories separately — they are
the rows the corpus exists for), and a worst-offenders list of scenario ids for
missed destructive rows, false escalations on routine rows, and code misses.
Those ids are the review hook: each one is a labeled corpus line to read and
argue with. The text report shows up to ten ids per list; `--json` carries all of
them.

Corpus problems are reported with the line number the file shows, and a run stops
rather than skipping a row: a harness that silently dropped scenarios would
report a score for a corpus it did not run.

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

On macOS 26 or later, the runtime uses Apple's on-device Foundation Model when
Apple Intelligence reports it available. The model classifies supported prose
questions and shortens them for speech with a five-second provider timeout. If the
model is unavailable or fails, TapQ falls through to its deterministic structured-option
heuristic and then to Claude Code's normal UI.

When `--question-classifier anthropic` is passed and `ANTHROPIC_API_KEY` is present,
the runtime explicitly overrides the on-device model with
`claude-haiku-4-5-20251001` through Anthropic’s Messages API to
classify and shorten the reply. It sends up to the final 16,384 characters, returns
at most six cloud-extracted options, and uses a five-second provider timeout. API
failure or invalid output falls through to the deterministic local heuristic and
then to Claude’s normal UI.

The API key and submitted reply are not intentionally logged. The reply may
contain project or user data, and API use may incur charges. Restart with
`--question-classifier auto` or `local` to disable cloud processing. An inherited API
key alone does not activate the provider.

## Codex integration

```bash
tapq integration codex install [--hooks PATH] [--hook PATH]
tapq integration codex status [--hooks PATH] [--hook PATH]
tapq integration codex uninstall [--hooks PATH] [--hook PATH]
```

By default, the installer merges TapQ-managed hook groups into
`~/.codex/hooks.json`. When `CODEX_HOME` is set, the default becomes
`$CODEX_HOME/hooks.json`. It preserves unrelated top-level data, events, matcher groups,
and handlers; snapshots an existing file to a restrictive timestamped backup; and
atomically replaces the original. Do not edit the file concurrently with installation.
Reinstall after moving TapQ because the hook command is an absolute path.

The installed executable is named `tapq-codex-hook` and is expected beside `tapq`.
Development and custom installations can pass `--hook PATH`; isolated setups and tests
can pass `--hooks PATH`.

Installation is not activation. Codex requires users to review and trust the exact
definition of every non-managed command hook. After installation, open an interactive
Codex session, run `/hooks`, inspect all three TapQ entries, and trust their current
definitions. Changed definitions receive a new hash and must be reviewed again. The
`status` command validates only TapQ’s file layout; it cannot read or change Codex’s
trust decision.

### Supported Codex event slice

TapQ installs three lifecycle hooks:

| Event | Matcher | Current behavior |
|---|---|---|
| `PreToolUse` | `request_user_input` | Answers one supported root-agent single-choice question before Codex opens its native selector |
| `PermissionRequest` | `Bash`, `apply_patch` | Answers only native approval prompts Codex was already going to show |
| `Stop` | All root turns | Sends completion and optionally routes an explicit final-response question |

For `request_user_input`, TapQ supports exactly one question with two or three valid,
uniquely labelled options. A hands-free selection is delivered to the model through
Codex’s documented `PreToolUse` deny feedback, so the native selector does not also
open. Multiple questions, auto-resolving questions, unsupported option shapes,
secret questions, subagent calls, unanswered interactions, broker failures, and missing
runtimes emit no hook output; Codex then retains its native behavior, including its
free-form `Other` choice.

For `PermissionRequest`, an allow or deny becomes Codex’s documented event-specific
decision. A broker timeout, `.ask`, invalid reply, incompatible wire version, or missing
runtime emits no hook output, so Codex retains its native approval prompt. Existing
Codex rules, sandbox policy, and permission modes remain authoritative; an operation
that does not produce a native `PermissionRequest` does not reach TapQ.

For `Stop`, Codex supplies the final text through `last_assistant_message`; TapQ does not
parse Codex transcript files. Replies without `?`, inconclusive classifications, and
unanswered interactions complete normally. A hands-free answer produces one continuation
prompt. On the subsequent `stop_hook_active` callback, TapQ skips question interception
to prevent a re-ask loop and reports completion.

For cloud classification on this path, start the runtime with
`--question-classifier openai` and provide `OPENAI_API_KEY`. TapQ uses `gpt-5.6-luna`
through OpenAI's Responses API with strict structured output, no reasoning effort, and a
five-second provider timeout. API failure, an incomplete or refused response, or invalid
output falls through to the deterministic local heuristic and then Codex's normal UI.
Because provider selection is runtime-wide, any Claude Code adapter connected to the
same instance also uses Luna in this mode.

The Codex adapter has no broad strict `PreToolUse` mode, `UserPromptSubmit` steering, or
generic notification-hook equivalent. Completion notification is derived from `Stop`;
these limitations are intentional rather than installation errors.

Codex CLI `0.142.5` is TapQ’s tested lifecycle-hook contract floor. Structured
`request_user_input` uses a versioned Codex CLI `0.146.0` fixture and a real
hook-executable-to-broker test. Older hook contracts are unsupported. This adapter
targets local Codex clients that load user lifecycle hooks; it does not attach to hosted
Codex Cloud tasks.

## Environment variables and local data

| Name | Purpose |
|---|---|
| `TAPQ_DEBUG=1` | Enable verbose console diagnostics |
| `TAPQ_BROKER_DIR` | Override the runtime discovery/socket directory |
| `TAPQ_SPEECH_VOICE` | Voice used for spoken output when `--speech-voice` is not passed. Primary control for the packaged runtime app, which is launched through `open` and takes no flags |
| `TAPQ_CONFIG_DIR` | Override calibration profile storage |
| `CODEX_HOME` | Select the Codex state directory whose `hooks.json` the integration command manages |
| `ANTHROPIC_API_KEY` | Authenticate classification requests selected with `--question-classifier anthropic` |
| `OPENAI_API_KEY` | Authenticate classification requests selected with `--question-classifier openai` |
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
AirPods acquisition, calibration, gesture diagnostics, voice, Claude Code and Codex hook
installation, hook trust, cloud classification, and Linux limitations.
