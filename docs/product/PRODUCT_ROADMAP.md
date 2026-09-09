# TapQ Product Roadmap — Outcome Oriented

**Status:** Directional, not a commitment to dates  
**Last updated:** 2026-09-08

This roadmap complements TapQ's technical roadmap by organizing product work around user outcomes rather than only integrations and capabilities.

## North-star vision

> **Let people stay present in the real world while AI remains available, informed, and controllable.**

---

## Horizon 0 — Developer Agent Mode

**Outcome:** Users can supervise AI coding agents without repeatedly returning to a screen.

### Existing / active capabilities

- spoken agent prompts,
- approve / deny by voice or motion,
- option selection,
- completion announcements,
- follow-up instructions,
- questions about agent work,
- multiple agent adapters,
- fail-through to native on-screen behavior.

### Product work still needed

- measure time saved / context switches avoided,
- instrument interaction acceptance and fallback,
- improve multi-agent queue UX,
- reduce false gesture detection,
- test accessibility configurations,
- document user journeys and adoption funnel.

### Exit criterion

A repeat cohort chooses TapQ because it materially reduces screen-return behavior while supervising agents.

---

## Horizon 1 — Business Mode — **Priority**

**Outcome:** Professionals remain engaged in meetings while privately receiving context and retaining decisions.

### MVP

- explicit meeting session,
- transcription,
- rolling context,
- candidate concept detection,
- proactive “want an explanation?” offer,
- nod / shake response,
- concise contextual explanation,
- post-meeting summary,
- decision/action-item extraction,
- glossary,
- delete / retention controls.

### Follow-on

- user vocabulary personalization,
- “save for later” gesture / voice action,
- calendar-aware session setup,
- organization glossary,
- exports to common work systems,
- meeting follow-up agent actions.

### Exit criterion

Users repeatedly accept useful clarifications and choose Business Mode for real meetings without reporting unacceptable interruption or trust concerns.

---

## Horizon 2 — Lecture Mode

**Outcome:** Students capture and understand lectures without splitting attention between the instructor and a device.

### Proposed capabilities

- lecture session capture,
- structured notes,
- key-concept detection,
- discreet “explain this” interactions,
- glossary,
- unresolved-question list,
- summary by topic,
- post-lecture review prompts.

### Research questions

- Does proactive clarification help or distract during learning?
- Should student mode be manual-first rather than proactive-first?
- How should equations, diagrams, or board content be incorporated?
- What accessibility use cases emerge?

### Exit criterion

Students demonstrate improved perceived comprehension and repeat use without increased distraction.

---

## Horizon 3 — Travel / Translation Mode

**Outcome:** Travelers understand and respond to unfamiliar language without repeatedly handling a phone.

### Proposed capabilities

- integrate best-available translation provider,
- private translated audio,
- context-aware follow-up questions,
- phrase generation,
- saved travel context,
- translate + act workflows.

### Strategic constraint

Basic live translation is already bundled into major ecosystems and dedicated devices. TapQ should not build a translation engine as a primary moat.

### Differentiated experiences

- “What did they mean by that?”
- “Was that a price or a time?”
- “Tell them I have a reservation.”
- “Remember these instructions.”

### Exit criterion

TapQ adds meaningful context or action beyond what native translation already provides.

---

## Cross-cutting platform roadmap

### Interaction

- lower false-positive motion recognition,
- wake-word-light / wake-wordless interaction research,
- interruption arbitration,
- richer gesture vocabulary only when reliable,
- cross-device input.

### Context

- session memory,
- user-authorized persistent memory,
- contextual entity/term extraction,
- “what just happened?” short-term recall,
- domain vocabulary.

### Privacy

- explicit recording session model,
- retention controls,
- local processing where feasible,
- provider routing,
- enterprise policy layer.

### Device expansion

- Apple Watch,
- other earbuds,
- smart glasses,
- rings and additional subtle-input devices where APIs support reliable control.

---

## Prioritization framework

Use **RICE + strategic fit**, with safety as a gate rather than a score.

### Factors

- **Reach:** how many target users experience the problem?
- **Impact:** how much attention/time/comprehension does it improve?
- **Confidence:** quality of user evidence and technical validation.
- **Effort:** engineering/design/research cost.
- **Strategic fit:** does it strengthen TapQ's ambient interaction layer?
- **Safety gate:** can it fail without causing unacceptable harm or privacy risk?

### Current directional prioritization

| Initiative | Reach | Impact | Confidence | Effort | Strategic fit | Priority |
|---|---:|---:|---:|---:|---:|---|
| Business Mode MVP | High in target cohort | High | Medium | High | Very high | **P0** |
| Developer multi-agent UX | Medium | High | High | Medium | Very high | **P0** |
| Lecture Mode | Medium-high | Medium-high | Medium-low | Medium | High | P1 |
| Apple Watch support | Medium | Medium | Medium | Medium-high | High | P1 |
| Travel contextual layer | High | Medium | Medium | Medium | Medium | P2 |
| Build proprietary translation model | High | Low strategic differentiation | Low | Very high | Low | Do not prioritize |

