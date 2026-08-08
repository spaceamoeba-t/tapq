# OpenCode hook process-contract fixtures

These fixtures drive `tapq-opencode-hook` as a real child process and send its
authenticated request through the real Unix-socket transport to `BrokerServer`.
The tests assert the decision JSON written by the executable as well as the
normalized request observed by the broker.

This is a **plugin-relay-to-broker process contract**, not a model-level or
OpenCode end-to-end test. It does not start OpenCode, load the installed plugin
into OpenCode's runtime, contact a model, or prove that OpenCode accepted the
permission reply the plugin issues after reading this executable's stdout. Those
boundaries remain covered by upstream schema provenance and manual compatibility
testing.

Unlike Claude Code and Codex, OpenCode does not invoke a TapQ executable itself:
the stdin envelope here is **TapQ's own plugin↔executable relay format**, not an
OpenCode format. Each field is derived from one OpenCode bus-event property, and
that derivation lives in `OpenCodePluginSource`. The fixtures therefore pin the
relay contract; the OpenCode-shaped half is pinned by the source references in
`OpenCodePluginSource` and `OpenCodeHookShim`.

Each `opencode-<version>` directory documents the OpenCode release whose event
schema the relay was derived from. Add a new version directory when OpenCode
changes a permission or session event; do not silently rewrite an older
release's fixture.

## `opencode-1.18.15`

Both files are **official-source-derived fixtures**, not runtime captures.

`permission-asked-bash.json` is the relay envelope the installed plugin writes
for a `permission.asked` bus event. Its OpenCode-side properties (`id`,
`sessionID`, `permission`, `metadata`) come from the `PermissionRequest` schema
at:

- https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/v1/permission.ts
- https://github.com/anomalyco/opencode/blob/dev/packages/sdk/js/src/v2/gen/types.gen.ts
  (`EventPermissionAsked`)

The `bash` kind and its `metadata.command` shape match the repository's own
permission test fixture at
`packages/opencode/test/acp/permission.test.ts`. Identifiers, paths, and the
command were normalized to stable non-destructive test values.

`session-idle.json` is the relay envelope for OpenCode's completion signal,
derived from:

- https://github.com/anomalyco/opencode/blob/dev/packages/schema/src/session-status-event.ts

OpenCode currently emits both the deprecated `session.idle` event and its
`session.status` replacement for the same transition. The plugin collapses them
into the single relayed event this fixture represents, so there is no separate
`session.status` fixture.
