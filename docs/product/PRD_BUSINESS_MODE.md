# PRD — TapQ Business Mode

**Status:** Proposed / Discovery-to-MVP  
**Priority:** P0 for next product expansion  
**Product owner:** Zhuoran “Ted” Wang  
**Engineering collaborator:** Zijing Wu  
**Last updated:** 2026-09-08

## 1. Summary

Business Mode turns TapQ into a private real-time meeting copilot.

When explicitly enabled, TapQ captures the meeting context, produces a transcript, identifies potentially important or unfamiliar terminology, and can privately ask the wearer whether a quick explanation would help. The user can nod to hear the explanation, shake their head to dismiss it, or ignore the prompt. After the meeting, TapQ generates structured notes including decisions, action items, key topics, and a contextual glossary.

The product goal is not to replace existing meeting recorders. The goal is to reduce the **understanding gap during the meeting**, while preserving attention and social presence.

---

## 2. Problem statement

Professionals regularly encounter unfamiliar acronyms, domain terms, companies, products, or references during meetings and conferences. Existing choices are imperfect:

- interrupt and ask the speaker,
- open a phone or laptop to search,
- ignore the term and risk misunderstanding later discussion,
- wait until after the meeting, when context may be lost.

Users also spend time reconstructing decisions and action items after meetings.

Business Mode addresses both problems, but differentiates on the first: **private clarification while the conversation is still happening**.

---

## 3. Research basis

The prioritization originated from qualitative feedback from a prior investor and professionals in that network who described this problem in business meetings and conferences. Follow-up interviews and survey responses reinforced the hypothesis that participants sometimes encounter unfamiliar terms but do not want to interrupt the meeting or visibly search on a phone.

### Research limitation

The existing research is directional. The sample size, industry mix, seniority distribution, and frequency of the problem should be documented before making market-size claims.

Before broad launch, the team should answer:

1. How frequently does the problem occur per meeting?
2. Which user groups experience it most?
3. Is private real-time explanation meaningfully better than post-meeting search?
4. What interruption rate is acceptable?
5. What level of transcription consent is acceptable in professional environments?

---

## 4. Goals

### Primary goals

1. Let a user stay visually engaged in a meeting while receiving optional, private AI assistance.
2. Provide context-aware clarification without requiring the user to type or reach for a phone.
3. Create reliable post-meeting notes from the same captured context.
4. Reuse TapQ's motion and voice interaction model rather than introduce a new hardware product.

### Secondary goals

- Build the foundation for Lecture Mode.
- Validate proactive AI intervention as a product behavior.
- Create a reusable session/context layer for future ambient modes.

---

## 5. Non-goals for MVP

- covert or always-on recording,
- replacing regulated professional interpretation,
- real-time coaching of every sentence,
- automatically answering on the user's behalf,
- emotion detection,
- employee surveillance,
- sales-performance scoring,
- automatically sending summaries to other participants,
- full multilingual simultaneous interpretation as the core MVP.

---

## 6. Primary user story

> As a professional in a meeting, I want TapQ to privately help me understand unfamiliar concepts without pulling out my phone or interrupting the speaker, so I can stay present and follow the conversation.

### Secondary user story

> As a meeting participant, I want a trustworthy summary of decisions, action items, key concepts, and open questions after the meeting so I do not need to reconstruct the discussion manually.

---

## 7. Experience principles

### A. The meeting belongs to the humans, not the assistant

TapQ should be quiet by default. It should intervene only when the expected value is high.

### B. Ask before explaining

For proactive assistance, TapQ should not immediately lecture the wearer. It should first offer a short prompt such as:

> “Want a quick explanation of EBITDA?”

The user can nod yes, shake no, or ignore it.

### C. Keep explanations short

Default explanation target: approximately one sentence / 5–12 seconds of audio. The user can request more detail later.

### D. Use the meeting context

The answer should distinguish between generic and contextual meaning.

Example:

> “Here, ARR means annual recurring revenue — they are using it as the subscription revenue run rate.”

### E. Never hide recording state

The user intentionally starts Business Mode and can see a persistent recording/session state in the companion UI.

---

## 8. Proposed user flow

### 8.1 Start

1. User puts on AirPods.
2. User starts **Business Mode** from TapQ or an explicit voice/control action.
3. TapQ shows the audio source and recording status.
4. User confirms that required participant consent has been obtained.
5. TapQ begins transcription and context processing.

### 8.2 During meeting

1. Speech is transcribed in real time.
2. Context engine maintains a rolling semantic window.
3. Concept detector identifies candidate terms or references.
4. Relevance engine estimates whether an intervention would be useful.
5. If confidence and utility thresholds are met, TapQ privately asks whether the user wants clarification.
6. User response:
   - nod → explain,
   - shake → dismiss,
   - no response → dismiss silently,
   - short voice request → expand / repeat / save for later.
7. TapQ applies a cooldown before another proactive prompt.

### 8.3 End meeting

TapQ produces:

- executive summary,
- decisions,
- action items and owners when explicitly stated,
- key topics,
- contextual glossary,
- questions the user asked TapQ,
- unresolved questions / follow-ups,
- timestamped transcript where available.

---

## 9. Functional requirements

### FR-1 — Explicit session control

The user can start, pause, resume, and stop Business Mode.

**Acceptance criteria**

- Recording/transcription does not begin before explicit start.
- Current state is visible in the companion UI.
- Stop ends audio capture immediately.

### FR-2 — Audio source selection

TapQ can choose or allow the user to choose an appropriate capture source.

**MVP sources**

- system audio + local microphone for online meetings where technically available,
- Mac microphone for in-person meetings,
- AirPods microphone where appropriate.

**Future**

- iPhone companion capture for better in-room positioning.

### FR-3 — Real-time transcription

TapQ maintains a timestamped transcript with reasonable speaker segmentation when available.

**Acceptance criteria**

- partial transcription latency is low enough to support near-real-time concept detection,
- transcript can be reviewed after the session,
- user can delete the session.

### FR-4 — Context buffer

TapQ maintains enough recent conversational context to interpret terms in their local meaning.

**Acceptance criteria**

- explanation prompt includes the detected term,
- explanation can reference recent discussion,
- deleted sessions are not silently retained in the product context store.

### FR-5 — Candidate concept detection

The system detects potentially unfamiliar or important:

- acronyms,
- domain terminology,
- named products,
- organizations,
- frameworks,
- technical concepts,
- financial/legal/industry references.

The detector should prefer precision over recall in early versions.

### FR-6 — Proactive intervention policy

The system estimates whether a concept deserves interruption.

Inputs may include:

- term rarity,
- domain specificity,
- recurrence,
- apparent importance to subsequent discussion,
- user history / known vocabulary (future),
- prior dismissals,
- time since last intervention.

**Hard requirement:** proactive assistance must have a configurable cooldown and a global off switch.

### FR-7 — Gesture response

TapQ uses existing head-motion interaction patterns where supported.

- nod → yes / explain,
- shake → no / dismiss,
- ignore → no action.

High confidence is required. Ambiguous motion must not be interpreted as affirmative.

### FR-8 — Private contextual explanation

TapQ plays a concise explanation through the user's earbuds.

**Acceptance criteria**

- default explanation is short,
- explanation distinguishes uncertainty when context is ambiguous,
- user can request “more,” “repeat,” or “save this.”

### FR-9 — Manual clarification

User can request help even when TapQ did not proactively detect the need.

Examples:

- “Explain that.”
- “What does ARR mean here?”
- “Save that for later.”
- “What did she mean by dilution?”

**Implementation note:** the current TapQ repository supports no-wake-word responses inside active response windows, while idle initiation uses an optional “hey tapq” wake mechanism. Fully wake-wordless manual question detection should be treated as a separate future interaction project rather than claimed as already shipped.

### FR-10 — Meeting notes

After session end, generate:

1. summary,
2. decisions,
3. action items,
4. topics,
5. glossary,
6. open questions,
7. user-marked important moments.

### FR-11 — Search / Ask after meeting

User can ask questions grounded in the meeting transcript.

Examples:

- “What did we decide about pricing?”
- “Who owns the follow-up with the vendor?”
- “What did ARR mean in this meeting?”

### FR-12 — Privacy controls

At minimum:

- start/stop is explicit,
- user acknowledges consent responsibility,
- local session state is visible,
- delete is available,
- retention behavior is documented,
- raw audio retention is minimized where feasible,
- sensitive transcripts are not committed to the public repository or telemetry.

---

## 10. Proposed MVP scope

### Must have

- explicit Business Mode start/stop,
- audio capture,
- real-time transcription,
- rolling context,
- candidate acronym/term detection,
- conservative proactive clarification,
- nod/shake response,
- concise in-ear explanation,
- post-meeting summary + glossary,
- deletion and basic retention controls.

### Should have

- manual “explain that” request,
- speaker labels,
- user-controlled intervention sensitivity,
- highlights / bookmarks,
- action items.

### Could have

- calendar integration,
- organization vocabulary,
- CRM export,
- Slack/Notion export,
- personalized known-vocabulary model,
- iPhone capture companion.

### Not now

- sales coaching,
- hidden recording,
- employee scoring,
- broad enterprise admin console,
- full travel translation stack.

---

## 11. Success metrics

See [`METRICS.md`](METRICS.md) for the complete framework.

### MVP decision metrics

Proposed targets to validate, not historical results:

- **Clarification acceptance rate:** >25% of proactive offers accepted during the first calibrated cohort.
- **Unwanted interruption rate:** <1 clearly unwanted proactive interruption per 30 minutes.
- **Gesture false-affirm rate:** effectively zero in high-risk confirmation paths; product target <0.1% for ordinary clarification prompts.
- **Clarification latency:** first useful audio within ~3 seconds after user nod, subject to backend/network constraints.
- **Post-meeting usefulness:** >70% of pilot users rate generated notes “useful” or better.
- **Repeat usage:** >40% of activated pilot users run Business Mode in at least 3 meetings within 30 days.

Targets should be revised after baseline testing.

---

## 12. Safety, privacy, and trust

### Recording consent

Recording laws and workplace rules vary. TapQ should not attempt to infer that recording is allowed. The user must intentionally start the session and confirm that required consent has been handled.

### Visible state

Because AirPods do not provide an outward-facing recording indicator to the room, TapQ should make recording state unambiguous in the Mac/iPhone UI and encourage explicit participant notice.

### Enterprise sensitivity

Business conversations may contain confidential information. Future enterprise readiness may require:

- configurable retention,
- approved model providers,
- local/on-device transcription options,
- encryption,
- auditability,
- admin policy controls,
- data residency choices.

### Hallucination

TapQ must distinguish “I am not sure what that means in this context” from a confident explanation. The meeting transcript is evidence, not proof.

---

## 13. Technical feasibility notes

Business Mode should reuse TapQ's existing architecture where possible:

- device adapters for AirPods,
- motion detection,
- voice backends,
- context subsystem,
- wearer attribution,
- fail-through principles.

New capabilities likely include:

- continuous session transcription pipeline,
- speaker segmentation,
- rolling semantic context,
- terminology/entity detector,
- proactive-intervention policy,
- meeting-note generator,
- session storage/retention layer,
- consent/session UI.

### Critical feasibility question

Do not assume AirPods should be the only room microphone. For many in-person meetings, the highest-quality architecture may use AirPods as **private output + wearer input + gesture sensor**, while a Mac or iPhone provides ambient capture.

---

## 14. Experiment plan

### Experiment 1 — Problem frequency

Recruit professionals across product, engineering, consulting, finance, and research. Ask them to log every moment in 10 meetings where they heard an unfamiliar term or wanted private context.

**Decision:** Is the pain frequent enough to justify real-time intervention?

### Experiment 2 — Wizard-of-Oz intervention

Use prerecorded or live test meetings. A researcher manually triggers clarification offers.

Measure:

- acceptance rate,
- interruption annoyance,
- preferred explanation length,
- ideal cooldown.

**Decision:** Is proactive assistance better than manual-only assistance?

### Experiment 3 — Detection quality

Run the concept detector on labeled meeting transcripts.

Measure:

- precision,
- recall,
- false-intervention cost,
- domain performance.

**Decision:** Can the product safely automate intervention?

### Experiment 4 — Capture architecture

Compare AirPods mic, Mac mic, iPhone mic, and online system-audio capture across meeting environments.

**Decision:** What is the minimum reliable capture configuration without dedicated hardware?

---

## 15. Launch stages

### Alpha

Internal team + trusted testers. Manual session start. Conservative interventions.

### Private beta

20–50 knowledge workers across several domains. Instrument acceptance, dismissals, latency, and repeat usage.

### Public beta

Only after:

- interruption rate is acceptable,
- consent UX is stable,
- data-retention behavior is documented,
- transcript quality meets threshold,
- false gesture affirmations are well controlled.

---

## 16. Open questions

1. Should proactive explanation be opt-in per session or enabled by default inside Business Mode?
2. Should the user build a “known vocabulary” profile?
3. How much context should be sent to external models?
4. Should raw audio be deleted immediately after transcription by default?
5. Can iPhone capture materially improve in-room audio while keeping setup simple?
6. What meeting integrations are valuable enough to justify platform-specific work?
7. What is the best balance between proactive assistance and manual “explain that” requests?

