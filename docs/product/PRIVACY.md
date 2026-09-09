# Privacy Principles

TapQ's product vision includes increasingly context-aware experiences. That makes privacy and user control part of the product, not an afterthought.

This document describes principles for current and planned TapQ experiences. Exact implementation may evolve with each feature.

## 1. Explicit capture

Meeting, lecture, or other ambient capture modes should start only after an explicit user action.

TapQ should not disguise recording or transcription as passive background behavior.

## 2. Clear state

When a capture session is active, the product should make that state easy to verify and easy to stop.

A user should never need to wonder:

> “Is TapQ recording right now?”

## 3. Consent comes first

Recording and transcription laws vary by location and context. Companies, schools, conferences, and meeting organizers may also have their own rules.

Users must obtain any consent required before enabling a capture mode. TapQ should make that responsibility clear in the experience.

## 4. Private output by default

When possible, AI assistance should be delivered through the user's earbuds rather than through a shared speaker or screen.

Private delivery is especially important for contextual explanations during meetings and lectures.

## 5. Minimize retained data

Planned session features should avoid retaining raw audio longer than needed for the experience. Users should have clear controls for reviewing and deleting stored session data.

Retention behavior should be documented rather than assumed.

## 6. Proactive does not mean autonomous

TapQ may identify moments where assistance could help, but a proactive suggestion should not automatically trigger consequential actions.

Examples:

- offering an explanation can be low risk,
- sending a message, approving a sensitive action, or speaking on behalf of the user may require stronger confirmation.

## 7. Safe failure

If TapQ is uncertain about a gesture, voice attribution, context, or user intent, the safe behavior is to do nothing or fall back to a conventional interface.

Ambiguity should not become accidental action.

## 8. User control over AI context

As TapQ expands, users should be able to understand what context an AI model receives and when external services are involved.

The product should favor transparent boundaries over invisible data flows.

---

Privacy behavior for shipped functionality is defined by the implementation and repository documentation. Planned modes described here are product direction, not a claim that every privacy control is already implemented.
