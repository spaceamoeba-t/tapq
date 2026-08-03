# Milestone one — manual test plan

Structured, sessioned test plan for a human with AirPods, a Mac, and (for session 5) an
OpenAI key. It organizes and extends [MILESTONE1_SMOKE_CHECKLIST.md](MILESTONE1_SMOKE_CHECKLIST.md):
the checklist is the per-item reference for exact commands and expected output; this plan
adds execution order, stop/continue gates, the discrimination scenarios that probe the
science risk, and the results log the capture study needs.

**Scope.** Everything the automated suite (1,169 tests) cannot verify: real IMU signal,
real clock alignment, real permissions, real network failure. **Out of scope:** the Linux
portable build (CI's job) and anything already covered by `swift test`.

**Total time:** roughly 2 hours across five sessions. Sessions 1–4 need no network or
OpenAI account. Sessions can run on different days; each is self-contained.

---

## Environment (once, before session 1)

Follow "Before you start" in the smoke checklist. In short:

- `scripts/package-runtime-app.sh debug`; AirPods connected; `serve` reports
  `AirPods motion: available`.
- System audio input = **built-in microphone** (sessions 2–4 depend on it).
- `mkdir -p /tmp/tapq-smoke`.
- Remember the launcher rules: stdin is EOF (`--non-interactive` / `--yes` everywhere),
  paths must be absolute, and exit codes only survive when running
  `build/TapQRuntime.app/Contents/MacOS/tapq` directly.

Record once at the top of your results log: macOS version, AirPods model + firmware,
Mac model.

---

## Session 1 — Regression baseline (~15 min, run first)

*Why first: if the default path moved, nothing else matters, and every later session is
easier to debug knowing the baseline was clean.*

Run smoke item 7 in full:

| # | Check | Pass criterion |
|---|-------|----------------|
| 1.1 | `serve` (no flags): approval by voice, double nod, double shake, double tap, volume-swipe navigation | Identical to pre-milestone behavior; **no** `Voice backend:` line in the ready block |
| 1.2 | `capture` without `--mic-envelope` | Microphone never opens (no macOS mic indicator); output shape identical to a pre-milestone capture |
| 1.3 | `replay` without new flags | No wearer-speech section in text; no `wearer_speech` key in `--json` |
| 1.4 | `calibration show` with only gesture/tap saved | Prints those two; wearer-speech block reads as not calibrated; nothing errors |

**Gate G1 — any regression here is a stop-ship defect.** File it and stop; do not
continue on a moved baseline.

---

## Session 2 — Capture tooling integrity (~25 min)

Smoke items 1, 2, 3 in order. The one result that gates everything downstream:

| # | Check | Pass criterion |
|---|-------|----------------|
| 2.1 | Item 1: co-recorded capture, 30 s, speak two sentences mid-run | Both files written; envelope header correct; **first/last timestamps of `env.jsonl` and `imu.jsonl` agree within a few hundred ms**; speech clearly visible in `rms` |
| 2.2 | Item 2: repeat with AirPods mic as input | Completes; audible HFP degradation confirms the documented guidance; input restored to built-in mic afterwards |
| 2.3 | Item 3a: mid-capture route change | IMU track complete, sidecar truncated, truncation message, `exit=1` |
| 2.4 | Item 3b: mic permission revoked | **Record which behavior occurs** — abort with exit 69 and nothing recorded (intended), or a "successful" run with a full-length near-zero-rms sidecar (the silent-buffer hole) |

**Gate G2 — clock alignment (2.1).** A constant offset between the two clocks means the
host-time→boot-time anchor is wrong; sessions 3–4 metrics would be meaningless. Stop and
report the offset.

**Gate G3 — the authorization question (2.4).** This is a genuine open question from the
implementation review, not a formality. If you observe the silent-buffer outcome, the
fail-closed policy needs an explicit mic-authorization check ahead of engine start —
record it as a required fix before the capture study runs, because a study session
recorded under a denied mic would be silently worthless. Re-grant mic access afterwards.

---

## Session 3 — Calibration lifecycle (~20 min)

Smoke item 4 in full:

| # | Check | Pass criterion |
|---|-------|----------------|
| 3.1 | `calibration run wearer-speech --non-interactive`, speaking normally through the 6 s speak phase | Saves; prints sustained envelope, resting peak, and required threshold — **record all three numbers** |
| 3.2 | Deliberately silent speak phase | Fails with the documented separation message; saves nothing; any existing gesture/tap profiles untouched |
| 3.3 | `show` / `show --json` | Three blocks; `wearer_speech` key present in JSON |
| 3.4 | `reset wearer-speech --yes` then `show` | Only the wearer-speech document is gone; gesture and tap survive |
| 3.5 | Re-run 3.1 so a calibrated profile exists for session 4 | Saves again |

A speak phase that cannot separate speech from rest on your hardware is *data, not
necessarily a bug* — the defaults are provisional until the capture study. Record the
numbers; do not tune code.

---

## Session 4 — Detection quality and discrimination (~40 min, the science session)

This is the session the milestone exists for. Part A is smoke item 5; part B extends it
with the confusion cases that decide whether the 25 Hz signal is real. Every replay run
is hardware-free (`tapq replay` directly is fine).

### Part A — baseline metrics (smoke item 5)

| # | Check | Pass criterion |
|---|-------|----------------|
| 4.1 | Replay item-1 capture, default config | Sane: detected span overlaps the spoken span; onset latency well under a second; **record precision / recall / F1 / onset latency** |
| 4.2 | Same, `--wearer-speech-profile` from 3.5 | Not dramatically worse than defaults; ideally better — record both for comparison |
| 4.3 | Silent control capture (30 s, no speech) | **Zero false activations** — this is a target, not a measurement |
| 4.4 | Optional: hand-labeled truth vs envelope-derived truth | `truth: labels`, stderr note that labels won; metrics roughly agree — cross-validates the envelope derivation |

### Part B — discrimination matrix

Record one 30 s co-recorded capture per row (same command as 2.1), then replay each.
Rows 4.5–4.9 are silent-mouth scenarios: the envelope sidecar should show near-silence
while the IMU carries the confounder, so any detection is a false activation. These are
exactly the confounders the analyzer's gates claim to reject — this is their first
contact with reality.

| # | Scenario (30 s each) | Target | What a failure means |
|---|----------------------|--------|----------------------|
| 4.5 | Chewing (gum or food), head still, silent | 0 false activations | Jaw-motion confusion — the classic bone-conduction confounder; thresholds or breadth gate need study data |
| 4.6 | Walking around the room, silent | 0–low false activations | Gait energy leaking through the envelope; rotation gate insufficient alone |
| 4.7 | Nodding and shaking deliberately, silent | 0 false activations | Rotation-quiet gate failing on real gestures — would misattribute during gesture use |
| 4.8 | Bystander speech: someone else talks (or TV/speaker at conversational volume), wearer silent and still | 0 false activations | **The wearer-attribution claim itself** — acoustic sound must not shake the wearer's skull enough to fire |
| 4.9 | Music in the AirPods at normal listening volume, wearer silent | 0 false activations | Speaker vibration bleeding into the IMU at 25 Hz |
| 4.10 | Speaking while slowly walking | Detection comparable to 4.1 | Real usage isn't statue-still; heavy recall loss here bounds the feature to desk use |
| 4.11 | Whispering two sentences | Record whatever happens | Expected weak/no detection — establishes the floor of the modality; data, not pass/fail |

**Gate G4 — go/no-go input for `WearerGatedVoice`.** The wrapper stays out of the live
composition until the capture study validates the signal. These numbers are that study's
pilot: 4.3, 4.5, 4.7 and 4.8 at zero (or near) false activations is the minimum bar for
ever wiring attribution into live approvals — a detector that fires on a bystander's
voice would attribute their command to the wearer, which is worse than no attribution at
all. Keep every capture file: they seed the study corpus either way.

---

## Session 5 — Cloud backend and fail-through (~20 min, needs network + OpenAI key)

Smoke item 6 in full. Note a live Realtime session bills to your OpenAI account
(cents, not dollars, at this duration).

| # | Check | Pass criterion |
|---|-------|----------------|
| 5.1 | `serve --voice-backend openai-realtime` with key exported | Ready block prints `Voice backend: openai-realtime (fail-through: apple)`; a live approval answered by voice takes effect |
| 5.2 | Wi-Fi off while a response window is open | **Window resolves** (Apple-stack voice, gesture, tap, or timeout) — never hangs; later windows work on-device; mic never stuck open between windows |
| 5.3 | Key unset, same flag, direct executable | Exact error `OpenAI Realtime voice requires OPENAI_API_KEY…`, `exit=1` — refuses rather than silently serving on-device |
| 5.4 | Wi-Fi restored, new serve | Cloud path works again |

**Gate G5 — a hung window in 5.2 is the serious failure.** Fail-through exists so a
network problem costs latency, never the interaction. A window that cannot be resolved
is worse than having no cloud backend; that outcome blocks shipping the flag.

---

## Results log

Copy this skeleton into your run notes; a bad number is data, a missing number is not.

```
Hardware: macOS ____ / AirPods ____ (fw ____) / Mac ____          Date: ____

S1 regression:            PASS / FAIL (detail: ____)
S2 clock offset (2.1):    first ____ ms, last ____ ms
S2 auth behavior (2.4):   abort-69 / silent-buffers        ← G3
S3 calibration (3.1):     sustained ____ g, resting ____ g, required ____ g
S4 baseline (4.1/4.2):    P ____ R ____ F1 ____ onset ____ s   (default / calibrated)
S4 silent control (4.3):  ____ false activations
S4 matrix (4.5–4.11):     chew ____  walk ____  gesture ____  bystander ____
                          music ____  walk+speak P/R ____/____  whisper ____
S5 fail-through (5.2):    resolved by ____ ; mic released: Y/N
Verdict per gate:         G1 __ G2 __ G3 __ G4 __ G5 __
```

## What the outcomes decide

- **All gates pass, matrix clean** → proceed to the full capture study with this exact
  tooling; `WearerGatedVoice` live wiring becomes a thresholds-and-review decision.
- **G3 silent-buffers** → add the mic-authorization gate before any study recording.
- **Matrix rows fail** → the study's job is now threshold retuning against the recorded
  corpus (config change, no code change); keep all captures.
- **G2 or G5 fail** → code defects; fix before anything else consumes the tooling.
