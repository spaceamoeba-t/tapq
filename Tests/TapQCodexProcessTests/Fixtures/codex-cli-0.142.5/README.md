# Codex CLI 0.142.5 hook fixtures

These are **official-source-derived fixtures**, not runtime captures. They pin
TapQ's advertised lifecycle-hook compatibility floor to the annotated Codex tag
`rust-v0.142.5`:

- tag object: `1b30ea33f13533474db7c3ad6313ef280769e432`
- commit: `26de83050b20f7e0ee211b9739e52ae00ce8032a`

`permission-request-bash.json` derives its complete envelope from:

- `codex-rs/hooks/src/events/permission_request.rs` (`build_command_input`)
- `codex-rs/hooks/src/schema.rs` (`PermissionRequestCommandInput`)
- `codex-rs/hooks/schema/generated/permission-request.command.input.schema.json`
- `codex-rs/hooks/schema/generated/permission-request.command.output.schema.json`
- `codex-rs/hooks/src/events/permission_request.rs` (`parse_completed`, which calls
  `output_parser::parse_permission_request`)
- `codex-rs/core/src/hook_runtime.rs` (the core approval path that executes and applies
  the parsed hook decision)
- `codex-rs/core/tests/suite/hooks.rs`
  (`permission_request_hook_allows_shell_command_without_user_approval` and
  `assert_permission_request_hook_input`)

The upstream test pins `Bash`, a `{ "command": ... }` tool input, and the absence
of `tool_use_id` and approval-attempt metadata. Dynamic identifiers, paths,
model, and the temporary command path were normalized to stable test values.

`stop-question.json` derives its complete envelope from:

- `codex-rs/hooks/src/events/stop.rs` (`StopCommandInput` construction)
- `codex-rs/hooks/src/schema.rs` (`StopCommandInput`)
- `codex-rs/hooks/schema/generated/stop.command.input.schema.json`
- `codex-rs/hooks/schema/generated/stop.command.output.schema.json`
- `codex-rs/hooks/src/events/stop.rs` (`parse_completed`, which calls
  `output_parser::parse_stop` and creates continuation fragments)
- `codex-rs/core/src/hook_runtime.rs` (the core lifecycle path that executes Stop hooks
  and applies their continuation result)
- `codex-rs/core/tests/suite/hooks.rs`
  (`stop_hook_can_block_multiple_times_in_same_turn`)

That upstream contract pins `stop_hook_active` as `false` on the first Stop and
`true` on continuation callbacks. Dynamic identifiers, paths, model, and final
assistant text were normalized to stable values. The representative question
lets TapQ exercise the continuation response without starting Codex or a model.

See the parent fixture README for the exact boundary these process contracts do
and do not cover.
