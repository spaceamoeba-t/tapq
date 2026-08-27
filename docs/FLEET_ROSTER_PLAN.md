# Fleet roster: routing instructions across agent sessions

Status: design agreed 2026-08-27. Rung E (single-session v0) in implementation;
the full roster (rung F) is designed but deliberately deferred.

## Problem

TapQ triages a fleet but cannot command one. Every wire message carries a
`sessionID` and an `AgentIdentity`, the gate serializes attention, and the wearer
can hear who is waiting — but a dictated instruction can only be addressed
implicitly: the session whose window is open (`dictationTarget`), or the last
session served (`standingTarget`). "Tell Codex to run the tests" while a Claude
window is open has nowhere to go.

There is also no roster: TapQ only knows sessions that have *asked* something
(wait registry, context store, instruction queue). A session quietly working has
never been seen.

## Invariants that do not move, in any rung

- **InteractionGate stays FIFO.** One spoken window at a time; routing never
  touches attention scheduling.
- **Decisions stay pinned.** Approvals, selections, and stop-answers always apply
  to the open window. Only the instruction channel is routable — the resolver is
  structurally unreachable from any decision path.
- **Delivery is unchanged.** Per-session `InstructionMailbox` (cap 4, drop-oldest),
  `InstructionWaitRegistry` held Stop boundaries, delivery at a turn boundary.
- **Redaction by construction.** Anything the roster stores is speech-safe:
  session ID, agent identity, timestamps, display labels. No `toolInput`, no
  `cwd`, no `permissionMode` — the types have nowhere to put them.
- **The read-back is the safety mechanism.** A routed instruction's read-back
  names the resolved target ("Queued for Codex."), so a misroute is caught out
  loud before anything is queued. No confidence scores.

## Rung E (v0, shipping now): one session per adapter

Assumption: each adapter has at most one active session. Under it, "the last
session this agent contacted us from" *is* the session, and the entire roster
collapses to a per-agent map inside `ConversationMemory`:

- `agentID → (sessionID, AgentIdentity, lastSeen)`, updated as a side effect of
  traffic TapQ already observes. Liveness is a last-seen expiry (~30 min).
  No wire change, no adapter hooks, no new module.
- **Resolver seam.** Target resolution is a closure/protocol in the style of
  `InstructionCapabilityChecking` / `InstructionDictating`, so rung F's roster
  replaces the map behind the same interface without touching grammar, read-back,
  or tests.
- **Grammar (deterministic, minimal).** A leading "tell <agent> to …" address,
  matched case-insensitively against live display names ("claude" matches
  "Claude Code" when unambiguous). The address is stripped before queueing. No
  address → exactly today's behavior.
- **The guard (the one piece of complexity kept).** If a second distinct session
  ID is observed for the same agent inside the liveness window, that agent is
  *ambiguous*: name-routing for it is refused — fail closed, out loud, and
  nothing is queued anywhere ("More than one Claude Code session is active —
  say it from that session's window"). Refusal, not fallback: silently
  delivering to a guessed session is the exact failure this design exists to
  prevent. The assumption is known-false in TapQ's primary scenario (people run
  multiple Claude Code sessions), so it must degrade honestly, never misroute
  silently. Ambiguity clears when the stale session expires.
- Capability checks still apply: a name-route to an agent whose adapter does not
  accept instructions is refused by name, exactly like today's in-window refusal.

Scope: one PR, essentially confined to `TapQCLI` (map + resolver + grammar +
read-back + status wording) and its tests.

## Rung F (full roster, deferred): multiple sessions per agent

Built only when someone actually hits the two-sessions-per-agent wall.

- **`FleetRoster`** — a bounded, in-memory store in the house style (`Sendable`
  value type with caps, `@MainActor`-owned, FIFO/LRU eviction, last-seen expiry):
  session ID, agent, first/last-seen, speakable label. Populated two ways:
  - *Passively* (~80%): `roster.noteSeen(session, agent)` on every message the
    broker already dispatches.
  - *Announce* (the remaining 20%): wire v7 adds `session.announce`
    (started/ended), gated by `minimumVersion` exactly like `instruction.submit`
    (v5) and `instruction.wait` (v6). Claude Code adapter first
    (SessionStart/SessionEnd hook specs in `HookInstaller`); every other agent
    stays passive and appears on first activity.
- **Speakable labels** are display name + stable ordinal ("Claude Code two") —
  session IDs are opaque and never spoken. Task-derived labels ("the one running
  tests") are a later, model-assisted rung.
- **Resolver stays heuristic**: named agent with exactly one live match → route;
  exactly one live session total → route; otherwise fall back or ask one
  disambiguation question ("Claude Code one or two?"). A model enters the
  routing path only in a rung beyond F, grounded on `SessionContextStore`
  digests (already speech-safe).
- **Fleet status line**: `SessionRecall` grows a roster-fed line — "Three
  sessions running: two Claude Code, one Codex. Codex is waiting." — within the
  existing `statusCharacterLimit`.
- Module diff: `TapQWireProtocol` (v7 + announce), `TapQClaudeAdapter` (hook
  specs + shim announce), `TapQBrokerRuntime` (one arm + `onSessionEvent`
  callback), `TapQContextBaseline` (`FleetRoster`), `TapQCLI` (resolver reads
  roster; ordinal labels; disambiguation question).
- Known seam with existing caps: the roster may know sessions
  `SessionContextStore` (cap 8, first-seen eviction) has evicted; recall then
  degrades to "nothing recorded", same as today.

## Explicitly out of scope (all rungs so far)

- Roster persistence or heartbeats — expiry is the whole liveness story.
- Orchestration / fan-out: one utterance targets exactly one session. A full
  orchestrator needs conversation state and output prose the voice-agent gap
  analysis (docs/VOICE_AGENT_PLAN.md) already flags as missing.
- Routing anything other than instructions.
