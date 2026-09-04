# Wake word: a session from nothing

Status: **planned 2026-09-03**, not started. Builds on session focus
(`docs/SESSION_FOCUS_PLAN.md`, on `tapq-agent-m3`, PR #46) and on the voice
session (Rung H leg 1, merged). Supersedes Rung G (acoustic attention, shelved
2026-09-02): the wake word is the opener Rung G was going to be, without the
attribution machinery.

Only the `openai-realtime` backend is considered. The Apple voice backend is
deprecated (`CLAUDE.md`, "Voice backend"); nothing here keeps parity with it.

## 0. The idea in plain words

Today every listening window is opened by something that already exists: an
agent's request, a Claude turn that finished and is being held, or an IMU speech
onset under a flag nobody uses. With nothing running, nothing opens a window,
so nothing listens, and the only way in is a keyboard-started session.

This plan adds one more opener. The wearer says the wake word; TapQ opens a
window that behaves exactly like the held-boundary window (a plain sentence is
an instruction); and if no session is live, that instruction starts one in a
folder TapQ makes under the wearer's home. From there the loop that exists
today takes over: the new session's first held Stop opens the voice session,
and the wake word is not needed again until everything is idle.

```
"Hey TapQ"  ──►  wake listener  ──►  window (held-boundary rules)
                                          │
                        "set up a Swift package for the parser"
                                          │
                     ┌────────────────────┴────────────────────┐
                     │ something live?                          │
                 yes │                                          │ no
                     ▼                                          ▼
              queued as its next prompt            new session in ~/TapQ/sessions/…
                                                   goal = the sentence
                                                   "Started a new Claude Code session: …"
                                                          │
                                                   first Stop held ──► voice session as today
```

## 1. Rules

1. **The wake listener runs only when nothing else is listening.** No window
   open, no request waiting, no held-boundary loop running, no TapQ speech
   draining. The moment any of those becomes true it stops; when all are false
   again it restarts. It never shares the microphone with the realtime session.
2. **The wake window is a held-boundary window.** `CommandWindowKind.voiceSession`
   semantics: a plain sentence is an instruction, read back and announced the way
   dictation is today. It differs from a held boundary in only two ways: it has
   a deadline (§3), and it is not tied to a session.
3. **One rule for "nothing is live".** Whether the sentence arrives as free text,
   as a `queue_instruction` tool call with no agent, or as `start_task` →
   `start_session`, an instruction with no live session starts one with that
   sentence as its goal. Three doors, one function.
4. **Live means live.** "Nothing is live" is judged from roster liveness, never
   from the last session TapQ spoke to. `ConversationMemory.lastTarget` is set
   on every request window and never cleared; a session that exited an hour ago
   must not swallow the wearer's sentence into a dead mailbox.
5. **TapQ makes the folder.** When no session is focused and no
   `--session-directory` was given, the new session works in a fresh folder
   under TapQ's workspace (default `~/TapQ/sessions/`). TapQ writes the hook
   settings into that folder before launching. User-level Claude settings stay
   hook-free, as they do today.
6. **No keyword matching on the realtime path.** The wake word is matched on the
   wake listener's own transcript, before any realtime session exists. Once the
   window is open, intent is the model's tool calls, exactly as today (decision
   0b, `tapq-voice-failure-posture`).
7. **Every refusal is spoken.** A wake word that cannot open a window (a request
   is waiting, the launcher is not composed, the folder cannot be made) says so
   in one sentence, through the backend voice. Silence never.

## 2. The wake listener

`WakeWordListener` in `TapQAppleAdapters`. On-device `SFSpeechRecognizer`
(`requiresOnDeviceRecognition`), its own `AVAudioEngineVoiceAudioSource`,
partial results on. This is Apple's Speech framework used as a keyword spotter;
it is not the deprecated Apple voice backend, and nothing it hears is ever
spoken by an Apple voice. `VoiceListener.start` is the template (same request
setup, same generation-guarded teardown); the new type does not share code with
it because `VoiceListener` is on its way out.

- **Phrase.** `--wake-word "hey tapq"` (default). Matching is on a normalized
  transcript: lowercased, punctuation stripped, and the spellings the recognizer
  produces for the name (`tapq`, `tap q`, `tap queue`, `tap cue`) folded to one.
  A hit anywhere in a partial or final transcript fires once per recognition
  request; the request is then ended and a new one started, so the sentence
  after the wake word is heard by the realtime session, not by this recognizer.
- **Restart.** On-device requests end on their own after about a minute and on
  every error. The listener restarts with a short back-off and logs each
  restart at debug level. Ten failures in a row is a warning and a spoken
  "Wake word listening stopped." Not a break: the voice session still works.
- **Suspend and resume.** A `WakeWordGate` in the runtime owns `start`/`stop`
  and reads four booleans: `attentionArming.isWindowOpen`, a wake window open,
  `waits.waitingCount == 0`, `voiceSessionListening.isListening`, and
  `voiceChannelDrain` idle. Every transition is a diagnostic
  (`wake.suspended reason=…`, `wake.resumed`).
- **Portable port.** `WakeWordSpotting` protocol in `TapQContracts`
  (`start(onWake:)`, `stop()`), so the arming and the gate are testable on
  Linux with a fake spotter.

## 3. The wake window

`WakeWordArming` in the runtime, beside `AttentionArming`. On `onWake`:

- Refuse and say why if a request is waiting (`"Something is waiting for you
  first."`) or a held-boundary loop is listening (nothing said; the loop is
  already listening and the word is redundant, logged as
  `wake.ignored_listening`).
- Otherwise open one `CommandWindowController` with `kind: .voiceSession`,
  cue `"Yes?"`, and a deadline of `CommandWindowController.wakeWindowSeconds`
  (20 s; a new constant, not the 60 s a held boundary gets, and not the 8 s the
  IMU window gets). `voiceMayEndSession: false`. Composed like the attention
  window (standing recall responder, shared gate, `voiceIntentSource`,
  `voiceChannelDrain`), with two differences:
  - `instructionEnqueue` is the routing closure from §4, not
    `memory.standingInstructionEnqueue`.
  - `instructionCapability` is true whenever a live Claude Code session exists
    or the owned launcher is composed.
- One window per wake word. It does not rotate; when it closes, the gate
  resumes the listener. A session the window started opens the held-boundary
  loop by itself at its first Stop.

CLI: `--attention wake` joins `off` and `imu` (`AttentionMode.wake`). It does
not require `--wearer-gate` — the wake word is the attribution. `--attention
imu` keeps its gate requirement and is otherwise untouched.

## 4. The routing rule

One function in the runtime composition, used by all three doors:

```
routeInstruction(text) -> InstructionQueueOutcome
  if let target = memory.liveStandingTarget      // §1 rule 4
      return enqueue(text, session: target)      // as today
  guard let ownedLauncher else
      return .refused("Nothing is running, and TapQ cannot start Claude Code here.")
  return startSession(goal: text)                // startSessionSurface's body, shared
      ? .startedSession(agentDisplayName)
      : .refused(refusal.spoken)
```

- **Door 1, free text.** The wake window's dictation flow calls it. A new
  `InstructionQueueOutcome.startedSession` makes the announcement
  `"Started a new Claude Code session: ⟨goal⟩."` instead of `"Queued for …"`.
- **Door 2, `queue_instruction` with no agent.** The loop's `queueInstruction`
  surface (`AppleTapQRuntimeService.swift` ~2305) today refuses "Nothing live
  answers to …". It calls the same function first; the refusal remains for a
  *named* agent that is not live.
- **Door 3, `start_task` → `start_session`.** Already lands on
  `startSessionSurface`; the shared body is extracted from it, not duplicated.
- **Grounding.** The cold-start line in `currentGrounding()`
  (`VoiceBackendCommandProvider.swift:711`) changes from "No agent names are
  known; do not fill in queue_instruction's agent" to: "No agent session is
  running. A task or instruction from the wearer starts a new Claude Code
  session; send it as queue_instruction with no agent." This is what makes the
  model call the tool rather than answer in words, so door 1 is the fallback
  and not the common path.
- **Liveness.** `ConversationMemory` gains `liveStandingTarget`: `standingTarget`
  filtered through the same liveness the `instructionAddressResolver` uses.
  `standingInstructionEnqueue` and `standingInstructionCapability` switch to it
  too, so the IMU window stops queueing into dead sessions.

## 5. The workspace

`OwnedSessionWorkspace` in `TapQClaudeAdapter`:

- Root: `--session-workspace <dir>`, default `~/TapQ/sessions`. Created on
  first use.
- `makeSessionDirectory(goal:now:) -> String`: `<root>/<yyyy-MM-dd-HHmm>-<slug>`
  where the slug is the first four words of the goal, lowercased, hyphenated,
  or `session` when the goal is the goalless prompt. Collisions get `-2`, `-3`.
- Writes `<dir>/.claude/settings.json` through
  `HookInstaller(settingsURL:hookCommand:).install()` with the runtime's hook
  command. The launcher's `hookStatus` check then reads that file, as it reads
  `--session-directory`'s today (51dfeb6).
- Runs `git init -q` in the folder. Default on, `--no-session-git` to skip. In
  hardware run 5 the first thing Claude asked in a bare folder was whether to
  initialize a repository; an empty repo removes that turn.
- `sessionDirectoryForNewSession` becomes: focused session's folder → 
  `--session-directory` → `workspace.makeSessionDirectory(goal:)`. The path is
  recorded in the session book as today, so a later "go back" knows it.
- Failure to create the folder or write the settings is a spoken refusal
  (`workingDirectoryUnusable` already exists; add `workspaceUnwritable`).

## 6. Steps

| # | Step | Where | Tests |
|---|------|-------|-------|
| 0 | Merge PR #46; branch `wake-word` off `main` | — | CI green |
| 1 | `WakeWordSpotting` port; `AttentionMode.wake`; `--attention wake` parses without `--wearer-gate`; `--wake-word`, `--session-workspace`, `--no-session-git` | Contracts, CLI | CLICommandTests |
| 2 | `WakeWordPhrase` normalizer + matcher | InteractionBaseline | new suite: spellings, false positives ("tap the queue"), once-per-request |
| 3 | `OwnedSessionWorkspace` | ClaudeAdapter | temp-dir tests: naming, collision, settings written, git init, unwritable root |
| 4 | `ConversationMemory.liveStandingTarget`; standing enqueue/capability use it | CLI | ConversationMemoryTests: dead session yields nil |
| 5 | `InstructionQueueOutcome.startedSession`; dictation flow announces it | InteractionBaseline | DictationFlow tests |
| 6 | `routeInstruction` shared body; three doors call it; grounding line | runtime, provider | RealtimeGrounding tests; loop surface tests |
| 7 | `WakeWordArming` + `WakeWordGate` with a fake spotter | runtime (portable core in InteractionBaseline) | gating table: each of the four booleans suspends; refusal sentences |
| 8 | `WakeWordListener` (SFSpeech) | AppleAdapters | host `swift build` only |
| 9 | Docs, CLI.md, smoke checklist §8 | docs | — |

Rough size: listener one day, arming and gate half a day, routing and grounding
one day, workspace half a day, tests and docs one day.

## 7. Open decisions

1. **Wake-word matching on device vs a dedicated spotter.** SFSpeech on-device
   is free and already permitted (`NSSpeechRecognitionUsageDescription` is in
   the bundle). Its false-positive rate on "TapQ" is unknown; the phrase table
   in §2 is the first defence, a two-word phrase is the second. Revisit only if
   the smoke run shows spurious windows.
2. **Cue.** "Yes?" is short and unmistakably a reply to the wearer. "Listening."
   would match the held-boundary cue but sounds like TapQ talking to itself.
3. **Mid-task wake.** If the focused session is mid-task and the wearer's
   sentence is an instruction, it is queued for that session (rule 3, "live"
   branch); the wake word does not imply "new session". Saying "start a new
   session, …" reaches `start_session` as today, with its mid-task confirmation.
4. **Double voice on a text-only model answer.** If the model ignores the
   grounding and answers in words, the wearer hears the model's sentence and
   then the dictation announcement. Accepted for v0; measured in the smoke run.

## 8. Smoke checklist

Launch: `TAPQ_DEBUG=1 scripts/run-runtime-app.sh serve --voice-backend
openai-realtime --voice-instructions --voice-session --voice-freeform
--voice-trust environment --attention wake` with no session running.

1. Say the wake word. Expect `wake.fired`, `wake.suspended reason=window`,
   "Yes?" in the backend voice, `window.opened kind=voiceSession`.
2. Say "set up a new Swift package for the parser". Expect `queue_instruction`
   with no agent (door 2) or `freeform.delivered` (door 1); then
   `session.started owned=true directory=~/TapQ/sessions/…`, the folder exists
   with `.claude/settings.json` and `.git`, and "Started a new Claude Code
   session: …" is spoken once.
3. Claude's first Stop is held; `listening.began`; the voice session runs as
   today. `wake.suspended reason=listening` stays until the session ends.
4. End the session by tap. Expect `wake.resumed` within a second.
5. Say the wake word, then nothing. Expect the window to close at 20 s with no
   sentence, and `wake.resumed`.
6. With a permission prompt waiting, say the wake word. Expect "Something is
   waiting for you first." and no window.
7. Say "tap the queue" in conversation. Expect no `wake.fired`.
8. Leave the runtime idle 10 minutes. Expect periodic `wake.restarted` at debug
   level and no warning.
