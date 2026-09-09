# TapQ Product Metrics

**Last updated:** 2026-09-08

## 1. North-star metric

### Helpful hands-free interactions per active user

A **helpful hands-free interaction** is an interaction completed without requiring the user to return to a screen and without being immediately reversed, rejected as mistaken, or reported as unwanted.

This metric aligns with TapQ's core value: preserving attention while keeping AI useful and controllable.

It should never be optimized without guardrails; increasing interruptions can inflate activity while harming the experience.

---

## 2. Business Mode funnel

### Awareness → Activation

- Business Mode viewed
- Business Mode started
- consent acknowledgement completed
- first meeting reaches 10 minutes
- first summary generated

### Activation definition

A user is **Business Mode activated** when they complete a meeting session and receive at least one useful output:

- accepted clarification,
- saved contextual explanation,
- meeting summary viewed,
- post-meeting question asked.

---

## 3. Real-time assistance metrics

### Clarification offer precision

`accepted clarification offers / total proactive clarification offers`

Acceptance is an imperfect proxy, so pair it with explicit feedback and dismiss patterns.

### Unwanted interruption rate

Number of proactive offers users rate as unnecessary or annoying per hour of meeting time.

### Silent dismissal rate

Percent of proactive offers with no response.

A high silent-dismissal rate may indicate poor timing, low relevance, or inaudible prompts.

### Explanation follow-up rate

Percent of accepted explanations followed by “more,” “repeat,” or another related question.

This can reveal both engagement and insufficient first-response quality.

### Time to useful answer

Time from user nod/manual request to start of the useful explanation.

---

## 4. Gesture quality metrics

### False affirmative rate

Cases where TapQ interprets a gesture as yes when the user did not intend yes.

This is the most important motion guardrail.

### False dismissal rate

Cases where an intended nod is missed or interpreted as dismissal.

### Gesture completion rate

Percent of gesture-eligible interactions successfully completed with motion rather than fallback.

### Fallback rate

Percent of interactions returned to screen/manual flow.

Fallback is not inherently bad; safe fallback is preferable to incorrect automation.

---

## 5. Meeting output metrics

### Summary usefulness

Post-session rating or task-based evaluation of whether the summary correctly captures the meeting.

### Decision recall precision

Percent of extracted “decisions” that were actually decisions.

### Action-item precision

Percent of extracted action items that are supported by the transcript and correctly attribute owner/deadline when explicit.

### Glossary usefulness

Percent of generated glossary items the user marks as relevant/useful.

### Grounding rate

Percent of post-meeting answers that can be traced to session transcript/context.

---

## 6. Retention metrics

### W1 / W4 active meeting users

Users who start at least one Business Mode session in week 1 / week 4 after activation.

### Meetings per active user

Shows whether Business Mode becomes habitual rather than a demo feature.

### Multi-mode adoption

Percent of users who use TapQ in more than one context, e.g. Developer + Business.

This tests the broader interaction-layer thesis.

---

## 7. Trust and safety guardrails

Do not ship an optimization that improves engagement while materially worsening these metrics:

- false affirmative rate,
- unwanted interruption rate,
- consent-flow completion,
- user-reported privacy incidents,
- deletion failures,
- hallucinated decision/action-item rate.

---

## 8. Proposed pilot targets

These are hypotheses for an initial pilot, not historical performance.

| Metric | Initial target |
|---|---:|
| Proactive clarification acceptance | >25% after user calibration |
| Clearly unwanted interruptions | <1 per 30 meeting minutes |
| Ordinary clarification false-affirm gesture rate | <0.1% |
| First useful explanation latency | ~3 seconds or less where backend permits |
| Post-meeting notes rated useful or better | >70% |
| Users with 3+ Business Mode meetings in first 30 days | >40% of activated pilot cohort |
| Critical consent/deletion failures | 0 |

Targets should be replaced with observed baselines after the first controlled pilot.

