# OpenCode Adapter Manual Test Plan

## Purpose

Use this plan to validate the TapQ OpenCode adapter as one tester on one Mac. It covers:

- OpenCode plugin installation, status, repair, idempotence, backup, and removal.
- Preservation of unrelated plugins and refusal to overwrite a plugin TapQ did not write.
- Native `permission.asked` handling for `bash`, `edit`, and `webfetch` permissions.
- Completion announcements derived from OpenCode's session-idle transition.
- The speech boundary for permission metadata and web-fetch URLs.
- Fail-open behavior when TapQ is unavailable, deferred, or answered on screen first.

The plugin and permission surface tested by this plan is OpenCode `1.18.15`. Automated
relay-process-to-broker contracts cover the executable edge against a real broker, but
they do not launch OpenCode, load the plugin into OpenCode's runtime, or prove that
OpenCode accepted the reply the plugin issues. Required live cases cover those boundaries.

Passing a fixture-driven or direct-hook case proves TapQ's process boundary only. It does
not prove that OpenCode loaded the plugin or applied its reply. Never mark a required
live-OpenCode case as passed from process-contract evidence alone.

Unlike the Claude Code and Codex adapters, this adapter deliberately has no question
interception and no final-response continuation. Do not file those as defects; see the
unsupported table below.

## Supported and unsupported behavior

| Area | Expected adapter behavior |
|---|---|
| `permission.asked` for `bash` | TapQ may answer allow or deny when OpenCode was already going to prompt. |
| `permission.asked` for `edit` | TapQ may answer allow or deny when OpenCode was already going to prompt. |
| `permission.asked` for `webfetch` | TapQ may answer a prompt while speaking only the request host. |
| `permission.asked` for any other kind | TapQ speaks the kind name alone and never the permission's metadata. |
| Session idle | Announce `OpenCode finished.` exactly once per completed turn. |
| Missing runtime, timeout, invalid reply, or no hands-free answer | Apply no reply and leave OpenCode's on-screen prompt usable. |
| Operations OpenCode does not prompt for | Do not intercept. |

Structured single-select questions, final-response continuation, remembered `always`
replies, and per-project plugin installation are intentionally unsupported. OpenCode's
own permission rules, `opencode.json` configuration, and on-screen prompt remain
authoritative throughout.

## Test environment

### Required

- macOS 14 or newer.
- Swift 6 and a compatible Xcode toolchain.
- Local OpenCode `1.18.15` or the newer version under compatibility evaluation.
- A working OpenCode provider login.
- Two terminals: one for TapQ and one for OpenCode.
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
| OpenCode version | |
| TapQ version / wire version | |
| Active `OPENCODE_CONFIG_DIR` / `XDG_CONFIG_HOME`, or `default` | |
| Input mode tested: voice / motion / tap | |

## Safe setup

Run all file-changing OpenCode prompts in a disposable workspace, never in the TapQ
checkout.

From the TapQ checkout:

```bash
swift build
scripts/package-runtime-app.sh debug

OPENCODE_ADAPTER_TAPQ="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq"
OPENCODE_ADAPTER_HOOK="$PWD/build/TapQRuntime.app/Contents/MacOS/tapq-opencode-hook"
OPENCODE_ADAPTER_RUN_DIR="$(mktemp -d /tmp/tapq-opencode-manual.XXXXXX)"
OPENCODE_ADAPTER_WORKSPACE="$OPENCODE_ADAPTER_RUN_DIR/workspace"
OPENCODE_ADAPTER_ISOLATED_PLUGIN="$OPENCODE_ADAPTER_RUN_DIR/isolated-opencode/plugins/tapq.js"

mkdir -p "$OPENCODE_ADAPTER_WORKSPACE"
git init "$OPENCODE_ADAPTER_WORKSPACE"
printf 'before\n' > "$OPENCODE_ADAPTER_WORKSPACE/target.txt"
```

Keep this terminal open so the variables remain defined. Confirm the paths before any
test:

```bash
printf 'TapQ: %s\nHook: %s\nWorkspace: %s\nIsolated plugin: %s\n' \
  "$OPENCODE_ADAPTER_TAPQ" \
  "$OPENCODE_ADAPTER_HOOK" \
  "$OPENCODE_ADAPTER_WORKSPACE" \
  "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"
```

Do not put API keys, broker tokens, full transcripts, or private source in test evidence.

## Evidence and result convention

For every case, record `Pass`, `Fail`, `Blocked`, or `Not run`, plus:

- Relevant terminal output or a screenshot.
- The OpenCode prompt used.
- The input given to TapQ.
- The actual file/result.
- Any relevant `TAPQ_DEBUG=1` lines, with paths and tokens redacted if necessary.

A test passes only when both the user-visible result and the listed expected result match.

## Phase 1: build and installer tests

These cases use only the disposable plugin path.

### OC-001 — Version and executable smoke test — P0

Steps:

```bash
opencode --version
swift --version
"$OPENCODE_ADAPTER_TAPQ" version --json
test -x "$OPENCODE_ADAPTER_HOOK" && echo "hook executable: yes"
```

Expected:

- OpenCode reports `1.18.15`, or the newer version under compatibility evaluation.
- TapQ prints valid version JSON.
- The hook is executable.
- No command crashes.

### OC-002 — Fresh isolated install and layout — P0

Steps:

```bash
"$OPENCODE_ADAPTER_TAPQ" integration opencode status \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

"$OPENCODE_ADAPTER_TAPQ" integration opencode install \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

"$OPENCODE_ADAPTER_TAPQ" integration opencode status \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

head -1 "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"
grep -n 'const HOOK' "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"
stat -f 'plugin mode: %OLp' "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"
stat -f 'dir mode: %OLp' "$(dirname "$OPENCODE_ADAPTER_ISOLATED_PLUGIN")"
```

Expected:

- Initial status is `not installed`; final status is `installed`.
- Install output says `Permission policy: native OpenCode prompts` and tells the tester to
  restart OpenCode.
- The first line begins with `// tapq-opencode-plugin` and carries the plugin version.
- `const HOOK` is the quoted absolute hook path.
- The plugin file mode is `600` and the created directory mode is `700`.

### OC-003 — Repeated install is idempotent — P0

Steps:

```bash
shasum -a 256 "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"

"$OPENCODE_ADAPTER_TAPQ" integration opencode install \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

shasum -a 256 "$OPENCODE_ADAPTER_ISOLATED_PLUGIN"
find "$(dirname "$OPENCODE_ADAPTER_ISOLATED_PLUGIN")" -maxdepth 1 \
  -name 'tapq.js.tapq-backup-*' -print
```

Expected:

- The hashes before and after are identical.
- No backup is created for the no-op second install.
- The second install reports no restart requirement.

### OC-004 — Stale hook path is detected and repaired — P1

Steps:

1. Install once with a deliberately different hook path:

   ```bash
   "$OPENCODE_ADAPTER_TAPQ" integration opencode install \
     --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
     --hook /usr/bin/true
   ```

2. Run `status` with the real hook path from OC-002.
3. Run `install` with the real hook path.
4. Run `status` and inspect `const HOOK` again.

Expected:

- Step 2 reports `incomplete` and tells the tester to rerun `install`.
- Step 3 rewrites the plugin, reports a restart requirement, and creates exactly one new
  timestamped backup containing the previous plugin text.
- Step 4 reports `installed` with the real hook path.
- Uninstalling first is not required.

### OC-005 — Unrelated plugins and foreign files are preserved — P0

This case deliberately writes only inside the disposable plugin directory.

Steps:

```bash
PLUGIN_DIR="$(dirname "$OPENCODE_ADAPTER_ISOLATED_PLUGIN")"
printf 'export const Mine = async () => ({})\n' > "$PLUGIN_DIR/user-plugin.js"

"$OPENCODE_ADAPTER_TAPQ" integration opencode install \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

ls -l "$PLUGIN_DIR"

# Now make the managed path itself a file TapQ did not write.
printf 'export const NotTapQ = async () => ({})\n' > "$PLUGIN_DIR/foreign.js"
"$OPENCODE_ADAPTER_TAPQ" integration opencode status \
  --plugin "$PLUGIN_DIR/foreign.js" --hook "$OPENCODE_ADAPTER_HOOK"
"$OPENCODE_ADAPTER_TAPQ" integration opencode install \
  --plugin "$PLUGIN_DIR/foreign.js" --hook "$OPENCODE_ADAPTER_HOOK"; echo "exit=$?"
"$OPENCODE_ADAPTER_TAPQ" integration opencode uninstall \
  --plugin "$PLUGIN_DIR/foreign.js" --hook "$OPENCODE_ADAPTER_HOOK"
cat "$PLUGIN_DIR/foreign.js"
```

Expected:

- `user-plugin.js` is untouched by install.
- `status` on the foreign file reports `not installed` and says TapQ did not write it.
- `install` on the foreign file fails with a non-zero exit and an explanatory message.
- `uninstall` on the foreign file leaves it unchanged and says so.
- `foreign.js` still contains its original text.

### OC-006 — Uninstall removes only the TapQ plugin — P0

Steps:

```bash
"$OPENCODE_ADAPTER_TAPQ" integration opencode uninstall \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

"$OPENCODE_ADAPTER_TAPQ" integration opencode status \
  --plugin "$OPENCODE_ADAPTER_ISOLATED_PLUGIN" \
  --hook "$OPENCODE_ADAPTER_HOOK"

ls -l "$(dirname "$OPENCODE_ADAPTER_ISOLATED_PLUGIN")"
```

Expected:

- Status is `not installed`.
- `tapq.js` is gone and a timestamped backup of it remains.
- `user-plugin.js` and `foreign.js` still exist.
- The CLI tells the tester to restart OpenCode.

## Phase 2: install into the active OpenCode configuration

The following cases manage the real OpenCode configuration directory. By default that is
`~/.config/opencode`; when `OPENCODE_CONFIG_DIR` or `XDG_CONFIG_HOME` is set, both the
installer and the OpenCode process must use the same value.

### OC-007 — Active install and plugin load — P0

Steps:

1. Close other OpenCode sessions.
2. Install and check status:

   ```bash
   "$OPENCODE_ADAPTER_TAPQ" integration opencode install
   "$OPENCODE_ADAPTER_TAPQ" integration opencode status
   ```

3. Confirm the reported plugin path is inside the configuration directory OpenCode
   actually uses.
4. Start an interactive OpenCode session in the disposable workspace.

Expected:

- CLI status is `installed` and names the plugin and hook paths.
- OpenCode starts without a plugin load error.
- No unrelated plugin is modified or removed.

Record the plugin backup name, if any, before continuing. If the checkout or runtime app
moves later, reinstall and repeat this case because the stored hook path is absolute.

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
If the packaging step changed the installed hook path, repeat OC-007 before continuing.

For every permission case below, start a fresh OpenCode session in terminal 2 from the
disposable workspace, with OpenCode configured to ask before running the relevant tool.
Fresh sessions prevent one case's conversation or permission choice from changing the
next. Never choose a remembered "always" option in OpenCode during fallback tests.

## Phase 4: native permission requests

### OC-008 — Allow a `bash` permission through TapQ — P0

Prompt OpenCode:

> Use the shell to run exactly `printf 'bash-approved\n' > bash-approved.txt`. Do not do
> anything else. If permission is denied, do not retry or use another method. End with a
> statement, not a question.

When TapQ says the OpenCode command needs approval, say `approve` or perform the allow
gesture.

Expected:

- TapQ speaks a prompt beginning with `OpenCode:` and ending with `Approve?`.
- The spoken summary names the command.
- Debug output includes one `approval.received` for agent `opencode`, tool `bash`, source
  `permission_request`.
- OpenCode's on-screen prompt resolves without the tester touching it.
- `bash-approved.txt` exists and contains `bash-approved`.

### OC-009 — Deny a `bash` permission through TapQ — P0

Prompt OpenCode:

> Use the shell to run exactly `printf 'bash-denied\n' > bash-denied.txt`. Do not do
> anything else. If permission is denied, do not retry or use another method. End with a
> statement, not a question.

Say `deny` or perform the deny gesture.

Expected:

- TapQ receives one `bash` approval request.
- OpenCode reports that the operation was rejected and does not retry it.
- `bash-denied.txt` does not exist.

### OC-010 — Allow an `edit` permission through TapQ — P0

Reset the disposable target outside OpenCode:

```bash
printf 'before\n' > "$OPENCODE_ADAPTER_WORKSPACE/target.txt"
```

Prompt OpenCode:

> Use the edit tool exactly once to change the only line in target.txt from `before` to
> `after`. Do not use the shell or another editing method. If denied, do not retry. End
> with a statement, not a question.

Approve through TapQ.

Expected:

- Debug output identifies tool `edit` and source `permission_request`.
- TapQ speaks the file name, and `details` reports the full path.
- No second on-screen approval prompt is required.
- `target.txt` contains exactly `after`.

### OC-011 — Deny an `edit` permission through TapQ — P0

Reset `target.txt` to `before`, repeat the OC-010 prompt, and deny through TapQ.

Expected:

- OpenCode reports the rejection and does not retry with another tool.
- `target.txt` still contains exactly `before`.

### OC-012 — `webfetch` speaks only the host — P1

Prompt OpenCode to fetch exactly one URL that carries a distinctive non-secret query
value, for example `https://example.com/index.html?tapq-value-must-not-be-spoken=1`.
Approve or deny through TapQ.

Expected:

- TapQ speaks `fetch a page from example.com` and nothing more specific.
- Neither the initial prompt nor a `details` command speaks the path or the query value.
- Debug diagnostics contain no spoken rendering of the query value.
- The decision reaches OpenCode normally.

### OC-013 — An unrecognized permission kind is spoken generically — P1

Trigger any permission kind other than `bash`, `edit`, or `webfetch` that the local
OpenCode configuration prompts for, such as a web search or an external-directory access.
If no such kind can be triggered, record this case as `Blocked`, not `Pass`.

Expected:

- TapQ speaks `approve a <kind name> operation` derived from the kind alone.
- No metadata value from that permission is spoken, including after `details`.
- Allow and deny both reach OpenCode.

### OC-014 — An operation without a prompt bypasses approval handling — P1

Configure OpenCode to allow the relevant tool without asking, then ask it to run a
harmless read-only command and finish with a statement.

Expected:

- TapQ does not ask for approval because OpenCode published no `permission.asked` event.
- The operation completes normally.
- A later completion announcement is allowed and must not be mistaken for an approval
  interaction.

## Phase 5: completion notifications

### OC-015 — Completion announced exactly once — P0

Prompt OpenCode:

> Do not call tools. Reply with exactly `OPENCODE ADAPTER COMPLETE.` and nothing else.

Expected:

- The turn completes normally.
- TapQ announces `OpenCode finished.` exactly once, not twice.
- Debug output includes exactly one `notification.received` with agent `opencode` and
  event `stop` for that turn.

Announcing twice is a defect: OpenCode emits both `session.idle` and `session.status`
for the same transition and the plugin is expected to collapse them.

### OC-016 — Completion after an approved tool call — P1

Repeat OC-008 and let the turn finish.

Expected:

- Exactly one completion announcement follows the approval interaction.
- The approval and the announcement are distinct interactions in debug output.

### OC-017 — No final-response question interception — P1

Prompt OpenCode:

> Do not call tools. End with exactly `What name should I use?` and nothing else.

Expected:

- TapQ announces completion and does not present a question interaction.
- The question remains in OpenCode's normal interface.
- The turn completes without hanging.

This is the documented unsupported behavior, not a defect.

## Phase 6: fail-open boundaries

### OC-018 — Runtime absent falls back to the native prompt — P0

1. Stop TapQ with Control-C and confirm the runtime process has exited.
2. Start a fresh OpenCode session with the permission settings from Phase 4.
3. Ask OpenCode to run exactly:

   > Use the shell to run exactly `printf 'native-fallback\n' > native-fallback.txt`. If
   > denied, do not retry. End with a statement, not a question.

4. At OpenCode's own prompt, choose the one-time allow option.

Expected:

- The plugin fails open without an error, rejection, or hang.
- OpenCode's normal prompt appears promptly and remains usable.
- After the one-time approval, `native-fallback.txt` contains `native-fallback`.

### OC-019 — Deferring returns control to the screen — P0

Restart the runtime, repeat the OC-018 prompt, and say `skip`, `later`, or `not sure`
instead of approving or denying.

Expected:

- TapQ applies no reply.
- OpenCode's prompt is still pending and still answerable on screen.
- Answering on screen completes the operation normally.
- There is no plugin error, rejection, or duplicate prompt.

### OC-020 — Answering on screen while TapQ is speaking — P0

Repeat the OC-018 prompt with the runtime running. While TapQ is still speaking, answer
the prompt on screen instead.

Expected:

- The on-screen answer takes effect immediately.
- The turn proceeds according to the on-screen answer.
- A later hands-free answer for the same prompt does not change the outcome and produces
  no error, no second execution, and no hang.

### OC-021 — Runtime absent does not block completion — P0

With TapQ stopped, ask OpenCode to reply with a short statement and no tools.

Expected:

- OpenCode finishes normally.
- There is no long wait, plugin error, or duplicate final response.
- No TapQ announcement occurs because the runtime is absent.

### OC-022 — Uninstalled plugin restores stock behavior — P1

Uninstall the plugin, restart OpenCode, and repeat OC-008 with the runtime running.

Expected:

- No TapQ interaction occurs.
- OpenCode's own prompt handles the approval.
- Reinstalling and restarting restores TapQ interception.

### OC-023 — A restart is required before a changed plugin takes effect — P1

With OpenCode running, reinstall the plugin with a different valid hook path, then trigger
a permission prompt without restarting OpenCode.

Expected:

- The still-running OpenCode session keeps the previously loaded plugin behavior.
- Restarting OpenCode picks up the new plugin.
- TapQ's CLI status reflects the file on disk, not the behavior of a running session.

## Input-modality extension

After all P0 adapter cases pass with one reliable modality, repeat OC-008, OC-009,
OC-010, and OC-019 with every modality claimed for the release:

| Intent | Motion or hardware | Voice example | Result |
|---|---|---|---|
| Allow / yes | Double nod or double tap | `approve` | |
| Deny / no | Double shake | `deny` | |
| Return to screen | Double shake | `skip` | |

For motion-only coverage, restart the runtime with `--no-voice` and confirm its readiness
output says voice is unavailable while the chosen AirPods input still resolves the case.

## Cleanup and restoration

1. Stop the TapQ runtime with Control-C.
2. Remove TapQ only from the active OpenCode configuration:

   ```bash
   "$OPENCODE_ADAPTER_TAPQ" integration opencode uninstall
   "$OPENCODE_ADAPTER_TAPQ" integration opencode status
   ```

3. Confirm that the TapQ plugin is gone while unrelated plugins in the same directory
   remain, then restart OpenCode and confirm it starts cleanly.
4. Keep the disposable directory until evidence and defects are filed. When it is no
   longer needed, reveal it in Finder and move that exact directory to Trash:

   ```bash
   open -R "$OPENCODE_ADAPTER_RUN_DIR"
   ```

5. If any active plugin content is unexpectedly lost, stop testing and restore only from
   the exact timestamped `tapq.js.tapq-backup-*` file captured for this run.

## Exit criteria

The adapter is ready for the tested environment when:

- All P0 cases pass.
- No unrelated plugin or configuration file is lost or modified.
- `bash` and `edit` permissions each honor both allow and deny, and the decision reaches
  OpenCode without a second on-screen prompt.
- `webfetch` speech is limited to the host, and unrecognized kinds speak only the kind
  name, with no permission metadata reaching speech or diagnostics.
- Completion is announced exactly once per turn.
- Runtime absence, deferral, and an on-screen answer each leave OpenCode's own permission
  flow correct and usable.
- Installing over a foreign plugin fails safely, and uninstall removes only TapQ's file.
- No blocker or major defect remains open.

## Defect template

```text
Title: [OpenCode adapter] <short failure>
Case: OC-###
Commit / TapQ version:
OpenCode version:
macOS / hardware:
Active OPENCODE_CONFIG_DIR / XDG_CONFIG_HOME: default | custom (redacted path if needed)
Installed plugin path and marker line:
Runtime readiness: motion=<...>, voice=<...>
Steps:
Expected:
Actual:
Repeatability: always | intermittent (<passed>/<runs>)
Evidence: sanitized screenshot/log/plugin diff
Regression from known commit/version:
```
