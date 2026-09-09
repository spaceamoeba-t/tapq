# TapQ Product Decision Log

This document records major product decisions, why they were made, what alternatives were considered, and what evidence could reverse them.

---

## PD-001 — Use AirPods as the first interaction surface

**Status:** Accepted  
**Decision type:** Product / platform  
**Owners:** Product + Engineering

### Context

Early qualitative observation among technology workers showed substantial overlap between users who regularly use AI assistants/coding agents and users who already wear Apple AirPods. Graduate-student observation reinforced a similar early-adopter pattern: premium earbuds and AI subscriptions are both treated as high-value daily tools.

### Decision

Use AirPods as TapQ's first wearable interaction surface instead of requiring users to buy a new AI-specific device.

### Rationale

- existing installed behavior: users already wear them,
- private audio output,
- motion sensing enables subtle yes/no interaction,
- microphone/voice channel is already present,
- no additional charging/wearing habit for another device,
- strong fit with AI-native early adopters.

### Important caveat

The research cohort is not representative of all consumers. This is an early-adopter strategy, not a claim about general population overlap.

### Revisit if

- platform APIs meaningfully restrict product reliability,
- another common device provides substantially better sensing and adoption,
- user research shows AirPods ownership is a material adoption barrier.

---

## PD-002 — Prioritize Business Mode over Lecture and Travel modes

**Status:** Accepted for next discovery/MVP cycle

### Context

A prior investor surfaced a specific professional pain point: during meetings and conferences, participants often encounter terminology or abbreviations they do not understand but may not feel comfortable interrupting the room or searching on a phone.

Follow-up interviews and survey responses indicated this is a real workflow problem worth testing.

### Decision

Prioritize Business Mode as TapQ's first major use-case expansion beyond developer agents.

### Why Business Mode first

- clear problem statement,
- direct qualitative evidence,
- high willingness-to-pay potential among professional users,
- strong fit with private in-ear output,
- nod/shake interaction maps cleanly to “explain / dismiss,”
- creates reusable infrastructure for Lecture Mode,
- differentiates from ordinary meeting notes through real-time contextual assistance.

### Why not Lecture Mode first

Lecture Mode is attractive and technically adjacent, but current evidence is more anecdotal. Education willingness-to-pay may also be lower and proactive interruptions could affect learning differently.

### Why not Travel Mode first

Live translation is increasingly bundled by Apple, Google, and Meta and is a primary capability of dedicated products such as Timekettle. TapQ would have lower differentiation if it entered as a translation-first product.

### Revisit if

- Business Mode intervention acceptance is low,
- consent/privacy prevents normal professional use,
- lecture research demonstrates significantly stronger retention or adoption,
- platform translation APIs create a unique TapQ workflow opportunity.

---

## PD-003 — Differentiate on in-meeting intervention, not meeting transcription

**Status:** Accepted

### Context

ChatGPT Record, Granola, Otter, Plaud, and Limitless already provide strong meeting capture, transcription, summary, and post-meeting question answering.

### Decision

Treat transcription and summarization as enabling capabilities, not the primary product promise.

### Product promise

> TapQ privately helps you understand the meeting while it is happening, then remembers it afterward.

### Consequence

Prioritize:

- context-aware concept detection,
- interruption policy,
- private explanation,
- gesture response,
- user trust.

De-prioritize attempts to win purely on transcript formatting or generic summaries.

---

## PD-004 — Proactive assistance must ask permission before explaining

**Status:** Accepted

### Context

Continuous unsolicited AI narration would be distracting and could make the product socially unusable.

### Decision

When TapQ detects a potentially useful clarification, it first asks a minimal private question such as:

> “Want a quick explanation of ARR?”

A nod confirms; a shake or no response dismisses.

### Rationale

- preserves user agency,
- limits interruption cost,
- creates labeled feedback for personalization,
- maps directly onto TapQ's existing motion interaction.

### Revisit if

Users overwhelmingly prefer manual-only requests or if detection quality cannot support acceptable interruption rates.

---

## PD-005 — Meeting recording is explicit, not ambient-by-default

**Status:** Accepted / safety requirement

### Decision

Business and Lecture session capture starts only after explicit user action. The product must expose recording/session state and require the user to acknowledge consent responsibilities.

### Rationale

- protects trust,
- reduces covert-recording risk,
- supports enterprise adoption,
- aligns product behavior with major meeting/recording products that emphasize consent.

### Non-negotiable

Do not optimize activation by hiding or weakening recording transparency.

---

## PD-006 — AirPods are the control/output surface; capture source can vary

**Status:** Proposed technical-product principle

### Context

For an in-person meeting or lecture, a user's earbud microphone may not be the best microphone for capturing a room or distant speaker.

### Decision

Separate **interaction device** from **ambient capture device**.

TapQ should use AirPods for:

- private output,
- wearer speech,
- motion and hardware controls.

It may use Mac system audio, Mac microphone, or a future iPhone companion for meeting capture depending on environment.

### Rationale

This preserves the “no dedicated new hardware” strategy without forcing one sensor to solve every problem.

