import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// What the coordinator owes the instruction channel (RC1/RC2): the ratified reply, one
/// instruction per turn boundary, precedence over every guard that exists to stop TapQ
/// re-answering the agent, and a loop cap on the blocks it emits.
@MainActor
final class StopQuestionInstructionDeliveryTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }
    }

    /// Counts classification attempts: the delivery branch must not reach the classifier
    /// at all, so "how many times were you asked" is the assertion that proves it.
    private final class CountingClassifier: ResponseQuestionClassifying, @unchecked Sendable {
        private let result: ResponseQuestionClassification?
        private(set) var calls = 0

        init(_ result: ResponseQuestionClassification?) {
            self.result = result
        }

        func classify(_ text: String) async -> ResponseQuestionClassification? {
            calls += 1
            return result
        }
    }

    private struct Harness {
        let coordinator: StopQuestionCoordinator
        let mailbox: InstructionMailbox
        let classifier: CountingClassifier
        let sink: RecordingSink
        let recorded: () -> [(session: String, agent: AgentIdentity, text: String)]
        let announced: () -> [String]
        let approvals: () -> Int
    }

    private func makeHarness(
        classify: ResponseQuestionClassification? = .yesNo(question: "Continue?"),
        decision: Decision = .allow,
        withMailbox: Bool = true
    ) -> Harness {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)
        let classifier = CountingClassifier(classify)
        var recorded: [(session: String, agent: AgentIdentity, text: String)] = []
        var announced: [String] = []
        var approvals = 0
        let coordinator = StopQuestionCoordinator(
            classifier: classifier,
            diagnosticSink: sink,
            instructions: withMailbox ? mailbox : nil,
            recordInstruction: { session, agent, text in
                recorded.append((session, agent, text))
            },
            announce: { announced.append($0) },
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in
                approvals += 1
                return decision
            }
        )
        return Harness(
            coordinator: coordinator,
            mailbox: mailbox,
            classifier: classifier,
            sink: sink,
            recorded: { recorded },
            announced: { announced },
            approvals: { approvals }
        )
    }

    // MARK: - The reply

    func testQueuedInstructionIsDeliveredWithTheRatifiedTemplate() async {
        let harness = makeHarness()
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let reply = await harness.coordinator.handle(sessionID: "s1", text: "All done.")

        XCTAssertEqual(
            reply,
            "The user dictated a new instruction via TapQ hands-free: 'run the tests again'. Proceed accordingly."
        )
    }

    func testDeliveryIsScopedToItsOwnSession() async {
        let harness = makeHarness(classify: .noQuestion)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let other = await harness.coordinator.handle(sessionID: "s2", text: "All done.")
        XCTAssertNil(other, "another session's boundary must not drain this queue")
        XCTAssertTrue(harness.mailbox.hasPending(session: "s1"))
    }

    func testOneInstructionDrainsPerBoundary() async {
        let harness = makeHarness(classify: .noQuestion)
        harness.mailbox.enqueue("run the tests again", session: "s1")
        harness.mailbox.enqueue("then push the branch", session: "s1")

        let first = await harness.coordinator.handle(sessionID: "s1", text: "reply one")
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 1)
        XCTAssertTrue(first?.contains("'run the tests again'") == true)

        let second = await harness.coordinator.handle(sessionID: "s1", text: "reply two")
        XCTAssertTrue(second?.contains("'then push the branch'") == true)
        XCTAssertFalse(harness.mailbox.hasPending(session: "s1"))
    }

    func testEmptyMailboxLeavesEveryOtherPathUntouched() async {
        let harness = makeHarness(classify: .yesNo(question: "Continue?"), decision: .allow)

        let reply = await harness.coordinator.handle(sessionID: "s1", text: "reply")

        XCTAssertTrue(reply?.contains("they chose: 'Yes'") == true)
        XCTAssertEqual(harness.classifier.calls, 1)
        XCTAssertTrue(harness.recorded().isEmpty)
    }

    func testWithoutAMailboxBehaviorIsTheOneItAlwaysHad() async {
        let harness = makeHarness(
            classify: .yesNo(question: "Continue?"),
            decision: .allow,
            withMailbox: false
        )
        // Enqueuing into a mailbox the coordinator was never given changes nothing:
        // this is `--voice-instructions` absent.
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let reply = await harness.coordinator.handle(sessionID: "s1", text: "reply")

        XCTAssertTrue(reply?.contains("they chose: 'Yes'") == true)
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 1)
    }

    // MARK: - Precedence over the guards (RC1)

    func testDeliveryOutranksTheRepeatGuard() async {
        let harness = makeHarness(classify: .yesNo(question: "Continue?"), decision: .allow)

        let answered = await harness.coordinator.handle(sessionID: "s1", text: "same reply")
        XCTAssertNotNil(answered)
        // The same text again is a repeat, and a repeat passes through — unless an
        // instruction is waiting, which is not an answer to anything.
        let repeated = await harness.coordinator.handle(sessionID: "s1", text: "same reply")
        XCTAssertNil(repeated)

        harness.mailbox.enqueue("run the tests again", session: "s1")
        let delivered = await harness.coordinator.handle(sessionID: "s1", text: "same reply")
        XCTAssertTrue(delivered?.contains("'run the tests again'") == true)
    }

    func testDeliveryOutranksTheConsecutiveAnswerCap() async {
        let harness = makeHarness(classify: .yesNo(question: "Continue?"), decision: .allow)
        for index in 1...StopQuestionCoordinator.maxConsecutiveAnswers {
            _ = await harness.coordinator.handle(sessionID: "s1", text: "question \(index)?")
        }
        // The cap is now exhausted: the next boundary would pass through.
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let reply = await harness.coordinator.handle(sessionID: "s1", text: "question 6?")
        XCTAssertTrue(reply?.contains("'run the tests again'") == true)
    }

    func testDeliveryOutranksTheClassifierAndNeverCallsIt() async {
        let unavailable = makeHarness(classify: nil)
        unavailable.mailbox.enqueue("run the tests again", session: "s1")
        let reply = await unavailable.coordinator.handle(sessionID: "s1", text: "All done.")
        XCTAssertTrue(reply?.contains("'run the tests again'") == true)
        XCTAssertEqual(
            unavailable.classifier.calls, 0,
            "an instruction is delivered without asking whether the agent asked anything"
        )

        let noQuestion = makeHarness(classify: .noQuestion)
        noQuestion.mailbox.enqueue("run the tests again", session: "s1")
        let delivered = await noQuestion.coordinator.handle(sessionID: "s1", text: "All done.")
        XCTAssertNotNil(delivered)
        XCTAssertEqual(noQuestion.classifier.calls, 0)
    }

    func testDeliveryRunsNoInteractionAndAnswersNothing() async {
        let harness = makeHarness(classify: .yesNo(question: "Continue?"), decision: .allow)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        _ = await harness.coordinator.handle(sessionID: "s1", text: "same reply")
        XCTAssertEqual(harness.approvals(), 0, "delivery asks the wearer nothing")

        // The delivering boundary did not record "same reply" as answered, so the stop
        // question it carried is still there to be handled on the next boundary.
        let answered = await harness.coordinator.handle(sessionID: "s1", text: "same reply")
        XCTAssertTrue(answered?.contains("they chose: 'Yes'") == true)
        XCTAssertEqual(harness.approvals(), 1)
    }

    // MARK: - The broker's dedupe cache

    func testDeliveryIsIdempotentForTheBrokersCachedDuplicate() async {
        // `BrokerServer.resolveStopQuestion` caches a completed stop reply for five
        // seconds, keyed by agent + session + verbatim text, and replays it for an
        // identical duplicate rather than calling the coordinator again. That is what
        // makes hook retries safe here: a retried stop block gets the *same* instruction
        // reply from the cache, and the queue is drained exactly once, because the
        // coordinator is never re-entered. The coordinator therefore does not — and must
        // not — dedupe deliveries itself; two genuinely separate boundaries five seconds
        // apart are two deliveries, which is exactly what draining one per boundary
        // means. This test pins the coordinator half of that contract: one call, one
        // drain, and the reply is a pure function of the instruction, so the cached
        // replay is byte-identical to what a second call would have produced.
        let harness = makeHarness(classify: .noQuestion)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let first = await harness.coordinator.handle(sessionID: "s1", text: "All done.")
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 0)
        XCTAssertEqual(
            first,
            StopQuestionCoordinator.instructionReply("run the tests again")
        )

        // Whatever the cache replays, a *second* coordinator call would not re-deliver
        // an instruction that is already gone.
        let second = await harness.coordinator.handle(sessionID: "s1", text: "All done.")
        XCTAssertNil(second)
    }

    // MARK: - Loop cap (RC2)

    func testThreeConsecutiveDeliveriesThenSuppression() async {
        let harness = makeHarness(classify: .noQuestion)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }

        for index in 1...StopQuestionCoordinator.maxConsecutiveInstructions {
            let reply = await harness.coordinator.handle(sessionID: "s1", text: "reply \(index)")
            XCTAssertTrue(reply?.contains("'instruction \(index)'") == true)
        }

        let suppressed = await harness.coordinator.handle(sessionID: "s1", text: "reply 4")
        XCTAssertNil(suppressed, "the fourth block in a row is not emitted")
        XCTAssertEqual(
            harness.mailbox.pendingCount(session: "s1"), 1,
            "a suppressed instruction is held, never discarded"
        )
        XCTAssertTrue(harness.sink.names.contains("instruction.loop_cap.suppressed"))
        XCTAssertEqual(harness.announced(), [StopQuestionCoordinator.loopCapNotice])
    }

    func testTheSuppressedBoundaryItselfClearsTheCount() async {
        let harness = makeHarness(classify: .noQuestion)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }
        for index in 1...StopQuestionCoordinator.maxConsecutiveInstructions {
            _ = await harness.coordinator.handle(sessionID: "s1", text: "reply \(index)")
        }
        let suppressed = await harness.coordinator.handle(sessionID: "s1", text: "reply 4")
        XCTAssertNil(suppressed)

        // The suppressed boundary is the intervening non-instruction event, so the held
        // instruction goes out on the next one rather than being stranded.
        let resumed = await harness.coordinator.handle(sessionID: "s1", text: "reply 5")
        XCTAssertTrue(resumed?.contains("'instruction 4'") == true)
    }

    func testAnOrdinaryBoundaryClearsTheCount() async {
        let harness = makeHarness(classify: .noQuestion)
        for index in 1...StopQuestionCoordinator.maxConsecutiveInstructions {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
            _ = await harness.coordinator.handle(sessionID: "s1", text: "reply \(index)")
        }
        // A boundary with nothing queued: the agent got somewhere on its own.
        let quiet = await harness.coordinator.handle(sessionID: "s1", text: "quiet reply")
        XCTAssertNil(quiet)

        harness.mailbox.enqueue("instruction 4", session: "s1")
        let reply = await harness.coordinator.handle(sessionID: "s1", text: "reply 4")
        XCTAssertTrue(reply?.contains("'instruction 4'") == true)
        XCTAssertEqual(harness.announced(), [], "nothing was suppressed, so nothing is said")
    }

    func testTheCapIsCountedPerSession() async {
        let harness = makeHarness(classify: .noQuestion)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }
        harness.mailbox.enqueue("other session work", session: "s2")
        for index in 1...StopQuestionCoordinator.maxConsecutiveInstructions {
            _ = await harness.coordinator.handle(sessionID: "s1", text: "reply \(index)")
        }

        let other = await harness.coordinator.handle(sessionID: "s2", text: "reply")
        XCTAssertTrue(other?.contains("'other session work'") == true)
    }

    // MARK: - The store hook (RC7)

    func testDeliveryRecordsTheInstructionOnce() async {
        let harness = makeHarness(classify: .noQuestion)
        let agent = AgentIdentity.claudeCode
        harness.mailbox.enqueue("run the tests again", session: "s1")

        _ = await harness.coordinator.handle(sessionID: "s1", agent: agent, text: "All done.")

        XCTAssertEqual(harness.recorded().count, 1)
        XCTAssertEqual(harness.recorded().first?.session, "s1")
        XCTAssertEqual(harness.recorded().first?.agent, agent)
        XCTAssertEqual(harness.recorded().first?.text, "run the tests again")
    }

    func testSuppressedDeliveryRecordsNothing() async {
        let harness = makeHarness(classify: .noQuestion)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            _ = await harness.coordinator.handle(sessionID: "s1", text: "reply \(index)")
        }

        XCTAssertEqual(
            harness.recorded().count, StopQuestionCoordinator.maxConsecutiveInstructions,
            "memory records what the agent received, not what is still waiting"
        )
    }

    func testDeliveryIsDiagnosed() async {
        let harness = makeHarness(classify: .noQuestion)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        _ = await harness.coordinator.handle(sessionID: "s1", text: "All done.")

        XCTAssertTrue(harness.sink.names.contains("instruction.delivered"))
    }
}
