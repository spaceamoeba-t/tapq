# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through **Security → Report a
vulnerability** in the project’s GitHub repository. Include affected versions,
impact, reproduction steps, and any suggested mitigation.

If private vulnerability reporting is not available, do not publish sensitive
details in an issue. Email `spaceamoeba_t@gmail.com` and ask to establish a
secure reporting channel before sending sensitive details.

The maintainers will acknowledge a report, investigate it, coordinate a fix when
needed, and agree on disclosure timing with the reporter. Please allow a
reasonable remediation period before public disclosure.

## Supported versions

TapQ has not published its first stable release. Security fixes target the latest
published prerelease and the latest commit on the default branch. Historical releases,
older prereleases, local snapshots, and modified distributions are not guaranteed to
receive fixes.

## Local broker boundary

TapQ runs an authenticated broker over a Unix-domain socket; it does not listen
on a TCP or other network socket. On startup, the runtime:

- Creates a user-private runtime directory with mode `0700`.
- Creates the socket and discovery record with mode `0600`.
- Generates a fresh random 256-bit bearer token.
- Publishes discovery only after the socket is listening.
- Validates the token and wire protocol version on every request.
- Removes its discovery record and socket during normal shutdown.

These controls protect against other operating-system users. They are not a
sandbox between mutually untrusted processes running as the same user: a process
that can read the discovery record can obtain the bearer token.

Agent hooks send the complete supported tool input to the local broker over this socket.
For Claude Code this can include Bash commands and file contents. The Codex slice
forwards native `PermissionRequest` inputs for `Bash`, `apply_patch`, and canonical
`mcp__<server>__<tool>` calls, including their command, patch, or connector arguments.
Adapters also supply normalized summaries and details used by the reference broker, but
the complete input is still carried and decoded locally. Hosts and debugging tools must
treat every request as sensitive.

## External data processing

Cloud question classification is disabled by default. Anthropic activates only with
`--question-classifier anthropic` and `ANTHROPIC_API_KEY`; OpenAI activates only with
`--question-classifier openai` and `OPENAI_API_KEY`. An inherited API key alone does not
enable cloud processing.

For a qualifying final response, TapQ may send up to its final 16,384 characters to the
selected provider's API. Claude Code obtains the reply from its local transcript; Codex
supplies it directly through the stable `last_assistant_message` Stop-hook field. That
reply can contain source snippets, paths, secrets, or customer data. Enable a provider
only when such processing is acceptable under your organization’s policy and the
selected provider's API terms. Restart with `--question-classifier auto` or `local` to
disable cloud processing.

Voice input is active only during a hands-free response window. TapQ requires
on-device recognition when the selected English recognizer supports it;
otherwise Apple’s Speech framework may use Apple’s service. Start the runtime
with `--no-voice` to prevent TapQ from requesting microphone access or starting
speech recognition.

TapQ does not intentionally log or persist either cloud API key, the submitted assistant
reply, microphone audio, or speech transcript. The bundled debug sink
can record tool names, request identifiers, option labels, lifecycle events, and
bounded timestamped motion measurements. Normal CLI output can also expose local
paths. Review both before sharing.

## Stage-2 risk reasoner

The stage-2 risk reasoner (`tapq serve --reasoner apple`) performs on-device inference
only in this release. Apple's Foundation Models framework runs the assessment locally and
no part of the request reaches a network service. Selecting a reasoner never enables cloud
processing; that remains the separate, explicit `--question-classifier` decision above.

What a reasoner is shown is a strictly larger surface than what the question classifier is
shown. The classifier sees assistant reply text. The reasoner sees the established
command/path context for supported closed-schema tools and, for a canonical Codex MCP
call, the server-defined argument object. Complete objects are encoded as sorted JSON.
Oversized objects become key-balanced excerpts spanning early and late top-level keys,
with balanced head/tail excerpts of selected values so one large early field cannot hide
later destinations or flags. Non-ASCII scalars, including Unicode line and paragraph
separators, are escaped before size accounting. The entire rendered input, including its
truncation header, omitted-key notice, and per-value markers, is at most 4,000 characters.
This context stays in process and connector values are not spoken, written to diagnostics,
or sent to a cloud service.

A reasoner's only power is raising the confirmation bar. It cannot approve, deny, resolve,
or weaken a request, and no configuration grants it those. Every failure mode — no model,
an ineligible device, a backend error, an unreadable answer, a confidence below threshold,
or an answer arriving after the wall-clock deadline — leaves the deterministic confirmation
requirement exactly as it was, so a failing reasoner is indistinguishable from an absent
one. A hostile or miscalibrated model can make a user confirm more; it cannot make TapQ
approve anything.

Auto-mode requests are exempt from the reasoner. A strict `PreToolUse` request whose
reported permission mode contains `auto` is allowed by the broker before an approval is
built, so it is never assessed, escalated, or logged. This preserves the compatibility
behavior described under *Authorization and failure behavior*.

Selecting a reasoner also starts a local shadow-review log at
`<broker-dir>/reasoner-log.jsonl`: one JSON line per reasoner-observed approval, recording
the risk tier, rationale code, disclosure-permitted model note and confidence or an
abstention reason, latency, the confirmation the decision implied, and what the user then
decided. The full command line, working directory, adapter detail, and MCP argument values
are deliberately absent. MCP rows also omit the model-generated free-text note, because
an instruction not to copy request data is not a redaction boundary. They omit model
confidence as well,
because a numeric field can echo an argument value. Their constrained tier and rationale
code remain reviewable when a decision exists, and the interaction outcome remains on
every row. The recorded `summary` is the same
text TapQ speaks aloud. For a `Bash` request that summary is the *front* of the command
line — its first six words, capped at 64 characters.
That prefix can carry a real secret: a connection string, a header fragment, a token passed
as an early argument. Treat the file as the same class of local state as `broker.json`. It
is created `0600` inside the `0700` runtime directory, is capped at roughly 5 MB with a
single rotation to `reasoner-log.1.jsonl`, is never transmitted, and is never read back by
TapQ. Deleting either file at any time is safe and costs only review history.

## Local files

Calibration stores thresholds and aggregate quality metrics, not raw motion
streams. `tapq capture` is different: it deliberately writes raw motion records
to the destination chosen by the user.

The Claude integration modifies `~/.claude/settings.json` through an atomic
write and creates a restrictive, timestamped backup beside the settings file.
That backup contains the complete prior settings and may include credentials.
Do not edit the settings concurrently with installation, review backups before
sharing them, and remove obsolete backups according to your retention policy.

The Codex integration similarly modifies `~/.codex/hooks.json`, or
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set, and creates a restrictive backup of
an existing file before atomic replacement. Hook commands and unrelated preserved groups
may contain sensitive paths, arguments, or environment-specific information. Review and
retain these backups with the same care as Claude settings backups.

TapQ does not grant, record, or bypass Codex hook trust. Codex hashes the exact
non-managed command-hook definition and skips new or changed definitions until the user
reviews and trusts them through `/hooks`. Do not use
`--dangerously-bypass-hook-trust` as a substitute for that review.

`tapq integration codex status` resolves `codex` from the invoking process's `PATH` and
may execute that resolved file with two fixed read-only argument sets: `--version`, then
`features list` when the first probe completes. It supplies a minimal allowlisted
environment containing only process/configuration lookup, temporary-directory, and locale
values, with `NO_COLOR=1` and `TERM=dumb`; API keys, SSH agent paths, and unrelated
inherited variables are omitted. This limits accidental credential inheritance but does
not sandbox the executable. A malicious or
unexpected file earlier on `PATH` still runs with the user's authority. Invoke status
only with a trusted `PATH`. TapQ bounds probe time/output and distinguishes “not found on
PATH” from “executable found, but diagnostics failed or timed out”; probe failure never
changes the hooks-file status result.

## Authorization and failure behavior

The Claude Code and Codex hooks are designed to leave the agent’s normal on-screen flow
in control when the broker is unavailable, incompatible, times out, or returns an
invalid response. Hosts and adapters must preserve this property.

Strict policy intercepts matching `PreToolUse` events before Claude Code’s
permission engine. For compatibility with the original runtime, a strict request
whose reported permission mode contains `auto` is allowed without waiting for a
gesture. Native policy instead handles only supported permission dialogs that
Claude Code chooses to emit; Claude allow rules and `bypassPermissions` can
bypass TapQ entirely. Choose the policy as part of the host’s authorization and
risk model.

Codex has native approval behavior only: TapQ answers `PermissionRequest` events for
`Bash`, `apply_patch`, and canonical MCP calls that Codex was already going to show. A
narrow `PreToolUse` hook handles one supported root-agent `request_user_input`; there is
no broad strict policy. Commands and connector calls that Codex permits without a native
prompt do not reach TapQ. Every missing runtime, timeout, `.ask`, invalid response, and
unsupported input emits no decision, preserving Codex’s own sandbox and approval flow.

The matcherless root-only `UserPromptSubmit` hook is advisory and opt-in. It injects one
fixed instruction to use `request_user_input` “when available” only when a live,
wire-compatible local TapQ runtime advertises `--steering`. It reads discovery and opens
then closes a bounded EOF-only Unix-socket connection to verify liveness. That probe
sends no request bytes or application data and performs no broker request/response
round-trip. The hook emits nothing for subagents, invalid input, a stopped runtime, an
incompatible wire version, or disabled steering. It does not create a strict policy or
replace Codex's generic notification behavior. The submitted prompt is validated in the
hook process but is never copied into the fixed output, sent to the broker, or written to
diagnostics.

The Codex Stop hook can turn one explicit final-response question into a continuation
prompt only after the broker returns an answer. It uses `last_assistant_message`, never
the unstable Codex transcript format, and honors `stop_hook_active` to prevent re-ask
loops. Codex CLI `0.142.5` is the tested lifecycle-hook contract floor.

Gesture, tap, voice, volume, and heuristic outputs are convenience inputs, not
high-assurance authentication. A host remains responsible for deciding which
actions may be approved and for applying its own risk policy.
