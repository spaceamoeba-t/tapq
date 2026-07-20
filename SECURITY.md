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

TapQ has not published its first stable release. Security fixes currently
target the latest commit on the default branch. Older commits, local snapshots,
and modified distributions are not guaranteed to receive fixes.

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
For Claude Code this can include Bash commands and file contents. The current Codex
slice forwards native `PermissionRequest` inputs for `Bash` and `apply_patch`, including
the command or patch text. Adapters also supply normalized summaries and details used by
the reference broker, but the complete input is still carried and decoded locally.
Hosts and debugging tools must treat every request as sensitive.

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

Codex currently has native behavior only: TapQ answers `PermissionRequest` events for
`Bash` and `apply_patch` that Codex was already going to show. It does not install a
strict `PreToolUse` policy, intercept structured `request_user_input`, or replace Codex’s
generic notification behavior. Commands and patches that Codex permits without a native
prompt do not reach TapQ. Every missing runtime, timeout, `.ask`, invalid response, and
unsupported input emits no decision, preserving Codex’s own sandbox and approval flow.

The Codex Stop hook can turn one explicit final-response question into a continuation
prompt only after the broker returns an answer. It uses `last_assistant_message`, never
the unstable Codex transcript format, and honors `stop_hook_active` to prevent re-ask
loops. Codex CLI `0.142.5` is the tested lifecycle-hook contract floor.

Gesture, tap, voice, volume, and heuristic outputs are convenience inputs, not
high-assurance authentication. A host remains responsible for deciding which
actions may be approved and for applying its own risk policy.
