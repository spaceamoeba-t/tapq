# Milestone two — manual smoke checklist

Live voice loop: conversation sessions, microphone pump, response playback, wearer gate,
IMU turn control, barge-in, and free-form voice answers, verified against real hardware.

Everything here needs a human, physical AirPods, macOS privacy permissions, and — for most
items — a live network and an OpenAI account. **Agents must not attempt these.** The
automated suite covers every seam that can be faked; this file covers exactly the part it
cannot: whether the cloud voice session actually works end-to-end, whether the wearer gate
rejects a bystander, and whether free-form text reaches the agent.

Nothing in this milestone changes the shipped default paths. Item 7 is the regression
check that proves it.

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works at all: `scripts/run-runtime-app.sh serve`
  should report `AirPods motion: available`. If it does not, stop — every item below
  depends on it.
- Run the wearer-speech calibration if you have not already:
  `scripts/run-runtime-app.sh calibration run wearer-speech --non-interactive`.
  Items 2 and 3 require the IMU wearer-speech signal, which works with or without a
  calibration profile but is more accurate with one.
- Export `OPENAI_API_KEY` in the shell that launches the runtime. Items 1, 2, 4, and 5
  require it.
- Keep a scratch directory, e.g. `mkdir -p /tmp/tapq-smoke-m2`.

Three properties of the development launcher shape every command below. It runs the
bundle through `open -n -W`, which means:

- **stdin is closed.** Interactive prompts see EOF. Always pass `--non-interactive` to
  `calibration run` and `--yes` to `calibration reset`.
- **the working directory is `/`.** Every path argument must be absolute.
- **the exit code is lost.** `open -W` returns `0` no matter what the app returned, so the
  launcher cannot be used to check an exit status. Where an item asks for one, run the
  bundle's executable directly instead:
  `build/TapQRuntime.app/Contents/MacOS/tapq ...`, and grant permission again if macOS
  re-prompts.

Environment variables *are* inherited, so `OPENAI_API_KEY`, `TAPQ_DEBUG=1`, and
`TAPQ_SPEECH_VOICE` work through the launcher.

---

## 1. Cloud voice end-to-end: speak, hear, resolve

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

Trigger a live approval from Claude Code or Codex. When the prompt is spoken, answer by
voice. Say it however you would say it — since 2026-08-28 there is no keyword grammar on this
backend, and the model decides what you meant and calls a tool. Then trigger a second
approval.

**Expect**

- The ready block prints `Voice backend: openai-realtime`.
- The approval is answered by your spoken voice, and the decision takes effect exactly as
  it does on the Apple path.
- **You hear the cloud voice.** The agent's response audio — not the local `AVSpeech`
  synthesizer — should be audible through the AirPods. This is the thing milestone one
  could not do: the pipe now actually transmits audio (microphone pump), the cloud returns
  audio, and TapQ plays it (backend playback).
- The approval resolves by voice on the OpenAI path — the only path there is. With
  `TAPQ_DEBUG=1`, the resolving window should show `tool.grounding_updated` before the
  microphone opens, then `tool.called name=approve` (or `deny`), `tool.result_sent`, and
  `tool.executed`. There must be **no** `command.matched`: a keyword match on this backend
  means the grammar is still wired in somewhere, which is the defect the tool path replaced.
  No `voice.pipeline_failed`, and no `tool.protocol_failed`.
- **Say something that merely contains an answer word.** Dictate a sentence with "no" or
  "stop" in it — "tell it not to stop the server" — into an open approval. Nothing must
  resolve. This is the failure that forced the change: on 2026-08-28 a fragment like this
  matched `command=no` and ended a live session.
- **Try to end the session by speaking.** With `--voice-session` (leg 5), say "stop
  listening" and "no" at a held boundary. The loop must keep listening; only a shake, a tap,
  a break in the voice pipeline, or stopping the runtime ends it.
- **Leave a held boundary alone for five minutes.** With `--voice-session`, say nothing at
  all after "Listening." The loop must still be listening when you come back — silence does
  not end a voice session (ratified 2026-08-28). With `TAPQ_DEBUG=1` the renewals are
  visible as `wait.renewed` about once a minute (every tenth at info), and there must be
  **no** `listening.ended`, no second "Listening." cue, and no `wait.released` until you end
  it with a tap or a shake. Confirm the Stop hook is still shown in flight in the Claude
  Code terminal throughout.
- **Reinstall the hooks first.** `tapq integration claude status` must report `strict` (or
  `native`), not `partial` — a Stop entry from an older build carries the old timeout and
  would kill a held boundary part-way through. After `tapq integration claude install`, the
  `Stop` entry in `~/.claude/settings.json` carries `"timeout": 2147483`.
- A second approval on the same session reuses the existing WebSocket session (no
  reconnect churn). With `TAPQ_DEBUG=1`, you should not see a fresh `session.created`
  between consecutive windows unless 60 seconds of idle time elapsed.

**Also verify playback across devices.** If possible, repeat with different audio output
configurations: AirPods only, Mac speakers only, an external audio interface. The
`AVAudioPlayerNode` int16-interleaved connect/schedule/completion path was empirically
verified on one Mac only; the smoke checklist must confirm playback across output devices
and macOS versions. Record which macOS version and output device you used.

**If it fails** — no audible cloud voice means the playback path is broken. No voice
resolution means either the microphone pump is not transmitting or the transcript is not
arriving. Check `TAPQ_DEBUG=1` output for `MicPump` and `Playback` diagnostics.

## 2. IMU turn control: endpointing and barge-in

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime --imu-turn-control
```

The ready block should print `Wearer speech: turn-control`.

Trigger an approval. When the prompt is spoken, answer by voice. Stop talking and wait.

**Expect — endpointing**

- The turn commits within roughly 1 second of the wearer stopping speech (0.6 s detector
  hangover + 0.4 s endpoint delay). The window resolves without waiting for the full
  timeout.
- Without `--imu-turn-control`, the same scenario would wait for the window timeout or a
  gesture/tap before resolving.

**Expect — barge-in**

Trigger another approval. While the agent is speaking its response audio (the cloud voice
or TTS), start talking.

- **Playback stops immediately.** The agent's voice cuts off when the wearer starts
  speaking.
- The wearer's answer is heard on the next turn and the window resolves.
- The first ~0.3-0.5 seconds of the barge-in utterance may be lost (IMU onset latency plus
  mic-open latency). This is expected and documented.

**If it fails** — endpointing not firing means the wearer-speech signal is not reaching the
turn coordinator; check that AirPods motion is available and that per-axis data is present.
Barge-in not firing means the `startedSpeaking` transition is not being observed during
playback; check `TAPQ_DEBUG=1` for wearer-speech transitions.

## 3. Wearer gate: attribution filtering

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime --wearer-gate
```

The ready block should print `Wearer speech: gate`.

**Expect — bystander rejection**

Trigger an approval. While the window is open, play "yes" from a phone speaker or have
another person say "yes" near the AirPods.

- The bystander's "yes" should be **rejected**. The wearer-speech signal should not
  attribute the command to the wearer. With `TAPQ_DEBUG=1`, you should see a `WearerGate`
  diagnostic indicating the command was not attributed.
- The window should remain open for the wearer to answer by gesture, tap, or their own
  voice.

**Expect — wearer acceptance**

Then the wearer themselves says "yes".

- The wearer's own "yes" should pass through. The approval resolves.

**Expect — fail-open on signal loss**

Pull the AirPods out of your ears (or wait for motion to disconnect) while a window is
open.

- The gate should degrade to pass-through. A voice command should resolve the window as if
  the gate were not present (fail-open).
- With `TAPQ_DEBUG=1`, you should see a `WearerGate` diagnostic indicating the signal is
  unavailable and the command is being passed through.

**If it fails** — the gate rejecting the wearer's own speech means the attribution window
is too narrow or the detector is not sensitive enough on your hardware. Record the
calibration profile numbers and the behavior. The thresholds are provisional.

## 4. Free-form voice answers

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime --imu-turn-control \
  --voice-freeform
```

**Via Claude Code `AskUserQuestion`**

Trigger a multi-option question from Claude Code (e.g. use `--steering` and prompt Claude
to ask a question with options). When the options are spoken, instead of selecting one,
speak an answer in your own words — something clearly different from any of the listed
options.

**Expect**

- TapQ reads back your answer: "You said: '<your text>'. Nod to send, shake to discard."
- Nod to confirm.
- Claude receives the free text. Check the Claude Code transcript: the deny reason should
  contain your spoken text. Claude should proceed with your answer rather than re-asking.

**Via Codex `request_user_input`**

Repeat the same test with a Codex `request_user_input` question.

**Expect**

- The same read-back confirmation flow.
- **Record whether Codex accepts the free-text answer.** Whether `request_user_input`
  tolerates non-option answer strings is not verifiable from this repository. If Codex
  re-asks the same question, the free-text delivery is best-effort and the documented
  fallback is that nothing worse than today's behavior happens. Record the observed
  behavior.

**Also verify discard**

Speak a free-form answer, hear the read-back, then shake to discard.

**Expect**

- The answer is discarded and TapQ re-listens for the next command.

**If it fails** — if the read-back never fires, check that `--voice-freeform` is passed and
the backend is `openai-realtime`. If Claude does not see the text, check the wire protocol
version in the debug output.

## 5. Fail-through: network death mid-conversation

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

Trigger a live approval. After it resolves, **turn Wi-Fi off** while the session is idle
(between windows).

Then trigger another approval.

**Expect**

- The window does **not** hang. It resolves by gesture, tap, or timeout.
- You hear one sentence, once: "Hands-free voice is off. The voice backend failed."
- With `TAPQ_DEBUG=1`, the log shows `voice.pipeline_failed` (with `backend=` and
  `reason=`) followed by `voice.disabled_for_run`, both at error level.
- Hands-free voice is over for the run. Subsequent windows log `open.refused` with
  `reason=voice_disabled_for_run`, send no traffic to the backend, and resolve by gesture,
  tap, or timeout. Voice does **not** continue on the Apple stack — that is the policy.
- If a `--voice-session` boundary was held, its Stop hook is released immediately rather
  than waiting out its budget.
- The microphone is **never stuck open** between windows.

Turn Wi-Fi back on and trigger another approval.

**Expect**

- Nothing reconnects. The break lasts the run; restarting the runtime is the only recovery.

**If it fails** — a hung window is the serious case, and so is a run that quietly keeps
working on the Apple recognizer. The first strands the wearer; the second lies to them
about which pipe they are speaking to.

## 6. Old shim against new broker

Build the hook executable from the milestone-one tip (`0fc7474`) and leave it installed.
Start the current milestone-two runtime.

```bash
# Build old shim (in a separate checkout or worktree)
git checkout 0fc7474
swift build
# Note the path to the built tapq-hook / tapq-codex-hook

# Start the current M2 runtime
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

Trigger an approval from the old shim.

**Expect**

- The old shim (v3) connects to the new broker (which accepts v3). The approval resolves
  normally — it fails open loudly to the on-screen prompt rather than silently breaking.
- The old shim never sees `free_text` fields (it decodes them as absent), so free-form
  voice answers are not delivered through the old shim. This is expected.

Reinstall hooks with the current build (`tapq integration claude install` and/or
`tapq integration codex install`).

**Expect**

- The new shim (v4) connects and all features including free-text work.

**If it fails** — if the old shim is rejected entirely, the broker's version acceptance
(`{3, 4}`) is not working. If the old shim hangs or crashes, there is a wire
incompatibility in the request or response format.

## 7. Regression: the default path is unchanged

```bash
scripts/run-runtime-app.sh serve
```

**Expect**

- **No** `Voice backend:` line. The default prints nothing, because nothing changed.
- **No** `Wearer speech:` line. Neither gate nor turn control is active by default.
- Voice approvals, double nod, double shake, double tap, and volume-key option navigation
  all behave exactly as they did before this milestone.
- The default Apple voice path is unchanged: `VoiceListener` opens and closes its
  recognizer per window, no conversation session, no playback, no microphone pump.

Also verify that the new flags do not change behavior when not passed:

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

**Expect**

- Without `--wearer-gate`, `--imu-turn-control`, or `--voice-freeform`, the
  `openai-realtime` path resolves windows by gesture, tap, or timeout exactly as before.
  The only behavioral difference from milestone one is that the pipe now actually transmits
  audio and the cloud voice is audible (items covered in item 1).
- No new status lines beyond `Voice backend:`.

This is the item that matters most. Everything in milestone two is either behind an
explicit flag or an improvement to the existing `openai-realtime` flag path; if any
unflagged default behavior moved, that is a defect regardless of how well items 1
through 6 went.

---

## Recording results

Record the following with every run:

- macOS version and hardware (Mac model, AirPods model).
- Audio output device used for item 1's playback verification.
- Whether Codex accepts the free-text answer in item 4 (the one open question).
- Calibration profile numbers from `tapq calibration show` for items 2 and 3.
- Any `TAPQ_DEBUG=1` output that shows unexpected behavior.

Wearer-speech thresholds are provisional by design — they live in a calibration profile
precisely so the capture study can retune them without a code change. An endpoint that
fires too early or a gate that passes a bystander on your hardware is data for the study,
not necessarily a bug. Record the numbers.
