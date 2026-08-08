# Milestone one — essential manual test (~20 min)

Five steps that touch every milestone surface once: capture tooling, detector, calibration,
cloud voice backend (`gpt-realtime`, the built-in default model), and the unchanged default
path. The exhaustive version (discrimination matrix, permission edge cases, full lifecycle)
lives in [MILESTONE1_SMOKE_CHECKLIST.md](MILESTONE1_SMOKE_CHECKLIST.md) — run it before
calling the milestone *done*; run this to see it *work*.

**Setup:** `scripts/package-runtime-app.sh debug`; AirPods connected; system audio input =
**built-in mic**. Launcher quirks: pass `--non-interactive`/`--yes` to calibration
commands, use absolute paths everywhere.

**Triggering approvals (steps 4–5):** run `claude` in a scratch directory in **default
permission mode** (not accept-edits or bypass — prompts must actually appear), then paste
one of these:

- *Yes/no permission prompt:*
  > Run `sw_vers` and show me the output.

  (Any non-allowlisted Bash command works; swap in another if your allowlist covers this
  one.)
- *File-write prompt:*
  > Create a file named hello.txt here containing the single word "hello".
- *Multi-option question* (exercises stem-swipe navigation + select):
  > Use the AskUserQuestion tool to ask me what greeting hello.txt should use. Offer
  > exactly three options: casual, formal, pirate.

Each is harmless to approve, deny, or answer either way — the point is the prompt, not
the outcome.

---

## 1. Capture with ground truth (5 min)

```bash
scripts/run-runtime-app.sh capture --duration 30 \
  -o /tmp/tapq-imu.jsonl --mic-envelope /tmp/tapq-env.jsonl
```

Head still. Silent ~10 s, read two sentences aloud, silent to the end.

**Pass:** both files written; the first/last `timestamp` in the two files agree within a
few hundred ms (this validates the audio→IMU clock anchor — the one thing no unit test
could check); `rms` in `tapq-env.jsonl` is clearly higher while you spoke.

## 2. Detector sees you — and only you (3 min)

```bash
tapq replay -i /tmp/tapq-imu.jsonl --mic-envelope /tmp/tapq-env.jsonl
```

**Pass:** a `Wearer speech (truth: mic_envelope)` section appears; the detected span
overlaps when you actually spoke; **no activation during the silent stretches**. Absolute
precision/recall numbers are study input, not pass/fail — but false activations while
silent matter: that's the wearer-attribution claim.

## 3. Calibration (2 min)

```bash
scripts/run-runtime-app.sh calibration run wearer-speech --non-interactive
```

Read aloud continuously through the 6-second speak phase, head still, hands off the earbuds.

**Pass:** prints the envelope numbers and saves `wearer-speech-calibration.json`;
`calibration show` prints three blocks (gesture, tap, wearer speech).

## 4. Cloud backend on gpt-realtime, with the kill test (7 min)

```bash
export OPENAI_API_KEY=…   # then:
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

**Pass:** ready block prints `Voice backend: openai-realtime (fail-through: apple)`.
Trigger the *yes/no* prompt from the setup list ("Run `sw_vers`…") and answer "yes" by
voice — Claude Code proceeds. Then trigger the *multi-option* question and walk the three
options by stem swipe, selecting one by tap or voice.

Then the part that actually matters: paste the *file-write* prompt, and while its response
window is open, **turn Wi-Fi off**.

**Pass:** the window resolves anyway (on-device voice, nod, or timeout) — it must never
hang — and the next window works on-device. A hung window is the one serious failure here.

## 5. Default path untouched (3 min)

```bash
scripts/run-runtime-app.sh serve
```

**Pass:** **no** `Voice backend:` line; re-run the *yes/no* prompt and approve by double
nod, then the *multi-option* question navigated by stem swipe — both behave exactly as
before the milestone. Everything new sits behind flags — if the default moved, that's a
defect regardless of steps 1–4.

---

Record: clock offset (step 1), false activations while silent (step 2), calibration
envelope numbers (step 3), and how the killed window resolved (step 4). Keep the two
capture files — they seed the study corpus.
