# Rung A — Spoken Summaries: Implementation Plan

*Ratified 2026-08-15. Branch `rung-a-spoken-summaries` off `origin/main` @ `9520f69`
(baseline: 1,583 tests, 0 failures). Parent program: `docs/VOICE_AGENT_PLAN.md` §3.
All file:line references verified against this baseline on 2026-08-15.*

Goal: everything TapQ says about the agent is real content. The agent's final reply
is summarized into speech, notifications speak the text they already carry, the
"details" command on a stop question stops saying "No further details.", and the
realtime path never emits an ungrounded model reply.

## Verified inventory (what the plan builds on)

- The classifier provider stack in `Sources/TapQContextBaseline/ResponseQuestionClassifier.swift`
  (protocol / provider enum / factory / chain / `auto` selection at :187-207) is the
  pattern to mirror. Cloud providers inject HTTP via an internal
  `HTTPSender` typealias + internal `init(…, send:)`; 5 s timeout raced via task
  group; missing API key throws from the factory and `serve()` exits 1.
  Keys are read once at `Executables/tapq/AppleTapQRuntimeService.swift:45-46`.
- Notification speech: `DefaultApprovalRequestPresenter.notification(for:)`
  (`Sources/TapQInteractionBaseline/InteractionController.swift:61-70`) never reads
  `AgentNotification.summary`. Only the Claude adapter ever populates it
  (`HookShim.swift:183`, the hook's own short message text); all four adapters send
  `null` on stop/finished. So notifications need *speaking*, not summarizing.
- Stop questions: `StopQuestionCoordinator` (TapQContextBaseline) holds the agent's
  full final text but wraps only the classified question with `detail: ""`
  (:119-127), so `details` during a yes/no stop question always speaks
  "No further details." (`InteractionController.swift:57-59`). Raw stop text is
  never spoken. Multi-option questions speak via `SelectionController.swift:199-213`.
- `VoiceBackend.requestResponse(text:)` (`TapQContracts/VoiceBackend.swift:217`) is
  implemented by all backends, called by nobody. On the realtime backend it becomes
  `response.create(instructions: text)` — the model may paraphrase; on the Apple
  backend it goes verbatim to the shared `SpeechEngine`. State machine allows it
  only from `.open`/`.committed` (`VoiceBackendSession.swift:134-141`).
- `endUserTurn(expectingResponse: true)` has exactly one call site:
  `VoiceBackendCommandProvider.swift:297` (`endActiveTurn()`); `response.create`
  is reachable from nowhere else except `requestResponse`. Suppression machinery:
  `endWindowKeepSession(suppressResponse:)` :520-545, `cancelActiveResponse()` :305.
- `TranscriptSummarizer.swift` (Claude adapter): zero call sites, zero tests.
- Approval strings are pinned by `InteractionControllerTests.swift:101,105,116` and
  `InteractionConfirmationTests.swift:318` plus the E2E suite — these tests are the
  invariant's enforcement and MUST NOT be weakened.

## Ratified decisions

- **RA1 — Approval sentences are untouchable.** No LLM output in any utterance that
  names what the user is authorizing. The pinned tests stay byte-identical. Backend
  voice routing (RA7) is forbidden for priority ≥ `.approval` because realtime
  `instructions` may paraphrase.
- **RA2 — Summarizer surface** (new, in TapQContextBaseline, mirroring the
  classifier): protocol `SpokenSummarizing` with
  `func summarize(_ text: String) async -> SpokenSummary?`;
  `struct SpokenSummary { let sentence: String; let detail: String }` — `sentence`
  ≤ 120 chars / 1 sentence, `detail` ≤ 320 chars. Caps are enforced by
  deterministic truncation AFTER the provider returns, never trusted to a model.
  `nil` on any failure/timeout ⇒ caller behaves exactly as today. 5 s bound, task
  group race, diagnostics events (`summary.timeout`, `summary.unparseable`, …)
  mirroring the classifier's names.
- **RA3 — Flag** `--speech-summarizer auto|apple|anthropic|openai|heuristic|off`,
  default `auto` (= Foundation Models if eligible, else heuristic — same resolution
  logic as the classifier's :187-207). Cloud value without its key: same
  factory-throw → exit-1 behavior and same env vars (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`). `off` disables all Rung A speech changes that depend on it.
- **RA4 — Stop questions get the summary.** Yes/no: the coordinator passes
  `summary.sentence` into the spoken prompt (final shape:
  `"<Name>: <sentence> <question> Yes or no?"`) and `summary.detail` as the
  request's `detail`, fixing the details hole. Multi-option: `summary.sentence` is
  spoken once as an introduction before the first prompt, never repeated on
  navigation. Raw stop text is still never spoken. Summarizer `nil` ⇒ today's exact
  behavior.
- **RA5 — Notifications speak their summary, deterministically.** No LLM.
  `notification(for:)` appends the wire summary when non-empty, condensed to 12
  words / 96 chars: `"Claude is waiting: <condensed summary>"`. Kinds with null
  summary are unchanged. The pinned `"The agent is waiting."` test still passes
  (null case).
- **RA6 — Suppress the ungrounded reply.** The single `expectingResponse: true`
  becomes `false`; endpointed unmatched turns produce no model reply. All
  suppression machinery is retained untouched for Rung B's grounded re-enable.
- **RA7 — Backend-preferred speech, narrow.** A `SpeechPresenting` decorator
  (`BackendPreferredSpeech`) routes ONLY `priority == .notification` utterances to
  the backend voice, and only when the session state legally permits
  `requestResponse` (attempt returns false ⇒ silent fallback to the TTS engine).
  Non-verbatim rendering is acceptable for notifications only (RA1 excludes
  everything else). On the Apple backend this is a no-op by construction (it
  already routes to the same engine).
- **RA8 — `TranscriptSummarizer` is deleted.** CHANGELOG notes it.
- **RA9 — Docs land in CLI.md only** (flag row in Runtime options :64-, prose
  section beside "Final-response questions" :702, env-var table :994, one privacy
  paragraph stating exactly what leaves the machine when a cloud summarizer is
  chosen). CHANGELOG `[Unreleased]` bullets. New `docs/RUNGA_SMOKE_CHECKLIST.md`
  (hardware items only a human can run). README untouched.
- **RA10 — No wire protocol changes.** The stop text already reaches the runtime.

## Work packages

### Track A — summarizer core (parallel with Track B; worktree `rung-a-track-a`)

NEW FILES ONLY in `Sources/TapQContextBaseline/` + `Tests/TapQContextBaselineTests/`.
No edits to any existing file (guarantees a clean merge with Track B).

1. `SpokenSummary.swift`: `SpokenSummary`, `SpokenSummarizing`,
   `SpeechSummarizerProvider` enum (`off|heuristic|apple|anthropic|openai|auto`),
   `SpeechSummarizerFactory` + selection + configuration errors — all mirroring
   the classifier types' shapes, doc-comment density, and diagnostics style.
2. `HeuristicSpokenSummarizer.swift`: first sentence(s) of the text, cleaned
   (markdown/code stripped like `HeuristicQuestionClassifier` does), capped per RA2.
   Always succeeds on non-empty text.
3. `FoundationModelSummarizer.swift`: `#if canImport(FoundationModels)`, macOS 26
   gate, `@Generable` constrained output `{sentence, detail}`, greedy sampling,
   prewarm — mirror `FoundationModelClassifier.swift` structure.
4. `AnthropicHaikuSummarizer.swift` + `OpenAILunaSummarizer.swift`: same models,
   endpoints, `HTTPSender` typealias + internal `init(send:)`, 5 s race, strict
   JSON output contract, same diagnostic event naming discipline.
5. Tests: heuristic determinism + caps; factory selection matrix incl. missing-key
   throws and `auto` with `allowFoundationModel: false`; cloud providers via inline
   `send:` stubs (mirror `AnthropicHaikuQuestionClassifierTests` helpers); timeout
   → nil; truncation enforcement on oversized model output.

### Track B — voice plumbing (parallel with Track A; worktree `rung-a-track-b`)

Files: `Sources/TapQInteractionBaseline/VoiceBackendCommandProvider.swift`, new
`Sources/TapQInteractionBaseline/BackendPreferredSpeech.swift`, matching tests.
MUST NOT touch TapQContextBaseline, presenters, controllers, CLI, or Executables.

1. Flip `VoiceBackendCommandProvider.swift:297` to `expectingResponse: false`
   (RA6); update any tests asserting the old behavior; add a test pinning that an
   endpointed turn commits without creating a response.
2. Add `VoiceBackendCommandProvider.speakViaBackend(_ text: String) -> Bool`:
   returns false unless a session is open and the turn state legally permits
   `requestResponse` (never throws through); on true, routes to
   `backend.requestResponse(text:)`. Diagnostic event on both outcomes.
3. New `BackendPreferredSpeech: SpeechPresenting` decorator per RA7: takes the
   real engine + a `route: (String) -> Bool` closure; `.notification` priority
   attempts the route first, everything else (and failed routes) goes verbatim to
   the engine, preserving `onFinish` semantics in both paths.
4. Tests: state matrix for `speakViaBackend` (idle/open/userTurn/committed/
   responding); decorator policy incl. priority exclusion (RA1) and fallback;
   suppression machinery untouched (existing tests keep passing).

### Integration (single writer, after tracks merge; worktree `rung-a-spoken-summaries`)

1. `StopQuestionCoordinator`: accept an optional `SpokenSummarizing`; summarize
   once per stop text (5 s bound is inside the provider); yes/no → prompt sentence
   + `detail` per RA4; multi-option → introduction seam. `SelectionController`
   gains the once-only `introduction` (spoken before the first prompt, not on
   navigation/repeat re-entry — mirror the `hasAnnouncedControls` pattern).
2. `DefaultApprovalRequestPresenter.notification(for:)` per RA5 + tests (null case
   byte-identical, populated case added).
3. Flag plumbing per RA3: `CLICommand.swift` (beside :323-330), help text
   (`TapQCLIApplication.swift:1689` block), config through `RuntimeService.swift`,
   composition in `AppleTapQRuntimeService.swift` beside the classifier (:43-56),
   `BackendPreferredSpeech` wrapped around the engine at the :317/:347 injection
   points wired to `speakViaBackend`.
4. Delete `TranscriptSummarizer.swift` (RA8).
5. Docs per RA9 + CHANGELOG + `docs/RUNGA_SMOKE_CHECKLIST.md`.
6. Tests: coordinator with stub summarizer (sentence + detail flow, nil flow,
   multi-option intro once-ness); config plumbing; one E2E-style test in the
   existing portable harness asserting a stop question with a stub summarizer
   speaks the summary sentence and `details` speaks the detail.

## Execution rules (binding for every agent)

- Work ONLY inside your assigned worktree; use `git -C <worktree>` or
  `--package-path` absolute paths; never rely on cwd persistence.
- Never pipe build/test output through `head`/`tail` in a way that masks exit
  codes; redirect to a file and echo `$?` separately.
- Run the FULL suite (`swift test --package-path <worktree>`) before your final
  commit; report the count. Baseline is 1,583/0.
- `scripts/check-public-boundary.sh` must pass (run from the worktree root).
- Match surrounding code style: doc-comment density, diagnostics naming, actor
  isolation patterns. New public API needs doc comments like its neighbors.
- Commit on your track's branch with a descriptive message; do NOT push, do NOT
  touch versions/tags, do NOT edit CHANGELOG (integration owns it).
- Deviations from this plan are allowed only with a one-line justification in
  your report's `deviations` field.
- Keep your final report within the schema; no logs, no diffs, no file dumps.

## Exit criteria

Full suite green (≥ baseline + new tests); boundary script green; approval-string
tests byte-identical; no `response.create` without TapQ-authored content;
`--speech-summarizer off` produces today's exact spoken behavior end to end.
