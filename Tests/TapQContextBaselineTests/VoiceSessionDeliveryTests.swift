import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// What a voice session changes about delivery (RH1), and what it does not.
///
/// Two claims. A held turn boundary drains the queue through the *same* coordinator the
/// stop-question path drains it through — same template, same one-per-boundary rule, same
/// memory recording — so there is one piece of code in TapQ that hands an agent a sentence
/// nobody typed. And the loop cap, which exists because instruction-bearing blocks can
/// chase each other, stands down in the one mode where every boundary is meant to carry
/// one; the four-deep queue bound is untouched.
@MainActor
final class VoiceSessionDeliveryTests: XCTestCase {
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

    private struct NeverAQuestion: ResponseQuestionClassifying {
        func classify(_ text: String) async -> ResponseQuestionClassification? { nil }
    }

    private struct Harness {
        let coordinator: StopQuestionCoordinator
        let mailbox: InstructionMailbox
        let sink: RecordingSink
        let recorded: () -> [String]
        let announced: () -> [String]
    }

    private func makeHarness(voiceSession: Bool) -> Harness {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)
        var recorded: [String] = []
        var announced: [String] = []
        let coordinator = StopQuestionCoordinator(
            classifier: NeverAQuestion(),
            diagnosticSink: sink,
            instructions: mailbox,
            recordInstruction: { _, _, text in recorded.append(text) },
            announce: { announced.append($0) },
            suppressesLoopCap: voiceSession,
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in .ask }
        )
        return Harness(
            coordinator: coordinator,
            mailbox: mailbox,
            sink: sink,
            recorded: { recorded },
            announced: { announced }
        )
    }

    // MARK: - The held boundary drains the same queue

    func testAHeldBoundaryDeliversWithTheRatifiedTemplate() async {
        let harness = makeHarness(voiceSession: true)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        let reply = harness.coordinator.deliverInstruction(
            sessionID: "s1", agent: .claudeCode
        )

        XCTAssertEqual(
            reply,
            "The user dictated a new instruction via TapQ hands-free: "
                + "'run the tests again'. Proceed accordingly.",
            "a held boundary and a stop question must hand over identical text"
        )
        XCTAssertEqual(harness.recorded(), ["run the tests again"],
                       "and it is remembered as work handed over")
        XCTAssertFalse(harness.mailbox.hasPending(session: "s1"))
    }

    func testAHeldBoundaryWithNothingQueuedDeliversNothing() async {
        let harness = makeHarness(voiceSession: true)
        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode))
        XCTAssertEqual(harness.recorded(), [])
    }

    func testAHeldBoundaryDrainsOnlyItsOwnSession() async {
        let harness = makeHarness(voiceSession: true)
        harness.mailbox.enqueue("run the tests again", session: "s1")

        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s2", agent: .claudeCode))
        XCTAssertTrue(harness.mailbox.hasPending(session: "s1"))
    }

    func testAHeldBoundaryTakesExactlyOneInstruction() async {
        let harness = makeHarness(voiceSession: true)
        harness.mailbox.enqueue("first", session: "s1")
        harness.mailbox.enqueue("second", session: "s1")

        let reply = harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)

        XCTAssertTrue(reply?.contains("'first'") == true)
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 1,
                       "the next boundary is a sentence away and it will take the next one")
    }

    // MARK: - The loop cap

    /// The rung's bound change: in a voice session the wearer is standing at the boundary
    /// dictating one sentence at a time, so a cap after three would hold back the fourth
    /// thing they said and wait for a boundary only their own next sentence can produce.
    func testTheLoopCapDoesNotFireInAVoiceSession() async {
        let harness = makeHarness(voiceSession: true)
        let depth = InstructionQueue.capacity
        for index in 1...depth {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }

        for index in 1...depth {
            let reply = harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            )
            XCTAssertTrue(reply?.contains("'instruction \(index)'") == true,
                          "boundary \(index) must carry its instruction")
        }

        XCTAssertFalse(harness.sink.names.contains("instruction.loop_cap.suppressed"))
        XCTAssertEqual(harness.announced(), [], "and the wearer is never told to wait")
        XCTAssertFalse(harness.mailbox.hasPending(session: "s1"))
    }

    /// The same script with the flag off is the shipped RC2 behavior, unchanged: three in a
    /// row, then a spoken notice and a held instruction.
    func testTheLoopCapStillFiresWithoutAVoiceSession() async {
        let harness = makeHarness(voiceSession: false)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }

        for _ in 1...StopQuestionCoordinator.maxConsecutiveInstructions {
            XCTAssertNotNil(harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            ))
        }

        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode))
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 1,
                       "a suppressed instruction is held, never discarded")
        XCTAssertTrue(harness.sink.names.contains("instruction.loop_cap.suppressed"))
        XCTAssertEqual(harness.announced(), [StopQuestionCoordinator.loopCapNotice])
    }

    /// The queue bound is not the loop cap and does not stand down with it: a fifth
    /// instruction still drops the oldest, in a voice session as anywhere else.
    func testTheQueueBoundStillHoldsInAVoiceSession() async {
        let harness = makeHarness(voiceSession: true)
        for index in 1...(InstructionQueue.capacity + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
        }

        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), InstructionQueue.capacity)
        let reply = harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)
        XCTAssertTrue(reply?.contains("'instruction 2'") == true,
                      "the oldest was dropped to make room for the newest")
    }

    /// The stop-question path in a voice-session run: an instruction still outranks every
    /// guard, and the cap being stood down does not change what a boundary carries.
    func testTheStopQuestionPathIsUnchangedApartFromTheCap() async {
        let harness = makeHarness(voiceSession: true)
        harness.mailbox.enqueue("ship it", session: "s1")

        let reply = await harness.coordinator.handle(sessionID: "s1", text: "All done.")

        XCTAssertTrue(reply?.contains("'ship it'") == true)
    }

    // MARK: - The enqueue observer

    /// The seam the wait registry hangs on: every accepted instruction reports its session,
    /// and an empty one — which is queued nowhere — reports nothing.
    func testTheMailboxAnnouncesEveryAcceptedInstruction() async {
        let mailbox = InstructionMailbox()
        var announced: [String] = []
        mailbox.onEnqueued = { announced.append($0) }

        mailbox.enqueue("run the tests", session: "s1")
        mailbox.enqueue("   \n  ", session: "s1")
        mailbox.enqueue("push the branch", session: "s2")

        XCTAssertEqual(announced, ["s1", "s2"],
                       "an empty dictation queues nothing and wakes nobody")
    }
}
