# Rung D — manual smoke checklist

The largest hardware list of the ladder, because Rung D is the rung whose four legs are all
things software cannot check about itself: whether echo cancellation actually cancels,
whether a tone is audible in a room, what continuous motion costs a battery, and whether a
filter that answers approvals on your behalf answers the ones you would have.

Everything here needs a human, physical AirPods, macOS privacy permissions, a device
eligible for Apple's on-device Foundation Model (items 1–3), and a second person for
item 6. **Agents must not attempt these.** The automated suite already pins the verdict
matrix, the audit-log discipline, the routing table, the hold semantics, the cue waveforms,
and the whole path from a simulated onset to a spoken answer. What it cannot tell you is
whether any of it is *good enough on your head*.

Item 12 is the regression check: with all four flags off, the build must be
indistinguishable from Rung C.

Items 1–3 (auto-answer live-fire), 8 (chime audibility), 9 (always-on battery), and 10 (AEC
quality) are the four the plan calls out. Do those even if you do nothing else.

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works: `scripts/run-runtime-app.sh serve` should
  report `AirPods motion: available`.
- Calibrate everything — `tapq calibrate` — and especially wearer speech, which items 4–7
  depend on. Note in your results whether thresholds were calibrated or provisional.
- Confirm the reasoner loads: `scripts/run-runtime-app.sh serve --reasoner apple
  --reasoner-mode primary` must report `Stage-2 reasoner: primary (apple)` and **not**
  "unavailable". Items 1–3 measure nothing on a device that degrades to no reasoner.
- Start each auto-answer item from a clean audit log: `rm -f "$HOME/Library/Application
  Support/TapQ/runtime/auto-answer-log.jsonl"`.
- Have Claude Code installed (`tapq integration claude install`).

The development launcher runs the bundle through `open -n -W`: stdin is closed, the working
directory is `/`, and the exit code is lost. Where an item asks for an exit status or a
terminal command, run `build/TapQRuntime.app/Contents/MacOS/tapq …` directly.

---

## 1. Auto-answer live-fire: what does it actually answer?

**The item this rung exists to justify.** Everything else can be re-run later; this one has
to be done with real agent traffic, because the question is not "does the filter work" but
"does the model's idea of routine match yours".

```bash
scripts/run-runtime-app.sh serve --reasoner apple --reasoner-mode primary \
    --auto-answer routine
```

Work with Claude Code for a full hour of ordinary tasks — reading files, running tests,
editing code, whatever your real work looks like. Do not curate the session.

**Expect**

- The startup line reads `Auto-answer: routine (min confidence 0.8, 0 never-auto tools)`.
- Some approvals never reach you. Others do, exactly as before.
- Ask "who's waiting" at some point: the status line ends
  `"Auto-answered N this session."` with a plausible N.

**Then read the log, line by line:**

```bash
python3 -m json.tool --json-lines \
    < "$HOME/Library/Application Support/TapQ/runtime/auto-answer-log.jsonl"
```

For **every** row, ask yourself: would I have said yes to this without thinking? Record

- the total count, and the count you would *not* have approved unhesitatingly;
- any row whose `summary` you consider sensitive in your environment even if it is routine
  in general (deploy scripts, anything touching credentials, anything with a blast radius
  outside the repository);
- any row whose `tool_name` you would want on `never_auto_tools`;
- the spread of `confidence`, so a sensible default floor can be argued about with data.

**One row you would not have approved is a finding, not a rounding error.** Report it with
the full line. The filter's premise is that `routine` means "nobody would want to be woken
for this"; a counterexample refutes the premise, not the implementation.

Also confirm the log's discipline on disk:

```bash
ls -l "$HOME/Library/Application Support/TapQ/runtime/auto-answer-log.jsonl"   # 0600
```

## 2. The filter declines when it should

Same run, or a fresh one. Get the agent to ask for something plainly destructive — deleting
a directory, force-pushing, rewriting history.

**Expect**

- You are asked, out loud, exactly as you would be without the flag, and the confirmation
  is whatever `--reasoner-mode primary` escalated it to (very likely a double gesture or
  gesture-and-voice).
- No row appears in the auto-answer log for it: the log records what was answered, not what
  was asked.
- Now put a tool you know gets auto-answered onto the never-list:

  ```bash
  cat > "$HOME/Library/Application Support/TapQ/auto-answer-policy.json" <<'JSON'
  {"schema_version": 1, "minimum_confidence": 0.8, "never_auto_tools": ["Bash"]}
  JSON
  tapq policy show
  ```

  Restart the runtime and confirm the startup line now says `1 never-auto tool` and that
  `Bash` approvals reach you again.

## 3. A broken policy file stops the runtime

```bash
echo '{ not json' > "$HOME/Library/Application Support/TapQ/auto-answer-policy.json"
build/TapQRuntime.app/Contents/MacOS/tapq serve --reasoner apple \
    --reasoner-mode primary --auto-answer routine
```

**Expect**

- It refuses to start, with a message about the policy, and a non-zero exit status.
- `tapq policy show` fails the same way, with the same message — that is where an operator
  is supposed to find the typo.
- Restore or delete the file and confirm both start cleanly again. With **no** file,
  `tapq policy show` says `Source: defaults (no file)`.

**A runtime that starts and quietly uses the defaults here is a serious defect**: the file
exists to narrow what gets answered, and ignoring it widens it.

## 4. An attention window opens when you speak

```bash
scripts/run-runtime-app.sh serve --wearer-gate --attention imu
```

With **nothing** pending — no agent waiting on you — say "status" out loud.

**Expect**

- `"Yes?"` within a beat of you starting to speak, then `"Nothing is waiting."`
- Say "what changed" in another window: you hear the last session's recent history.
- Say nothing after "Yes?": the window closes silently after about eight seconds. Confirm
  it does not stay open.
- Record how often a window opens when you did **not** mean to open one — talking to a
  colleague, on a call, muttering. This is the number that decides whether the feature is
  usable, and it is the one no test can produce.

**If the window never opens**, run with `TAPQ_DEBUG=1` and look for `Attention` events:
`onset.ignored_request_waiting` means the gate was busy, no event at all means the
wearer-speech signal is not reaching the arming — check that motion is available and that
the detector hold is held (`detection.hold_acquired` at startup).

## 5. An attention window cannot answer for the agent

Same run. With nothing pending, say "status", and then — inside the window — **nod**.

**Expect**

- `"Nothing is waiting."` and the window keeps listening.
- Nothing is approved. Check the agent: no tool ran.
- Repeat with "yes", "no", and "the first one". All four are refused the same way.
- Now do the opposite: while an approval **is** open, speak. You must get the approval
  window's own behavior — no "Yes?", no second window. `TAPQ_DEBUG=1` shows
  `onset.ignored_request_waiting`.

**If a nod inside an attention window resolves anything at all**, stop and report it. This
is the invariant the leg is shaped around.

## 6. A bystander does not open your window

**Needs a second person.** Same run. Take the AirPods out, put them on the desk, and have
your helper talk near them for a minute.

**Expect**

- No windows open. `"Yes?"` in an empty room is the failure mode here.
- Put the AirPods back in and confirm your own speech opens one again.
- Record any window a bystander opened while you were wearing them, with what they said.

## 7. Dictating between requests

```bash
scripts/run-runtime-app.sh serve --wearer-gate --attention imu --voice-instructions
```

Let Claude Code ask for something and answer it. Then, with nothing pending, say
"tell it to run the tests again".

**Expect**

- `"Yes?"`, the read-back, and `"Queued for Claude Code."` — addressed to the agent whose
  request you just answered.
- The instruction arrives at that agent's next turn boundary.
- Before any request has been served in a run, the same dictation is refused rather than
  guessing an addressee.

## 8. Chime audibility

```bash
scripts/run-runtime-app.sh serve --quiet
```

**The item the whole quiet leg depends on.** A cue nobody notices is worse than silence,
because the wearer thinks nothing happened.

Test in at least three places: a quiet room, a noisy one (café, street, fan), and with
music or a call playing through the same AirPods.

**Expect**

- An approval prompt plays a **rising two-tone** cue. An agent notification plays **one
  flat, lower** tone. Record whether you can tell them apart without thinking, in each
  environment. That distinction is the entire information content of quiet mode.
- Both are audible over music and over street noise. Record any environment where one is
  not.
- Neither clicks, pops, or is startlingly loud. Record the opposite if you hear it.
- After a prompt cue, say "status": you hear the request spoken in full. Then nod: it
  resolves normally. **Confirm you can always find out what you are approving.**
- "What changed", "details", and a dictation read-back are all still spoken.
- Take the AirPods out mid-window: you hear the notification cue, not silence.

**If you cannot reliably distinguish the two cues**, that is a finding about the waveforms,
not about you. Report the environment and what you heard.

## 9. Always-on battery cost

**Two sessions, same length, same work, same starting charge.** Two hours each is enough to
see the difference; four is better. Do not use the Mac's battery for anything unusual in
either.

```bash
# Session A (baseline)
scripts/run-runtime-app.sh serve --wearer-gate
# Session B (always-on)
scripts/run-runtime-app.sh serve --wearer-gate --attention imu
```

**Record for each**

- AirPods charge at start and end (both buds), from the Bluetooth menu or the widget.
- Mac battery percentage at start and end, and `pmset -g batt` output at both ends.
- Whether either bud got warm.
- Whether the AirPods dropped their motion connection at any point (you would hear the
  disconnect notice).

**Report the delta**, not the absolutes. The number that matters is "how much shorter is an
AirPods session with `--attention imu`", and it belongs in `docs/CLI.md` only once it has
been measured on more than one pair — until then the documentation says "materially
shorter" on purpose.

Also confirm the hold releases: stop the runtime and check with `TAPQ_DEBUG=1` that
`detection.hold_released` and then `motion.stopped` appear. A hold that outlives the run
would leave the IMU streaming after shutdown.

## 10. AEC quality (voice-processing spike)

```bash
scripts/run-runtime-app.sh serve --voice-processing
```

**This item decides whether acoustic barge-in is ever built.** The flag is a spike; its
whole purpose is to produce this measurement.

**Expect and record**

- Startup reports `Voice processing: experimental, enabled (half-duplex unchanged)`.
- Voice commands still work at all. Say "yes" and "no" into prompts; record any drop in
  recognition compared with a run without the flag. AGC changes the signal the recognizer
  sees, and this is where that shows up.
- **The echo test.** While TapQ is speaking a long prompt, speak over it. TapQ still
  ignores you — half-duplex is unchanged and that is correct — but run with `TAPQ_DEBUG=1`
  and look at whether the microphone path reports its own playback as input. Note whether
  the input level tracks TapQ's own speech.
- With `--imu-turn-control`, confirm IMU barge-in still interrupts playback exactly as it
  does without `--voice-processing`.
- Any `configuration_changed` failure at startup. Exactly one configuration change is
  forgiven, within a second of the start that armed it; a window that dies at startup with
  this flag is a finding.
- Compare wearer-speech endpointing with and without the flag: does speech-end still commit
  the turn at the same moment? AGC shifts the RMS envelope the endpointing reads, and a
  drift here would be the reason to keep the flag off.

**The verdict to write down**: is the echo reference good enough that a future duplex mode
could tell TapQ's own voice from yours? "No" is a perfectly good answer and is cheaper to
learn here than after barge-in is built.

## 11. Everything at once

```bash
scripts/run-runtime-app.sh serve --reasoner apple --reasoner-mode primary \
    --auto-answer routine --wearer-gate --attention imu --quiet
```

Half an hour of ordinary work with all four legs on (minus the experimental one).

**Expect**

- Cues for prompts, speech for everything you ask for, windows that open when you speak,
  and approvals you never hear about.
- No cue for an auto-answered approval — it is silent, and a cue would defeat it.
- "Status" inside an attention window reports both the queue and the auto-answer count.
- Nothing stutters, overlaps, or talks over itself. Record any two sounds that collide.

## 12. Regression: with the flags off, nothing changed

```bash
scripts/run-runtime-app.sh serve
```

**Expect**

- No `Auto-answer:`, `Attention:`, `Voice processing:`, or `Quiet output:` line at startup.
- Every prompt is spoken in full. No tone is ever played.
- Detection stops between windows: `TAPQ_DEBUG=1` shows `motion.stopped` after each window
  and no `detection.hold_acquired` anywhere.
- No `auto-answer-log.jsonl` is created.
- "Who's waiting" and "what changed" answer exactly as they did in Rung C — the status line
  has no auto-answer clause.
- Speaking between requests does nothing at all.
- One behavior *has* changed on purpose, and this is where to confirm it: with
  `--no-announcements`, an agent notification is still silent, but asking "what changed?"
  afterwards **does** report it. Before this rung it did not.

Then confirm the refusals:

```bash
build/TapQRuntime.app/Contents/MacOS/tapq serve --auto-answer routine            # 64
build/TapQRuntime.app/Contents/MacOS/tapq serve --reasoner apple --auto-answer routine  # 64
build/TapQRuntime.app/Contents/MacOS/tapq serve --attention imu                  # 64
```

Each must name the flag it needs.

---

## Recording results

- macOS version, Mac model, AirPods model, calibration state, Foundation Model eligibility,
  and which agents produced the requests.
- **Item 1:** the whole audit log, plus your verdict on every row. This is the rung's
  primary artifact.
- **Item 8:** for each of the three environments, whether you could distinguish the two
  cues, and whether you missed any.
- **Item 9:** the four charge readings and the delta, per session.
- **Item 10:** the AEC verdict in one sentence, plus any recognition or endpointing drift.
- `TAPQ_DEBUG=1` diagnostics for any failure: `approval.auto_allowed`, `write_failed`,
  `detection.hold_acquired`, `detection.hold_released`, `detection.stopped_hold_active`,
  `onset.ignored_request_waiting`, `onset.ignored_window_open`, `window.arming`,
  `window.finished`, `intent.ignored`, `cue.played`, `cue.unavailable`,
  `cue.configuration_changed`, `voice_processing`.
- Any approval that was answered without you, that you would not have answered yourself —
  reported as a defect, with the log line, whatever else passed.
