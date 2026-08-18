import Foundation
import TapQContracts

/// Classifies an agent's final reply, prevents re-ask loops, runs the matching
/// hands-free interaction, and formats the answer returned to the agent adapter.
@MainActor public final class StopQuestionCoordinator {
    public typealias RunSelection = @MainActor (
        SelectionRequest,
        ContinuousClock.Instant
    ) async -> SelectionResult
    public typealias RunApproval = @MainActor (
        ApprovalRequest,
        ContinuousClock.Instant
    ) async -> Decision

    private let classifier: any ResponseQuestionClassifying
    private let summarizer: (any SpokenSummarizing)?
    private let runSelection: RunSelection
    private let runApproval: RunApproval
    private var answered = AnsweredQuestionStore()
    private var consecutiveAnswers: [String: Int] = [:]
    private let diagnostics: TapQDiagnosticEmitter

    static let maxConsecutiveAnswers = 5

    /// `summarizer` is optional in the strong sense: with none — which is what
    /// `--speech-summarizer off` composes, and what every caller written before spoken
    /// summaries existed passes — the requests this coordinator builds are byte for byte
    /// the ones it built before, so the wearer hears exactly what they heard before.
    public init(
        classifier: any ResponseQuestionClassifying,
        summarizer: (any SpokenSummarizing)? = nil,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        runSelection: @escaping RunSelection,
        runApproval: @escaping RunApproval
    ) {
        self.classifier = classifier
        self.summarizer = summarizer
        self.runSelection = runSelection
        self.runApproval = runApproval
        self.diagnostics = TapQDiagnosticEmitter(
            category: "StopQuestion",
            sink: diagnosticSink
        )
    }

    /// Returns the adapter reply that answers the question, or `nil` to fail open and
    /// leave the agent's normal on-screen question untouched.
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
}
