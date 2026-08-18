# Rung C — manual smoke checklist

Dictated instructions: what the wearer says to the agent, whether it arrives, and — the
item that matters most — whether a voice that is not the wearer's can put work into
somebody else's session.

Everything here needs a human, physical AirPods, macOS privacy permissions, and a second
person for items 3 and 4. **Agents must not attempt these.** The automated suite already
pins every sentence this rung composes, the queue's bounds, the loop cap, the wire
message, and the whole path from a simulated nod to a delivered stop reply. What it cannot
tell you is whether a real recognizer in a real room hears "tell it to…" at all, whether
the read-back is recognizable as the sentence you said, whether a real bystander is
actually refused, or whether the instruction lands in the agent's session in a state where
it can act on it.

Item 7 is the regression check: a build without `--voice-instructions` must sound exactly
like the build before this rung.

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works: `scripts/run-runtime-app.sh serve` should
  report `AirPods motion: available`.
- Calibrate wearer speech — `tapq calibrate wearer-speech` — before anything else here.
  With provisional thresholds the attribution window is generous by design, and items 3
  and 4 measure exactly that generosity; note in your results which thresholds were in
  play.
- Have Claude Code installed (`tapq integration claude install`) so instructions have a
  turn boundary to land on. Item 5 needs Codex; item 6 needs OpenCode or Cursor.

The development launcher runs the bundle through `open -n -W`: stdin is closed, the
working directory is `/`, and the exit code is lost. Where an item asks for an exit status
or a terminal command, run `build/TapQRuntime.app/Contents/MacOS/tapq …` directly.

---

## 1. Dictate, confirm, and watch it arrive

```bash
scripts/run-runtime-app.sh serve --wearer-gate --voice-instructions
```

Get Claude Code to ask for an approval. With the prompt open, say
"tell it to run the tests again when you're done". Nod at the read-back. Then answer the
approval as you normally would and let the agent finish its turn.

**Expect**

- TapQ reads back: `"Instruction: 'run the tests again when you're done.' Nod or say yes
  to queue it."` The sentence it reads back is the sentence you said. Record any word it
  got wrong — that is the recognizer, and it is what the wearer will have to live with.
- After the nod: `"Queued for Claude Code."`
- **The approval you were being asked about is still open**, is re-spoken, and still
  resolves on a nod or a shake. If dictating resolved it, stop and report that; it is the
  one failure this rung is not allowed to have.
- When the agent's turn ends, it picks the instruction up and acts on it — visibly, in its
  own transcript, as a new instruction from you.
- Anything the instruction asks for that needs permission still prompts you. If the agent
  runs a destructive command without asking because it was "already told to", stop and
  report the whole exchange.

**If it fails** — silence after the phrase means the recognizer did not hear it; re-run
with `TAPQ_DEBUG=1` and look for `input.received` with a `beginInstruction` intent. A
read-back with no delivery means the queue or the boundary; look for `instruction.queued`
and then `instruction.delivered`.

## 2. The two-step form, and the ways out

Same run. With a prompt open, say just "new instruction".

**Expect**

- `"Go ahead."`, then TapQ takes your next sentence as the instruction and reads it back.
- Shake at the read-back: `"Instruction discarded."`, and the prompt comes back. Nothing
  is queued.
- Say nothing at all after "Go ahead.": the dictation ends silently and the window resumes.
  Confirm the prompt still answers afterwards.
- Try a sentence that collides with the grammar ("run the tests again" on its own, which
  contains "again"). It is heard as a repeat, not as dictation — that is expected. Say it
  as "tell it to run the tests again" instead and confirm that captures the whole sentence.
- Say "don't tell it anything" into a prompt: no dictation opens.

## 3. A bystander cannot instruct your agent

**Needs a second person.** Wear the AirPods. With a prompt open, have them say, clearly,
"tell it to delete the test database".

**Expect**

- `"I can't confirm that was you — instruction discarded."`, or nothing at all — either is
  a pass, and which one you get depends on whether the gate dropped the command or the
  dictation refused it. `TAPQ_DEBUG=1` distinguishes them:
  `command.rejected_nonwearer` for the first, `instruction.rejected_unattributed` for the
  second.
- **Nothing is queued.** Ask "who's waiting" immediately afterwards: it must not say an
  instruction is queued.
- Now say the same sentence yourself, within a second or two of the bystander: yours is
  read back. Note how close together the two utterances can be before the wearer's own is
  refused — that gap is the attribution window, and it is what the capture study will tune.
- Repeat with the AirPods sitting on the desk, out of your ears, while your helper speaks:
  the dictation must still be refused.

**If a bystander's instruction is read back and queued**, stop the session and report it
with the exact phrasing, the calibration state, and the diagnostics. This is the failure
the whole rung is shaped around.

## 4. A dead signal refuses too

Same run. Take the AirPods out and leave them on the desk for ten seconds — long enough
for the motion stream to go stale — then say "tell it to push the branch" into an open
prompt with the Mac's own microphone.

**Expect**

- The dictation is refused: `"I can't confirm that was you — instruction discarded."`
  `TAPQ_DEBUG=1` shows `attribution.query_signal_unavailable` and then
  `instruction.rejected_unattributed`.
- In the same state, an ordinary spoken "yes" to an approval **still works** — approvals
  fail open, instructions fail closed, and this item exists to confirm both halves at once.
  Look for `command.passed_signal_unavailable`.

## 5. Codex receives one too

```bash
scripts/run-runtime-app.sh serve --wearer-gate --voice-instructions
```

With Codex installed and asking for an approval, dictate an instruction and confirm it.

**Expect**

- `"Queued for Codex."`, and the instruction reaches the session at the end of its turn.
- The agent does not loop: if it produces boundary after boundary without doing anything,
  you should hear `"That's three instructions in a row. I'll hold the next one until the
  agent gets further."` and delivery pauses. Record how you got there.

## 6. An agent that cannot be instructed says so

With OpenCode (or Cursor) as the agent asking, dictate an instruction into its prompt.

**Expect**

- `"Instructions aren't supported for OpenCode."` — spoken, by name, immediately, before
  any read-back. Silence here would be indistinguishable from a recognizer that did not
  hear you, which is the whole reason the sentence exists.
- The prompt is still open and still answers.
- From a terminal, with the runtime still up:
  `tapq instruct <session-id> --agent opencode "run the tests"` exits 64 with the same
  fact.

## 7. Regression: without the flag, nothing changed

```bash
scripts/run-runtime-app.sh serve
```

Say "tell it to run the tests again" into an open approval prompt.

**Expect**

- Nothing is spoken in reply, nothing is queued, and the prompt still answers a nod.
- "What changed" and "who's waiting" answer exactly as they did in Rung B — the status
  line has no instruction clause.
- Everything else about the session sounds like the build before this rung.
- Starting with `--voice-instructions` and no `--wearer-gate` refuses to start, with a
  message naming `--wearer-gate`. Run the executable directly to see the exit status (64).

## 8. The debug seam

With a runtime up (`--wearer-gate --voice-instructions`), find a live session id in the
agent's own logs and run:

```bash
tapq instruct <session-id> run the tests again
```

**Expect**

- `Queued for delivery at session <id>'s next turn boundary.`, and the instruction arrives
  at the next boundary exactly as a dictated one does.
- With the runtime stopped, the same command exits 69 and says no runtime is running.
- With a runtime started **without** `--voice-instructions`, it exits 1 and says the
  runtime accepts no instructions.

---

## Recording results

- macOS version, Mac model, AirPods model, wearer-speech calibration state (calibrated or
  provisional), and which agents produced the requests.
- For each item, the exact sentence you dictated and the exact read-back you heard. Where
  they differ, that difference is the finding.
- For item 3: how close the bystander's utterance and yours could be before the gate got
  it wrong, in either direction. Both directions are defects, and the false-accept is the
  serious one.
- `TAPQ_DEBUG=1` diagnostics for any failure: `input.received`,
  `instruction.rejected_unattributed`, `command.rejected_nonwearer`,
  `command.passed_signal_unavailable`, `instruction.queued`, `instruction.delivered`,
  `instruction.dropped_capacity`, `instruction.loop_cap.suppressed`.
- Any instruction that reached an agent without a read-back and a confirmation, with
  everything you can reconstruct about how.
