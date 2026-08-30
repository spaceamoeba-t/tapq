# TapQ

## Testing

While iterating, run the slim check plus whatever suites you touched:

    scripts/slim-check.sh SuiteYouTouchedTests OtherTests

Warm, that is ~45s for 385 tests. It is the ratified loop. Do NOT sweep every
suite in its own container to verify a change: the exhaustive run (~2,500
tests, macOS + Linux) is CI's job and lands ~3 minutes after a push. A full
local sweep is reserved for when CI is unavailable or a maintainer asks.

`scripts/linux-check.sh` is the CI mirror (release build + bare `swift test`).
It hangs locally — treat it as CI-only and leave it alone.

Container facts, all hard-won — do not rediscover them by hanging:

- This host has Command Line Tools only: `swift build` works, `swift test` does
  not (no XCTest). Tests run in a `swift:6.0` container (native arm64 — the
  wedge below is not emulation).
- **The container wedges nondeterministically.** Roughly one `swift test`
  invocation in five stalls at ~0% CPU forever, never the same suite twice — a
  suite that wedges runs clean in 1s next attempt. A stall says nothing about
  your change, and waiting it out never works. Bare `swift test` and
  target-level filters hang for this reason: many suites in one process, any one
  of which wedges it. slim-check gives each suite its own process, a short first
  attempt and 3 tries; it exits 1 for a real failure, 2 for "wedged every
  attempt" (inconclusive — confirm via CI).
- CLASS-level filters are the reliable unit. `--filter` is a regex matched on
  `Target.Class/testMethod`, so a class name that is a substring of its own
  target (`WireProtocolTests` in `TapQWireProtocolTests`) also pulls that
  target's siblings. Never anchor it: `--filter '^(A|B)$'` matches nothing,
  runs 0 tests and exits 0 — a silent false green.
- macOS has no `timeout`; any watchdog must live INSIDE the container.
- On Linux, the Swift 6 test-discovery shim cannot register SYNCHRONOUS test
  methods on a `@MainActor` XCTestCase — hard errors in the container,
  invisible on macOS. Every test method in a `@MainActor` suite must be
  `async`, even pure assertions.
- Agent worktrees are sometimes created at a stale base (seen twice at an
  old main). First act in any worktree: `git log --oneline -1` and
  fast-forward to the intended branch tip before writing code.
- Voice-timing tests need the drain-aware doubles (speech occupies the
  injected clock and holds the voice channel — see
  InstructionAnnouncementTests / RealtimeSelfAudioTests). The instantaneous
  `onFinish?()` doubles cannot express any deadline-vs-playback race.
- The build dir is the shared volume `tapq-linux-build` via `--scratch-path
  /build`. Never run two containers against it at once — they starve each other.
- Only the host `swift build` covers the Apple adapters and runtime app; they
  never compile in the container. slim-check does it first and fails fast.

## Runtime

`scripts/run-runtime-app.sh serve ...` launches the bundle via `open -n -W`:
the environment IS inherited (TAPQ_DEBUG, API keys work), but stdin is
`/dev/null` (EOF) and cwd is `/`. Interactive prompts (the calibration Return
prompt, reset confirm) and relative path arguments do not survive the launcher.
