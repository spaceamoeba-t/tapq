# Codex CLI 0.146.0 hook fixture

`pre-tool-use-request-user-input-single-choice.json` is a sanitized capture of
the complete `PreToolUse` stdin emitted by Codex CLI `0.146.0` for a root
`request_user_input` call. Only session/turn/tool identifiers and local paths
were replaced with stable test values; all keys, nesting, and other values are
preserved.

The capture was also checked against the exact `rust-v0.146.0` serializer and
generated schema:

- `codex-rs/hooks/src/events/pre_tool_use.rs`
- `codex-rs/hooks/schema/generated/pre-tool-use.command.input.schema.json`

Keep fixtures versioned by Codex CLI release. A contract change should add a new
version directory instead of silently rewriting this fixture.
