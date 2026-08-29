import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// The narration fork in ``StopQuestionCoordinator``: what replaced the heuristics, what
/// it does with each outcome, and what happens when the model cannot answer.
@MainActor
final class StopQuestionNarrationTests: XCTestCase {
    /// Records the request it was given and answers from a script.
    final class ScriptedNarrator: BoundaryNarrating, @unchecked Sendable {
        private var outcomes: [Result<NarrationUtterance, NarrationFailure>]
        private(set) var requests: [NarrationRequest] = []

        init(_ outcomes: [Result<NarrationUtterance, NarrationFailure>]) {
            self.outcomes = outcomes
        }

        convenience init(_ text: String, _ mode: NarrationDeliveryMode) {
            self.init([.success(NarrationUtterance(text: text, mode: mode))])
        }

        convenience init(failing failure: NarrationFailure) {
            self.init([.failure(failure)])
        }

        func narrate(_ request: NarrationRequest) async throws -> NarrationUtterance {
            requests.append(request)
            let outcome = outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
            return try outcome.get()
        }
    }

    /// A classifier and a summarizer that fail the test if the narration path ever reaches
    /// them. The whole claim of rule 2 is that they are unreachable with a narrator
    /// composed, and an assertion is the only way to hold that claim over time.
    final class ForbiddenClassifier: ResponseQuestionClassifying, @unchecked Sendable {
        func classify(_ text: String) async -> ResponseQuestionClassification? {
            XCTFail("the narration path must not consult the question classifier")
            return .yesNo(question: "should not happen")
        }
    }

    final class ForbiddenSummarizer: SpokenSummarizing, @unchecked Sendable {
        func summarize(_ text: String) async -> SpokenSummary? {
            XCTFail("the narration path must not consult the spoken summarizer")
            return nil
        }
    }

    private struct Harness {
        let coordinator: StopQuestionCoordinator
        let narrator: ScriptedNarrator
        let spoken: () -> [String]
        let approvals: () -> [ApprovalRequest]
        let breaks: () -> [String]
    }

    private func makeHarness(
        narrator: ScriptedNarrator,
        approvalDecisions: [Decision] = [.ask],
        instructions: InstructionMailbox? = nil,
        suppressesLoopCap: Bool = false
    ) -> Harness {
        var spoken: [String] = []
        var approvals: [ApprovalRequest] = []
        var breaks: [String] = []
        var decisions = approvalDecisions
        let coordinator = StopQuestionCoordinator(
            classifier: ForbiddenClassifier(),
            summarizer: ForbiddenSummarizer(),
            narrator: narrator,
            onNarrationFailed: { breaks.append($0) },
            instructions: instructions,
            announce: { spoken.append($0) },
            suppressesLoopCap: suppressesLoopCap,
            runSelection: { _, _ in .noSelection },
            runApproval: { request, _ in
                approvals.append(request)
                if decisions.count > 1 { return decisions.removeFirst() }
                return decisions.first ?? .ask
            }
        )
        return Harness(
            coordinator: coordinator,
            narrator: narrator,
            spoken: { spoken },
            approvals: { approvals },
            breaks: { breaks }
        )
    }

    // MARK: - What is sent

    func testTheAgentsFinalMessageIsTheOnlyItemAtAnOrdinaryBoundary() async {
        let harness = makeHarness(narrator: ScriptedNarrator("Tests are green.", .verbatim))
        _ = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "  All done —\n the tests are green.  "
        )

        let request = try? XCTUnwrap(harness.narrator.requests.first)
        XCTAssertEqual(request?.agentDisplayName, AgentIdentity.claudeCode.displayName)
        XCTAssertEqual(request?.items.count, 1)
        XCTAssertEqual(request?.items.first?.kind, .agentMessage)
        XCTAssertEqual(
            request?.items.first?.text,
            "All done — the tests are green.",
            "whitespace is collapsed for speech and nothing else is done to it"
        )
    }

    /// The long-message case that the removed summarizer would have cut at 320 characters.
    /// The whole message reaches the model, which is the only way it can decide whether to
    /// read it out or condense it.
    func testALongFinalMessageReachesTheModelWhole() async {
        let long = "It finished the migration. " + String(repeating: "detail here. ", count: 60)
        let harness = makeHarness(narrator: ScriptedNarrator("It finished.", .summary))
        _ = await harness.coordinator.handle(sessionID: "s1", agent: .claudeCode, text: long)

        let sent = harness.narrator.requests.first?.items.first?.text ?? ""
        XCTAssertEqual(sent, long.trimmingCharacters(in: .whitespaces))
        XCTAssertGreaterThan(sent.count, SpokenSummary.detailCharacterLimit)
    }

    func testABoundaryWithNothingPendingNeverCallsTheModel() async {
        let harness = makeHarness(narrator: ScriptedNarrator("unused", .verbatim))
        let reply = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "   \n  "
        )
        XCTAssertNil(reply)
        XCTAssertTrue(harness.narrator.requests.isEmpty)
        XCTAssertTrue(harness.spoken().isEmpty)
    }

    // MARK: - Statement modes

    func testStatementModesAreSpokenVerbatimAndFailOpenToTheAgent() async {
        for mode in [NarrationDeliveryMode.verbatim, .summary, .combined] {
            let utterance = "It finished the migration in \(mode.rawValue) mode."
            let harness = makeHarness(narrator: ScriptedNarrator(utterance, mode))
            let reply = await harness.coordinator.handle(
                sessionID: "s1", agent: .claudeCode, text: "The migration is done."
            )
            XCTAssertNil(reply, "a statement must not send anything back to the agent")
            XCTAssertEqual(harness.spoken(), [utterance])
            XCTAssertTrue(harness.approvals().isEmpty,
                          "a statement must not open an answer window")
        }
    }

    /// The single-voice rule: what the model wrote is what is said, not a re-summary of it.
    func testTheUtteranceIsNeverReshapedBeforeItIsSpoken() async {
        let utterance = "It changed Sources/TapQCLI/CLICommand.swift, ran "
            + "swift test --filter InstructionQueueTests, and 3 of 141 are failing. "
            + String(repeating: "There is more to say. ", count: 30)
        let harness = makeHarness(narrator: ScriptedNarrator(utterance, .verbatim))
        _ = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "A long report."
        )
        XCTAssertEqual(harness.spoken().first, utterance)
        XCTAssertGreaterThan(harness.spoken().first?.count ?? 0,
                             SpokenSummary.sentenceCharacterLimit)
    }

    // MARK: - Question mode reuses the answer machinery

    func testQuestionModeOpensTheAnswerWindowAndCarriesYesBack() async {
        let question = "It can delete the old importer — should it?"
        let harness = makeHarness(
            narrator: ScriptedNarrator(question, .question),
            approvalDecisions: [.allow]
        )
        let reply = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Should I delete the old importer?"
        )

        XCTAssertEqual(reply, StopQuestionCoordinator.reply(question: question, answer: "Yes"))
        let request = try? XCTUnwrap(harness.approvals().first)
        XCTAssertEqual(request?.summary, question)
        XCTAssertEqual(request?.kind, .question)
        XCTAssertEqual(request?.toolName, "StopQuestion")
        XCTAssertEqual(request?.sessionID, "s1")
        XCTAssertEqual(request?.agent, .claudeCode)
        XCTAssertNil(request?.spokenPreamble,
                     "the model wrote one utterance; there is no preamble in front of it")
        XCTAssertEqual(request?.detail, "")
        XCTAssertTrue(harness.spoken().isEmpty,
                      "the question is spoken by the answer window, not announced beside it")
    }

    func testQuestionModeCarriesNoBack() async {
        let question = "Should it delete the old importer?"
        let harness = makeHarness(
            narrator: ScriptedNarrator(question, .question),
            approvalDecisions: [.deny]
        )
        let reply = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Should I delete the old importer?"
        )
        XCTAssertEqual(reply, StopQuestionCoordinator.reply(question: question, answer: "No"))
    }

    func testAnUnansweredQuestionFailsOpenAndLeavesTheAgentAlone() async {
        let harness = makeHarness(
            narrator: ScriptedNarrator("Should it proceed?", .question),
            approvalDecisions: [.ask]
        )
        let reply = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Should I proceed?"
        )
        XCTAssertNil(reply)
        XCTAssertEqual(harness.approvals().count, 1)
        XCTAssertTrue(harness.breaks().isEmpty, "a timeout is not a narration failure")
    }

    // MARK: - Failure posture

    func testEveryNarrationFailureBreaksTheVoicePipeAndSpeaksNothing() async {
        let failures: [NarrationFailure] = [
            .http(status: 500), .timedOut, .emptyOutput, .malformedResponse,
            .transport("send failed"),
        ]
        for failure in failures {
            let harness = makeHarness(narrator: ScriptedNarrator(failing: failure))
            let reply = await harness.coordinator.handle(
                sessionID: "s1", agent: .claudeCode, text: "Something happened."
            )
            XCTAssertNil(reply, "\(failure): a broken narrator must not stop the agent")
            XCTAssertEqual(harness.breaks(), [failure.reason])
            XCTAssertTrue(harness.spoken().isEmpty,
                          "\(failure): there is no heuristic to fall back to")
            XCTAssertTrue(harness.approvals().isEmpty)
        }
    }

    // MARK: - Multiple pending items

    /// The loop-cap notice stops being a second utterance racing the narrated one: with a
    /// narrator composed it becomes an item in the same call, which is what gives the model
    /// something to combine.
    func testTheLoopCapNoticeIsFoldedIntoTheNarratedUtterance() async {
        let mailbox = InstructionMailbox()
        let harness = makeHarness(
            narrator: ScriptedNarrator("It is still working. I'm holding your next one.",
                                       .combined),
            instructions: mailbox
        )
        // Three instruction-bearing boundaries in a row, then a fourth that trips the cap.
        for index in 0..<4 { mailbox.enqueue("instruction \(index)", session: "s1") }
        for _ in 0..<3 {
            _ = await harness.coordinator.handle(
                sessionID: "s1", agent: .claudeCode, text: "working"
            )
        }
        _ = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Still working on it."
        )

        let request = try? XCTUnwrap(harness.narrator.requests.last)
        XCTAssertEqual(request?.items.count, 2)
        XCTAssertEqual(request?.items.first?.kind, .agentMessage)
        XCTAssertEqual(request?.items.first?.text, "Still working on it.")
        XCTAssertEqual(request?.items.last?.kind, .notice)
        XCTAssertEqual(request?.items.last?.text, StopQuestionCoordinator.loopCapNotice)
        XCTAssertEqual(harness.spoken(), ["It is still working. I'm holding your next one."],
                       "one boundary, one utterance")
    }

    func testBufferedNoticesDrainOnceAndAreBounded() async {
        let harness = makeHarness(narrator: ScriptedNarrator("Noted.", .combined))
        for index in 0..<6 {
            harness.coordinator.noteNarrationNotice("notice \(index)", session: "s1")
        }
        _ = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Working."
        )
        let first = try? XCTUnwrap(harness.narrator.requests.first)
        XCTAssertEqual(first?.items.count, 1 + StopQuestionCoordinator.maxPendingNotices)
        XCTAssertEqual(first?.items.last?.text, "notice 5", "the newest notices survive")

        _ = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Working some more."
        )
        XCTAssertEqual(harness.narrator.requests.last?.items.count, 1,
                       "notices drain once")
    }

    // MARK: - Instructions still come first

    func testAQueuedInstructionStillPreemptsNarration() async {
        let mailbox = InstructionMailbox()
        mailbox.enqueue("run the tests again", session: "s1")
        let harness = makeHarness(narrator: ScriptedNarrator("unused", .verbatim),
                                  instructions: mailbox)
        let reply = await harness.coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "All done."
        )
        XCTAssertEqual(reply,
                       StopQuestionCoordinator.instructionReply("run the tests again"))
        XCTAssertTrue(harness.narrator.requests.isEmpty,
                      "a boundary carrying an instruction is not a narration boundary")
    }

    // MARK: - The Apple path is untouched

    /// With no narrator composed the classifier and the summarizer are the whole of the
    /// delivery decision, exactly as they were before 2026-08-28.
    func testWithoutANarratorTheHeuristicPathIsUnchanged() async {
        var approvals: [ApprovalRequest] = []
        var spoken: [String] = []
        final class FixedClassifier: ResponseQuestionClassifying, @unchecked Sendable {
            func classify(_ text: String) async -> ResponseQuestionClassification? {
                .yesNo(question: "Delete the old importer")
            }
        }
        final class FixedSummarizer: SpokenSummarizing, @unchecked Sendable {
            func summarize(_ text: String) async -> SpokenSummary? {
                SpokenSummary(sentence: "The importer streams rows.", detail: "Three retries.")
            }
        }
        let coordinator = StopQuestionCoordinator(
            classifier: FixedClassifier(),
            summarizer: FixedSummarizer(),
            announce: { spoken.append($0) },
            runSelection: { _, _ in .noSelection },
            runApproval: { request, _ in
                approvals.append(request)
                return .allow
            }
        )
        let reply = await coordinator.handle(
            sessionID: "s1", agent: .claudeCode, text: "Should I delete the old importer?"
        )

        XCTAssertEqual(reply, StopQuestionCoordinator.reply(
            question: "Delete the old importer", answer: "Yes"
        ))
        XCTAssertEqual(approvals.first?.spokenPreamble, "The importer streams rows.")
        XCTAssertEqual(approvals.first?.detail, "Three retries.")
        XCTAssertEqual(approvals.first?.summary, "Delete the old importer")
        XCTAssertTrue(spoken.isEmpty)
    }

    /// The loop-cap notice is still spoken the moment it happens when there is no narrator
    /// to fold it into.
    func testWithoutANarratorTheLoopCapNoticeIsStillSpokenImmediately() async {
        var spoken: [String] = []
        final class NeverAQuestion: ResponseQuestionClassifying, @unchecked Sendable {
            func classify(_ text: String) async -> ResponseQuestionClassification? {
                .noQuestion
            }
        }
        let mailbox = InstructionMailbox()
        for index in 0..<4 { mailbox.enqueue("instruction \(index)", session: "s1") }
        let coordinator = StopQuestionCoordinator(
            classifier: NeverAQuestion(),
            instructions: mailbox,
            announce: { spoken.append($0) },
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in .ask }
        )
        for _ in 0..<4 {
            _ = await coordinator.handle(sessionID: "s1", agent: .claudeCode, text: "working")
        }
        XCTAssertEqual(spoken, [StopQuestionCoordinator.loopCapNotice])
    }
}
