# Voice backend failure policy: no cross-backend degradation

Status: ratified by the maintainer 2026-08-27, during live no-AirPods testing.
Supersedes the fail-through composition documented in CLI.md ("There is no
OpenAI-only mode"). Not yet implemented.

## The rule

**A specified backend never degrades into a different backend.** When the user
passes `--voice-backend openai-realtime` (or any future backend), that backend
is the whole of the voice pipe. If it fails — at open, mid-run, any severity —
hands-free voice **breaks completely** for the run: loud diagnostics, one
locally spoken notice, and a dead voice channel until the runtime is restarted.
No silent swap, no sticky fallback, no per-utterance re-speak. The maintainer's
words: "If TapQ fails, no matter severity, under realtime backend, it breaks
completely. No degrading between different backends."

Rationale: a degraded run lies about what is being tested and what the wearer
is talking to. The Apple pipe has different capabilities (no free-form, no
grounded answers, different endpointing); swapping it in mid-run silently
changes the contract the wearer thinks they are speaking under. This extends
the 2026-08-27 playback decision (terminate loudly, never silently fall back)
from one seam to the whole backend boundary.

## What failure looks like (the terminal state)

On any specified-backend failure (`sessionFailed`, open failure after startup,
playback termination):

1. Error-level diagnostics, cause then consequence:
   `voice.pipeline_failed backend=openai-realtime reason=…` followed by
   `voice.disabled_for_run`.
2. One notice spoken through the local TTS output: "Hands-free voice is off —
   the voice backend failed." TTS output is not a backend (the Apple *backend*
   is the recognizer); announcing the break locally is how the wearer learns
   the mic is dead, and it is the same engine every non-voice announcement
   already uses.
3. The voice channel is terminally down for the run: windows open without a
   microphone and resolve by gesture, tap, or timeout only; approvals keep
   failing open to the agent's on-screen prompt exactly as today.
4. Voice-session holds are released immediately (`releaseAll`), dictation and
   free-form are refused, and no re-open of the backend is attempted.
5. The status line and "who's waiting?" reflect the broken state. Restarting
   the runtime is the only recovery.

Recommended (not yet ratified): keep the runtime alive in this state — gestures,
taps, screen fail-open, and the broker all still work, matching the existing
approvals-fail-open philosophy. The alternative (hard process exit on backend
failure) kills approvals-by-gesture too; flag to the maintainer only if the
gesture-alive state proves confusing in practice.

## What is removed

- `FailThroughVoiceBackend` as a cross-backend composition: `openai-realtime`
  no longer runs "(fail-through: apple)". The ready line drops that suffix.
- The sticky-skip machinery (`primary.skipped_sticky`, `fallback.opened`,
  `fallback.turn_resumed`) for cross-backend use.
- CLI.md's "There is no OpenAI-only mode" paragraph — inverted: an explicit
  backend IS the only mode.
- The `bargeInUnsupported`-after-drop defect (flagged 2026-08-27) becomes moot:
  there is no fallback session to mis-drive.

`--voice-backend apple` (the default) is unaffected: Apple is then the
specified backend, and its own failures get the same break-completely
treatment.

## What is kept, unchanged

- Startup refusal: `--voice-backend openai-realtime` without `OPENAI_API_KEY`
  still refuses to start. A backend that cannot open at startup is a startup
  error, not a run-time break.
- The AirPods voice-only/never-streamed degrade: that is a *gesture* degrade
  within one backend, not a backend swap.
- The playback fail-loud termination (2026-08-27): its `sessionFailed` now
  lands in the break-completely handler instead of the fail-through.
- The wire, broker, approvals, and instruction channels: a broken voice pipe
  changes how windows resolve, not what they are about.

## Implementation sketch

1. `AppleTapQRuntimeService`: compose the specified backend bare (no
   `FailThroughVoiceBackend` wrapper); route `sessionFailed` into a new
   terminal `VoiceBrokenState` owned by the runtime.
2. `VoiceBrokenState` (portable, testable on Linux): latches on first failure,
   drives the diagnostics, the one local notice, the `releaseAll`, and the
   refuse-all-reopens behavior.
3. Windows/arbiters: honor the latch — open without mic, keep gesture/tap/
   timeout resolution (the `--no-voice` composition is the model; reuse it).
4. Delete or narrow `FailThroughVoiceBackend` + its 28 tests; rewrite the
   degrade E2E suites (`VoiceDegradeAndQuietE2ETests`,
   `VoiceProviderRouteE2ETests`) around break semantics.
5. Docs: CLI.md Voice backend section, ready-line examples, CHANGELOG.

Sequencing: land after the cancel-race tombstone fix (in flight 2026-08-27) —
under this policy that race would kill voice for the run instead of degrading,
so the fix is a prerequisite for a usable `--voice-session` at all.

## Addendum, 2026-08-28: scripted speech joins this break

Ratified alongside voice-output isolation ("isolate ALL voices from the Apple
backend and the openai-realtime backend"). With a non-`apple` backend selected,
**every sentence TapQ speaks** — prompts, read-backs, `Listening.`, `Queued for
…`, `Voice session ended.`, summaries, degrade notices — is voiced by that
backend, as an out-of-band verbatim reading (`response.create` with
`conversation: "none"` and an empty `input`). The local synthesizer is not used
while the pipe is alive.

The relevant consequence for this document: **a sentence the specified backend
cannot be made to say is a failure of the pipe, and it lands here.** The session
could not be opened, the session died with sentences still waiting, or the
speech queue overflowed — each is logged as `scripted_speech.undeliverable` at
error level and reported to the same latch, producing the same
`voice.pipeline_failed` / `voice.disabled_for_run` pair, the same single local
notice, and the same dead voice channel for the run. There is deliberately no
path that re-speaks the sentence in the Apple voice while the backend is
nominally alive: that per-utterance re-speak is exactly what "no degrading
between different backends" rules out, and on hardware it was also audible to
the backend's own open microphone and transcribed as wearer speech.

Unchanged by this: the break notice itself, and every sentence after it, are
spoken locally. That was already the rule for the notice ("the local
synthesizer is not a backend"); it now explicitly extends to the rest of a
broken run, because windows keep opening and resolving by gesture, tap, and
timeout, and a prompt nobody can hear makes them unanswerable. The gate is
one-way — it opens only on the latch and never closes.
