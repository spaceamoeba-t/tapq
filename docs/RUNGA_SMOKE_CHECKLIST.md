# Rung A — manual smoke checklist

Spoken summaries: what TapQ says about an agent's final reply, verified by listening to it
on real hardware.

Everything here needs a human, physical AirPods, macOS privacy permissions, and — for the
cloud items — a live network and an API key. **Agents must not attempt these.** The
automated suite already pins every string this feature produces and every seam that can be
faked. What it cannot do is judge whether a summary is *useful*, whether a sentence is
short enough to sit through before the question arrives, or whether Apple's on-device model
answers within its five-second bound on the machine in front of you.

Item 5 is the regression check: `--speech-summarizer off` must sound exactly like the build
before this feature. If it does not, that is a defect regardless of how well the rest went.

> **Scope, since 2026-08-28.** Every phrasing pinned below — the summary sentence in front
> of a question, the `details` text, the multi-option preamble — is the
> `--voice-backend apple` behavior, which is the default and is unchanged. On
> `--voice-backend openai-realtime` a narration model decides what is said at a turn
> boundary and `--speech-summarizer` has no effect there, so run every item on the Apple
> backend. Narration has its own checklist item in
> [Rung C, item 10](RUNGC_SMOKE_CHECKLIST.md).

## Before you start

- Build the runtime bundle once: `scripts/package-runtime-app.sh debug`.
- Connect AirPods and confirm head motion works at all: `scripts/run-runtime-app.sh serve`
  should report `AirPods motion: available`.
- Have an agent installed that sends final-response text — Claude Code
  (`tapq integration claude install`) or Codex. Cursor sends none, so it cannot exercise
  any item here.
- Export `ANTHROPIC_API_KEY` or `OPENAI_API_KEY` in the launching shell for item 4 only.

The development launcher runs the bundle through `open -n -W`: stdin is closed, the working
directory is `/`, and the exit code is lost. Environment variables are inherited, so
`TAPQ_DEBUG=1` and the API keys work through it. Where an item asks for an exit status, run
`build/TapQRuntime.app/Contents/MacOS/tapq ...` directly instead.

---

## 1. Yes/no stop question: the sentence, then the question

```bash
scripts/run-runtime-app.sh serve
```

Ask the agent to do something substantial and to finish by asking a yes/no question about
it — for example, "refactor this file, then ask me whether to delete the old version".

**Expect**

- The prompt is one summary sentence followed by the question, then "Yes or no?", spoken as
  a single utterance: `"Claude: <one sentence about the work>. <the question>. Yes or no?"`
- The sentence describes what the agent actually did. It is not the first line of the reply
  read out verbatim, and it is not something the reply never said.
- The whole utterance is short enough to sit through. Record it if it is not; the caps are
  120 characters for the sentence and 6 words (64 characters) for the condensed question,
  and an utterance that still feels long is a tuning result worth having.
- A nod approves and a shake denies, exactly as before. The summary changes what you hear,
  never what the answer means.

**If it fails** — no sentence at all means the summarizer returned nothing. Re-run with
`TAPQ_DEBUG=1` and look for `summarizer.selected` in the ready diagnostics and
`summary.unavailable` on the stop question. On a device without Apple Intelligence,
`summarizer.selected` reporting `heuristic` is correct, not a failure.

## 2. "Details" on a stop question

With the same prompt open, say "details" (or "tell me more") instead of answering.

**Expect**

- TapQ speaks the summary's longer text — several sentences of what the reply said.
- It does **not** say "No further details.", which is what every stop question said before
  this feature.
- The window stays open and a nod still approves afterwards.

## 3. Multi-option question: introduced once

```bash
scripts/run-runtime-app.sh serve --steering
```

Prompt the agent to ask you to choose between options (Claude Code's `AskUserQuestion`).

**Expect**

- The first utterance is the summary sentence, then the question, then "1 of N: <option>",
  then the controls hint on the session's first question.
- Navigating with a volume swipe, a lateral double tilt, or "next" speaks only the new
  option — **the sentence is not repeated**.
- Saying "repeat" re-speaks the question, the current option, and the controls — **and
  still not the sentence**. Hearing the introduction a second time is the defect this item
  exists to catch.

## 4. Cloud summarizers

```bash
scripts/run-runtime-app.sh serve --speech-summarizer anthropic
# and, separately:
scripts/run-runtime-app.sh serve --speech-summarizer openai
```

**Expect**

- The ready diagnostics (`TAPQ_DEBUG=1`) report `summarizer.selected` with
  `anthropic_haiku` or `openai_gpt_5_6_luna`.
- Stop questions behave as in items 1 through 3, with a noticeably better sentence than the
  heuristic produces on a long or code-heavy reply. Compare against
  `--speech-summarizer heuristic` on the same reply and record both.
- The prompt still arrives promptly. The provider bound is five seconds; a request that
  loses the race degrades to the local heuristic sentence, not to a delayed prompt. A
  prompt that takes longer than about five seconds to be spoken is a defect.

**Then verify the startup contract.** With the key unset:

```bash
unset ANTHROPIC_API_KEY
build/TapQRuntime.app/Contents/MacOS/tapq serve --speech-summarizer anthropic; echo $?
```

- Serving refuses to start, prints the missing-key message, and exits `1`. It must not
  start and quietly summarize with something else.

**Also try** `--speech-summarizer apple` on a machine without Apple Intelligence: the same
refusal, naming the unavailable model.

## 5. Regression: `off` sounds like the old build

```bash
scripts/run-runtime-app.sh serve --speech-summarizer off
```

Repeat items 1, 2, and 3.

**Expect**

- The yes/no prompt is `"Claude: <the question>. Yes or no?"` with no sentence in front.
- "details" says "No further details."
- The multi-option prompt has no introduction.
- Agent notifications say "Claude is waiting." / "Claude finished." with nothing appended,
  even though the Claude adapter does send a short message with them.
- Tool-approval prompts are identical in every configuration, on and off. If any approval
  prompt ever contains model-written words, stop and report it — that is the one invariant
  this rung is not allowed to spend.

## 6. Notifications and the realtime voice

```bash
scripts/run-runtime-app.sh serve --voice-backend openai-realtime
```

Let the agent finish a turn while you are not watching the screen.

**Expect**

- The notification is spoken in the **cloud voice**, and it says the agent's short message:
  "Claude is waiting: <what it is waiting on>."
- Approval prompts and stop questions are still spoken by the **local** synthesizer, in the
  local voice. The change of voice mid-session is the audible signal that the split is
  working: status lines may be rendered by the model, sentences that name an action may not.
- With `--speech-summarizer off` **and** `--voice-backend openai-realtime`, notifications
  are still spoken in the cloud voice — they just no longer carry the agent's message.
  Whose voice speaks and what the words are are independent settings.
- If the realtime session is closed or busy, the notification is spoken locally instead.
  Nothing is ever dropped; record it if an announcement goes missing.

---

## Recording results

- macOS version, Mac model, AirPods model, and which agent produced the replies.
- For each item, the exact utterance you heard. The sentence quality is the whole point of
  the rung, and it cannot be asserted in a test.
- `summarizer.selected` from `TAPQ_DEBUG=1` for every run — a heuristic fallback you did
  not ask for changes what item 1 is measuring.
- Any reply where the sentence was wrong about what the agent did, with the reply text.
  A summary that misstates the work is more serious than one that says too little.
