# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately through **Security → Report a
vulnerability** in the project’s GitHub repository. Include affected versions,
impact, reproduction steps, and any suggested mitigation.

If private vulnerability reporting is not available, do not publish sensitive
details in an issue. Contact a maintainer through the private method listed on
their GitHub profile and ask to establish a secure reporting channel.

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

Claude Code hooks send the complete tool input to the local broker over this
socket, including Bash commands and potentially file contents. The adapter also
supplies a normalized summary and detail used by the reference broker, but the
complete tool input is still carried and decoded locally. Hosts and debugging
tools must treat the request as sensitive.

## External data processing

Cloud question classification is opt-in and activates only when
`ANTHROPIC_API_KEY` is present. For a qualifying Claude Code final response,
TapQ reads the trailing assistant reply from the local transcript and may send
up to its final 16,384 characters to Anthropic’s Messages API. That reply can
contain source snippets, paths, secrets, or customer data. Enable the provider
only when such processing is acceptable under your organization’s policy and
Anthropic’s API terms. Unset the environment variable to use the local heuristic
only.

Voice input is active only during a hands-free response window. TapQ requires
on-device recognition when the selected English recognizer supports it;
otherwise Apple’s Speech framework may use Apple’s service. Start the runtime
with `--no-voice` to prevent TapQ from requesting microphone access or starting
speech recognition.

TapQ does not intentionally log or persist the Anthropic API key, submitted
assistant reply, microphone audio, or speech transcript. The bundled debug sink
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

## Authorization and failure behavior

The Claude hook is designed to leave Claude Code’s normal on-screen flow in
control when the broker is unavailable, incompatible, times out, or returns an
invalid response. Hosts and adapters must preserve this property.

Strict policy intercepts matching `PreToolUse` events before Claude Code’s
permission engine. For compatibility with the original runtime, a strict request
whose reported permission mode contains `auto` is allowed without waiting for a
gesture. Native policy instead handles only supported permission dialogs that
Claude Code chooses to emit; Claude allow rules and `bypassPermissions` can
bypass TapQ entirely. Choose the policy as part of the host’s authorization and
risk model.

Gesture, tap, voice, volume, and heuristic outputs are convenience inputs, not
high-assurance authentication. A host remains responsible for deciding which
actions may be approved and for applying its own risk policy.
