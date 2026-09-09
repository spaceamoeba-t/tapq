# TapQ Product Strategy

**Status:** Living strategy document  
**Last updated:** 2026-09-08  
**Product:** TapQ

## 1. Executive summary

TapQ's thesis is simple:

> **AI should meet people where their attention already is, instead of repeatedly pulling them back to a screen.**

Chatbots and AI agents are becoming a routine layer of knowledge work. At the same time, today's assistant interaction still has visible friction: open an app, look at a screen, type, tap, or speak a wake phrase such as “Hey Siri” or “Hey Google.” Those interaction patterns can feel unnatural in meetings, classrooms, public spaces, and focused work.

TapQ uses devices people already wear — starting with AirPods — as a private interaction surface for AI. Voice delivers context. Head motion and hardware controls capture low-friction responses. AI-agent adapters connect the interaction back to real work.

The existing TapQ wedge is developer-agent supervision: users can hear agent prompts and respond by voice or gesture without returning to the terminal. The next strategic expansion is **Business Mode**, where TapQ becomes a real-time meeting copilot that can capture context, privately clarify unfamiliar terminology when useful, and produce structured notes after the meeting.

The long-term opportunity is not “AI in earbuds.” It is an **agent-neutral, device-neutral interaction layer for ambient computing**.

---

## 2. Problem

### 2.1 AI capability is scaling faster than human attention

Modern users increasingly delegate work to AI systems, but supervising those systems still requires frequent attention shifts. The interface remains centered on screens even when the actual work is asynchronous or conversational.

TapQ's existing developer experience already demonstrates this problem: an AI agent may be capable of working independently, but a permission request, clarification, or completion event can stall until the user returns to the terminal.

### 2.2 Voice assistants still create social friction

Wake phrases are functional but conspicuous. Saying “Hey Siri” or “Hey Google” in a meeting, lecture, shared office, or quiet public space announces the interaction to everyone nearby. That makes the assistant less usable precisely when private assistance would be valuable.

The product opportunity is not to remove voice entirely. It is to make the interaction **situationally appropriate**:

- AI speaks privately through an earbud.
- A nod, shake, tap, or short reply can communicate intent.
- The user should not need to open a phone for routine interactions.
- Proactive assistance should be rare, high-confidence, and interruptible.

### 2.3 Existing meeting tools are mostly retrospective

Meeting products are good at recording, transcription, summaries, action items, and post-meeting search. The less-served opportunity is **private, real-time assistance while the conversation is still happening**.

A participant may hear an unfamiliar acronym, technical concept, company name, financial term, or domain-specific reference. Searching a phone can be distracting or socially awkward. Asking the room can interrupt the conversation. Waiting until later means the user may misunderstand the rest of the discussion.

TapQ can use the conversation's recent context to offer a short, private clarification at the moment it matters.

---

## 3. Product vision

### Vision

**Turn everyday wearables into the human interface for AI.**

TapQ should let users interact with AI agents naturally while walking, working, meeting, learning, or traveling — without requiring a dedicated AI gadget or constant screen attention.

### Mission

Build the interaction layer that lets AI:

1. reach the user at the right moment,
2. understand the current context,
3. ask for human judgment when needed,
4. accept discreet responses,
5. return useful information privately,
6. fail safely back to a conventional interface.

### Long-term positioning

> **TapQ is the control layer between people, their wearables, and their AI agents.**

---

## 4. Strategic wedge and expansion

### Phase 0 — Developer Agent Mode: prove the interaction model

**Status: Existing / evolving**

TapQ currently focuses on developers supervising coding agents such as Claude Code, Codex, Cursor, and OpenCode. This is a strong wedge because:

- AI-agent users already experience repeated supervision interruptions.
- Developer workflows expose clear approval / deny / choose / follow-up actions.
- Head gestures map naturally to binary decisions.
- Users can measure whether hands-free interaction reduces context switching.

The existing product also provides a technical base: AirPods motion handling, spoken prompts, voice backends, wearer attribution, agent adapters, and fail-through behavior.

### Phase 1 — Business Mode: expand from agent supervision to ambient knowledge work

**Priority: Highest new product priority**

Business Mode targets meetings, conferences, and professional conversations.

Core value:

> Stay present in the conversation while TapQ privately helps you understand it and remember it.

The MVP should focus on:

- explicit meeting-session start/stop,
- real-time transcription,
- context-aware detection of unfamiliar or potentially important terminology,
- optional private clarification via AirPods,
- nod/shake response,
- post-meeting summary, decisions, action items, and glossary.

### Phase 2 — Lecture Mode: turn passive capture into active learning

**Priority: After Business Mode validation**

Lecture Mode applies the same context engine to education:

- capture lecture content,
- identify concepts likely to need clarification,
- allow discreet “explain this” interactions,
- produce structured lecture notes,
- surface key ideas and unresolved questions,
- generate a review summary after class.

### Phase 3 — Travel / Translation Mode: support cross-language interaction

**Priority: Later / integration-led**

Real-time translation is already becoming native to major device ecosystems. TapQ should avoid competing on basic speech translation alone.

The differentiated opportunity is to combine translation with context and agency:

- “What did they mean by that?”
- “Is this price per person or total?”
- “Tell them I have a reservation under Wang.”
- “Summarize the instructions they just gave me.”

TapQ should use best-available translation services rather than treat translation quality itself as the core moat.

---

## 5. Target users

### Primary persona — AI-native knowledge worker

Examples:

- software engineers,
- product managers,
- founders,
- consultants,
- researchers,
- finance and strategy professionals.

Behavioral characteristics matter more than degrees or job titles:

- uses AI tools frequently,
- already pays for one or more AI subscriptions,
- often uses AirPods or equivalent earbuds,
- values focus and fast information access,
- frequently works across meetings and asynchronous AI tasks,
- is comfortable delegating work to AI but wants control over important decisions.

### Secondary persona — university student

Common needs:

- lecture note capture,
- concept clarification,
- study review,
- terminology and abbreviation explanations,
- staying focused on the lecturer rather than switching to a phone or laptop.

### Future persona — international traveler / cross-language professional

Common needs:

- low-friction translation,
- context-aware explanation,
- fast response generation,
- hands-free assistance while moving.

---

## 6. Research insight behind the product

Early qualitative research among technology workers showed a recurring overlap between heavy users of AI products — including coding agents and general-purpose assistants — and Apple/AirPods users. Additional observation among graduate students suggested a similar pattern: both premium earbuds and AI subscriptions are increasingly perceived as high-value daily tools.

This is **directional evidence, not a population estimate**. The current research sample is biased toward highly technical and highly educated users. The strategic implication is therefore not “all AirPods users are AI power users.” It is:

> There is a reachable early-adopter segment that already owns the hardware and already understands the value of paid AI.

That reduces two forms of adoption friction at once: no new hardware purchase and little need to teach users why AI assistance is useful.

---

## 7. Product principles

### 7.1 Use hardware people already own

Avoid requiring a new pendant, pin, ring, or glasses product for the core experience when existing earbuds, phones, watches, and computers can provide the necessary sensing, audio, and compute.

### 7.2 Private by default

Audio assistance should be delivered through the user's ear whenever possible. Sensitive meeting content should not be spoken through a room speaker.

### 7.3 Proactive, not intrusive

TapQ may notice opportunities to help, but interruption must be tightly controlled. The product should optimize for **useful interventions per interruption**, not number of interventions.

### 7.4 Explicit recording mode

Meeting and lecture capture must never be disguised as background surveillance. Recording starts intentionally, has a visible status in the companion UI, and requires the user to acknowledge consent responsibilities.

### 7.5 Context before generic knowledge

When explaining a term, TapQ should use the surrounding conversation to infer what the term means *here*, rather than providing a generic dictionary response.

### 7.6 Human confirmation for consequential actions

A head gesture may approve a low-risk response. High-impact actions should require stronger confirmation or fall back to screen.

### 7.7 Graceful failure

If confidence is low, audio is unreliable, or the gesture is ambiguous, TapQ should do nothing or fall back to a conventional interface rather than invent an action.

---

## 8. Differentiation

TapQ should not position itself as another:

- general chatbot,
- meeting recorder,
- transcription service,
- dedicated wearable,
- translation engine.

Its differentiated combination is:

1. **Existing-device leverage** — starts with AirPods and computers users already own.
2. **Private in-ear output** — assistance is directed to the wearer rather than the room.
3. **Motion as intent** — nod/shake/tap create a silent response channel.
4. **Context-aware intervention** — the AI can act on what is happening now.
5. **Agent connectivity** — TapQ is designed to connect back to AI agents and workflows, not just answer questions.
6. **Safe fallback** — ambiguous interactions return to screen instead of forcing automation.

---

## 9. Business model hypotheses

Business model is intentionally not locked yet. Candidate paths:

### Individual Pro

Subscription for advanced meeting intelligence, longer history, premium models, multiple modes, and workflow integrations.

### Bring-your-own-model / bring-your-own-key

A developer-friendly path where advanced AI features can use the user's configured provider.

### Team / Enterprise

Potential future value:

- enterprise retention controls,
- meeting-policy configuration,
- SSO and admin controls,
- approved-model routing,
- CRM / project-management integrations,
- organization-specific vocabulary.

The product should validate repeated use and willingness to pay before optimizing monetization.

---

## 10. Strategic risks

### Privacy and consent

Meeting capture can create legal, ethical, and enterprise adoption risk. Consent workflow and transparent recording state are product requirements, not legal copy added later.

### False proactive interventions

A system that repeatedly interrupts with unnecessary explanations will be disabled quickly. Proactive clarification should begin conservatively.

### Audio capture quality

AirPods are excellent as a private output and wearer-control surface, but they may not be the ideal microphone for capturing an entire physical room. Business Mode should support source selection:

- system audio + microphone for online meetings,
- Mac microphone for nearby in-person meetings,
- iPhone microphone when it provides a better room-capture position,
- AirPods primarily for private output, wearer speech, and motion input.

### Platform dependence

TapQ depends on APIs and sensor access exposed by Apple and other device vendors. The long-term architecture should remain device-neutral.

### Platform bundling

Apple, Google, Meta, OpenAI, and others can bundle assistant, translation, and recording features. TapQ must differentiate through cross-agent interoperability, interaction design, context, and user control rather than a commodity model capability.

---

## 11. Strategic success test

The strategy is working if users begin describing TapQ not as “an AirPods gesture app” but as:

> **the AI interface I can use without leaving what I'm doing.**

