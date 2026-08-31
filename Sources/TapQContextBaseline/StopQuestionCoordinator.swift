import Foundation
import TapQContracts

/// Classifies an agent's final reply, prevents re-ask loops, runs the matching
/// hands-free interaction, and formats the answer returned to the agent adapter.
///
/// It is also where a queued instruction reaches the agent (RC1). A turn boundary is
/// the only moment TapQ can hand an agent a sentence it did not ask for, and this is the
/// one place that sees every boundary, so a queued instruction is delivered here instead
/// of an answer — one per boundary, ahead of everything else. From M3 that sentence may
/// have been dictated by the wearer or composed by TapQ's own loop, and this is where the
/// difference is enforced: two caps, and two delivery templates.
@MainActor public final class StopQuestionCoordinator {
    public typealias RunSelection = @MainActor (
        SelectionRequest,
        ContinuousClock.Instant
    ) async -> SelectionResult
    public typealias RunApproval = @MainActor (
        ApprovalRequest,
        ContinuousClock.Instant
    ) async -> Decision
    /// Notes a delivered instruction in whatever the host remembers about the session.
    /// The coordinator holds a closure rather than the store itself so it stays ignorant
    /// of conversation memory, the same way the controllers do.
    public typealias RecordInstruction = @MainActor (
        _ sessionID: String,
        _ agent: AgentIdentity,
        _ text: String
    ) -> Void
    /// Says one sentence to the wearer. Used for exactly one thing here: the notice that
    /// a cap is holding an instruction back — RC2's dictated cap, or M3's autonomous one.
    public typealias AnnounceToWearer = @MainActor (String) -> Void

    private let classifier: any ResponseQuestionClassifying
    private let summarizer: (any SpokenSummarizing)?
    /// The narration model, on the paths that have one.
    ///
    /// Composed only for a model-backed backend (`openai-realtime`). When it is present it
    /// replaces the whole heuristic delivery decision for this boundary: `classifier` and
    /// `summarizer` are not consulted at all, so the question detection, the spoken-summary
    /// templates, and the preamble/detail composition below are unreachable. When it is
    /// `nil` — the Apple path, and every composition written before 2026-08-28 — not one
    /// byte of the behavior below changes.
    private let narrator: (any BoundaryNarrating)?
    /// Where a narration failure goes: the run's voice-pipeline break latch.
    ///
    /// Its absence is not a fallback. A composition with a narrator and no failure hook is
    /// a composition bug, and the narration path says so at error level rather than
    /// resuming the heuristics — which no longer run on that path in any circumstance.
    private let onNarrationFailed: (@MainActor (String) -> Void)?
    private let instructions: InstructionMailbox?
    private let recordInstruction: RecordInstruction?
    private let announce: AnnounceToWearer?
    private let runSelection: RunSelection
    private let runApproval: RunApproval
    /// Whether the loop cap is stood down for this run (RH1).
    ///
    /// The cap exists because an instruction-bearing stop block restarts the agent's turn,
    /// which produces another boundary — so a queue of instructions and an agent that does
    /// nothing with them is a loop. In a voice session that reasoning inverts: every
    /// boundary is *supposed* to carry an instruction, because the wearer is standing there
    /// dictating them one at a time, and a cap that fired after three would hold back the
    /// fourth thing they said and tell them to wait for a boundary that only their own next
    /// sentence can produce. The four-deep queue bound is untouched and still applies.
    ///
    /// It stands down the *dictated* cap and nothing else. The reasoning above is a claim
    /// about a wearer standing at the boundary talking, and it says nothing whatsoever
    /// about instructions TapQ composed on its own — for which "the wearer will produce
    /// the next boundary" is not a reason to keep going but the very thing in doubt. See
    /// ``maxConsecutiveLoopInstructions``.
    private let suppressesLoopCap: Bool
    private var answered = AnsweredQuestionStore()
    private var consecutiveAnswers: [String: Int] = [:]
    private var consecutiveInstructions: [String: Int] = [:]
    /// Consecutive `.loop`-origin deliveries, counted separately from the line above (M3).
    ///
    /// A second counter rather than a smarter predicate on the first, because the two caps
    /// answer to different flags and reset on different events: a dictated delivery is an
    /// intervening act as far as autonomy is concerned — the wearer spoke — and clears
    /// this one while advancing the other.
    private var consecutiveLoopInstructions: [String: Int] = [:]
    /// TapQ's own status lines waiting to be folded into the next narrated utterance.
    ///
    /// Only the narration path uses this. Without a narrator a notice is spoken the moment
    /// it happens, exactly as it always was; with one, saying it immediately would put a
    /// second voice-line in front of the utterance the model is about to write, so it waits
    /// and becomes an item in that call. Bounded, because an un-drained buffer on a session
    /// nobody is narrating must not grow.
    private var pendingNotices: [String: [String]] = [:]
    private let diagnostics: TapQDiagnosticEmitter

    /// Status lines retained per session before the oldest is dropped.
    static let maxPendingNotices = 4

    static let maxConsecutiveAnswers = 5
    /// Instruction-bearing stop blocks a session may receive in a row (RC2).
    ///
    /// A stop block carrying an instruction restarts the agent's turn, which produces
    /// another stop block: without a cap, a queue of four instructions and an agent that
    /// does nothing with them is a loop. Claude's stop hook has no `stop_hook_active`
    /// flag to lean on (Codex's does), so this is the whole of the loop safety on that
    /// path. Any boundary that does *not* carry an instruction clears the count.
    static let maxConsecutiveInstructions = 3
    /// Instruction-bearing stop blocks TapQ may compose *for itself* in a row (M3).
    ///
    /// The same number as above and a different rule, and the difference is the whole
    /// point. ``suppressesLoopCap`` stands the cap above down in voice sessions — which is
    /// precisely the configuration the deliberation loop runs in — so "the existing cap
    /// applies to the loop too" was never satisfiable by composition: in the one mode where
    /// autonomous instructions can occur, the cap that would bound them is off. This
    /// counter is the one the stand-down does not cover. Three of TapQ's own sentences in
    /// a row with no word from the wearer is the point at which TapQ is running the session
    /// rather than helping with it, whatever mode it is in.
    ///
    /// Same semantics as its sibling otherwise: the held instruction stays at the head of
    /// the queue, and a boundary the wearer's own sentence carries clears the count.
    static let maxConsecutiveLoopInstructions = 3

    /// `summarizer` is optional in the strong sense: with none — which is what
    /// `--speech-summarizer off` composes, and what every caller written before spoken
    /// summaries existed passes — the requests this coordinator builds are byte for byte
    /// the ones it built before, so the wearer hears exactly what they heard before.
    ///
    /// `instructions` is optional in the same strong sense: with no mailbox — which is
    /// what an absent `--voice-instructions` composes — nothing can be queued, the
    /// delivery branch is never entered, and every stop question takes exactly the path
    /// it took before instructions existed.
    ///
    /// - Parameters:
    ///   - instructions: the queue this coordinator drains at turn boundaries.
    ///   - recordInstruction: notes a delivered instruction in conversation memory.
    ///   - announce: says the loop-cap notice out loud.
    ///   - suppressesLoopCap: `true` only in a voice session (RH1), where every boundary is
    ///     meant to carry an instruction. `false` — the default and every earlier
    ///     composition — keeps RC2's three-in-a-row cap exactly as it shipped.
    ///   - narrator: the model that decides what this boundary says out loud. Composed only
    ///     on a model-backed backend; `nil` — the default, and the Apple path — leaves the
    ///     classifier/summarizer behavior below untouched.
    ///   - onNarrationFailed: the run's voice-pipeline break. Called with an operator-facing
    ///     reason when narration fails, and nothing is spoken for that boundary.
    public init(
        classifier: any ResponseQuestionClassifying,
        summarizer: (any SpokenSummarizing)? = nil,
        narrator: (any BoundaryNarrating)? = nil,
        onNarrationFailed: (@MainActor (String) -> Void)? = nil,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        instructions: InstructionMailbox? = nil,
        recordInstruction: RecordInstruction? = nil,
        announce: AnnounceToWearer? = nil,
        suppressesLoopCap: Bool = false,
        runSelection: @escaping RunSelection,
        runApproval: @escaping RunApproval
    ) {
        self.classifier = classifier
        self.summarizer = summarizer
        self.narrator = narrator
        self.onNarrationFailed = onNarrationFailed
        self.instructions = instructions
        self.recordInstruction = recordInstruction
        self.announce = announce
        self.suppressesLoopCap = suppressesLoopCap
        self.runSelection = runSelection
        self.runApproval = runApproval
        self.diagnostics = TapQDiagnosticEmitter(
            category: "StopQuestion",
            sink: diagnosticSink
        )
    }

    /// Returns the adapter reply — a queued instruction, or the wearer's answer to the
    /// question in the agent's final text — or `nil` to fail open and leave the agent's
    /// normal on-screen question untouched.
    public func handle(_ stopQuestion: StopQuestion) async -> String? {
        await handle(
            sessionID: stopQuestion.sessionID,
            agent: stopQuestion.agent,
            text: stopQuestion.text
        )
    }

    public func handle(
        sessionID: String,
        agent: AgentIdentity = .unknown,
        text: String
    ) async -> String? {
        // Ahead of every guard below, deliberately (RC1). A queued instruction is the
        // wearer's own sentence, already read back and confirmed; it must not be
        // withheld because the agent happened to repeat itself, because five questions
        // were answered in a row, or because no classifier was reachable. The guards
        // exist to stop TapQ from re-answering the agent, and an instruction is not an
        // answer.
        if let delivery = deliverQueuedInstruction(sessionID: sessionID, agent: agent) {
            return delivery
        }

        let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)

        // Both guards are loop safety, not delivery heuristics, so they hold on both
        // paths unchanged. They are about text TapQ has already *answered*: a narrated
        // question that was answered must not be re-asked, and five answers in a row means
        // TapQ is arguing with the agent rather than helping the wearer. A narrated
        // statement records nothing and is not covered — exactly as a `.noQuestion`
        // boundary was not covered before narration existed.
        guard !answered.isRepeat(session: sessionID, text: text) else {
            diagnostics.record("repeat.pass", fields: ["session": sessionID])
            consecutiveAnswers[sessionID] = 0
            return nil
        }
        guard (consecutiveAnswers[sessionID] ?? 0) < Self.maxConsecutiveAnswers else {
            diagnostics.record(
                "answer_chain_cap.pass",
                level: .warning,
                fields: ["session": sessionID]
            )
            consecutiveAnswers[sessionID] = 0
            return nil
        }

        // The fork. Everything below this line is the heuristic path and runs only when no
        // narrator was composed.
        if narrator != nil {
            return await narrateBoundary(
                sessionID: sessionID,
                agent: agent,
                text: text,
                deadline: deadline
            )
        }

        guard let classification = await classifier.classify(text) else {
            diagnostics.record("classifier_unavailable.pass")
            consecutiveAnswers[sessionID] = 0
            return nil
        }

        switch classification {
        case .noQuestion:
            diagnostics.record("no_question.pass")
            consecutiveAnswers[sessionID] = 0
            return nil

        case .multiOption(let question, let options):
            diagnostics.record("multi_option.detected", fields: [
                "agent": agent.id,
                "options": "\(options.count)",
            ])
            let request = SelectionRequest(
                id: UUID().uuidString,
                sessionID: sessionID,
                agent: agent,
                question: question,
                options: options,
                multiSelect: false,
                // Said once, ahead of the first option: what the agent's reply was about,
                // which the question alone — "Which approach?" — never conveys.
                spokenPreamble: await summarize(text)?.sentence
            )
            let selectionResult = await runSelection(request, deadline)
            // Labels take precedence over freeText when both are present (defensive).
            let labels = selectionResult.choices.map(\.label)
            if !labels.isEmpty {
                recordAnswer(sessionID: sessionID, text: text)
                diagnostics.record("multi_option.answered", fields: ["choices": "\(labels.count)"])
                return Self.reply(question: question, answer: labels.joined(separator: ", "))
            }
            // A free-text answer is a resolution even with empty choices.
            if let freeText = selectionResult.freeText {
                recordAnswer(sessionID: sessionID, text: text)
                diagnostics.record("multi_option.answered_freeform",
                                   fields: ["length": "\(freeText.count)"])
                return Self.reply(question: question,
                                  answer: "they answered: '\(freeText)'")
            }
            diagnostics.record("multi_option.unanswered.pass")
            consecutiveAnswers[sessionID] = 0
            return nil

        case .yesNo(let question):
            diagnostics.record("yes_no.detected", fields: ["agent": agent.id])
            let summary = await summarize(text)
            let request = ApprovalRequest(
                id: UUID().uuidString,
                sessionID: sessionID,
                agent: agent,
                toolName: "StopQuestion",
                summary: question,
                // The details hole: with no summarizer this is still "", and "details"
                // still answers "No further details." — the summary is the only thing
                // that ever had anything to put here.
                detail: summary?.detail ?? "",
                kind: .question,
                // Context in front of the question, never instead of it. The words the
                // user answers yes or no to remain the classified question, untouched.
                spokenPreamble: summary?.sentence
            )
            switch await runApproval(request, deadline) {
            case .allow:
                recordAnswer(sessionID: sessionID, text: text)
                diagnostics.record("yes_no.answered", fields: ["answer": "yes"])
                return Self.reply(question: question, answer: "Yes")
            case .deny:
                recordAnswer(sessionID: sessionID, text: text)
                diagnostics.record("yes_no.answered", fields: ["answer": "no"])
                return Self.reply(question: question, answer: "No")
            case .ask:
                diagnostics.record("yes_no.unanswered.pass")
                consecutiveAnswers[sessionID] = 0
                return nil
            }
        }
    }

    // MARK: - Narration (2026-08-28)

    /// Buffers a TapQ status line for the next narrated utterance on this session.
    ///
    /// Public because the notices worth folding in do not all originate here — a host that
    /// has something to tell the wearer *about TapQ* while an agent's turn is running can
    /// leave it here instead of speaking over the boundary. What is queued is TapQ's own
    /// prose, never agent output and never wearer speech: this is a speech-eligible surface
    /// by construction, and it is the only thing besides the agent's final message that
    /// reaches the narration model.
    ///
    /// A no-op without a narrator, so a host may call it unconditionally: without one there
    /// is no narrated utterance to fold anything into, and the caller's own `announce` is
    /// still the way a notice gets spoken.
    public func noteNarrationNotice(_ notice: String, session: String) {
        guard narrator != nil else { return }
        var queued = pendingNotices[session] ?? []
        queued.append(notice)
        if queued.count > Self.maxPendingNotices {
            queued.removeFirst(queued.count - Self.maxPendingNotices)
            diagnostics.record("narration.notice_dropped", level: .warning, fields: [
                "session": session,
                "cap": "\(Self.maxPendingNotices)",
            ])
        }
        pendingNotices[session] = queued
    }

    /// Asks the narration model what this boundary should say, then says it.
    ///
    /// ## What this replaced
    ///
    /// On a model-backed path there is no longer a classifier deciding whether the agent's
    /// last message was a question, no `SpokenSummary` sentence/detail split, no
    /// preamble-plus-question composition, and no character caps on any of it. One call
    /// receives what is pending and returns the utterance. TapQ speaks that utterance
    /// verbatim — it does not re-summarize, re-punctuate, or shorten what came back, because
    /// deciding the length was the job that was delegated.
    ///
    /// ## The two outcomes
    ///
    /// A statement is spoken and the agent's turn ends normally (`nil`, fail open). A
    /// question is spoken *by the answer machinery* — the same `ApprovalRequest` /
    /// `runApproval` / `Self.reply` plumbing the heuristic yes/no branch uses — so the
    /// wearer's nod, tap, or spoken answer reaches the agent through the one path that has
    /// always carried answers. Only the detection and the phrasing moved to the model.
    ///
    /// ## Failure
    ///
    /// Anything short of an utterance is a voice-pipeline failure and breaks the run's voice
    /// channel. Nothing is spoken and the boundary fails open to the agent, which is what
    /// every other unrecoverable path here does: TapQ going quiet must never also mean the
    /// agent stops.
    private func narrateBoundary(
        sessionID: String,
        agent: AgentIdentity,
        text: String,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        guard let narrator else { return nil }

        // The turn's own outcome first, then the status lines that piled up behind it.
        var items: [NarrationItem] = []
        let outcome = SpokenSummaryText.normalized(text)
        if !outcome.isEmpty {
            items.append(NarrationItem(kind: .agentMessage, text: outcome))
        }
        for notice in pendingNotices.removeValue(forKey: sessionID) ?? [] {
            items.append(NarrationItem(kind: .notice, text: notice))
        }
        guard !items.isEmpty else {
            diagnostics.record("narration.nothing_pending", fields: ["session": sessionID])
            consecutiveAnswers[sessionID] = 0
            return nil
        }

        let utterance: NarrationUtterance
        do {
            utterance = try await narrator.narrate(
                NarrationRequest(agentDisplayName: agent.displayName, items: items)
            )
        } catch {
            let reason = (error as? NarrationFailure)?.reason ?? "narration error"
            diagnostics.record("narration.pipeline_failed", level: .error, fields: [
                "session": sessionID,
                "items": "\(items.count)",
                "reason": reason,
            ])
            onNarrationFailed?(reason)
            consecutiveAnswers[sessionID] = 0
            return nil
        }

        guard utterance.isQuestion else {
            diagnostics.record("narration.statement", fields: [
                "items": "\(items.count)",
                "length": "\(utterance.text.count)",
                "mode": utterance.mode.rawValue,
                "session": sessionID,
            ])
            announce?(utterance.text)
            consecutiveAnswers[sessionID] = 0
            return nil
        }

        diagnostics.record("narration.question", fields: [
            "agent": agent.id,
            "items": "\(items.count)",
            "length": "\(utterance.text.count)",
        ])
        let request = ApprovalRequest(
            id: UUID().uuidString,
            sessionID: sessionID,
            agent: agent,
            toolName: "StopQuestion",
            // The model wrote one utterance and the wearer hears one utterance. There is
            // no preamble to put in front of it and no detail to hold behind it: those two
            // fields existed to reassemble a question out of a summary, which is exactly
            // the composition the model now does in a single string.
            summary: utterance.text,
            detail: "",
            kind: .question,
            spokenPreamble: nil
        )
        switch await runApproval(request, deadline) {
        case .allow:
            recordAnswer(sessionID: sessionID, text: text)
            diagnostics.record("narration.answered", fields: ["answer": "yes"])
            return Self.reply(question: utterance.text, answer: "Yes")
        case .deny:
            recordAnswer(sessionID: sessionID, text: text)
            diagnostics.record("narration.answered", fields: ["answer": "no"])
            return Self.reply(question: utterance.text, answer: "No")
        case .ask:
            diagnostics.record("narration.unanswered.pass")
            consecutiveAnswers[sessionID] = 0
            return nil
        }
    }

    // MARK: - Instruction delivery (Rung C)

    /// Drains one instruction for a boundary that is not a stop question at all.
    ///
    /// The caller is the held-boundary path (RH1): a shim that long-polled the broker and
    /// is being answered, either because something was already queued when it asked or
    /// because something arrived while it waited. It is the *same* delivery the stop-question
    /// path performs — same one-per-boundary rule, same reply template, same memory
    /// recording, same diagnostics — exposed rather than duplicated, so there is exactly one
    /// piece of code in TapQ that hands an agent a sentence nobody typed.
    public func deliverInstruction(sessionID: String, agent: AgentIdentity) -> String? {
        deliverQueuedInstruction(sessionID: sessionID, agent: agent)
    }

    /// The reply that hands one queued instruction to the agent, or `nil` when this
    /// boundary carries none.
    ///
    /// Exactly one instruction drains per boundary (RC1). The agent's turn restarts with
    /// this reply as its next instruction, so a second one delivered in the same breath
    /// would be read as part of the first; the next boundary is a moment away and it will
    /// take the next one.
    private func deliverQueuedInstruction(
        sessionID: String,
        agent: AgentIdentity
    ) -> String? {
        // The head is read before any decision is taken, because from M3 whether an
        // instruction may go out at all depends on whose sentence it is.
        guard let instructions, let next = instructions.peek(session: sessionID) else {
            // A boundary with nothing to deliver is the "intervening non-instruction
            // event" both caps are counting toward.
            clearInstructionChains(sessionID: sessionID)
            return nil
        }

        // The autonomous cap first, and deliberately outside the `suppressesLoopCap`
        // guard below: that flag stands down the cap on *dictation*, on the reasoning
        // that a wearer talking at the boundary is the thing producing the boundaries.
        // Nothing in that reasoning reaches an instruction TapQ wrote itself, so this
        // one binds in a voice session exactly as it binds anywhere else.
        if next.origin == .loop,
           (consecutiveLoopInstructions[sessionID] ?? 0) >= Self.maxConsecutiveLoopInstructions {
            diagnostics.record("instruction.autonomous_cap.suppressed", level: .warning, fields: [
                "session": sessionID,
                "cap": "\(Self.maxConsecutiveLoopInstructions)",
                "suppresses_loop_cap": "\(suppressesLoopCap)",
            ])
            // Held at the head, never discarded, on the same rule as its sibling: this
            // boundary now falls through to normal handling and is itself the intervening
            // non-instruction event, so the held sentence goes out on the next one.
            clearInstructionChains(sessionID: sessionID)
            announceCapNotice(Self.autonomousCapNotice, session: sessionID)
            return nil
        }

        guard suppressesLoopCap
            || (consecutiveInstructions[sessionID] ?? 0) < Self.maxConsecutiveInstructions else {
            diagnostics.record("instruction.loop_cap.suppressed", level: .warning, fields: [
                "session": sessionID,
                "cap": "\(Self.maxConsecutiveInstructions)",
            ])
            // Suppressed, never discarded: the instruction stays at the head of the
            // queue and the next boundary that is not itself instruction-bearing — this
            // one, which now falls through to normal handling — clears the count.
            clearInstructionChains(sessionID: sessionID)
            announceCapNotice(Self.loopCapNotice, session: sessionID)
            return nil
        }
        guard let instruction = instructions.dequeue(session: sessionID) else {
            clearInstructionChains(sessionID: sessionID)
            return nil
        }

        // Every delivery advances the block chain, whoever wrote the sentence: an
        // instruction-bearing stop block restarts the agent's turn regardless of origin,
        // which is the only thing that count has ever been about.
        consecutiveInstructions[sessionID, default: 0] += 1
        // The autonomy chain, though, is about TapQ acting unheard from. A dictated
        // delivery means the wearer just spoke into this session, which is the intervening
        // act the autonomous cap exists to wait for, so it resets the run to zero.
        switch instruction.origin {
        case .loop: consecutiveLoopInstructions[sessionID, default: 0] += 1
        case .dictated: consecutiveLoopInstructions[sessionID] = 0
        }
        recordInstruction?(sessionID, agent, instruction.text)
        diagnostics.record("instruction.delivered", fields: [
            "agent": agent.id,
            "session": sessionID,
            "length": "\(instruction.text.count)",
            "remaining": "\(instructions.pendingCount(session: sessionID))",
            "origin": instruction.origin.rawValue,
        ])
        return Self.instructionReply(instruction.text, origin: instruction.origin)
    }

    /// Zeroes both instruction chains for a boundary that carried nothing.
    ///
    /// One helper because the two counters agree on exactly this: a boundary that delivers
    /// no instruction — empty queue, or either cap holding one back — is the intervening
    /// event both were waiting for. They disagree only about what a *delivery* means, and
    /// that fork is written out at the delivery site rather than hidden in here.
    private func clearInstructionChains(sessionID: String) {
        consecutiveInstructions[sessionID] = 0
        consecutiveLoopInstructions[sessionID] = 0
    }

    /// Says a cap notice the way this composition says things.
    ///
    /// With a narrator, this boundary is about to produce one utterance and the notice
    /// belongs inside it — said on its own it would be a second line of speech racing the
    /// narrated one. Without a narrator nothing changed: it is spoken here, now, as it
    /// always was.
    private func announceCapNotice(_ notice: String, session: String) {
        if narrator == nil {
            announce?(notice)
        } else {
            noteNarrationNotice(notice, session: session)
        }
    }

    /// Summarizes the agent's final reply for speech, once per handled stop question.
    ///
    /// Called only after the classifier has found a question, so a reply nobody will be
    /// asked about costs nothing. The provider owns its own five-second bound and returns
    /// `nil` on every failure; `nil` here means the request is built exactly as it was
    /// before summaries existed.
    private func summarize(_ text: String) async -> SpokenSummary? {
        guard let summarizer else { return nil }
        guard let summary = await summarizer.summarize(text) else {
            diagnostics.record("summary.unavailable")
            return nil
        }
        diagnostics.record("summary.ready", fields: [
            "sentence": "\(summary.sentence.count)",
            "detail": "\(summary.detail.count)",
        ])
        return summary
    }

    private func recordAnswer(sessionID: String, text: String) {
        answered.record(session: sessionID, text: text)
        consecutiveAnswers[sessionID, default: 0] += 1
    }

    static func reply(question: String, answer: String) -> String {
        "The user answered hands-free. For the question '\(question)', they chose: '\(answer)'. Proceed with this choice without re-asking."
    }

    /// The stop reply that carries a queued instruction (RC1's ratified template, plus
    /// M3's autonomous variant).
    ///
    /// It says where the instruction came from, because the agent is receiving a
    /// sentence nobody typed into its session, and it authorizes nothing: whatever the
    /// instruction asks for still goes through the same approval path every other tool
    /// call goes through — which is as true of a sentence TapQ wrote as of one the wearer
    /// dictated, and is why the two differ in attribution and in nothing else.
    ///
    /// The `.dictated` string is byte-for-byte the one that shipped: it is asserted
    /// verbatim by the wire tests, the hook-shim tests, and four E2E suites, and more to
    /// the point it is the sentence agents have been reading since RC1. The `.loop`
    /// string is deliberately a *different* sentence rather than a qualified version of
    /// it, so an agent — or a human reading the transcript afterwards — can tell at a
    /// glance which instructions in a session a person actually asked for.
    static func instructionReply(
        _ text: String,
        origin: InstructionOrigin = .dictated
    ) -> String {
        switch origin {
        case .dictated:
            return "The user dictated a new instruction via TapQ hands-free: "
                + "'\(text)'. Proceed accordingly."
        case .loop:
            return "TapQ queued a new instruction on the user's behalf — the user did not "
                + "dictate it: '\(text)'. Proceed accordingly."
        }
    }

    /// What the wearer hears when the loop cap holds a dictated instruction back.
    static let loopCapNotice =
        "That's three instructions in a row. I'll hold the next one until the agent gets further."

    /// What the wearer hears when the autonomous cap holds one of TapQ's own back (M3).
    ///
    /// First person and unmistakably TapQ's: the wearer is being told that *TapQ* has been
    /// talking to their agent three times unprompted, which is a different thing to hear
    /// than "you dictated three" and must not be phrasable as the same sentence. It asks
    /// for the wearer, not for the agent — the intervening act this cap waits on is a
    /// person saying something, which is exactly what "until you weigh in" names.
    static let autonomousCapNotice =
        "I've sent three instructions in a row on my own — I'll hold the next until you weigh in."
}
