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

## Cursor agent hook integration

```bash
tapq integration cursor install
tapq integration cursor status
tapq integration cursor uninstall
```

The installer writes only TapQ-managed entries in `~/.cursor/hooks.json`, the user-level
file Cursor reads for every project. It points to the `tapq-cursor-hook` executable
installed beside `tapq`, preserves unrelated top-level data, events, and entries, and
creates a restrictive backup before changing an existing file. Custom installations can
pass `--hooks PATH` and `--hook PATH`. Rerun `install` directly to repair missing or stale
registrations whose command is the current hook, the bare `tapq-cursor-hook` command, or a
recognized TapQ app/build path. Unfamiliar custom executable paths are preserved as
unrelated hooks. Cursor's event arrays hold hook entries directly rather than matcher
groups, so `matcher` is a field on the TapQ entry itself.

Cursor has no hook-trust step. It reloads `hooks.json` when the file changes, so a fresh
install is active without further approval; restart Cursor if an open session does not
pick it up. `status` verifies the recognized layout and reports the documented client
coverage, but Cursor exposes no local command TapQ can query for hook activation.

The current supported slice is deliberately narrow:

- `beforeShellExecution` handles shell commands. TapQ answers `allow` or `deny`; anything
  else emits nothing. Cursor runs this hook for every command rather than only when it
  would prompt, so this is a strict pre-tool gate with no native-only mode. Executions
  Cursor reports as sandboxed are skipped: Cursor never prompts for those, and
  intercepting them would add an interruption Cursor did not intend.
- `preToolUse` matching `Write` and `Delete` handles the mutating file tools. Cursor has no
  pre-edit event of its own — `afterFileEdit` reports an edit that already happened — so
  these two tool types are the edit-approval surface. Cursor documents `tool_input` as an
  open object, so TapQ names the action from the tool type, speaks only a file path it can
  resolve from `file_path`, `path`, or `target_file`, and otherwise says "write a file" or
  "delete a file". Argument values, including a proposed file body, are never spoken.
- `stop` announces a finished turn. Cursor's `stop` payload carries a status and a loop
  count but no final assistant text, so this adapter does not route final-response
  questions, and it never returns `followup_message`: submitting a next user message is a
  turn TapQ was not asked for. Turns Cursor reports as `aborted` or `error` are not
  announced.
- Cursor's agent exposes no hookable question tool, so there is no Cursor equivalent of the
  Claude Code `AskUserQuestion` or Codex `request_user_input` path. Clarifying questions
  stay in Cursor's own interface.
- Broker absence, timeout, an incompatible wire version, invalid data, or no hands-free
  answer emits no hook output. Cursor's documented default is fail-open — a crashed,
  timed-out, or non-JSON hook lets the action continue through Cursor's own permission
  flow — and TapQ never sets `failClosed`.
- `beforeMCPExecution`, `beforeReadFile`, `beforeSubmitPrompt`, `sessionStart`/`sessionEnd`,
  the subagent hooks, and the Tab hooks are unsupported.

Client coverage differs by surface. The Cursor desktop app fires every installed TapQ hook.
`cursor-agent`, the CLI, does not fire `preToolUse`, so writes and deletes stay in Cursor's
native flow there while shell approvals and completion announcements still work. Cursor
Cloud agents read project and enterprise hook files but not the user-level file this
installer manages, so they are outside this integration surface.

The wire formats parsed and emitted by the shim come from Cursor's published hook
reference at <https://cursor.com/docs/agent/hooks>. TapQ ships no versioned Cursor fixture
corpus: unlike the Codex adapter, the payload shapes here are validated against that
documentation rather than against recorded output from a pinned client release.

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
installer again so `~/.claude/settings.json` or the active Codex `hooks.json` points to
the new hook executable. Uninstall integrations before deleting TapQ.
