# Agent M1 + M2 hardware smoke checklist

Verifies milestones M1 (wearer memory + transcript answers, PR #40) and M2
(the deliberation loop, PR #41) of TAPQ_AGENT_PLAN.md on real hardware.
Order matters: each part builds on the previous one's state.

Setup: runtime launched with `--voice-backend openai-realtime
--voice-freeform --voice-trust environment --voice-instructions
--voice-session`; a Claude Code session in ~/tapq-arena with hooks
installed; AirPods in. The ready block must show `openai-realtime`,
semantic turn detection, and the voice-session hold. Log signatures below
are grep-able in the runtime's TAPQ_DEBUG stderr log.

## Part A — ask about the work (M1 Pillar B)

- [ ] **A1 — transcript attaches.** In Claude Code, run something with
  visible output (`git status`). Approve by voice; let it finish.
  Log: `transcript.attached`, then `transcript.tailed bytes=…`.
- [ ] **A2 — the answer quotes reality.** Say: *"What did git status
  say?"* Expect a spoken answer quoting the actual output (branch name,
  clean/dirty). Under M2 the hold can reach ~35 s worst case; typical is
  a few seconds. Log: `ask.requested`, `ask.answered latency_ms=…
  slices=…`. Note the latency — it is a pending maintainer call.
- [ ] **A3 — honest unavailability.** Ask about an agent with no
  transcript: *"What did Codex run?"* Expect a plain spoken "can't see
  that history" — never silence — and the session stays alive.
- [ ] **A4 — follow-ups cohere.** Immediately ask: *"Which branch was
  that on?"* The answer should follow from A2's exchange (grounding).

## Part B — TapQ's own memory (M1 Pillar A)

- [ ] **B1 — recall within the run.** Minutes after some exchanges, ask:
  *"What was the thing I asked you earlier?"* Expect a correct recall of
  your earlier request (verbatim-ish — your words are stored verbatim).
- [ ] **B2 — memory survives a restart.** Have the runtime restarted,
  then ask the same question. The answer must survive the restart.
  The file: `wearer-conversation.jsonl` under the runtime's
  application-support dir.
- [ ] **B3 — `tapq memory clear` wipes.** Run it in a terminal (it
  confirms; names the path and entry count). Ask again — expect an
  honest "nothing remembered", not a fabricated memory.

## Part C — the deliberation loop (M2)

- [ ] **C1 — a knowledge task.** Say: *"Check what Claude Code is doing
  and tell me."* Expect an immediate spoken acknowledgment, then a
  spoken result when the loop finishes. Log: `tool.start_task_requested`,
  `task.started`, `task.step n=… tool=…`, `task.finished steps=…`.
- [ ] **C2 — a task that acts.** Say: *"Run the tests and tell me if
  anything fails."* Expect: acknowledgment; the loop announces the
  instruction it queues ("I told Claude Code to …"); the command still
  hits the normal approval gate (approve it by voice — the loop cannot
  approve); later, a spoken outcome. The loop's authority is only what
  dictation already had.
- [ ] **C3 — one task at a time.** While C2's task is still running,
  hand TapQ another goal. Expect a spoken busy refusal, not a queue.
  Log: `task.busy`.
- [ ] **C4 — the loop asks you.** Give a goal that needs a decision:
  *"Tell the agent to clean up the scratch files, but check with me
  first."* Expect TapQ to ask a question, pause, and resume with your
  answer. An unanswered question ends the task audibly at the question
  machinery's own bound (~4 min).
- [ ] **C5 — honest failure.** Give an impossible goal: *"Figure out why
  the production deploy failed."* Expect a spoken "I couldn't finish /
  couldn't find that" — never silent abandonment.
- [ ] **C6 — memory and transcript combine.** Say: *"What did I ask you
  to do earlier, and did Claude Code actually do it?"* The answer should
  draw on both your conversation record and the agent's transcript.
- [ ] **C7 — cancellation is the one silent ending.** End the voice
  session (tap/gesture) mid-task. The task cancels without speech (the
  session itself is ending); the started record stays in memory.
  Log: `task.cancelled reason=…`.

## Part D — the loop stays subordinate (M2 guardrails)

- [ ] **D1 — no approval bypass.** During C2, confirm the approval
  question reached you before the command ran, and that denying it works:
  repeat with a deny — the loop's task should surface the denial honestly.
- [ ] **D2 — reflex stays instant.** With and without a task running,
  a plain "approve" on a pending request must resolve immediately — no
  loop in that path.

## Part E — optional, destructive

- [ ] **E1 — voice break is loud.** Drop the network mid-question.
  Expect the ratified break: one local notice, dead voice for the run,
  clear error-level diagnostics. No half-alive session, no second voice.

Findings go back into TAPQ_AGENT_PLAN.md; the known pending calls this
smoke should inform: the ~35 s worst-case answer hold, the missing
`--no-memory` flag, and M3's initiative budgets.
