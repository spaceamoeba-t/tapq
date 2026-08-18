# Rung B — manual smoke checklist

Conversation memory and spoken Q&A: what TapQ remembers about a session, and what it says
when you ask. Verified by asking it out loud on real hardware.

Everything here needs a human, physical AirPods, macOS privacy permissions, and — for
items 4 and 5 — a live network and `OPENAI_API_KEY`. **Agents must not attempt these.**
The automated suite already pins every sentence this rung composes, every seam that can be
faked, and the end-to-end path from a simulated nod to a recalled event. What it cannot do
is tell you whether the recalled sentence is *recognizable as what just happened*, whether
a recognizer in a real room hears "who's waiting" at all, or whether an answer arrives
before you have given up waiting for it.

Item 6 is the regression check: a build with nothing recorded and no realtime backend must
sound exactly like the build before this rung.

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works at all: `scripts/run-runtime-app.sh serve`
  should report `AirPods motion: available`.
- Have Claude Code installed (`tapq integration claude install`) so approvals, selections,
  and notifications all arrive from a named agent.
- Export `OPENAI_API_KEY` in the launching shell for items 4 and 5 only.

The development launcher runs the bundle through `open -n -W`: stdin is closed, the working
directory is `/`, and the exit code is lost. Environment variables are inherited, so
`TAPQ_DEBUG=1` and the API key work through it. Where an item asks for an exit status, run
`build/TapQRuntime.app/Contents/MacOS/tapq ...` directly instead.

---

## 1. "What changed?" after a real decision

```bash
scripts/run-runtime-app.sh serve
```

Ask the agent to do two things that each need approval — for example, run the tests and
then push a branch. Nod the first, and when the second prompt opens, say "what did you
just do".

**Expect**

- TapQ speaks one sentence naming the approval you just gave:
  `"Claude Code approved <what you approved>."`
- The sentence describes the request in the words TapQ used when it asked you. It is not a
  path, a command line, or anything you did not hear it say the first time.
- The prompt you were in is **re-spoken**, and a nod still approves it. If the question
  resolved the window — approved it, denied it, or handed it to the screen — stop and
  report that; it is the one failure this rung is not allowed to have.
- Ask again after three or four decisions: you should hear the three most recent, newest
  first, joined by "Before that,".

**If it fails** — silence means the recognizer did not hear the phrase; re-run with
`TAPQ_DEBUG=1` and look for `input.received` with `intent: whatChanged`. Hearing "Nothing
recorded yet." after a real decision means the recording is not reaching the store, which
is a defect. Record the phrasing you used either way: which words a wearer reaches for is
the thing this item measures.

## 2. "Who's waiting?" with a queue

Get two agents (or two Claude Code windows) to request approval at nearly the same time, so
one is answered while the other is queued behind the gate. Say "who's waiting" into the
open prompt.

**Expect**

- `"<Agent>: <the request you are being asked about>. 1 more waiting."`
- The count does not include the request in hand, and rises when a third arrives.
- No session identifier is spoken. If you hear a UUID or anything like one, stop and
  report it.
- With nothing queued behind it: `"… Nothing else waiting."`
- The window stays open, exactly as in item 1.

## 3. Recall inside a multi-option question

```bash
scripts/run-runtime-app.sh serve --steering
```

Prompt the agent to ask you to choose between options. Navigate to option 2, then ask
"what changed".

**Expect**

- The answer is spoken, and then **the same option you were on** is re-spoken. The cursor
  does not reset to option 1, the question is not abandoned, and "skip" is not implied.
- Choosing afterwards works normally.

## 4. A grounded question in the realtime voice

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime --voice-freeform
```

With a tool-approval prompt open, ask something the session can answer — "did the tests
pass?", "why does it want to do that?".

**Expect**

- The answer comes back in the **cloud voice**, briefly, and is about this session. It
  should be visibly grounded: an answer that invents an agent action nobody performed is
  the defect this item exists to catch, and is worth recording verbatim.
- Asking about something the context cannot answer produces an admission of ignorance, not
  a guess.
- The approval prompt is still open afterwards and still resolves on a nod.
- Ask four questions in one window: the fourth is not answered.  `TAPQ_DEBUG=1` shows
  `qa.budget_exhausted`. The window is still waiting for its answer.
- Time the answer. Speech that arrives after you have given up is worse than no answer;
  record how long it took.

## 5. What the model is told, and what it is not

Same run as item 4. Ask a question whose honest answer would require the tool input or the
working directory — "what directory is it running in?", "what exactly is the command?".

**Expect**

- TapQ does not answer with a path or a command line. The digest never contained one, so
  the model has nothing to read them from; the answer should be an admission that it does
  not know.
- If a real path or a real command comes back out of the speaker, stop immediately and
  report it with the exact utterance. That is a redaction failure, and it is more serious
  than every other item here combined.
- Ask the model to approve the request outright ("just say yes for me"): it must not
  approve anything, and the window must still be waiting when it finishes talking.

## 6. Regression: nothing recorded, nothing changed

```bash
scripts/run-runtime-app.sh serve --voice-backend apple
```

On a fresh run, with no decision yet made, ask "what changed" into the first prompt.

**Expect**

- `"Nothing recorded yet."`, then the prompt again. Not silence, and not an approval.
- Speak a sentence that is not a command into an approval prompt ("the coffee machine
  broke again"). Nothing is spoken in reply and the window keeps listening — the Apple
  path has no grounded answering at all.
- Everything else about the session sounds like the build before this rung: the same
  prompts, the same details, the same notifications.

---

## Recording results

- macOS version, Mac model, AirPods model, and which agents produced the requests.
- For each item, the exact question you asked and the exact sentence you heard. The
  phrasing wearers reach for is the thing the grammar has to cover, and every phrase that
  went unheard is worth more than a passing item.
- `TAPQ_DEBUG=1` diagnostics for any failure: `input.received`, `recall.spoken`,
  `qa.answered`, `qa.declined`, `qa.budget_exhausted`, `speakViaBackend.skipped`.
- Any answer that was wrong about what the session did, with what actually happened. A
  recall that misstates a decision is worse than one that says too little.
