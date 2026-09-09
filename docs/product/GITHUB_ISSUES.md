# Copy-ready GitHub Product Issues

Use these as separate issues so product work becomes visible, reviewable, and linked to engineering implementation.

---

## Issue 1 — [Epic] Business Mode: real-time meeting copilot

### Problem

Professionals can encounter unfamiliar terminology during meetings but may not want to interrupt the speaker or visibly search on a phone. Existing meeting tools are strong after the meeting; TapQ can differentiate by providing private contextual help during the conversation.

### Desired outcome

A user can explicitly start Business Mode, stay visually engaged in the meeting, receive an optional private clarification offer, nod to hear the explanation, and receive useful notes afterward.

### MVP scope

- session start/stop,
- transcription,
- context buffer,
- candidate terminology detection,
- proactive clarification offer,
- nod/shake response,
- private explanation,
- summary + glossary,
- privacy/retention controls.

### Non-goals

- covert recording,
- sales coaching,
- automatic replies on user's behalf,
- full translation product.

### Success criteria

See `docs/product/METRICS.md`.

---

## Issue 2 — [Product] Define Business Mode consent and recording-state UX

### Problem

Business Mode processes other people's speech. Users need a clear start/stop model and an unambiguous understanding of when a session is active.

### Desired behavior

- explicit start,
- consent acknowledgement,
- persistent visible state,
- immediate stop,
- clear deletion control,
- documented retention.

### Acceptance criteria

- no meeting transcription before explicit start,
- stop halts capture immediately,
- user can determine session state at a glance,
- raw captures are not exposed in public logs or repository artifacts.

---

## Issue 3 — [Product/ML] Detect clarification-worthy concepts from meeting context

### Problem

Explaining every acronym would make Business Mode unusable. We need a high-precision system that identifies terms likely to be both unfamiliar and important.

### Candidate signals

- acronym / entity detection,
- rarity,
- domain specificity,
- repeated use,
- importance to subsequent statements,
- previous user dismissals,
- user vocabulary profile (future),
- intervention cooldown.

### Product requirement

Prefer precision over recall in MVP.

### Evaluation

Build a labeled transcript dataset with:

- should offer explanation,
- should not interrupt,
- ambiguous.

Measure precision/recall and user-rated interruption cost.

---

## Issue 4 — [Interaction] Nod / shake clarification flow

### User story

As a meeting participant, I want to accept or reject a private AI offer without speaking aloud or touching my phone.

### Flow

1. TapQ: “Want a quick explanation of EBITDA?”
2. Nod → TapQ explains privately.
3. Shake → dismiss.
4. No response → dismiss after timeout.

### Safety requirements

- ambiguous motion does not become yes,
- prompt expires,
- no high-impact external action is tied to this low-friction gesture without stronger confirmation.

---

## Issue 5 — [Product] Contextual explanation response policy

### Goal

Ensure Business Mode explanations are useful without taking over the meeting.

### Default response requirements

- one concise sentence,
- grounded in recent meeting context,
- state uncertainty when ambiguous,
- avoid repeating sensitive content unnecessarily,
- support “more,” “repeat,” and “save this.”

### Example

Instead of:

> “ARR is annual recurring revenue.”

Prefer:

> “Here ARR means annual recurring revenue; they are using it as the subscription revenue run rate.”

---

## Issue 6 — [Product] Post-meeting summary and contextual glossary

### Outputs

- executive summary,
- decisions,
- action items,
- key topics,
- contextual glossary,
- unresolved questions,
- user-marked moments.

### Requirements

- extracted decisions/action items must be grounded in transcript evidence,
- uncertain owners/deadlines should not be invented,
- user can delete the meeting.

---

## Issue 7 — [Research] Business Mode pilot study

### Goal

Validate whether real-time clarification creates enough value to justify proactive intervention.

### Participants

20–50 knowledge workers across multiple domains for private beta after alpha quality gates.

### Measure

- clarification acceptance,
- unwanted interruption,
- explanation latency,
- meeting-note usefulness,
- repeat usage,
- privacy objections,
- preferred capture configuration.

### Exit decision

Proceed toward public beta only if repeat usage and usefulness are strong without unacceptable trust or interruption cost.

---

## Issue 8 — [Discovery] Lecture Mode

### Problem

Students can miss subsequent content while trying to understand an unfamiliar concept during a lecture.

### Research before build

- interview students across disciplines,
- compare proactive vs manual clarification,
- test distraction effects,
- determine need for slide/board visual context,
- test post-class summary value.

### Dependency

Reuse Business Mode session/transcription/context stack after it is validated.

---

## Issue 9 — [Discovery] Travel Mode should add context beyond native translation

### Problem

Translation is useful but already provided by Apple, Google, Meta, and specialist devices.

### Product question

What can TapQ do *after* translation that native tools do not?

Examples:

- explain cultural/contextual meaning,
- remember instructions,
- formulate a response,
- route an action to another agent,
- summarize a multi-turn exchange.

### Decision gate

Do not build a proprietary translation stack unless research shows a differentiated need.

