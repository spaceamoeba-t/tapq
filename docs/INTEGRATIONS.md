# TapQ integration guide

How TapQ connects to each supported agent, what the hooks do, and how questions
and risk assessment behave at runtime. For every command, option, and environment
variable, see the [CLI reference](CLI.md); for the short version, see the
[README](../README.md).

## Claude Code permission policies

TapQ installs one of two mutually exclusive approval paths and does not alter Claude
Code’s own permission rules.

| Policy | Hook behavior | Best fit |
|---|---|---|
| `native` | `PermissionRequest` for `Bash`, `Write`, `Edit`, `MultiEdit`, and `NotebookEdit`; `AskUserQuestion` remains `PreToolUse` | Normal interactive sessions with fewer interruptions |
| `strict` | `PreToolUse` for those tools plus `AskUserQuestion`, before Claude’s permission engine | Workflows where every matched operation should reach TapQ |

Both policies also install `Notification`, `Stop`, and opt-in `UserPromptSubmit`
handling. Only one ordinary approval path is installed at a time.

```bash
tapq integration claude install --permission-policy native
tapq integration claude install --permission-policy strict
```

Important behavior:

- Native mode sees only permission dialogs Claude Code chooses to emit. Existing allow
  rules and `bypassPermissions` can therefore proceed without a TapQ interaction.
- Strict mode receives every matched event. For compatibility with the original runtime,
  TapQ returns allow without waiting for a gesture when Claude reports an auto permission
  mode; Claude Code’s own deny and ask rules still apply.
- TapQ handles one single-select `AskUserQuestion` at a time. Multi-select and
  multiple-question calls remain in Claude Code’s on-screen interface.
- If the hook cannot obtain a valid answer, Claude Code retains control of the normal
  on-screen flow.

## Codex stable hook integration

```bash
tapq integration codex install
tapq integration codex status
tapq integration codex uninstall
```

The installer writes only TapQ-managed groups in `~/.codex/hooks.json`, or in
`$CODEX_HOME/hooks.json` when `CODEX_HOME` is set. It points to the
`tapq-codex-hook` executable installed beside `tapq`, preserves unrelated hook data, and
creates a restrictive backup before changing an existing file. Custom installations can
pass `--hooks PATH` and `--hook PATH`. Rerun `install` directly to repair missing or stale
registrations whose command is the current hook, the bare `tapq-codex-hook` command, or a
recognized TapQ app/build path. Unfamiliar custom executable paths are preserved as
unrelated hooks. Users upgrading from the earlier three-hook layout must rerun `install`
to add `UserPromptSubmit`, then review the changed definitions in `/hooks`.

Installation does not grant hook trust. After every new or changed definition, open
Codex and use `/hooks` to review and trust the four current TapQ registrations at the
selected hook path. Unrecognized custom-path hooks may also remain as unrelated data.
`status` verifies the recognized layout and reports best-effort local Codex compatibility
diagnostics, but Codex remains the authority for trust state; that state is not inspectable
by TapQ.

The current supported slice is deliberately narrow:

- `PreToolUse` handles root-agent `request_user_input` calls containing one
  single-select question with two or three listed options. A TapQ selection is returned
  to the model without opening Codex’s selector.
- `PermissionRequest` handles native approval prompts for `Bash`, `apply_patch`, and
  canonical `mcp__<server>__<tool>` connector calls. Operations that Codex does not
  prompt for never reach TapQ. MCP speech identifies the server and operation without
  reading argument values; the original arguments remain in the local broker request
  context and are not spoken. When the on-device stage-2 reasoner is enabled, it sees
  complete sorted JSON when the argument object fits. Oversized objects become
  key-balanced excerpts across early and late top-level keys, with the start and end of
  each selected value retained. Non-ASCII text, including Unicode line separators, is
  escaped before budgeting, and the complete rendered input including truncation markers
  stays within 4,000 characters. MCP values are not spoken, diagnosed, or cloud-sent.
  MCP review rows omit the arguments, model note, and confidence while retaining the
  interaction outcome and, for a decided row, the closed tier/code.
- `Stop` reports completion and can route an explicit final-response question using
  Codex’s stable `last_assistant_message` field. It does not parse Codex transcripts.
- Matcherless `UserPromptSubmit` provides one fixed root-turn steering hint when a live,
  wire-compatible TapQ runtime advertises `--steering`: use `request_user_input` “when
  available” for choices or confirmation. It reads discovery and opens a bounded,
  EOF-only Unix-socket connection to verify broker liveness, but sends no broker request
  or application data and performs no request/response round-trip. Otherwise it emits
  nothing so Codex keeps its native behavior.
- Broker absence, timeout, an incompatible wire version, invalid data, or no hands-free
  answer emits no hook decision, leaving Codex’s normal selector, approval, or turn flow
  in control. Multiple questions, auto-resolving questions, unsupported option shapes,
  secret questions, and subagent calls also stay native.
- There is no broad Codex strict `PreToolUse` policy or generic notification-hook parity.

In Codex CLI `0.146.0`, Plan mode is the reliable surface for
`request_user_input`. Availability in default mode depends on Codex's
`default_mode_request_user_input` feature. `tapq integration codex status` resolves
`codex` from the caller's `PATH`, reports that executable, and runs only `--version` and
`features list` under a minimal allowlisted environment. A missing executable is distinct
from a resolved executable whose probe fails or times out; neither changes file-status
exit semantics. Because status executes the resolved path, use a trusted `PATH`. Use Codex's
`/hooks` view for the authoritative activation and trust result. A parsed version below
`0.142.5` produces a compatibility warning without changing status exit semantics.

TapQ’s lifecycle-hook contract floor is Codex CLI `0.142.5`. Versioned
`PermissionRequest` and `Stop` fixtures cover that floor; versioned
`request_user_input`, MCP `PermissionRequest`, and `UserPromptSubmit` fixtures target
Codex CLI `0.146.0`. Real hook-process-to-broker contracts cover supported decisions and
native fail-through,
but are not an authenticated model-level Codex end-to-end test. The adapter targets local
Codex clients that load user lifecycle hooks; hosted Codex Cloud tasks are outside this
integration surface.

## OpenCode plugin integration

```bash
tapq integration opencode install
tapq integration opencode status
tapq integration opencode uninstall
```

OpenCode has no hook-registration file. Its documented extension surface is a JavaScript
or TypeScript plugin loaded from the OpenCode configuration directory at startup, so the
unit of installation is one file TapQ owns end to end: `<config>/plugins/tapq.js`, where
`<config>` is `$OPENCODE_CONFIG_DIR`, `$XDG_CONFIG_HOME/opencode`, or
`~/.config/opencode`. Custom installations can pass `--plugin PATH` and `--hook PATH`. The
installer never merges into a file it did not write: an existing `tapq.js` without TapQ's
marker is reported and left untouched, and uninstall removes only TapQ's own file, leaving
every other plugin in the directory alone. A mutation snapshots the previous file to a
restrictive timestamped backup and replaces it atomically.

The generated plugin carries the absolute `tapq-opencode-hook` path, exactly as the Codex
installer carries its hook command. Rerun `install` directly to repair a plugin left stale
by a moved checkout or runtime app, or edited by hand; a matching plugin is a byte-for-byte
no-op that creates no backup. OpenCode reads its plugin directory at process start, so
restart OpenCode after installing, repairing, or removing the plugin.

The plugin is deliberately minimal and dependency-free. It observes two OpenCode bus
events, relays them to the `tapq-opencode-hook` executable over stdin, and applies the
returned decision through OpenCode's own permission API. All policy, broker
authentication, and speech rendering stay in the Swift adapter, so the JavaScript layer
carries no security-relevant logic. Relay work is dispatched without blocking OpenCode's
event bus, so a minutes-long hands-free interaction never stalls the agent.

The current supported slice is deliberately narrow:

- `permission.asked` handles native approval prompts. OpenCode publishes that event only
  when its own permission rules resolve to `ask`, so TapQ sees exactly the prompts the
  wearer would otherwise answer on screen. An allow becomes a one-time `once` reply and a
  deny becomes `reject` with TapQ's reason. TapQ never sends the remembered `always`
  reply: a hands-free answer is scoped to the single prompt it was spoken for. Operations
  OpenCode allows without prompting never reach TapQ.
- `bash`, `edit`, and `webfetch` permissions get kind-specific speech from documented
  scalar metadata: the command, the file path, and the request host. A URL's path and
  query are never spoken because they can carry tokens. Every other permission kind,
  including kinds OpenCode adds later, is spoken from the kind name alone; TapQ never
  serializes a permission's `metadata` object into speech. The original metadata remains
  in the local broker request context, where the on-device stage-2 reasoner can see it.
- `session.idle` reports completion. OpenCode currently emits both that deprecated event
  and its `session.status` replacement for the same transition, so the plugin collapses
  them into one announcement per turn.
- Broker absence, timeout, an incompatible wire version, invalid data, or no hands-free
  answer applies no reply at all, leaving OpenCode's on-screen prompt fully usable. The
  prompt stays pending and answerable on screen for the whole time TapQ is speaking, so
  whichever answer arrives first wins.
- There is no question interception and no final-response continuation. OpenCode has no
  structured single-select question tool comparable to Codex's `request_user_input` or
  Claude Code's `AskUserQuestion`, and no documented way for a plugin to continue a turn
  that has already finished.

The adapter targets the plugin and permission surface of OpenCode `1.18.15`. The
`permission.ask` plugin hook is intentionally unused: it is declared in
`@opencode-ai/plugin`'s types but no OpenCode code path triggers it
([opencode#7006](https://github.com/anomalyco/opencode/issues/7006)), so a plugin built on
it would silently never run. TapQ instead observes the `permission.asked` bus event and
answers over the permission API, which is the mechanism that works today. Replies prefer
the current `POST /permission/{requestID}/reply` route and fall back to the deprecated
session-scoped route exposed by the SDK client OpenCode injects into plugins, so a reply
still lands if either route changes.

Automated coverage runs the real hook process against a real broker over the real Unix
socket. It does not start OpenCode, load the plugin into OpenCode's runtime, or prove that
OpenCode accepted the reply the plugin issues; those remain manual-test-plan items. See
[OPENCODE_ADAPTER_MANUAL_TEST_PLAN.md](OPENCODE_ADAPTER_MANUAL_TEST_PLAN.md).

## Questions in final responses

The Claude Code and Codex adapters examine a final assistant reply only when it contains
`?`. Claude Code obtains that text from its transcript; Codex supplies it directly as
`last_assistant_message`. TapQ can route explicit yes/no questions and questions with
offered alternatives; open-ended, rhetorical, and inconclusive questions remain on
screen.

On macOS 26 or later, TapQ uses Apple's on-device Foundation Model when Apple
Intelligence reports it available. It classifies supported prose questions and produces
a shorter spoken rendering without sending the reply over the network. A deterministic
local heuristic handles structured alternatives when the model is unavailable.

The `--question-classifier` runtime option selects `auto`, `apple`, `anthropic`,
`openai`, or `local`. `auto` is the default and never enables a cloud provider: it uses
Apple's model when available and otherwise uses the local heuristic. Selecting
`anthropic` requires `ANTHROPIC_API_KEY` and uses Claude Haiku. Selecting `openai`
requires `OPENAI_API_KEY` and uses `gpt-5.6-luna` through OpenAI's Responses API. Either
cloud provider may receive up to the final 16,384 characters of the assistant reply for
classification and shortening, which may incur API charges and expose project or user
data contained in that reply. The selection applies to every agent adapter connected to
that runtime instance. See the [security policy](../SECURITY.md).

## Risk-aware confirmation

TapQ can ask a stage-2 risk reasoner how consequential a pending action is and require
more confirmation when it looks destructive. The `--reasoner` runtime option selects `off`
(the default) or `apple`, Apple's on-device Foundation Model, and `--reasoner-mode` selects
`shadow` or `primary`.

```bash
scripts/run-runtime-app.sh serve --reasoner apple
scripts/run-runtime-app.sh serve --reasoner apple --reasoner-mode primary
```

`shadow` is the default: decisions are recorded as diagnostics while the confirmation
actually demanded stays exactly what deterministic policy set. `primary` lets a decision
strengthen the requirement for that request. A reasoner can only ask for *more*
confirmation — it can never approve, deny, or resolve a request — so an abstention, a
timeout, a backend error, or an absent model leaves behavior exactly as it is without one.
A device where the model is unavailable keeps serving without risk escalation and reports
it. Strict-policy requests that Claude reports in an auto permission mode are allowed
before an approval is built, so they are never assessed.

Assessment is on-device only. For canonical Codex MCP calls, the reasoner receives
complete sorted JSON when it fits. Oversized objects are represented by key-balanced
top-level excerpts; all rendered input, including truncation markers, is capped at 4,000
characters after non-ASCII and line-separator escaping. Other supported tools keep their
established command/path context. MCP argument values are never spoken, diagnosed, or
cloud-sent. Their review rows also omit the model's free-text note and confidence,
retaining the interaction outcome and, for a decided row, constrained tier/code metadata. Selecting a
reasoner starts a local shadow-review log at `<broker-dir>/reasoner-log.jsonl`, which
records what each decision asked for against what the user then did; see the
[security policy](../SECURITY.md) for what a line can contain, and the
[CLI reference](CLI.md) for the full option list.
`tapq bench reasoner` scores a reasoner against the labeled corpus in
[bench/](../bench/README.md), and [TAPQ1_STAGE2.md](TAPQ1_STAGE2.md) documents the
design.

## Packaging and install locations

TapQ is currently distributed from source. Build optimized command-line binaries with:

```bash
swift build -c release
.build/release/tapq version
```

On macOS, package the supported live host with:

```bash
scripts/package-runtime-app.sh release
```

The result is `build/TapQRuntime.app`. It is ad-hoc signed for local development by
default; it is not notarized or prepared for redistribution. Set `TAPQ_SIGN_IDENTITY` to
use another local signing identity.

If the checkout or app moves after an agent hook is installed, run that integration’s
installer again so `~/.claude/settings.json`, the active Codex `hooks.json`, or the
installed OpenCode plugin points to the new hook executable. Uninstall integrations before
deleting TapQ.
