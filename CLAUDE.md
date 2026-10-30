# TapQ

TapQ is `tapq-kernel`: the user speaks to Claude Code or Codex by name, and TapQ relays the
words, reads requests aloud and speaks replies. README.md describes the program; this file
is for working on it.

## Design rules

- The person is "the user". A headset or earbuds are optional input devices, not the
  premise; the Mac's microphone and speaker are a first-class setup.
- Everything TapQ hears counts as the user's. Listening is open; there are no timers.
- Interpreting the user's words, including which agent they are for, is the text model's
  job. Deterministic checks act only on events and state, never on estimates of pace or
  length. The gate lets an answer through only for a request the user heard in full.
- Replies are summarized, never cut; "read it all" reads the original.
- One agent failing stops that agent alone.
- `TapQKernel` stays portable: no Apple framework, no network, no subprocess. Every
  sentence TapQ speaks lives in `Sentences.swift` and is pinned by tests.

## Testing

While iterating, run the slim check plus whatever suites you touched:

    scripts/slim-check.sh SuiteYouTouchedTests OtherTests

Do NOT sweep every suite locally to verify a change: the exhaustive run (macOS + Linux) is
CI's job and lands a few minutes after a push. `scripts/linux-check.sh` is the CI mirror
(release build + bare `swift test`).

On a Mac with Command Line Tools only (no XCTest), the local loop is:

    swift build --build-system native
    scripts/typecheck-tests.sh TestTargetYouTouched ...
    scripts/host-test.sh TestTargetYouTouched ...

`typecheck-tests.sh` compiles test targets against the stub XCTest module.
`host-test.sh` runs them on the host against a recording XCTest shim, linking the objects
of the prior build; it takes test TARGETS (`TapQKernelTests`), not classes, and exits
non-zero on any failure.

Container facts, all hard-won — do not rediscover them by hanging:

- Tests run in a `swift:6.0` container on a host without XCTest.
- **The container wedges nondeterministically.** Roughly one `swift test` invocation in
  five stalls at ~0% CPU forever, never the same suite twice. A stall says nothing about
  your change, and waiting it out never works. slim-check gives each suite its own
  process, a short first attempt and 3 tries; it exits 1 for a real failure, 2 for
  "wedged every attempt" (inconclusive — confirm via CI).
- CLASS-level filters are the reliable unit. `--filter` is a regex matched on
  `Target.Class/testMethod`, so a class name that is a substring of its own target (a
  `KernelTests` class in `TapQKernelTests`) also pulls that target's siblings. Never
  anchor it: `--filter '^(A|B)$'` matches nothing, runs 0 tests and exits 0 — a silent
  false green.
- macOS has no `timeout`; any watchdog must live INSIDE the container.
- On Linux, the Swift 6 test-discovery shim cannot register SYNCHRONOUS test methods on a
  `@MainActor` XCTestCase — hard errors in the container, invisible on macOS. Every test
  method in a `@MainActor` suite must be `async`, even pure assertions.
- Voice-timing tests are event-driven: order events by what the fakes report (the
  player's drain, a fake peer's frames, a fake channel's lines), never by sleeps or yield
  counts.
- The build dir is the shared volume `tapq-linux-build` via `--scratch-path /build`. Never
  run two containers against it at once — they starve each other.
- Only the host `swift build` covers the Apple adapters and the executable's `run`; they
  never compile in the container. slim-check does it first and fails fast.
