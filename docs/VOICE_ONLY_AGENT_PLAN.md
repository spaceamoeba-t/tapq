# TapQ Voice-Only Agent Plan — Rungs E–H

*Draft 2026-08-27. Written against `main` @ `ec536ec` (post PR #33; assumes PR #34's
server-VAD fallback and GA realtime migration are merged). Successor to
`docs/VOICE_AGENT_PLAN.md` (Rungs A–D, all merged 2026-08-18). This plan takes the
shipped instruction channel and attention machinery and removes their one shared
assumption: that AirPods are in the wearer's ears.*

> **Amendment, 2026-08-27 — lean scope for the first ship.** What is being built now is
> **Rung E in full** (`--voice-trust wearer|environment`, §4) and a **lean Rung H leg 1**
> (`--voice-session`, §7): a long-polling Stop hook, a broker that answers a held turn
> boundary, and a listening window in which an unmatched sentence is dictation. **Rung F
> (intent routing, §5), Rung G (`--attention acoustic`, §6), and Rung H leg 2 (owned
> sessions) are deferred** and nothing in this pass builds toward them. Attention still
> requires an IMU; the dictation prefixes still exist and still work everywhere they do
> today. The sections below describe the whole plan and are unchanged; this note says which
> parts of it are code.

---

## 0. End state (what Rung H buys, in plain words)

You sit down at your desk — no earbuds — and say "start on the dark mode thing."
Claude Code, which was idle, starts working. While it works you talk to it like a
colleague: "how's it going," "skip that file," "also update the changelog." When it
needs permission it asks out loud and you say yes or no. When it finishes it tells
you, and waits — for your next sentence, not your next keystroke. Nothing in the
flow requires touching the keyboard, and nothing you say can authorize an action
without the same read-back or approval step that exists today.

Rungs A–D made TapQ a chief of staff in your ear. Rungs E–H make the ear optional.

## 1. Starting point (verified 2026-08-27)

What exists and works: the full Rung A–D surface — dictated instructions with
read-back confirm and turn-boundary delivery (`--voice-instructions`), attention
windows (`--attention imu`), spoken summaries, session recall, auto-answer; plus
PR #34's no-AirPods realtime path (backend server VAD commits turns when no IMU
signal exists, GA API).

Why none of it adds up to a voice-only agent today:

- `--voice-instructions` hard-requires `--wearer-gate` and **fails closed on IMU
  wearer attribution** — with no AirPods streaming, every dictation is refused.
- `--attention` has exactly two values, `off` and `imu`. Without the earbud motion
  stream there is no way to open a window when no agent is prompting.
- Dictation is triggered by grammar prefixes ("tell it to…", "new instruction") —
  an arbitrary sentence without a trigger is free-form Q&A at best.
- Delivery is a Stop-event block: an instruction to an *idle* agent queues forever,
  because an idle agent produces no turn boundaries until someone types.

Seams already built and waiting:

- `MicrophonePumpVoiceBackend.onInputLevel` — the inert acoustic-endpointer hook
  from M2, exactly where a local onset detector taps in.
- The GA realtime session is conversation-scoped and already long-lived; only mic
  ownership is windowed. GA `session.update` tooling config is one message away.
- The Rung D command window (`AttentionWindow`) is onset-source-agnostic in shape:
  the IMU is one trigger, not the design.
- The Claude shim already blocks Stop to deliver instructions; the wire and broker
  already carry `instruction.submit` from any process (`tapq instruct`).

## 2. The policy change this plan is built on (ratify first)

**Decision: when no IMU device is streaming, TapQ may assume a quiet, single-person
environment.** Owner's call, 2026-08-27: "when AirPods is not connected we can
assume the user is in a quiet and isolated space."

Concretely, one new flag names the posture:

- `--voice-trust wearer` (default) — today's behavior, byte for byte. Instructions
  fail closed on attribution; attention requires IMU.
- `--voice-trust environment` — the mic is trusted as the user. Instructions and
  attention work with no AirPods. Read-back confirmation is kept (it catches
  mis-transcription, not just misattribution); the attribution check is skipped.

What does **not** change under either value, ever: an instruction authorizes
nothing. Approvals keep their own grammar, their own read-back, and their own
fail-open-to-screen semantics. The docs state the tradeoff in one honest sentence:
under `environment`, anyone audible to the microphone can instruct — but still
cannot approve, deny, select, or defer anything the wearer wouldn't.

## 3. Prior art (why the shapes below are low-risk)

Surveyed GitHub 2026-08-27 for voice layers over coding agents. Nobody has TapQ's
approval semantics, attribution, or broker — but three mechanisms are proven in
the wild and are borrowed outright:

| Mechanism | Proven by | Borrowed into |
|---|---|---|
| Stop-hook blocking loop: hook returns the next spoken command as the Stop-block reason; session never idles | mckaywrigley/claude-code-voice (hook source read and verified) | Rung H leg 1, improved: the hook long-polls the broker instead of owning the mic, so silence costs zero model turns |
| Realtime model does intent routing via a declared tool ("forward instruction to the agent") | dhuynh95/duck_talk | Rung F |
| Spawn-and-own sessions: map conversations to headless CLI/SDK sessions, resume by id | alexknowshtml/cord, Terobyte/codeflow, omnara-ai/omnara | Rung H leg 2 |

Rejected: OS-level keystroke injection into the terminal (thepradip/micoracle) —
works, but depends on window focus and accessibility permissions, and bypasses the
wire. Wrong posture for a broker-based product.

## 4. Rung E — voice-only mode (drop the gates)

*Goal: everything Rung C/D shipped works with AirPods in the case.*

Scope:

1. **`--voice-trust wearer|environment`** as §2. Under `environment`:
   `--voice-instructions` no longer requires `--wearer-gate`; the
   `instruction.rejected_unattributed` path is bypassed (a diagnostic records that
   trust was environmental); dictation confirm accepts spoken "yes" alone — the
   nod/double-tap paths simply don't exist and are not mentioned in read-backs.
2. **Spoken-confirm parity sweep:** every flow whose confirm mentions a gesture
   (free-form nod-to-send, dictation queue confirm) gets a voice-only phrasing
   when no IMU device is present.
3. **Startup validation matrix** updated: `--voice-instructions` alone is valid
   with `--voice-trust environment`; still an error under `wearer` (unchanged).

Exit: dictation end-to-end on the no-AirPods realtime path — speak "tell it to run
the tests again" during a window, hear the read-back, say yes, watch delivery at
the next boundary. E2E suite gains a voice-only-trust trace. Default-flag runs
byte-identical to today.

## 5. Rung F — intent routing (kill the prefixes)

*Goal: an arbitrary sentence during a window becomes the right thing — answer,
question, or instruction — without magic words.*

Scope:

1. **Realtime path: tool-calling.** Declare tools on the GA session
   (`session.update`): `submit_instruction(text)`, and optionally
   `ask_status()` mapping to existing recall intents. An unmatched utterance the
   deterministic grammar didn't claim goes to the model; a `submit_instruction`
   call feeds the *existing* read-back-confirm-queue flow — the model routes, it
   never delivers. No tool call → today's behavior (grounded Q&A / free-form).
2. **Grammar stays first.** Matched commands never reach the model. The approval
   grammar cannot be expressed as a tool; there is no `approve` tool to call.
3. **Apple path unchanged** this rung: prefixes remain the trigger (the on-device
   recognizer has no tool-calling). Documented as the honest capability gap.

Exit: "run the tests again after" — no prefix — is read back as an instruction and
queued, on the realtime path; "what's it doing" gets a status answer; a matched
"yes" still resolves instantly without touching the model. Transcript tests pin
that no tool call can resolve an approval.

## 6. Rung G — always listening (`--attention acoustic`)

*Goal: speak whenever you want, not only when a window happens to be open.*

Two-tier design — the long-lived part is local; the cloud session opens on demand:

1. **Tier 1, persistent, on-device, free:** the capture engine stays alive between
   windows; a local onset detector (RMS energy via the `onInputLevel` seam, or
   Apple VAD) watches for speech. Nothing leaves the machine while idle.
2. **Tier 2, on onset:** open a standard Rung D command window — same "Yes?", same
   eight seconds, same recall/dictation/no-resolution rules — with
   `--voice-trust environment` standing in for the attribution the IMU onset used
   to provide. All window machinery is reused; only the trigger is new.
3. **Optional wake phrase** (`--attention acoustic --wake-phrase "hey tapq"`) via
   persistent on-device SFSpeechRecognizer, if bare energy onset proves
   trigger-happy even in a quiet room. Decide from a week of real use, not upfront.
4. **Half-duplex preserved:** tier 1 pauses while TapQ speaks (the existing
   self-hearing gate, applied to the persistent engine).

Deliberately not in scope: holding the OpenAI realtime session streaming during
idle (billed silence, self-hearing against server VAD, server-side session
lifetime). Revisit only if window-open latency annoys in practice.

Exit: with an idle agent and no AirPods, saying "status" from across the desk gets
"Nothing is waiting." within a second or two; a dictated instruction from a cold
start reaches the queue. Mac-only power cost measured and documented.

## 7. Rung H — the long-lived agent (idle delivery)

*Goal: "start on the dark mode thing" moves an idle agent. The doorbell.*

**Leg 1 — voice-first sessions (long-poll Stop hook).** For a session the user has
put in voice mode:

1. The Claude shim's Stop handler, instead of returning when the instruction queue
   is empty, **long-polls the broker**: "hold my turn boundary open until the next
   instruction arrives." When one arrives — minutes later, from a Rung G window —
   the shim returns the existing Stop-block with the instruction as reason, and
   the agent continues. Silence burns zero model turns (the hook is waiting, the
   model is not running). This is TapQ's shipped delivery mechanism with patience.
2. **Mode is explicit and per-session:** entered by voice ("start voice session")
   or flag, exited the same way or by keyboard. While waiting, the terminal shows
   a hook in flight — the session is deliberately voice-first; typing exits the
   mode cleanly rather than fighting it.
3. **Plumbing:** a `wait_for_instruction` long-poll on the wire; the integration
   installer writes an explicit large hook `timeout` for the Stop entry; heartbeat
   so a killed runtime releases the hook instead of hanging the session.
4. **Bounds revisit** (the old RC caps were sized for steering): loop-cap paused in
   voice-session mode — every boundary is *supposed* to carry an instruction; the
   four-deep queue stands.

**Leg 2 — owned sessions (start from nothing).** "New task: ⟨…⟩" with no live
session spawns one — headless `claude -p` with TapQ's hooks installed, session id
mapped cord-style so later instructions and approvals target it. TapQ becomes the
launcher only for sessions it creates; existing keyboard-started sessions keep leg
1. Ships after leg 1 proves the conversation loop.

*Status (2026-09-02):* wired, under **session focus** rather than "from nothing" —
see `docs/SESSION_FOCUS_PLAN.md`. "Start a new session ⟨for goal⟩" reaches the
loop's `start_session` tool; the new session takes TapQ's focus and the old one is
detached (back on its keyboard, or wound down if TapQ started it), announced once.
Hardware-unverified.

Exit (leg 1): agent finishes a task, announces it, sits in voice mode; two minutes
of silence; "tell it to also update the changelog" spoken into an acoustic window
lands without a keystroke — demoed end to end on one Mac. Exit (leg 2): "new task"
from a cold start to first approval question, hands-free throughout.

## 8. Decisions and gates

| # | Decision / gate | Recommended | Needed by |
|---|---|---|---|
| 1 | `--voice-trust environment`: mic-as-user posture, instructions never authorize | Ratify §2 as written | E |
| 2 | Model routes, never delivers: tool calls feed the read-back flow, no approval tool exists | Ratify as invariant | F |
| 3 | Always-listening is local-first; cloud audio flows only after onset | Ratify (privacy is the point) | G |
| 4 | Voice-session mode is explicit, per-session, keyboard-escapable | Ratify | H |
| 5 | Wake phrase: decide after a week of `--attention acoustic` use | Defer with data | G promotion |
| 6 | Apple-path partial-transcript race (deferred 2026-08-27) | Fix before promoting any rung to default — a voice-only agent amplifies a false-approve | E–H promotion |

## 9. Sequencing

```
E (drop gates) ──► F (intent routing) ──► G (attention acoustic) ──► H (long-lived)
   │                    │                       │                     ▲       ▲
   │                    └── realtime only ──────┘                     │       │
   ├── smallest; unblocks hands-on testing of everything after ───────┘       │
   └── Apple partial-race fix (parallel, independent) ── gates promotion ─────┘
```

E is days and makes every later rung testable on this desk with no hardware. F
rides entirely on the GA session config. G reuses Rung D's window wholesale. H
leg 1 is a patient version of shipped code; leg 2 is the only genuinely new
surface and goes last. Each rung: own flags, own smoke checklist, CI green, same
discipline as A–D.
