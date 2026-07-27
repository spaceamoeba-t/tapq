# Codex Adapter Manual Test Plan

## Purpose

Use this plan to validate the TapQ Codex adapter as one tester on one Mac. It covers:

- Codex hook installation, status, repair, idempotence, backup, and removal.
- Codex hook review and trust.
- Native `PermissionRequest` handling for `Bash` and `apply_patch`.
- `Stop` completion announcements and final-response question continuation.
- Fail-open behavior when TapQ is unavailable.
- Preservation of unrelated Codex hook configuration.

The release contract tested by this plan is the local Codex CLI lifecycle-hook contract
from Codex CLI `0.142.5`. Hosted Codex Cloud tasks are out of scope.

## Supported and unsupported behavior

| Area | Expected adapter behavior |
|---|---|
| `PermissionRequest` for `Bash` | TapQ may answer allow or deny when Codex was already going to prompt. |
| `PermissionRequest` for `apply_patch` | TapQ may answer allow or deny when Codex was already going to prompt. |
| `Stop` without a supported question | Announce `Codex finished.` and let the turn finish normally. |
| `Stop` with a supported final question | Return one hands-free answer as a Codex continuation, then prevent a re-ask loop. |
| Missing runtime, timeout, invalid reply, or unsupported input | Emit no decision and leave Codex's native flow in control. |
| Other tools or operations that Codex does not prompt for | Do not intercept. |

Strict `PreToolUse`, structured `request_user_input`, `UserPromptSubmit`, generic
notification hooks, and hosted Cloud tasks are intentionally unsupported. Do not file a
defect merely because one of those paths stays in Codex's normal interface.

## Test environment

### Required

- macOS 14 or newer.
- Swift 6 and a compatible Xcode toolchain.
- Local Codex CLI `0.142.5` or a version being evaluated against that contract.
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

- Codex reports `0.142.5`, or the newer version under compatibility evaluation.
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
- Install output says `Permission policy: native Codex prompts` and tells the tester to
  review the definitions with `/hooks`.
- The JSON has exactly one TapQ group for each of these events:
  - `PermissionRequest`, matcher `^(Bash|apply_patch)$`.
  - `Stop`, with no matcher.
- Each handler is a command pointing to the quoted absolute hook path, with timeout `260`.
- File mode is `600`.

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
- The two TapQ groups are added.
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
- Reinstall restores one current `PermissionRequest` group and one current `Stop` group.
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
- No TapQ hook remains in `PermissionRequest` or `Stop`.
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
5. Inspect both TapQ entries before trusting them. Confirm the command is exactly the
   current absolute `tapq-codex-hook` path and that the events/matcher match CX-002.
6. Trust both current definitions.
7. Run `/hooks` again.

Expected:

- CLI status is `configured`, but does not claim to know the trust state.
- Before approval, Codex shows the TapQ definitions as needing review or untrusted.
- After approval, Codex shows both exact definitions as trusted.
- No unrelated hook trust or hook definition changes.

Record the active hooks-file backup name before continuing. If the checkout or runtime
app moves later, reinstall and repeat this trust case because the stored command is an
absolute path.

## Phase 3: start the live runtime

In terminal 1, from the TapQ checkout:

```bash
TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --timeout 30
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

## Phase 5: Stop lifecycle behavior

For these cases, start Codex with no approval prompts and instruct it not to call tools:

```bash
codex -C "$CODEX_ADAPTER_WORKSPACE" \
  --sandbox read-only \
  --ask-for-approval never \
  --no-alt-screen
```

### CX-013 — Completion notification without a question — P0

Prompt Codex:

> Do not call tools. Reply with exactly `CODEX ADAPTER COMPLETE.` and nothing else.

Expected:

- The turn completes normally.
- TapQ announces `Codex finished.` once.
- Debug output includes `notification.received` with agent `codex` and event `stop`.
- There is no question or approval interaction.

### CX-014 — Structured final question continues exactly once — P0

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
- The question is not presented a second time when `stop_hook_active` is true.
- The continued turn finishes and produces one final completion notification.

### CX-015 — Deferring a final question leaves it on screen — P0

Repeat CX-014 in a fresh session. Say `skip`, `later`, or `not sure` instead of selecting
an option.

Expected:

- TapQ returns control to the screen.
- Codex does not add `SELECTED: ...` and does not continue automatically.
- The original question remains in Codex's normal interface.
- The turn completes without hanging.

### CX-016 — Open-ended question is not intercepted — P1

Prompt Codex:

> Do not call tools. End with exactly `What name should I use?` and nothing else.

Expected:

- No option-selection prompt is presented because the question has no offered choices.
- The question remains on screen.
- The turn completes normally and may produce the ordinary completion announcement.

### CX-017 — Optional yes/no classifier coverage — P2

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

## Phase 6: fail-open and trust boundaries

### CX-018 — Runtime absent falls back to the native Codex prompt — P0

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

### CX-019 — Runtime absent does not block Stop — P0

With TapQ still stopped, ask Codex to reply with a short statement and no tools.

Expected:

- Codex finishes normally.
- There is no long wait, hook error, or duplicate final response.
- No TapQ announcement occurs because the runtime is absent.

### CX-020 — Untrusted definitions are not treated as active — P1

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

## Input-modality extension

After all P0 adapter cases pass with one reliable modality, repeat CX-008, CX-009, and
CX-014 with every modality claimed for the release:

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

3. Open Codex, run `/hooks`, and verify that neither TapQ entry remains while unrelated
   hooks remain.
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
- `Bash` and `apply_patch` each honor both allow and deny.
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
