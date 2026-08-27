import Foundation
import TapQContracts

/// Classifies an agent's final reply, prevents re-ask loops, runs the matching
/// hands-free interaction, and formats the answer returned to the agent adapter.
///
/// It is also where a dictated instruction reaches the agent (RC1). A turn boundary is
/// the only moment TapQ can hand an agent a sentence it did not ask for, and this is the
/// one place that sees every boundary, so a queued instruction is delivered here instead
/// of an answer — one per boundary, ahead of everything else.
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
    /// the loop cap is holding an instruction back (RC2).
    public typealias AnnounceToWearer = @MainActor (String) -> Void

    private let classifier: any ResponseQuestionClassifying
    private let summarizer: (any SpokenSummarizing)?
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
    private let suppressesLoopCap: Bool
    private var answered = AnsweredQuestionStore()
    private var consecutiveAnswers: [String: Int] = [:]
    private var consecutiveInstructions: [String: Int] = [:]
    private let diagnostics: TapQDiagnosticEmitter

    static let maxConsecutiveAnswers = 5
    /// Instruction-bearing stop blocks a session may receive in a row (RC2).
    ///
    /// A stop block carrying an instruction restarts the agent's turn, which produces
    /// another stop block: without a cap, a queue of four instructions and an agent that
    /// does nothing with them is a loop. Claude's stop hook has no `stop_hook_active`
    /// flag to lean on (Codex's does), so this is the whole of the loop safety on that
    /// path. Any boundary that does *not* carry an instruction clears the count.
    static let maxConsecutiveInstructions = 3

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
    public init(
        classifier: any ResponseQuestionClassifying,
        summarizer: (any SpokenSummarizing)? = nil,
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
        guard let instructions, instructions.hasPending(session: sessionID) else {
            // A boundary with nothing to deliver is the "intervening non-instruction
            // event" the loop cap is counting toward.
            consecutiveInstructions[sessionID] = 0
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
            consecutiveInstructions[sessionID] = 0
            announce?(Self.loopCapNotice)
            return nil
        }
        guard let instruction = instructions.dequeue(session: sessionID) else {
            consecutiveInstructions[sessionID] = 0
            return nil
        }

        consecutiveInstructions[sessionID, default: 0] += 1
        recordInstruction?(sessionID, agent, instruction.text)
        diagnostics.record("instruction.delivered", fields: [
            "agent": agent.id,
            "session": sessionID,
            "length": "\(instruction.text.count)",
            "remaining": "\(instructions.pendingCount(session: sessionID))",
        ])
        return Self.instructionReply(instruction.text)
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

    /// The stop reply that carries a dictated instruction (RC1's ratified template).
    ///
    /// It says where the instruction came from, because the agent is receiving a
    /// sentence nobody typed into its session, and it authorizes nothing: whatever the
    /// instruction asks for still goes through the same approval path every other tool
    /// call goes through.
    static func instructionReply(_ text: String) -> String {
        "The user dictated a new instruction via TapQ hands-free: '\(text)'. Proceed accordingly."
    }

    /// What the wearer hears when the loop cap holds an instruction back.
    static let loopCapNotice =
        "That's three instructions in a row. I'll hold the next one until the agent gets further."
}
