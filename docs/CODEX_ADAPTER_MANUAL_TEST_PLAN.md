# Codex Adapter Manual Test Plan

## Purpose

Use this plan to validate the TapQ Codex adapter as one tester on one Mac. It covers:

- Codex hook installation, status, repair, idempotence, backup, and removal.
- Best-effort Codex executable, version, and feature diagnostics plus hook review/trust.
- Root-agent `request_user_input` handling for one single-choice question.
- Native `PermissionRequest` handling for `Bash`, `apply_patch`, and MCP connector tools.
- `Stop` completion announcements and final-response question continuation.
- Opt-in root-turn `UserPromptSubmit` steering with native fail-through.
- On-device MCP reasoner context and its spoken, diagnostic, cloud, and review-log
  boundaries.
- Fail-open behavior when TapQ is unavailable.
- Preservation of unrelated Codex hook configuration.

The lifecycle-hook floor tested by this plan is Codex CLI `0.142.5`. Versioned
`PermissionRequest` and `Stop` process contracts cover that floor; structured
`request_user_input`, MCP `PermissionRequest`, and `UserPromptSubmit` coverage use the
Codex CLI `0.146.0` contract. Those automated contracts run the real hook process
against a broker but do not launch an authenticated model-level Codex session. Required
live cases cover applicable approval, structured-question, and Stop consumption
boundaries. `UserPromptSubmit` model behavior remains an optional observation: its
deterministic assertion is the exact hook output, not proof that a particular model will
follow the nudge. Hosted Codex Cloud tasks are out of scope.

Passing a fixture-driven or direct-hook case proves TapQ's process boundary only. It does
not prove that Codex consumed the hook output or that a model followed selection,
continuation, or steering feedback. Never mark a required live-Codex case as passed from
process-contract evidence alone.

## Supported and unsupported behavior

| Area | Expected adapter behavior |
|---|---|
| Root `request_user_input` with one question and two or three options | TapQ may return one listed choice before Codex opens its native selector. |
| `PermissionRequest` for `Bash` | TapQ may answer allow or deny when Codex was already going to prompt. |
| `PermissionRequest` for `apply_patch` | TapQ may answer allow or deny when Codex was already going to prompt. |
| `PermissionRequest` for `mcp__<server>__<tool>` | TapQ may answer a native connector prompt without speaking its argument values. |
| `Stop` without a supported question | Announce `Codex finished.` and let the turn finish normally. |
| `Stop` with a supported final question | Return one hands-free answer as a Codex continuation, then prevent a re-ask loop. |
| Root `UserPromptSubmit` with live compatible `--steering` discovery | Add the fixed `request_user_input` “when available” nudge after a connection-only liveness probe, without a broker request or application data. |
| Missing runtime, timeout, invalid reply, or unsupported input | Emit no decision and leave Codex's native flow in control. |
| Other tools or operations that Codex does not prompt for | Do not intercept. |

Multiple or auto-resolving questions, unsupported option shapes, and subagent
`request_user_input` calls intentionally stay in Codex’s native flow. Broad strict
`PreToolUse`, generic notification hooks, and hosted Cloud tasks are unsupported.

## Test environment

### Required

- macOS 14 or newer.
- Swift 6 and a compatible Xcode toolchain.
- Local Codex CLI `0.146.0` for the complete plan. Version `0.142.5` remains the
  lifecycle-only compatibility floor.
- A working Codex login.
- Two terminals: one for TapQ and one for Codex.
- For full hands-free coverage, connected in-ear AirPods, completed TapQ calibration,
  and microphone/Speech Recognition permission.

Voice alone can exercise the adapter. Run the modality extension near the end if AirPods
gesture behavior is also part of the release under test.

### Record before testing

| Field | Value |
|---|---|
| Date/time | |
| Commit | |
| macOS version | |
| Hardware / AirPods model | |
| Swift version | |
| Codex version | |
| TapQ version / wire version | |
| Active `CODEX_HOME`, or `default` | |
| Input mode tested: voice / motion / tap | |

## Safe setup

Run all file-changing Codex prompts in a disposable workspace, never in the TapQ checkout.

From the TapQ checkout:

```bash
swift build
scripts/package-runtime-app.sh debug

CODEX_ADAPTER_TAPQ="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq"
CODEX_ADAPTER_HOOK="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq-codex-hook"
CODEX_ADAPTER_RUN_DIR="$(mktemp -d /tmp/tapq-codex-manual.XXXXXX)"
CODEX_ADAPTER_WORKSPACE="$CODEX_ADAPTER_RUN_DIR/workspace"
CODEX_ADAPTER_ISOLATED_HOOKS="$CODEX_ADAPTER_RUN_DIR/isolated-codex/hooks.json"

mkdir -p "$CODEX_ADAPTER_WORKSPACE"
git init "$CODEX_ADAPTER_WORKSPACE"
printf 'before\n' > "$CODEX_ADAPTER_WORKSPACE/target.txt"
```

Keep this terminal open so the variables remain defined. Confirm the paths before any
test:

```bash
printf 'TapQ: %s\nHook: %s\nWorkspace: %s\nIsolated hooks: %s\n' \
  "$CODEX_ADAPTER_TAPQ" \
  "$CODEX_ADAPTER_HOOK" \
  "$CODEX_ADAPTER_WORKSPACE" \
  "$CODEX_ADAPTER_ISOLATED_HOOKS"
```

Do not put API keys, broker tokens, full transcripts, or private source in test evidence.

## Evidence and result convention

For every case, record `Pass`, `Fail`, `Blocked`, or `Not run`, plus:

- Relevant terminal output or a screenshot.
- The Codex prompt used.
- The input given to TapQ.
- The actual file/result.
- Any relevant `TAPQ_DEBUG=1` lines, with paths and tokens redacted if necessary.

A test passes only when both the user-visible result and the listed expected result match.

## Phase 1: build and installer tests

These cases use only the disposable hooks file.

### CX-001 — Version and executable smoke test — P0

Steps:

```bash
codex --version
swift --version
"$CODEX_ADAPTER_TAPQ" version --json
test -x "$CODEX_ADAPTER_HOOK" && echo "hook executable: yes"
```

Expected:

- Codex reports `0.146.0`, or the newer version under compatibility evaluation.
- TapQ prints valid version JSON.
- The hook is executable.
- No command crashes.

### CX-002 — Fresh isolated install and layout — P0

Steps:

```bash
"$CODEX_ADAPTER_TAPQ" integration codex status \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

"$CODEX_ADAPTER_TAPQ" integration codex install \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

"$CODEX_ADAPTER_TAPQ" integration codex status \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

python3 -m json.tool "$CODEX_ADAPTER_ISOLATED_HOOKS"
stat -f 'hooks mode: %OLp' "$CODEX_ADAPTER_ISOLATED_HOOKS"
```

Expected:

- Initial status is `not installed`; final status is `configured`.
- Status reports the detected Codex version, `hooks` state,
  `default_mode_request_user_input` state, Plan/default-mode guidance, and the reminder
  that only Codex can report trust.
- Install output says `Permission policy: native Codex prompts` and tells the tester to
  review the definitions with `/hooks`.
- The JSON has exactly one TapQ group for each of these events:
  - `PreToolUse`, matcher `^request_user_input$`.
  - `PermissionRequest`, matcher `^(Bash|apply_patch|mcp__.+__.+)$`.
  - `Stop`, with no matcher.
  - `UserPromptSubmit`, with no matcher.
- Each handler points to the quoted absolute hook path. `PreToolUse` and
  `PermissionRequest` have timeout `260`; `Stop` has timeout `2147483` (the held
  voice-session boundary's ceiling, ~24.9 days, as the Claude Code installer writes it);
  `UserPromptSubmit` has timeout `5` because it performs only bounded discovery and
  connection-only liveness checks, not a hands-free interaction.
- File mode is `600`.

“Exactly one” is asserted here because the disposable file has no prior TapQ custom path.
On a real existing file, repair removes only the current command, the bare command, and
recognized TapQ app/build paths; an unfamiliar custom executable path is preserved as an
unrelated hook. Users upgrading from the three-hook layout must rerun `install` to add
`UserPromptSubmit` and then retrust the changed definitions.

### CX-003 — Repeated install is idempotent — P0

Steps:

```bash
shasum -a 256 "$CODEX_ADAPTER_ISOLATED_HOOKS"

"$CODEX_ADAPTER_TAPQ" integration codex install \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

shasum -a 256 "$CODEX_ADAPTER_ISOLATED_HOOKS"
find "$(dirname "$CODEX_ADAPTER_ISOLATED_HOOKS")" -maxdepth 1 \
  -name 'hooks.json.tapq-backup-*' -print
```

Expected:

- The hashes before and after are identical.
- There is still one TapQ handler per managed event, with no duplicates.
- No backup is created for the no-op second install.
- The CLI still reminds the tester to verify trust; status does not claim that the hook
  is trusted.

### CX-004 — Preserve unrelated configuration and create a restrictive backup — P0

This case deliberately replaces only the disposable hooks file.

Steps:

```bash
printf '%s\n' \
  '{"marker":"keep-me","hooks":{"SessionStart":[{"matcher":"manual","hooks":[{"type":"command","command":"/usr/bin/true","timeout":8}]}]}}' \
  > "$CODEX_ADAPTER_ISOLATED_HOOKS"
chmod 644 "$CODEX_ADAPTER_ISOLATED_HOOKS"

"$CODEX_ADAPTER_TAPQ" integration codex install \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

python3 -m json.tool "$CODEX_ADAPTER_ISOLATED_HOOKS"
stat -f 'active mode: %OLp' "$CODEX_ADAPTER_ISOLATED_HOOKS"
find "$(dirname "$CODEX_ADAPTER_ISOLATED_HOOKS")" -maxdepth 1 \
  -name 'hooks.json.tapq-backup-*' -exec stat -f '%N mode=%OLp' {} \;
```

Expected:

- Top-level `marker: keep-me` remains.
- The unrelated `SessionStart` group and `/usr/bin/true` handler remain unchanged.
- The four TapQ groups are added.
- The active hooks file and new backup both have mode `600`.
- The newest backup contains the exact pre-install JSON.

### CX-005 — Incomplete layout is detected and repaired — P1

Steps:

1. In the disposable file, remove only the TapQ `Stop` group with an editor.
2. Run the isolated `status` command from CX-002.
3. Run the isolated `install` command from CX-002.
4. Run status and inspect the JSON again.

Expected:

- Status first reports `incomplete`.
- Direct reinstall restores one current `PreToolUse`, `PermissionRequest`, `Stop`, and
  `UserPromptSubmit` group because this fixture uses the current recognized hook path;
  uninstalling first is not required.
- Unrelated JSON remains intact.
- The changed definition requires review in `/hooks`.

### CX-006 — Uninstall removes only TapQ handlers — P0

Steps:

```bash
"$CODEX_ADAPTER_TAPQ" integration codex uninstall \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

"$CODEX_ADAPTER_TAPQ" integration codex status \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

python3 -m json.tool "$CODEX_ADAPTER_ISOLATED_HOOKS"
```

Expected:

- Status is `not installed`.
- The `marker` and unrelated `SessionStart` hook still exist.
- No TapQ hook remains in `PreToolUse`, `PermissionRequest`, `Stop`, or
  `UserPromptSubmit`.
- The CLI tells the tester to confirm removal in Codex.

## Phase 2: install and trust in the active Codex client

The following cases intentionally manage the active Codex hooks file. By default it is
`~/.codex/hooks.json`; when `CODEX_HOME` is set, both the installer and the Codex process
must use that same value.

### CX-007 — Active install and explicit hook trust — P0

Steps:

1. Close other Codex sessions that could edit or reload hooks during this case.
2. Install and check file-level status:

   ```bash
   "$CODEX_ADAPTER_TAPQ" integration codex install
   "$CODEX_ADAPTER_TAPQ" integration codex status
   ```

3. Start an interactive local Codex session.
4. Run `/hooks`.
5. Inspect the four current TapQ registrations before trusting them. Confirm the command
   is exactly the current absolute `tapq-codex-hook` path and that the events/matcher
   match CX-002. Treat any unrecognized custom-path hook as unrelated evidence.
6. Trust the four current definitions.
7. Run `/hooks` again.

Expected:

- CLI status is `configured`, but does not claim to know the trust state.
- Before approval, Codex shows the TapQ definitions as needing review or untrusted.
- After approval, Codex shows all four exact current-path definitions as trusted.
- No unrelated hook trust or hook definition changes.

Record the active hooks-file backup name before continuing. If the checkout or runtime
app moves later, reinstall and repeat this trust case because the stored command is an
absolute path.

## Phase 3: start the live runtime

In terminal 1, from the TapQ checkout:

```bash
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 60
```

Expected readiness output includes:

- `TapQ runtime is ready.`
- A broker socket and discovery path.
- Whether gesture and tap profiles were loaded.
- Whether AirPods motion and voice input are available.

Leave this terminal running. Announcements must remain enabled for the completion tests.
If the packaging step changed the installed hook path, repeat CX-007 before continuing.

For every permission case below, start a fresh Codex session in terminal 2:

```bash
codex -C "$CODEX_ADAPTER_WORKSPACE" \
  --sandbox read-only \
  --ask-for-approval untrusted \
  --no-alt-screen
```

Fresh sessions prevent one case's conversation or permission choice from changing the
next case. Never select a permanent allow rule in Codex during fallback tests.

## Phase 4: native permission requests

### CX-008 — Allow a `Bash` request through TapQ — P0

Prompt Codex:

> Use the shell, not apply_patch, to run exactly `printf 'bash-approved\n' >
> bash-approved.txt`. Do not do anything else. If permission is denied, do not retry or
> use another method. End with a statement, not a question.

When TapQ says the Codex command needs approval, say `approve` or perform the allow
gesture.

Expected:

- TapQ speaks a prompt beginning with `Codex:` and ending with `Approve?`.
- Debug output includes one `approval.received` for agent `codex`, tool `Bash`, source
  `permission_request`.
- Codex proceeds without showing a second native approval prompt.
- `bash-approved.txt` exists and contains `bash-approved`.

### CX-009 — Deny a `Bash` request through TapQ — P0

Prompt Codex:

> Use the shell, not apply_patch, to run exactly `printf 'bash-denied\n' >
> bash-denied.txt`. Do not do anything else. If permission is denied, do not retry or
> use another method. End with a statement, not a question.

Say `deny` or perform the deny gesture.

Expected:

- TapQ receives one `Bash` approval request.
- Codex reports that the operation was denied via TapQ and does not retry it.
- `bash-denied.txt` does not exist.

### CX-010 — Allow an `apply_patch` request through TapQ — P0

Reset the disposable target outside Codex:

```bash
printf 'before\n' > "$CODEX_ADAPTER_WORKSPACE/target.txt"
```

Prompt Codex:

> Use apply_patch exactly once to change the only line in target.txt from `before` to
> `after`. Do not use the shell, Python, or another editing method. If denied, do not
> retry. End with a statement, not a question.

Approve through TapQ.

Expected:

- Debug output identifies tool `apply_patch` and source `permission_request`.
- No second native approval prompt appears.
- `target.txt` contains exactly `after`.

### CX-011 — Deny an `apply_patch` request through TapQ — P0

Reset `target.txt` to `before`, repeat the CX-010 prompt, and deny through TapQ.

Expected:

- Codex reports the denial and does not retry with another tool.
- `target.txt` still contains exactly `before`.

### CX-012 — An operation without a native prompt bypasses approval handling — P1

Start Codex with `--sandbox workspace-write --ask-for-approval never`, ask it to run
`pwd`, and tell it to finish with a statement.

Expected:

- TapQ does not ask for approval because Codex emitted no native `PermissionRequest`.
- The operation completes normally.
- A later `Codex finished.` announcement from `Stop` is allowed and must not be mistaken
  for an approval interaction.

## Phase 5: structured tool questions

In Codex CLI `0.146.0`, Plan mode is the reliable `request_user_input` surface. Start a
fresh session, then use Codex's mode control to switch the root turn to Plan mode and
confirm the UI reports Plan before submitting each prompt:

```bash
codex -C "$CODEX_ADAPTER_WORKSPACE" \
  --sandbox read-only \
  --ask-for-approval never \
  --no-alt-screen
```

Default-mode coverage is optional and must follow the value reported by
`codex features list` or `tapq integration codex status`. To exercise it on `0.146.0`,
start a separate session with `--enable default_mode_request_user_input`; do not mistake
the absence of that feature for a hook failure.

### CX-013 — Select a `request_user_input` option through TapQ — P0

Prompt Codex:

> Call `request_user_input` exactly once with one question. Use header `Marker`, id
> `marker`, and question `Which marker should I print?`. Offer `ALPHA`, `BETA`, and
> `GAMMA`, each with a short description. After receiving the answer, print exactly
> `SELECTED: <answer>` and do not ask again.

Select `BETA` hands-free by saying `two`, or navigate to it and confirm.

Expected:

- TapQ presents the three listed alternatives.
- Runtime debug output records `Selection.selection.resolved`.
- Codex’s native selector does not also open.
- Codex treats the hook feedback as the successful tool response and prints
  `SELECTED: BETA` without re-asking.

### CX-014 — Deferring `request_user_input` returns to Codex’s native selector — P0

Repeat CX-013 in a fresh session. Say `skip`, `later`, or `not sure` instead of selecting
an option.

Expected:

- TapQ emits no hook decision.
- Codex opens its native selector with the three listed alternatives and its free-form
  `Other` choice.
- Choosing `BETA` on screen completes the tool normally and produces `SELECTED: BETA`.
- There is no hook error, denial, or duplicate selector.

Multiple questions, fewer than two or more than three options, duplicate or malformed
labels, secret questions, `autoResolutionMs`, and calls carrying subagent fields are automated
fail-through cases. They do not need to be forced through the live model for this manual
release gate.

## Phase 6: Stop lifecycle behavior

For these cases, start Codex with no approval prompts and instruct it not to call tools:

```bash
codex -C "$CODEX_ADAPTER_WORKSPACE" \
  --sandbox read-only \
  --ask-for-approval never \
  --no-alt-screen
```

### CX-015 — Completion notification without a question — P0

Prompt Codex:

> Do not call tools. Reply with exactly `CODEX ADAPTER COMPLETE.` and nothing else.

Expected:

- The turn completes normally.
- TapQ announces `Codex finished.` once.
- Debug output includes `notification.received` with agent `codex` and event `stop`.
- There is no question or approval interaction.

### CX-016 — Structured final question continues exactly once — P0

Prompt Codex:

> Do not call tools. End your response with exactly these three lines. After receiving a
> choice, print `SELECTED: <choice>` and do not ask another question.
>
> Which marker should I print?
> 1. ALPHA
> 2. BETA

Select `BETA` hands-free by saying `two`, or navigate to it and confirm.

Expected:

- TapQ presents the two alternatives.
- Debug output includes one answered `stop_question` interaction.
- Codex receives the hands-free answer and continues with `SELECTED: BETA`.
- The continued turn's reply (`SELECTED: BETA`) is forwarded and read out — every reply
  is, including on the `stop_hook_active` callback — and no question is re-asked.
- The continued turn finishes; "Codex finished" is not spoken after a reply that was just
  narrated.

### CX-017 — Deferring a final question leaves it on screen — P0

Repeat CX-016 in a fresh session. Say `skip`, `later`, or `not sure` instead of selecting
an option.

Expected:

- TapQ returns control to the screen.
- Codex does not add `SELECTED: ...` and does not continue automatically.
- The original question remains in Codex's normal interface.
- The turn completes without hanging.

### CX-018 — Open-ended question is not intercepted — P1

Prompt Codex:

> Do not call tools. End with exactly `What name should I use?` and nothing else.

Expected:

- No option-selection prompt is presented because the question has no offered choices.
- The question remains on screen.
- The turn completes normally and may produce the ordinary completion announcement.

### CX-019 — Optional yes/no classifier coverage — P2

This is not a portable release gate because yes/no classification depends on an available
local Foundation Model or an explicitly configured classifier. Do not enable a paid cloud
classifier merely to run the core plan.

Prompt Codex to end with `Should I print READY?` and, after an answer, print either
`READY` or `NOT READY` without re-asking.

Expected when a yes/no classifier is available:

- TapQ presents a yes/no interaction.
- The selected answer continues Codex exactly once.
- No re-ask loop occurs.

Expected when none is available: the question stays on screen and Codex completes
normally; record the case as `Not applicable`, not failed.

## Phase 7: fail-open and trust boundaries

### CX-020 — Runtime absent falls back to the native Codex approval prompt — P0

1. Stop TapQ with Control-C and confirm the runtime process has exited.
2. Start a fresh Codex session with the permission settings from Phase 4.
3. Ask Codex to run exactly:

   > Use the shell to run exactly `printf 'native-fallback\n' > native-fallback.txt`.
   > If denied, do not retry. End with a statement, not a question.

4. At Codex's native approval prompt, choose the one-time allow option.

Expected:

- The hook fails open without an error, denial, or hang.
- Codex's normal approval prompt remains usable.
- After the native one-time approval, `native-fallback.txt` contains
  `native-fallback`.

### CX-021 — Runtime absent leaves `request_user_input` native — P0

With TapQ still stopped, start Codex with the structured-question settings from Phase 5
and repeat the CX-013 prompt.

Expected:

- The hook fails through without a denial, error, or long hang.
- Codex’s native selector opens and remains usable.
- Selecting `BETA` on screen produces `SELECTED: BETA`.

### CX-022 — Runtime absent does not block Stop — P0

With TapQ still stopped, ask Codex to reply with a short statement and no tools.

Expected:

- Codex finishes normally.
- There is no long wait, hook error, or duplicate final response.
- No TapQ announcement occurs because the runtime is absent.

### CX-023 — Untrusted definitions are not treated as active — P1

Run this only when changing trust state is acceptable.

1. Reinstall with a different valid hook path or otherwise create a changed TapQ hook
   definition in the disposable/alternate Codex home.
2. Do not trust the changed definition.
3. Start the matching Codex client and inspect `/hooks`.
4. Trigger a native permission prompt.

Expected:

- Codex reports that the changed definition needs review and does not silently trust it.
- TapQ's CLI status can say `configured` while Codex remains the authority on trust.
- The normal Codex approval path remains available.

## Phase 8: MCP connector permission requests

### CX-024 — Allow and deny a native MCP connector request — P1

This case requires a disposable MCP server with a harmless operation that Codex is
configured to ask before invoking. If no such connector is available, record this case
as `Blocked`, not `Pass`. Do not put real secrets or private paths in the test input.

1. Record the connector's canonical Codex tool name, which must have the form
   `mcp__<server>__<tool>`.
2. Ask Codex to invoke it exactly once with a unique non-sensitive sentinel argument,
   such as `tapq-mcp-value-must-not-be-spoken`.
3. Approve through TapQ.
4. Repeat in a fresh Codex session and deny through TapQ.

Expected:

- Both interactions are sourced from Codex's native `PermissionRequest`; a connector
  call that Codex allows without prompting still bypasses TapQ.
- TapQ identifies the humanized MCP server and operation.
- TapQ never speaks the sentinel or any other MCP argument value, including after a
  `details` command.
- Approval runs the connector operation without a second native prompt.
- The denied connector invocation does not execute. Any later model-issued call is a
  separate request and must pass through native approval handling again.
- Runtime absence, deferral, or a malformed broker response leaves Codex's native
  connector approval prompt usable.

## Phase 9: activation diagnostics and prompt steering

### CX-025 — Status explains local Codex activation limits — P1

With the isolated hooks file configured, run:

```bash
"$CODEX_ADAPTER_TAPQ" integration codex status \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"

/usr/bin/env PATH=/nonexistent \
  "$CODEX_ADAPTER_TAPQ" integration codex status \
  --hooks "$CODEX_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CODEX_ADAPTER_HOOK"
```

Expected:

- With Codex on `PATH`, status reports its parsed version plus the observed `hooks` and
  `default_mode_request_user_input` stage/value. On the stock `0.146.0` configuration,
  `hooks` is stable/enabled and `default_mode_request_user_input` is under
  development/disabled. It also prints the terminal-safe resolved executable path.
- Guidance says Plan mode has `request_user_input`; Default-mode availability follows
  `default_mode_request_user_input`.
- The trust line says only Codex can report or grant trust and directs the tester to
  `/hooks`.
- With Codex hidden from `PATH`, status says `not found on PATH` and feature diagnostics
  become unknown without changing the configured file-level result or crashing.
- If `codex` resolves but cannot launch, complete, or drain within the probe bounds,
  status instead says `executable found, but diagnostics failed or timed out` and prints
  the resolved path. This is distinct from a missing executable and still does not change
  file-level status.
- Status executes resolved `codex --version` and `codex features list` commands with a
  minimal allowlisted environment. Run this diagnostic only with a trusted `PATH`; the
  environment filter is not a sandbox for an unexpected executable.
- A parsed version below `0.142.5` prints a compatibility warning.
- Automated probe tests separately cover malformed version and feature output, which
  must likewise remain best-effort.

### CX-026 — Matcherless root-only `UserPromptSubmit` steering — P1

Use this valid root payload for the direct hook checks:

```json
{"hook_event_name":"UserPromptSubmit","session_id":"manual-session","turn_id":"manual-turn","transcript_path":null,"cwd":"/tmp/project","model":"gpt-5.6","permission_mode":"default","prompt":"Plan the deployment."}
```

For example, keep the compact payload in a task-specific shell variable:

```bash
CODEX_ADAPTER_USER_PROMPT='{"hook_event_name":"UserPromptSubmit","session_id":"manual-session","turn_id":"manual-turn","transcript_path":null,"cwd":"/tmp/project","model":"gpt-5.6","permission_mode":"default","prompt":"Plan the deployment."}'
printf '%s\n' "$CODEX_ADAPTER_USER_PROMPT" | "$CODEX_ADAPTER_HOOK"
```

1. With a live runtime started **without** `--steering`, pipe the compact JSON above to
   `"$CODEX_ADAPTER_HOOK"`. Confirm stdout is empty.
2. Stop that runtime and restart it with:

   ```bash
   TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 60 --steering
   ```

3. Pipe the same payload to `"$CODEX_ADAPTER_HOOK"` again and format its stdout with
   `python3 -m json.tool`.
4. Add `"agent_id":"subagent-1"` to the payload and repeat.
5. Stop the runtime and repeat the original root payload once more.

Expected:

- Only step 3 emits JSON. Its sole top-level field is `hookSpecificOutput`; the nested
  event is `UserPromptSubmit` and `additionalContext` is exactly: `When you need the user
  to choose between options or confirm a decision, use request_user_input when available
  rather than asking in plain text.`
- The installed `UserPromptSubmit` group has no matcher. Root/subagent filtering is done
  by the shim, not by a matcher that Codex could interpret differently.
- No broker approval, selection, or notification appears in runtime diagnostics. The
  path reads discovery and opens/closes one bounded EOF-only Unix-socket liveness
  connection, but sends no broker request bytes or application data and performs no
  request/response round-trip.
- Disabled steering, subagent input, and missing discovery all emit nothing and exit
  successfully, preserving Codex's native prompt submission.

An optional authenticated smoke test can now submit a choice/confirmation prompt in a
root Codex turn and observe whether the model chooses `request_user_input`. Record model
behavior, but do not use one model choice as the contract assertion; the exact hook output
above is deterministic.

## Phase 10: on-device MCP reasoner boundary

### CX-027 — MCP arguments inform the reasoner without leaking to other surfaces — P1

This case requires macOS 26 or newer, an available Apple Foundation Model, and the
disposable MCP server from CX-024. If any prerequisite is absent, record `Blocked`.
Configure the harmless fixture operation so its canonical name is neutral but its
arguments include non-sensitive markers such as `action: "publish"`,
`destination: "public"`, and `sentinel: "tapq-mcp-value-must-not-leak"`. The fixture
must remain a no-op even if approved.

Restart TapQ with an isolated runtime directory and no cloud classifier:

```bash
TAPQ_BROKER_DIR="$CODEX_ADAPTER_RUN_DIR/reasoner-runtime" \
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve \
  --timeout 60 \
  --reasoner apple \
  --reasoner-mode shadow \
  --question-classifier local
```

Invoke the fixture once through a native Codex MCP `PermissionRequest`, then approve or
deny through TapQ. Inspect the spoken interaction, sanitized runtime diagnostics, and:

```bash
rg -n 'tapq-mcp-value-must-not-leak|"destination":"public"' \
  "$CODEX_ADAPTER_RUN_DIR/reasoner-runtime/reasoner-log.jsonl"
```

Expected:

- The reasoner records an assessment for the MCP approval. Its decision may identify the
  public/publication risk even though the fixture's tool name is neutral; record the
  exact tier/code as model evidence, not a deterministic assertion.
- Neither speech nor `details` contains any MCP argument value.
- Debug diagnostics and `reasoner-log.jsonl` contain no sentinel or destination value;
  the `rg` command returns no match. Nothing is cloud-sent because the reasoner is
  on-device and the question classifier is explicitly local.
- The MCP review row omits both `note` and `confidence`, while retaining constrained
  `risk_tier`/`code` when the model decided, and the interaction `outcome` plus ordinary
  bookkeeping fields on every row.
- Automated reasoner prompt tests remain the deterministic assertion that a fitting
  canonical argument object is complete sorted JSON; oversized objects use key-balanced
  early/late top-level excerpts with balanced value heads/tails. Non-ASCII scalars and
  line separators are escaped, and all rendered content including truncation markers is
  within 4,000 characters.

## Input-modality extension

After all P0 adapter cases pass with one reliable modality, repeat CX-008, CX-009,
CX-013, and CX-016 with every modality claimed for the release:

| Intent | Motion or hardware | Voice example | Result |
|---|---|---|---|
| Allow / yes | Double nod or double tap | `approve` | |
| Deny / no | Double shake | `deny` | |
| Next option | Stem swipe down | `next` | |
| Previous option | Stem swipe up | `previous` | |
| Confirm option | Double nod or double tap | `select` | |
| Return to screen | Double shake | `skip` | |

For motion-only coverage, restart the runtime with `--no-voice` and confirm its readiness
output says voice is unavailable while the chosen AirPods input still resolves the case.

## Cleanup and restoration

1. Stop the TapQ runtime with Control-C.
2. Remove TapQ only from the active Codex configuration:

   ```bash
   "$CODEX_ADAPTER_TAPQ" integration codex uninstall
   "$CODEX_ADAPTER_TAPQ" integration codex status
   ```

3. Open Codex, run `/hooks`, and verify that none of the four current registrations for
   the selected recognized TapQ path remain while unrelated hooks, including unrecognized
   custom paths, remain.
4. Keep the disposable directory until evidence and defects are filed. When it is no
   longer needed, reveal it in Finder and move that exact directory to Trash:

   ```bash
   open -R "$CODEX_ADAPTER_RUN_DIR"
   ```

5. If any active hooks content is unexpectedly lost, stop testing and restore only from
   the exact timestamped `hooks.json.tapq-backup-*` file captured for this run.

## Exit criteria

The adapter is ready for the tested environment when:

- All P0 cases pass.
- No unrelated hook data or trust entry is lost.
- A supported `request_user_input` choice reaches Codex exactly once, while deferral or
  runtime absence leaves the native selector usable.
- `Bash`, `apply_patch`, and a configured MCP connector each honor both allow and deny.
- Root-turn steering emits only with compatible live `--steering` discovery. Its bounded
  EOF-only liveness connection sends no broker request or application data and performs
  no request/response round-trip; subagents and unavailable runtimes remain silent.
- Status reports useful local Codex compatibility guidance without claiming hook trust.
- When reasoner prerequisites are available, MCP values reach only the bounded on-device
  reasoner prompt and remain absent from speech, diagnostics, cloud processing, and the
  review log; MCP review rows also omit model note and confidence while retaining
  outcome and, for decided rows, constrained tier/code.
- Supported final questions continue exactly once and never loop.
- Runtime absence leaves Codex's native permission and final-response flow usable.
- Active uninstall removes only TapQ-managed hooks.
- No blocker or major defect remains open.

## Defect template

```text
Title: [Codex adapter] <short failure>
Case: CX-###
Commit / TapQ version:
Codex version:
macOS / hardware:
Active CODEX_HOME: default | custom (redacted path if needed)
Hook trust state:
Runtime readiness: motion=<...>, voice=<...>
Steps:
Expected:
Actual:
Repeatability: always | intermittent (<passed>/<runs>)
Evidence: sanitized screenshot/log/hook JSON diff
Regression from known commit/version:
```
