# Cursor Adapter Manual Test Plan

## Purpose

Use this plan to validate the TapQ Cursor adapter as one tester on one Mac. It covers:

- Cursor hook installation, status, repair, idempotence, backup, and removal.
- `beforeShellExecution` approvals for non-sandboxed shell commands.
- `preToolUse` approvals for the `Write` and `Delete` file tools.
- `stop` completion announcements.
- Fail-open behavior when TapQ is unavailable.
- Preservation of unrelated Cursor hook configuration.
- The documented client-coverage difference between the Cursor desktop app and
  `cursor-agent`.

Unlike the Codex adapter, this adapter ships no versioned fixture corpus recorded from a
pinned client release. Its payload parsing and hook output follow Cursor's published hook
reference at <https://cursor.com/docs/agent/hooks>, and the unit tests assert against
fixtures written from that reference. This plan is therefore the only place the real wire
format is confirmed. Record the exact Cursor version used; a payload mismatch is a valid
defect against this adapter, not against the plan.

Passing a direct-hook case proves TapQ's process boundary only. It does not prove that
Cursor consumed the hook output. Never mark a required live-Cursor case as passed from
process evidence alone.

## Supported and unsupported behavior

| Area | Expected adapter behavior |
|---|---|
| `beforeShellExecution` for a non-sandboxed command | TapQ may answer allow or deny before Cursor runs the command. |
| `beforeShellExecution` for a sandboxed command | Do not intercept; Cursor does not prompt for these. |
| `preToolUse` matching `Write` | TapQ may answer allow or deny before a file write. |
| `preToolUse` matching `Delete` | TapQ may answer allow or deny before a file delete. |
| `stop` with status `completed` | Announce `Cursor finished.` and let the turn end normally. |
| `stop` with status `aborted` or `error` | Say nothing; the user already ended the turn. |
| Missing runtime, timeout, invalid reply, or unsupported input | Emit no hook output and leave Cursor's own flow in control. |
| Clarifying questions from the agent | Stay in Cursor's interface; Cursor exposes no hookable question tool. |

`beforeMCPExecution`, `beforeReadFile`, `beforeSubmitPrompt`, `afterFileEdit`, the
session-lifecycle hooks, the subagent hooks, and the Tab hooks are intentionally
unsupported. Cursor Cloud agents do not read the user-level hook file this installer
manages and are out of scope.

The Cursor adapter is strict-only. Cursor runs `beforeShellExecution` for every command
rather than only when it would prompt, so there is no equivalent of Claude Code's `native`
permission policy: expect an interaction for each non-sandboxed command.

## Test environment

### Required

- macOS 14 or newer.
- Swift 6 and a compatible Xcode toolchain.
- Cursor desktop app, signed in, with agent mode available.
- `cursor-agent` on `PATH` for the client-coverage case.
- Two terminals: one for TapQ and one for shell inspection.
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
| Cursor app version | |
| `cursor-agent --version` | |
| TapQ version / wire version | |
| Input mode tested: voice / motion / tap | |

## Safe setup

Run all file-changing Cursor prompts in a disposable workspace, never in the TapQ checkout.

From the TapQ checkout:

```bash
swift build
scripts/package-runtime-app.sh debug

CURSOR_ADAPTER_TAPQ="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq"
CURSOR_ADAPTER_HOOK="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq-cursor-hook"
CURSOR_ADAPTER_RUN_DIR="$(mktemp -d /tmp/tapq-cursor-manual.XXXXXX)"
CURSOR_ADAPTER_WORKSPACE="$CURSOR_ADAPTER_RUN_DIR/workspace"
CURSOR_ADAPTER_ISOLATED_HOOKS="$CURSOR_ADAPTER_RUN_DIR/isolated-cursor/hooks.json"

mkdir -p "$CURSOR_ADAPTER_WORKSPACE"
git init "$CURSOR_ADAPTER_WORKSPACE"
printf 'before\n' > "$CURSOR_ADAPTER_WORKSPACE/target.txt"
printf 'delete me\n' > "$CURSOR_ADAPTER_WORKSPACE/stale.txt"
```

Keep this terminal open so the variables remain defined. Confirm the paths before any
test:

```bash
printf 'TapQ: %s\nHook: %s\nWorkspace: %s\nIsolated hooks: %s\n' \
  "$CURSOR_ADAPTER_TAPQ" \
  "$CURSOR_ADAPTER_HOOK" \
  "$CURSOR_ADAPTER_WORKSPACE" \
  "$CURSOR_ADAPTER_ISOLATED_HOOKS"
```

Do not put API keys, broker tokens, full transcripts, or private source in test evidence.

## Evidence and result convention

For every case, record `Pass`, `Fail`, `Blocked`, or `Not run`, plus:

- Relevant terminal output or a screenshot.
- The Cursor prompt used.
- The input given to TapQ.
- The actual file/result.
- Any relevant `TAPQ_DEBUG=1` lines, with paths and tokens redacted if necessary.

A test passes only when both the user-visible result and the listed expected result match.

## Phase 1: build and installer tests

These cases use only the disposable hooks file.

### CU-001 — Version and executable smoke test — P0

Steps:

```bash
cursor-agent --version
swift --version
"$CURSOR_ADAPTER_TAPQ" version --json
test -x "$CURSOR_ADAPTER_HOOK" && echo "hook executable: yes"
```

Expected:

- Cursor reports the version under evaluation; record it.
- TapQ prints valid version JSON.
- The hook is executable.
- No command crashes.

### CU-002 — Fresh isolated install and layout — P0

Steps:

```bash
"$CURSOR_ADAPTER_TAPQ" integration cursor status \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

"$CURSOR_ADAPTER_TAPQ" integration cursor install \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

"$CURSOR_ADAPTER_TAPQ" integration cursor status \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

python3 -m json.tool "$CURSOR_ADAPTER_ISOLATED_HOOKS"
stat -f 'hooks mode: %OLp' "$CURSOR_ADAPTER_ISOLATED_HOOKS"
```

Expected:

- Initial status is `not installed`; final status is `configured`.
- Install output names the hooks file, the hook path, the permission policy
  `every non-sandboxed shell, write, and delete`, and the Cursor reload reminder.
- Status reports the client-coverage line stating that `cursor-agent` does not fire
  `preToolUse`.
- The root object has `"version": 1`.
- `hooks` has exactly one TapQ entry for each of:
  - `beforeShellExecution`, with no `matcher`.
  - `preToolUse`, `matcher` `Write`.
  - `preToolUse`, `matcher` `Delete`.
  - `stop`, with no `matcher`.
- Each entry has `"type": "command"` and the quoted absolute hook path. The three
  approval entries have timeout `260`; `stop` has timeout `8` because it only sends a
  fire-and-forget notification.
- No unmanaged event key (`beforeMCPExecution`, `beforeReadFile`, `beforeSubmitPrompt`,
  `afterFileEdit`, `sessionStart`, the Tab hooks) is present.
- File mode is `600`.

"Exactly one" is asserted here because the disposable file has no prior TapQ custom path.
On a real existing file, repair removes only the current command, the bare command, and
recognized TapQ app/build paths; an unfamiliar custom executable path is preserved as an
unrelated hook.

### CU-003 — Repeated install is idempotent — P0

Steps:

```bash
shasum -a 256 "$CURSOR_ADAPTER_ISOLATED_HOOKS"

"$CURSOR_ADAPTER_TAPQ" integration cursor install \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

shasum -a 256 "$CURSOR_ADAPTER_ISOLATED_HOOKS"
find "$(dirname "$CURSOR_ADAPTER_ISOLATED_HOOKS")" -maxdepth 1 \
  -name 'hooks.json.tapq-backup-*' -print
```

Expected:

- The hashes before and after are identical.
- There is still one TapQ entry per managed registration, with no duplicates.
- No backup is created for the no-op second install.

### CU-004 — Preserve unrelated configuration and create a restrictive backup — P0

This case deliberately replaces only the disposable hooks file.

Steps:

```bash
printf '%s\n' \
  '{"version":1,"marker":"keep-me","hooks":{"sessionStart":[{"command":"/usr/bin/true"}],"beforeShellExecution":[{"command":"/usr/bin/true","matcher":"^git push"}]}}' \
  > "$CURSOR_ADAPTER_ISOLATED_HOOKS"
chmod 644 "$CURSOR_ADAPTER_ISOLATED_HOOKS"

"$CURSOR_ADAPTER_TAPQ" integration cursor install \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

python3 -m json.tool "$CURSOR_ADAPTER_ISOLATED_HOOKS"
stat -f 'active mode: %OLp' "$CURSOR_ADAPTER_ISOLATED_HOOKS"
find "$(dirname "$CURSOR_ADAPTER_ISOLATED_HOOKS")" -maxdepth 1 \
  -name 'hooks.json.tapq-backup-*' -exec stat -f '%N mode=%OLp' {} \;
```

Expected:

- Top-level `marker: keep-me` remains, and `version` stays `1`.
- The unrelated `sessionStart` entry and the unrelated `beforeShellExecution` entry with
  matcher `^git push` both remain unchanged.
- The four TapQ entries are added alongside them.
- The active hooks file and new backup both have mode `600`.
- The newest backup contains the exact pre-install JSON.

### CU-005 — Incomplete layout is detected and repaired — P1

Steps:

1. In the disposable file, delete only the TapQ `stop` entry with an editor.
2. Run the isolated `status` command from CU-002.
3. Run the isolated `install` command from CU-002.
4. Run status and inspect the JSON again.

Expected:

- Status first reports `incomplete` and tells the tester to rerun `install`.
- Direct reinstall restores exactly one `beforeShellExecution`, two `preToolUse`, and one
  `stop` TapQ entry; uninstalling first is not required.
- Unrelated JSON remains intact.

### CU-006 — Uninstall removes only TapQ entries — P0

Steps:

```bash
"$CURSOR_ADAPTER_TAPQ" integration cursor uninstall \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

"$CURSOR_ADAPTER_TAPQ" integration cursor status \
  --hooks "$CURSOR_ADAPTER_ISOLATED_HOOKS" \
  --hook "$CURSOR_ADAPTER_HOOK"

python3 -m json.tool "$CURSOR_ADAPTER_ISOLATED_HOOKS"
```

Expected:

- Status is `not installed`.
- The `marker`, the unrelated `sessionStart` entry, and the unrelated
  `beforeShellExecution` entry still exist.
- `preToolUse` and `stop` are removed entirely because only TapQ entries were in them.
- No TapQ hook remains anywhere in the file.

## Phase 2: install in the active Cursor client

The following cases manage the real user-level hooks file at `~/.cursor/hooks.json`.

### CU-007 — Active install and reload — P0

Steps:

1. Quit Cursor.
2. Back up any existing file:

   ```bash
   cp ~/.cursor/hooks.json ~/.cursor/hooks.json.pre-tapq 2>/dev/null || true
   "$CURSOR_ADAPTER_TAPQ" integration cursor install --hook "$CURSOR_ADAPTER_HOOK"
   "$CURSOR_ADAPTER_TAPQ" integration cursor status --hook "$CURSOR_ADAPTER_HOOK"
   ```

3. Start Cursor and open `$CURSOR_ADAPTER_WORKSPACE` as the workspace.

Expected:

- Status reports `configured` with the real hooks path.
- Cursor starts normally with no hook error.
- Any pre-existing user hooks remain listed in the file.

Record whether Cursor surfaced a hooks output/diagnostic channel and whether it named the
TapQ entries. Cursor has no trust prompt; if this build introduces one, record it as a
finding.

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
If the packaging step changed the installed hook path, repeat CU-007 before continuing.

Start a fresh Cursor agent conversation for each case below so one case's decision does not
change the next. Never grant a permanent allow rule in Cursor during fallback tests.

## Phase 4: shell approvals

### CU-008 — Allow a shell command through TapQ — P0

Prompt Cursor's agent:

> Run exactly `printf 'shell-approved\n' > shell-approved.txt` in the terminal. Do not do
> anything else and do not use a file-writing tool. If it is denied, do not retry. End
> with a statement, not a question.

When TapQ speaks the request, say `approve` or perform the allow gesture.

Expected:

- TapQ speaks a prompt beginning with `Cursor:` and ending with `Approve?`.
- The spoken summary names the command, for example `run printf 'shell-approved…`.
- Debug output includes one `approval.received` for agent `cursor`, tool `Shell`, source
  `pre_tool_use`.
- Cursor runs the command without also showing its own approval prompt.
- `shell-approved.txt` exists and contains `shell-approved`.

### CU-009 — Deny a shell command through TapQ — P0

Repeat CU-008 with `shell-denied.txt` and say `deny` or perform the deny gesture.

Expected:

- TapQ receives one `Shell` approval request.
- Cursor reports that the command was denied and does not retry it.
- `shell-denied.txt` does not exist.
- The agent-visible message contains the TapQ denial reason.

### CU-010 — Deferral returns the command to Cursor — P0

Repeat CU-008 with `shell-deferred.txt`. When TapQ speaks, let the interaction time out or
answer with the skip/return input for the modality under test.

Expected:

- TapQ emits no decision.
- Cursor's own approval flow appears and remains usable.
- Choosing a one-time allow in Cursor creates `shell-deferred.txt`.

### CU-011 — A sandboxed command is not intercepted — P1

Configure Cursor to run terminal commands in its sandbox, then ask the agent to run `pwd`
and finish with a statement.

Expected:

- TapQ does not speak an approval request for the sandboxed command.
- Debug output shows no `approval.received` for it.
- A later `Cursor finished.` announcement is allowed and must not be mistaken for an
  approval interaction.

If this Cursor build never reports `sandbox: true` in the hook payload, record that and
mark the case `Blocked` rather than `Fail`.

## Phase 5: file-tool approvals

These cases require the Cursor desktop app; `cursor-agent` does not fire `preToolUse`.

### CU-012 — Allow a `Write` through TapQ — P0

Reset the target outside Cursor:

```bash
printf 'before\n' > "$CURSOR_ADAPTER_WORKSPACE/target.txt"
```

Prompt Cursor's agent:

> Edit target.txt so its only line is `after`. Use your file-editing tool, not the
> terminal. If denied, do not retry. End with a statement, not a question.

Approve through TapQ.

Expected:

- TapQ speaks a request naming the file, for example `write the file target.txt`.
- The spoken text never contains the proposed file contents.
- Debug output identifies tool `Write` and source `pre_tool_use`.
- `target.txt` contains exactly `after`.

If TapQ says `write a file` without a filename, the payload used an unexpected path key.
Record the observed `tool_input` keys — with values redacted — as a finding.

### CU-013 — Deny a `Write` through TapQ — P0

Reset `target.txt` to `before`, repeat the CU-012 prompt, and deny through TapQ.

Expected:

- Cursor reports the denial and does not retry with the terminal.
- `target.txt` still contains exactly `before`.

### CU-014 — Allow and deny a `Delete` through TapQ — P1

Prompt Cursor's agent to delete `stale.txt` using its file tool, not the terminal. Deny
first, then repeat in a fresh conversation and allow.

Expected:

- TapQ speaks `delete the file stale.txt`.
- After the denial, `stale.txt` still exists.
- After the approval, `stale.txt` is gone.

If this Cursor build performs deletes through the terminal rather than a `Delete` tool,
record that and mark the case `Blocked`.

## Phase 6: completion announcements

### CU-015 — Completion announcement — P0

Ask the agent for a one-sentence statement that uses no tools.

Expected:

- Cursor finishes normally.
- TapQ announces `Cursor finished.` exactly once.
- Debug output includes one `notification.received` for agent `cursor`, event `stop`.
- No continuation prompt or extra user message is submitted.

### CU-016 — An interrupted turn is not announced — P1

Start a long agent task and stop it from Cursor's interface before it finishes.

Expected:

- TapQ says nothing.
- Debug output shows no `stop` notification, or shows the shim declining a non-`completed`
  status.

### CU-017 — A final question stays on screen — P1

Ask the agent a question it must answer with a clarifying question of its own.

Expected:

- TapQ announces completion but does not read the question or ask for an answer.
- Cursor's question remains on screen and is answered normally by typing.

This is the documented limit of the slice: Cursor's `stop` payload carries no final
assistant text, so the adapter cannot route final-response questions the way the Codex
adapter does.

## Phase 7: fail-open boundaries

### CU-018 — Runtime absent falls back to Cursor's own approval — P0

1. Stop TapQ with Control-C and confirm the runtime process has exited.
2. Start a fresh Cursor conversation.
3. Repeat the CU-008 prompt with `native-fallback.txt`.
4. At Cursor's own approval prompt, choose the one-time allow option.

Expected:

- The hook fails open without an error, denial, or hang longer than a second or two.
- Cursor's normal approval prompt remains usable.
- After the native one-time approval, `native-fallback.txt` contains `native-fallback`.

### CU-019 — Runtime absent leaves file edits usable — P0

With TapQ still stopped, repeat CU-012.

Expected:

- The hook fails through without a denial, error, or long hang.
- Cursor's normal edit flow completes and `target.txt` contains `after`.

### CU-020 — Runtime absent does not block completion — P0

With TapQ still stopped, ask the agent for a short statement with no tools.

Expected:

- Cursor finishes normally.
- There is no long wait, hook error, or duplicate final response.
- No TapQ announcement occurs because the runtime is absent.

### CU-021 — Direct hook process fail-open — P1

With TapQ stopped, drive the hook directly:

```bash
printf '%s' '{"conversation_id":"conv-manual","generation_id":"gen-manual","hook_event_name":"beforeShellExecution","cursor_version":"manual","workspace_roots":["/tmp"],"command":"printf hi","cwd":"/tmp","sandbox":false}' \
  | "$CURSOR_ADAPTER_HOOK"; echo "exit: $?"
```

Expected:

- No stdout.
- Exit status `0`.

Repeat with the runtime running and a deferred answer; the result must be identical.

## Phase 8: client coverage

### CU-022 — `cursor-agent` fires shell hooks but not `preToolUse` — P1

With the runtime running and hooks installed, run a short `cursor-agent` session in the
disposable workspace. Ask it to run a terminal command, then ask it to edit a file.

Expected:

- The terminal command produces a TapQ approval request.
- The file edit does not, and Cursor's normal flow handles it.
- The status command's client-coverage line matches what was observed.

If a newer `cursor-agent` does fire `preToolUse`, record that: it is a documentation
update, not an adapter defect.

## Input-modality extension

After all P0 adapter cases pass with one reliable modality, repeat CU-008, CU-009, CU-012,
and CU-015 with every modality claimed for the release:

| Intent | Motion or hardware | Voice example | Result |
|---|---|---|---|
| Allow / yes | Double nod or double tap | `approve` | |
| Deny / no | Double shake | `deny` | |
| Return to screen | Double shake | `skip` | |

For motion-only coverage, restart the runtime with `--no-voice` and confirm its readiness
output says voice is unavailable while the chosen AirPods input still resolves the case.

## Cleanup and restoration

1. Stop the TapQ runtime with Control-C.
2. Remove TapQ from the active Cursor configuration:

   ```bash
   "$CURSOR_ADAPTER_TAPQ" integration cursor uninstall
   "$CURSOR_ADAPTER_TAPQ" integration cursor status
   ```

3. Inspect `~/.cursor/hooks.json` and verify that no TapQ entry remains while unrelated
   hooks, including unrecognized custom paths, remain.
4. Keep the disposable directory until evidence and defects are filed. When it is no
   longer needed, reveal it in Finder and move that exact directory to Trash:

   ```bash
   open -R "$CURSOR_ADAPTER_RUN_DIR"
   ```

5. If any active hooks content is unexpectedly lost, stop testing and restore only from
   the exact timestamped `hooks.json.tapq-backup-*` file captured for this run, or from
   `~/.cursor/hooks.json.pre-tapq`.

## Exit criteria

The adapter is ready for the tested environment when:

- All P0 cases pass.
- No unrelated hook data is lost.
- Shell commands, writes, and deletes each honor both allow and deny, and a deferral
  returns control to Cursor.
- Sandboxed executions are not intercepted, or the case is recorded as blocked with the
  observed payload.
- Spoken text never contains a proposed file body or other argument value.
- Completion is announced exactly once for a completed turn and never for an interrupted
  one.
- Runtime absence leaves Cursor's own permission and turn flow usable on every managed
  event.
- Uninstall removes only TapQ-managed entries.
- The observed hook payload fields match the documented reference, or every difference is
  filed.
- No blocker or major defect remains open.

## Defect template

```text
Title: [Cursor adapter] <short failure>
Case: CU-###
Commit / TapQ version:
Cursor app version / cursor-agent version:
macOS / hardware:
Client surface: desktop app | cursor-agent
Runtime readiness: motion=<...>, voice=<...>
Steps:
Expected:
Actual:
Observed hook payload keys (values redacted):
Repeatability: always | intermittent (<passed>/<runs>)
Evidence: sanitized screenshot/log/hook JSON diff
Regression from known commit/version:
```
