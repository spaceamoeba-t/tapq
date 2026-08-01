# Codex CLI 0.146.0 hook fixtures

`pre-tool-use-request-user-input-single-choice.json` is a sanitized capture of
the complete `PreToolUse` stdin emitted by Codex CLI `0.146.0` for a root
`request_user_input` call. Only session/turn/tool identifiers and local paths
were replaced with stable test values; all keys, nesting, and other values are
preserved.

The capture was also checked against the exact `rust-v0.146.0` serializer and
generated schema:

- `codex-rs/hooks/src/events/pre_tool_use.rs`
- `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json`

`permission-request-mcp-memory-create-entities.json` is an
**official-source-derived fixture**, not a runtime capture. It comes from the
exact MCP hook stdin asserted by Codex's
`permission_request_hook_allows_mcp_tool_call` test at:

- tag: `rust-v0.146.0`
- commit: `e363b08c9175ac1cbe5893615dd2cb9ddf95043b`
- test: `codex-rs/core/src/mcp_tool_call_tests.rs`

The canonical tool name `mcp__memory__create_entities` and its complete
`tool_input` value are copied exactly from that upstream test. Only the dynamic
`session_id`, `turn_id`, `cwd`, and `model` values were normalized for this
fixture. Its envelope and response contract were also verified against:

- `codex-rs/hooks/src/events/permission_request.rs`
- `codex-rs/hooks/schema/generated/permission-request.command.input.schema.json`
- `codex-rs/hooks/schema/generated/permission-request.command.output.schema.json`
- `codex-rs/core/src/hook_runtime.rs`

`user-prompt-submit-root.json` is also an **official-source-derived fixture**,
not a runtime capture. Its complete root-thread envelope comes from the same
`rust-v0.146.0` tag and commit above, specifically:

- `codex-rs/hooks/src/events/user_prompt_submit.rs`
- `codex-rs/hooks/src/schema.rs` (`UserPromptSubmitCommandInput`)
- `codex-rs/hooks/schema/generated/user-prompt-submit.command.input.schema.json`
- `codex-rs/hooks/schema/generated/user-prompt-submit.command.output.schema.json`
- `codex-rs/core/tests/suite/hooks.rs`
  (`session_start_runs_before_user_prompt_submit_on_first_turn` and the
  user-prompt blocking/acceptance tests)

The fixture deliberately omits `agent_id` and `agent_type`, as the upstream
serializer does for a root turn. Dynamic identifiers, paths, model, and prompt
text were normalized to stable test values. TapQ uses it to test the local
steering hook process; it is not presented as a capture of model behavior.

Keep fixtures versioned by Codex CLI release. A contract change should add a new
version directory instead of silently rewriting this fixture.

See the parent fixture README for the executable-to-broker boundary these tests
cover and the model/Codex-consumption boundary they intentionally do not claim.
