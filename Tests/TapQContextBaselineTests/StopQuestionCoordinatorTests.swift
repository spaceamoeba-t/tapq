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

    private func makeCoordinator(
        classify: ResponseQuestionClassification?,
        selectionResult: SelectionResult = .noSelection,
        approvalDecisions: [Decision] = [.ask]
    ) -> (StopQuestionCoordinator, () -> [SelectionRequest], () -> [ApprovalRequest]) {
        var selections: [SelectionRequest] = []
        var approvals: [ApprovalRequest] = []
        var decisions = approvalDecisions
        let coordinator = StopQuestionCoordinator(
            classifier: ScriptedClassifier(classify),
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
}
