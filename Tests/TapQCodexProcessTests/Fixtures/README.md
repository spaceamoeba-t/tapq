# Codex hook process-contract fixtures

These fixtures drive `tapq-codex-hook` as a real child process and, for
broker-backed cases, send its authenticated request through the real Unix-socket
transport to `BrokerServer`. The tests assert the Codex hook JSON written by the
executable as well as the normalized request observed by the broker.

This is an **executable-to-broker process contract**, not a model-level or Codex
CLI end-to-end test. It does not start Codex, require a Codex login, contact a
model, prove that a particular Codex build consumes the hook stdout, or prove
that a model follows TapQ's continuation/selection feedback. Those boundaries
remain covered by upstream source/schema provenance and manual compatibility
testing.

Each `codex-cli-<version>` directory documents whether its inputs are sanitized
captures or official-source-derived fixtures. Add a new version directory when
Codex changes a hook envelope; do not silently rewrite an older release's
fixture.
