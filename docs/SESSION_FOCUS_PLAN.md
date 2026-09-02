# Session focus: "start a new session" by voice

Status: plan, agreed with the maintainer 2026-09-02. Builds on Rung H leg 2
(`rung-h2-owned-sessions`, built, unwired). Rung H leg 1 (the voice session) is
merged and in use; nothing here changes it.

## 0. The idea in plain words

TapQ has one focus. When the wearer says "start a new session", TapQ starts one
and moves its focus there. The session that had the focus is not killed; it is
**detached**: it can no longer reach the wearer through TapQ, and TapQ no longer
sends it anything. A keyboard-started session goes back to being an ordinary
terminal session. A session TapQ started, which has no terminal, is wound down.

Every one of these moments is written to the wearer's memory, so "what happened
to the test-suite session" has an answer tomorrow.

Out of scope, on purpose: jumping back to a detached session, naming sessions,
addressing two sessions of the same agent, Rung F's roster, Rung G.

## 1. Rules

1. **One focus.** Exactly one session per agent can reach the wearer. Today the
   roster (`AgentRoster`, `Sources/TapQCLI/AgentRoster.swift`) refuses as
   *ambiguous* when it sees two live sessions for one agent. Focus replaces
   ambiguity: the roster resolves a name to the focused session, always.
2. **Newest wins.** Focus moves to a session the wearer asked TapQ to start. It
   also moves to a session the wearer started at the keyboard while another was
   live — the same rule, so a second terminal never produces a refusal.
3. **Detach is loud once, then silent.** The switch is announced in one
   sentence, including what happened to the old session and to anything the
   wearer had waiting on it. After that the old session is never spoken for.
4. **Detach is not destructive.** Claude Code keeps every session's transcript
   on disk under its id. TapQ deletes nothing and kills nothing it did not
   start. (It cannot run `/clear`: hooks deliver text to the model, not to the
   prompt.)
5. **Confirm only when work is running.** If the focused session is mid-task
   (`SessionContextStore` knows a turn is open or work was left running), TapQ
   asks first: "Claude Code is mid-task. Start a new session anyway?" A yes or
   a nod proceeds. Otherwise no confirmation.
6. **Wearer-attributed, or gesture-confirmed.** Under `--voice-trust
   environment` a bystander's "start a new session" must not move the focus.
   Same rule as dictation: attribution or a gesture.

## 2. What a detached session gets, per hook

Every hook arrives with its session id, so the rule is one check at dispatch
(`BrokerServer.swift:173` and the runtime handlers behind it).

| Hook from the detached session | Today | Detached |
|---|---|---|
| PreToolUse / PermissionRequest | Spoken prompt, up to 240 s, then defer | **Deferred to the screen immediately**, nothing spoken. Owned (headless) session: **denied** with reason "TapQ moved on" so it can wind down |
| Notification | Spoken or held for a quiet moment | Logged, never spoken |
| Stop | Narrated; in a voice session the boundary is held | Not narrated; boundary **not held**, hook returns at once |
| Stop with a follow-up set | Follow-up fires | Cancelled at the switch (see §3); nothing fires |
| UserPromptSubmit | May inject a queued instruction | Nothing injected |
| Spoken "tell Claude Code to …" | That session | The focused session |

## 3. The switch, in order

1. Resolve the request (§1 rules 5–6). Refusals are spoken, as leg 2's are.
2. Start the new session (leg 2 launcher) **before** touching the old one, so a
   spawn failure leaves the old session exactly as it was.
3. Move focus. From this instant the old session is detached (§2).
4. Release the old session's held boundary:
   `InstructionWaitRegistry` gains `release(session:)` beside `releaseAll()`.
5. Cancel its follow-ups and report-backs (`WearerFollowupBook.cancel(agent:)`;
   the book is per agent, which is right while there is one focus per agent).
6. Drop its queued instructions from the instruction store.
7. Owned old session: deny pending approvals, let the process finish its turn
   and exit; kill after `OwnedSessionBudget` grace if it does not.
8. Record (§4) and speak: "Focus moved to the new Claude Code session. The old
   one is back on the keyboard. Your follow-up on the test suite is cancelled."

## 4. Memory

New dialogue kind `session` in `WearerConversationStore`, alongside `task`,
`instruction`, `followup`:

- `session started` — the goal, the agent, a short id.
- `session focus moved` — from which id to which, and what was cancelled.
- `session detached: keyboard` / `session detached: stopped` — how the old one
  ended.
- `session ended` — an owned session's process exited.

Plus a durable session book, `sessions.jsonl` next to
`wearer-conversation.jsonl`: id, agent, working directory, goal, started-at,
ended-at, how it ended, whether TapQ owned it. Read by nothing yet; it is what
"go back to the previous session" would read later, and what a runtime restart
uses to know which session is focused.

## 5. Steps

| # | Step | Where | Tests |
|---|---|---|---|
| 0 | Rebase `rung-h2-owned-sessions` onto the current base | git | existing 515 lines of launcher tests stay green |
| 1 | **Focus state.** `SessionFocus` in the runtime: current session per agent; roster resolves to it; keyboard-started second session takes focus with an announcement. Remove the roster's ambiguity refusal | `AgentRoster`, `AppleTapQRuntimeService` | roster tests: newest wins, no ambiguity |
| 2 | **Detached fast path.** One check at dispatch; per-hook behavior of §2. `InstructionWaitRegistry.release(session:)` | `BrokerServer`, runtime handlers, `InstructionWaitRegistry` | one test per hook: detached session's approval defers at once, stop not held, notification silent |
| 3 | **Wire leg 2.** Compose `OwnedClaudeSessionLauncher`; working directory = the focused session's, else `--session-directory`; contact timeout as built. Replace its one-at-a-time guard with the focus rule (focus moves, old detaches) | runtime composition, launcher | launcher tests updated for the new guard |
| 4 | **The voice door.** Tenth tool `start_session(goal)`, declared with the others; the task lane routes "start a new session …" to it instead of `cannotDo`. Confirmation when mid-task (§1.5); attribution (§1.6) | `VoiceIntentTools`, `WearerTaskLoop`, `RealtimeDefaults` prompts | tool-intent tests; task-loop test that the goal is no longer refused |
| 5 | **Owned detach.** Deny pending approvals, release, let exit, kill after grace; spoken "stopped" | launcher, runtime | process-runner tests |
| 6 | **Memory.** `session` kind + `sessions.jsonl` book; restart reads focus back | `WearerConversationStore`, new `SessionBook` | store tests; recall answers "what happened to …" |
| 7 | Docs (`CLI.md` voice sessions, `VOICE_ONLY_AGENT_PLAN.md` §7), smoke checklist, hardware run: cold start → new session → second "new session" mid-task with confirmation → old session shows its own prompt | docs | — |

Order matters: 1–2 are independent of leg 2 and can land first (they also fix
the "two terminals = refusal" behavior on their own). 3–5 need the rebase. 6 can
ride with any of them.

## 6. Open decisions

1. **Working directory for a voice-started session.** Recommended: the focused
   session's directory when there is one, else a configured default. Never
   inferred from the spoken goal.
2. **Phrase.** "Start a new session" and "new session for ⟨goal⟩". Must not
   collide with "cancel the follow-up" or the end-session phrases.
3. **Keyboard-started second session takes focus (rule 2).** Recommended yes;
   the alternative is today's refusal.

## 7. Size

Steps 1–2: two days. Steps 3–5: three days after the rebase. Step 6: one day.
About a week, plus a hardware run. Rung F is not needed for any of it.
