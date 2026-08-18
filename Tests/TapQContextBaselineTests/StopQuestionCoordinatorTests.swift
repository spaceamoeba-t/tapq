import XCTest
import TapQContracts
@testable import TapQContextBaseline

@MainActor
final class StopQuestionCoordinatorTests: XCTestCase {
    final class ScriptedClassifier: ResponseQuestionClassifying, @unchecked Sendable {
        var result: ResponseQuestionClassification?

        init(_ result: ResponseQuestionClassification?) {
            self.result = result
        }

        func classify(_ text: String) async -> ResponseQuestionClassification? {
            result
        }
    }

    final class DriftingClassifier: ResponseQuestionClassifying, @unchecked Sendable {
        var calls = 0

        func classify(_ text: String) async -> ResponseQuestionClassification? {
            calls += 1
            return .yesNo(question: "summary variant \(calls)")
        }
    }

    /// Answers with a fixed summary, and counts how often it was asked. The real
    /// providers' behavior is their own tests' subject; what the coordinator owes is to
    /// ask once per stop question and to put both fields where they belong.
    final class ScriptedSummarizer: SpokenSummarizing, @unchecked Sendable {
        private let summary: SpokenSummary?
        private(set) var calls = 0

        init(_ summary: SpokenSummary?) {
            self.summary = summary
        }

        func summarize(_ text: String) async -> SpokenSummary? {
            calls += 1
            return summary
        }
    }

    private func makeCoordinator(
        classify: ResponseQuestionClassification?,
        summarizer: (any SpokenSummarizing)? = nil,
        selectionResult: SelectionResult = .noSelection,
        approvalDecisions: [Decision] = [.ask]
    ) -> (StopQuestionCoordinator, () -> [SelectionRequest], () -> [ApprovalRequest]) {
        var selections: [SelectionRequest] = []
        var approvals: [ApprovalRequest] = []
        var decisions = approvalDecisions
        let coordinator = StopQuestionCoordinator(
            classifier: ScriptedClassifier(classify),
            summarizer: summarizer,
            runSelection: { request, _ in
                selections.append(request)
                return selectionResult
            },
            runApproval: { request, _ in
                approvals.append(request)
                if decisions.count > 1 { return decisions.removeFirst() }
                return decisions.first ?? .ask
            }
        )
        return (coordinator, { selections }, { approvals })
    }

    func testNoQuestionAndClassifierFailurePassThrough() async {
        let (noQuestion, selections, approvals) = makeCoordinator(classify: .noQuestion)
        let noQuestionReply = await noQuestion.handle(sessionID: "s1", text: "All done.")
        XCTAssertNil(noQuestionReply)
        XCTAssertTrue(selections().isEmpty)
        XCTAssertTrue(approvals().isEmpty)

        let (unavailable, _, _) = makeCoordinator(classify: nil)
        let unavailableReply = await unavailable.handle(sessionID: "s1", text: "Continue?")
        XCTAssertNil(unavailableReply)
    }

    func testMultiOptionAnswerPreservesAgentAndFormatsReply() async {
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which approach?",
            options: [
                SelectionOption(label: "Patch", description: "small fix"),
                SelectionOption(label: "Rewrite", description: "big change"),
            ]
        )
        let (coordinator, selections, _) = makeCoordinator(
            classify: classification,
            selectionResult: SelectionResult(choices: [.init(index: 0, label: "Patch")])
        )
        let agent = AgentIdentity(id: "codex", displayName: "Codex")
        let reply = await coordinator.handle(sessionID: "s1", agent: agent, text: "reply")

        XCTAssertEqual(
            reply,
            "The user answered hands-free. For the question 'Which approach?', they chose: 'Patch'. Proceed with this choice without re-asking."
        )
        XCTAssertEqual(selections().first?.agent, agent)
        XCTAssertEqual(selections().first?.options.map(\.label), ["Patch", "Rewrite"])
        XCTAssertEqual(selections().first?.multiSelect, false)
    }

    func testUnansweredSelectionIsRetried() async {
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which?",
            options: [
                SelectionOption(label: "A", description: ""),
                SelectionOption(label: "B", description: ""),
            ]
        )
        let (coordinator, selections, _) = makeCoordinator(classify: classification)
        let first = await coordinator.handle(sessionID: "s1", text: "reply")
        let second = await coordinator.handle(sessionID: "s1", text: "reply")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(selections().count, 2)
    }

    func testYesNoAllowAndDenyReturnAnswers() async {
        let (allow, _, allowRequests) = makeCoordinator(
            classify: .yesNo(question: "Prepare the rollback plan?"),
            approvalDecisions: [.allow]
        )
        let agent = AgentIdentity.claudeCode
        let yes = await allow.handle(sessionID: "s1", agent: agent, text: "reply one")
        XCTAssertTrue(yes?.contains("they chose: 'Yes'") == true)
        XCTAssertEqual(allowRequests().first?.kind, .question)
        XCTAssertEqual(allowRequests().first?.agent, agent)

        let (deny, _, _) = makeCoordinator(
            classify: .yesNo(question: "Prepare the rollback plan?"),
            approvalDecisions: [.deny]
        )
        let no = await deny.handle(sessionID: "s1", text: "reply two")
        XCTAssertTrue(no?.contains("they chose: 'No'") == true)
    }

    func testAskPassesThroughAndDoesNotDedupe() async {
        let (coordinator, _, approvals) = makeCoordinator(
            classify: .yesNo(question: "Continue?"),
            approvalDecisions: [.ask]
        )
        let first = await coordinator.handle(sessionID: "s1", text: "reply")
        let second = await coordinator.handle(sessionID: "s1", text: "reply")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(approvals().count, 2)
    }

    func testVerbatimReplyDedupeSurvivesDriftingSummaries() async {
        var approvals = 0
        let coordinator = StopQuestionCoordinator(
            classifier: DriftingClassifier(),
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in approvals += 1; return .allow }
        )
        let first = await coordinator.handle(sessionID: "s1", text: "Continue?")
        let second = await coordinator.handle(sessionID: "s1", text: "Continue?")
        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(approvals, 1)
    }

    func testConsecutiveAnswerCapBreaksRewordedLoop() async {
        let (coordinator, _, approvals) = makeCoordinator(
            classify: .yesNo(question: "Continue?"),
            approvalDecisions: [.allow]
        )
        for index in 1...5 {
            let reply = await coordinator.handle(
                sessionID: "s1",
                text: "distinct question \(index)?"
            )
            XCTAssertNotNil(reply)
        }
        let sixth = await coordinator.handle(sessionID: "s1", text: "distinct question 6?")
        XCTAssertNil(sixth)
        XCTAssertEqual(approvals().count, 5)
        let seventh = await coordinator.handle(sessionID: "s1", text: "distinct question 7?")
        XCTAssertNotNil(seventh)
    }

    func testDeadlineStartsAtArrival() async {
        var captured: ContinuousClock.Instant?
        let coordinator = StopQuestionCoordinator(
            classifier: ScriptedClassifier(.yesNo(question: "Continue?")),
            runSelection: { _, _ in .noSelection },
            runApproval: { _, deadline in captured = deadline; return .ask }
        )
        _ = await coordinator.handle(sessionID: "s1", text: "reply")
        let remaining = captured?.secondsFromNow ?? 0
        XCTAssertGreaterThan(remaining, InteractionBudget.total - 5)
        XCTAssertLessThanOrEqual(remaining, InteractionBudget.total)
    }

    // MARK: - Free-text reply (WP8)

    func testFreeTextSelectionProducesReply() async {
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which approach?",
            options: [
                SelectionOption(label: "Patch", description: "small fix"),
                SelectionOption(label: "Rewrite", description: "big change"),
            ]
        )
        let (coordinator, _, _) = makeCoordinator(
            classify: classification,
            selectionResult: SelectionResult(choices: [], freeText: "use a hybrid approach")
        )
        let reply = await coordinator.handle(sessionID: "s1", text: "reply")
        XCTAssertNotNil(reply)
        XCTAssertTrue(reply?.contains("they answered: 'use a hybrid approach'") == true)
    }

    func testFreeTextSelectionRecordsForRepeatSuppression() async {
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which approach?",
            options: [
                SelectionOption(label: "Patch", description: "small fix"),
            ]
        )
        let (coordinator, _, _) = makeCoordinator(
            classify: classification,
            selectionResult: SelectionResult(choices: [], freeText: "use a hybrid approach")
        )
        let first = await coordinator.handle(sessionID: "s1", text: "reply")
        let second = await coordinator.handle(sessionID: "s1", text: "reply")
        XCTAssertNotNil(first)
        XCTAssertNil(second, "the same reply text must be deduplicated")
    }

    func testLabelSelectionStillPreferred() async {
        // When the result has both labels and freeText, labels win (defensive).
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which approach?",
            options: [
                SelectionOption(label: "Patch", description: "small fix"),
            ]
        )
        let (coordinator, _, _) = makeCoordinator(
            classify: classification,
            selectionResult: SelectionResult(
                choices: [.init(index: 0, label: "Patch")],
                freeText: "actually something else")
        )
        let reply = await coordinator.handle(sessionID: "s1", text: "reply")
        XCTAssertTrue(reply?.contains("'Patch'") == true,
                      "label selection must be preferred over freeText when both present")
    }

    // MARK: - Spoken summaries (Rung A)

    func testYesNoCarriesSummarySentenceAndDetail() async {
        let summarizer = ScriptedSummarizer(
            SpokenSummary(
                sentence: "The migration rewrites the users table.",
                detail: "It backfills the email column and drops the legacy index."
            )
        )
        let (coordinator, _, approvals) = makeCoordinator(
            classify: .yesNo(question: "Apply the migration"),
            summarizer: summarizer,
            approvalDecisions: [.allow]
        )
        _ = await coordinator.handle(sessionID: "s1", text: "long final reply")

        let request = approvals().first
        XCTAssertEqual(request?.spokenPreamble, "The migration rewrites the users table.")
        XCTAssertEqual(request?.detail,
                       "It backfills the email column and drops the legacy index.")
        XCTAssertEqual(request?.summary, "Apply the migration",
                       "the question the user answers must stay the classified one")
        XCTAssertEqual(summarizer.calls, 1, "one stop question, one summarization")
    }

    func testNoSummarizerReproducesPreSummaryRequest() async {
        let (coordinator, _, approvals) = makeCoordinator(
            classify: .yesNo(question: "Apply the migration"),
            approvalDecisions: [.allow]
        )
        _ = await coordinator.handle(sessionID: "s1", text: "long final reply")

        XCTAssertNil(approvals().first?.spokenPreamble)
        XCTAssertEqual(approvals().first?.detail, "")
    }

    func testUnavailableSummarizerReproducesPreSummaryRequest() async {
        let summarizer = ScriptedSummarizer(nil)
        let (coordinator, _, approvals) = makeCoordinator(
            classify: .yesNo(question: "Apply the migration"),
            summarizer: summarizer,
            approvalDecisions: [.allow]
        )
        _ = await coordinator.handle(sessionID: "s1", text: "long final reply")

        XCTAssertEqual(summarizer.calls, 1)
        XCTAssertNil(approvals().first?.spokenPreamble)
        XCTAssertEqual(approvals().first?.detail, "")
    }

    func testMultiOptionCarriesSummarySentenceAsIntroduction() async {
        let classification = ResponseQuestionClassification.multiOption(
            question: "Which approach?",
            options: [
                SelectionOption(label: "Patch", description: "small fix"),
                SelectionOption(label: "Rewrite", description: "big change"),
            ]
        )
        let summarizer = ScriptedSummarizer(
            SpokenSummary(sentence: "Two ways to fix the parser.", detail: "Longer text.")
        )
        let (coordinator, selections, _) = makeCoordinator(
            classify: classification,
            summarizer: summarizer,
            selectionResult: SelectionResult(choices: [.init(index: 0, label: "Patch")])
        )
        _ = await coordinator.handle(sessionID: "s1", text: "long final reply")

        XCTAssertEqual(selections().first?.spokenPreamble, "Two ways to fix the parser.")
        XCTAssertEqual(selections().first?.question, "Which approach?")
        XCTAssertEqual(summarizer.calls, 1)
    }

    func testUnclassifiedReplyIsNeverSummarized() async {
        let summarizer = ScriptedSummarizer(
            SpokenSummary(sentence: "Nothing to ask about.", detail: "")
        )
        let (coordinator, _, _) = makeCoordinator(
            classify: .noQuestion,
            summarizer: summarizer
        )
        _ = await coordinator.handle(sessionID: "s1", text: "All done.")

        XCTAssertEqual(summarizer.calls, 0,
                       "a reply that raises no question is never sent to a summarizer")
    }
}
