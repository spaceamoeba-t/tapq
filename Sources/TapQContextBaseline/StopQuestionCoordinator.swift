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
    private let runSelection: RunSelection
    private let runApproval: RunApproval
    private var answered = AnsweredQuestionStore()
    private var consecutiveAnswers: [String: Int] = [:]
    private let diagnostics: TapQDiagnosticEmitter

    static let maxConsecutiveAnswers = 5

    public init(
        classifier: any ResponseQuestionClassifying,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        runSelection: @escaping RunSelection,
        runApproval: @escaping RunApproval
    ) {
        self.classifier = classifier
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
                multiSelect: false
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
            let request = ApprovalRequest(
                id: UUID().uuidString,
                sessionID: sessionID,
                agent: agent,
                toolName: "StopQuestion",
                summary: question,
                detail: "",
                kind: .question
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

    private func recordAnswer(sessionID: String, text: String) {
        answered.record(session: sessionID, text: text)
        consecutiveAnswers[sessionID, default: 0] += 1
    }

    static func reply(question: String, answer: String) -> String {
        "The user answered hands-free. For the question '\(question)', they chose: '\(answer)'. Proceed with this choice without re-asking."
    }
}
