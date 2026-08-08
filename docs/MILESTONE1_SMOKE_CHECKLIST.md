# Milestone one — manual smoke checklist

Wearer-speech detection and the `VoiceBackend` contract, verified against real hardware.

Everything here needs a human, physical AirPods, macOS privacy permissions, and — for the
last items — a live network and an OpenAI account. **Agents must not attempt these.** The
automated suite covers every seam that can be faked; this file covers exactly the part it
cannot: whether the earbud IMU can actually hear its wearer talk, whether the microphone
and motion clocks really line up, and whether a cloud voice session degrades the way the
tests say it does.

Nothing in this milestone changes the shipped default paths. Item 7 is the regression
check that proves it.

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works at all: `scripts/run-runtime-app.sh serve`
  should report `AirPods motion: available`. If it does not, stop — every item below
  depends on it and a missing profile will read as a detection failure.
- Set the Mac's **built-in microphone** as the system audio input (System Settings →
  Sound → Input). Items 1 and 5 depend on this; item 2 deliberately changes it back.
- Keep a scratch directory, e.g. `mkdir -p /tmp/tapq-smoke`.

Three properties of the development launcher shape every command below. It runs the
bundle through `open -n -W`, which means:

- **stdin is closed.** Interactive prompts see EOF. Always pass `--non-interactive` to
  `calibration run` and `--yes` to `calibration reset`.
- **the working directory is `/`.** Every path argument must be absolute.
- **the exit code is lost.** `open -W` returns `0` no matter what the app returned, so the
  launcher cannot be used to check an exit status. Where an item asks for one, run the
  bundle's executable directly instead:
  `build/TapQRuntime.app/Contents/MacOS/tapq …`, and grant permission again if macOS
  re-prompts.

Environment variables *are* inherited, so `OPENAI_API_KEY` and `TAPQ_DEBUG=1` work through
the launcher.

---

## 1. Envelope co-recording aligns with the IMU track

```bash
scripts/run-runtime-app.sh capture --duration 30 \
  -o /tmp/tapq-smoke/imu.jsonl \
  --mic-envelope /tmp/tapq-smoke/env.jsonl
```

Wear the AirPods, keep your head still, and during the 30 seconds: stay silent for about
5 s, read two sentences aloud at a normal volume, then stay silent again to the end. Note
roughly when you started and stopped talking.

**Expect**

- stderr says `Co-recording a microphone envelope to /tmp/tapq-smoke/env.jsonl…` *before*
  the motion capture line — the microphone opens first by design.
- Both files exist, and the run ends with a motion sample count and an envelope block
  count.
- `env.jsonl`'s first line is the header:
  `{"block_frames":…,"clock":"boottime","sample_rate":…,"schema":"tapq-mic-envelope-v1"}`.
- **The clocks overlay.** The first `timestamp` in `env.jsonl` is within a few hundred
  milliseconds of the first `timestamp` in `imu.jsonl`, and the last of each likewise.
  This is the item's real purpose: the audio host-time to boot-time anchor conversion is
  the one piece of arithmetic no unit test can validate against actual hardware.
- **Speech is visible in the envelope.** The `rms` values during your two sentences are
  clearly above the silent stretches — an order of magnitude, not a few percent — and the
  loud span lines up with when you were actually talking.

**If it fails** — a constant offset between the two clocks means the anchor conversion is
wrong and every metric in item 5 is meaningless; do not proceed past item 5 without
resolving it. An envelope with no contrast between speech and silence usually means the
wrong input device is selected.

## 2. AirPods microphone as input: the HFP degradation story

Set the system input to the **AirPods microphone**, then repeat item 1's command to a new
pair of paths.

**Expect**

- The capture still completes; nothing crashes.
- Audio quality audibly drops as Bluetooth switches into headset mode — this is the
  documented reason `tapq capture --help` and
  [CLI.md](CLI.md#microphone-envelope-sidecar) tell operators to select the built-in
  microphone instead.
- The motion track itself may look different from item 1's. That is the point of the
  warning: opening the AirPods microphone changes the very signal the study measures.

**Then set the system input back to the built-in microphone** before continuing.

**If it fails** — if the AirPods path is *not* noticeably worse, the documented guidance
is overstated and should be softened rather than left as folklore.

## 3. Mid-capture route change truncates cleanly

Start a long capture, and while it runs, change the system audio input device.

```bash
build/TapQRuntime.app/Contents/MacOS/tapq capture --duration 60 \
  -o /tmp/tapq-smoke/imu-route.jsonl \
  --mic-envelope /tmp/tapq-smoke/env-route.jsonl
echo "exit=$?"
```

(Run the executable directly, not through the launcher — this item is about the exit
code, which `open -W` discards.)

**Expect**

- The **motion capture finishes and is written**. Losing the IMU track because the
  microphone had a problem would be the wrong trade.
- stderr reports the truncated sidecar:
  `The microphone envelope track ended early (…). The motion capture finished and was
  written, but its envelope sidecar is truncated and covers only part of the session.`
- `exit=1` — a failed run, not an unavailable service.
- `env-route.jsonl` covers only the first part of the session; `imu-route.jsonl` covers all
  of it.

**Also check the fail-closed direction — and treat this one as an open question.** Revoke
microphone access for the runtime bundle in System Settings → Privacy & Security →
Microphone, then run the same command again.

The intended behavior is an abort *before* any motion is recorded: exit `69`, a message
ending `Nothing was recorded — a study session without its label track is not worth
keeping`, and no output file. That is what happens when the audio engine refuses to start.

But the envelope source has no explicit authorization check — it starts the engine and
trusts the result — and a denied microphone on macOS may instead deliver *silent buffers*
rather than an error. If that is what you observe, the run will look successful and write
a full-length sidecar of near-zero `rms` values. **Record which of the two happens.** The
silent-buffer outcome is exactly the failure the fail-closed policy was written to
prevent, and would mean the policy needs an authorization gate ahead of the engine start
rather than relying on it.

## 4. Wearer-speech calibration profile lifecycle

```bash
scripts/run-runtime-app.sh calibration run wearer-speech --non-interactive
```

Follow the printed stage prompts. For the 6-second speak phase, read aloud continuously at
a normal pace, keeping your head still and your hands away from the earbuds — the envelope
uses the same acceleration channel a fingertip on the stem saturates, which is also why
the speak phase runs last in an `all` session.

**Expect**

- The run reports `Wearer speech envelope: … g sustained (resting peak … g; required … g)`
  and then `Wearer speech calibration saved to …/wearer-speech-calibration.json`.
- A deliberately bad run — stay silent through the speak phase — fails with the documented
  message about a vibration envelope not sufficiently separated from resting motion, and
  saves nothing.

Then walk the rest of the lifecycle:

```bash
scripts/run-runtime-app.sh calibration show
scripts/run-runtime-app.sh calibration show --json
scripts/run-runtime-app.sh calibration reset wearer-speech --yes
scripts/run-runtime-app.sh calibration show
```

**Expect**

- `show` prints three blocks: gesture, tap, and wearer speech.
- `show --json` includes all three keys, the third being `wearer_speech`.
- After the reset, **gesture and tap survive** and only the wearer-speech block is gone.
  Three independent documents is the whole design; a reset that took the others with it
  would cost a full recalibration session.

**If it fails** — a speak phase that cannot separate speech from rest on your hardware is
useful information, not necessarily a bug: the default thresholds are provisional until
the capture study. Record the printed envelope numbers rather than adjusting code.

## 5. Replay precision and recall on real recordings

Score the detector against the recording from item 1:

```bash
tapq replay -i /tmp/tapq-smoke/imu.jsonl \
  --mic-envelope /tmp/tapq-smoke/env.jsonl
tapq replay -i /tmp/tapq-smoke/imu.jsonl \
  --mic-envelope /tmp/tapq-smoke/env.jsonl \
  --wearer-speech-profile ~/Library/Application\ Support/TapQ/wearer-speech-calibration.json
```

Replay needs no hardware or permissions, so a plain `swift run tapq` works here.

**Expect**

- A `Wearer speech (truth: mic_envelope)` section with frame precision and recall that are
  at least *sane* — the detected span overlaps the span you actually spoke in, onset
  latency is a fraction of a second rather than seconds, and the counts are not zero.
- The calibrated profile does not make things dramatically worse than the defaults.
- Numbers well below 1.0 are expected at this stage and are the study's input, not a
  release blocker. Record them.

Then the silent control:

```bash
# a 30 s capture with no speech at all, recorded the same way as item 1
tapq replay -i /tmp/tapq-smoke/imu-silent.jsonl \
  --mic-envelope /tmp/tapq-smoke/env-silent.jsonl
```

**Expect** — **zero false activations.** This is the one number in item 5 that is a
target rather than a measurement. A detector that fires while nobody is talking would,
once `WearerGatedVoice` goes live, attribute a bystander's command to the wearer.

Optionally hand-label the same capture and compare:

```bash
printf '{"start": %s, "end": %s, "label": "wearer_speech"}\n' START END \
  > /tmp/tapq-smoke/labels.jsonl
tapq replay -i /tmp/tapq-smoke/imu.jsonl \
  --labels /tmp/tapq-smoke/labels.jsonl \
  --mic-envelope /tmp/tapq-smoke/env.jsonl
```

**Expect** — `truth: labels` and a stderr note that both sources were supplied and the
labels won. Metrics close to the envelope-derived run cross-validates the derivation.

## 6. OpenAI Realtime voice backend

With `OPENAI_API_KEY` exported in the shell that launches the runtime:

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

**Expect**

- The ready block prints `Voice backend: openai-realtime (fail-through: apple)`.
- A live approval — trigger one from Claude Code or Codex — can be answered by voice, and
  the answer takes effect exactly as it does on the Apple path.

Then break it deliberately, mid-session: turn Wi-Fi off while a response window is open.

**Expect**

- The window does **not** hang. It resolves — by voice on the Apple stack, or by gesture,
  tap, or timeout.
- Voice keeps working on subsequent windows, on-device.
- No stuck microphone: the mic must not stay open between windows.

Finally, the misconfiguration:

```bash
env -u OPENAI_API_KEY build/TapQRuntime.app/Contents/MacOS/tapq serve \
  --voice-backend openai-realtime
echo "exit=$?"
```

**Expect** —
`error: OpenAI Realtime voice requires OPENAI_API_KEY in the TapQ process environment.`
and `exit=1`. Serving must refuse rather than quietly fall back to Apple: silently serving
on-device after the operator asked for a cloud backend would hide the mistake behind
working voice.

**If it fails** — a hung window is the serious one. Fail-through exists so that a network
problem costs latency and never the interaction; a window that cannot be resolved is worse
than having no cloud backend at all.

## 7. Regression: the default path is unchanged

```bash
scripts/run-runtime-app.sh serve
```

**Expect**

- **No** `Voice backend:` line. The default prints nothing, because nothing changed.
- Voice approvals, double nod, double shake, double tap, and volume-key option navigation
  all behave exactly as they did before this milestone.
- `tapq capture` without `--mic-envelope` never touches the microphone and produces a file
  byte-identical in shape to a pre-milestone capture.
- `tapq replay` without the new flags prints no wearer-speech section, and its `--json`
  report has no `wearer_speech` key.

This is the item that matters most. Everything in milestone one is either study tooling or
sits behind an explicit flag; if any default behavior moved, that is a defect regardless of
how well items 1 through 6 went.

---

## Recording results

Wearer-speech thresholds are provisional by design — they live in a calibration profile
precisely so the capture study can retune them without a code change. When reporting a
run, include the envelope numbers from item 4, the precision/recall/F1 and false-activation
figures from item 5, and the hardware and macOS version. A number that looks bad is data;
a number that is missing is not.
