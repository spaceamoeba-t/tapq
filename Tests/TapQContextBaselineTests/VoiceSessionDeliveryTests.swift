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
///
/// M3 adds the third claim, which is the reason the stand-down needed splitting: the cap
/// on TapQ's *own* instructions binds here too. `suppressesLoopCap` is the configuration
/// the deliberation loop runs in, so a stand-down that covered both would leave autonomy
/// unbounded in precisely the mode that has any.
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

    // MARK: - The autonomous cap (M3)

    /// The leg's whole point. `suppressesLoopCap` is exactly the configuration the
    /// deliberation loop runs in, so a cap on TapQ's own instructions that the stand-down
    /// covered would be a cap that never once fired where it was needed.
    func testTheAutonomousCapBindsWhileTheDictatedCapIsStoodDown() async {
        let harness = makeHarness(voiceSession: true)
        let cap = StopQuestionCoordinator.maxConsecutiveLoopInstructions
        for index in 1...(cap + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1", origin: .loop)
        }

        for index in 1...cap {
            let reply = harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            )
            XCTAssertTrue(reply?.contains("'instruction \(index)'") == true,
                          "boundary \(index) is within the autonomous budget")
        }

        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode),
                     "the fourth of TapQ's own sentences in a row is held")
        XCTAssertEqual(harness.mailbox.pendingCount(session: "s1"), 1,
                       "held at the head of the queue, never discarded")
        XCTAssertEqual(harness.mailbox.peek(session: "s1")?.text, "instruction 4")
        XCTAssertTrue(harness.sink.names.contains("instruction.autonomous_cap.suppressed"))
        XCTAssertFalse(harness.sink.names.contains("instruction.loop_cap.suppressed"),
                       "it is the autonomous cap that fired, not the stood-down one")
        XCTAssertEqual(harness.announced(), [StopQuestionCoordinator.autonomousCapNotice])
        XCTAssertNotEqual(StopQuestionCoordinator.autonomousCapNotice,
                          StopQuestionCoordinator.loopCapNotice,
                          "the wearer must be able to hear which of the two happened")
    }

    /// The other half of the same claim: nothing about the new counter reaches dictation.
    /// The wearer keeps dictating past the three-in-a-row line in a voice session, which
    /// is what the stand-down was for.
    func testDictationStaysUncappedInTheSameConfiguration() async {
        let harness = makeHarness(voiceSession: true)
        // Well past both caps, one sentence at a time, which is how a wearer produces them.
        for index in 1...(StopQuestionCoordinator.maxConsecutiveInstructions * 2) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1")
            let reply = harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            )
            XCTAssertTrue(reply?.contains("'instruction \(index)'") == true,
                          "sentence \(index) is the wearer's and must go out")
        }

        XCTAssertEqual(harness.announced(), [], "the wearer is never told to wait")
        XCTAssertFalse(harness.sink.names.contains("instruction.autonomous_cap.suppressed"))
    }

    /// Suppression is a hold, not a loss: the suppressed boundary is itself the intervening
    /// non-instruction event, so the held sentence goes out on the very next one.
    func testASuppressedAutonomousInstructionGoesOutOnTheNextBoundary() async {
        let harness = makeHarness(voiceSession: true)
        let cap = StopQuestionCoordinator.maxConsecutiveLoopInstructions
        for index in 1...(cap + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1", origin: .loop)
        }
        for _ in 1...cap {
            XCTAssertNotNil(harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            ))
        }
        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode))

        let resumed = harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)
        XCTAssertTrue(resumed?.contains("'instruction 4'") == true,
                      "the held instruction is delivered, not stranded")
        XCTAssertFalse(harness.mailbox.hasPending(session: "s1"))
    }

    /// A boundary that carries nothing at all is the same intervening event, which is what
    /// keeps the cap counting *runs* of autonomy rather than a session's lifetime total.
    func testAQuietBoundaryClearsTheAutonomousRun() async {
        let harness = makeHarness(voiceSession: true)
        for index in 1...StopQuestionCoordinator.maxConsecutiveLoopInstructions {
            harness.mailbox.enqueue("instruction \(index)", session: "s1", origin: .loop)
            XCTAssertNotNil(harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            ))
        }
        // The agent got somewhere on its own and TapQ had nothing to add.
        XCTAssertNil(harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode))

        harness.mailbox.enqueue("instruction 4", session: "s1", origin: .loop)
        XCTAssertTrue(
            harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)?
                .contains("'instruction 4'") == true
        )
        XCTAssertEqual(harness.announced(), [], "nothing was held, so nothing is said")
    }

    /// The intervening event the cap is really waiting for: the wearer saying something.
    /// A dictated delivery resets the autonomous run — and is itself never held by it, even
    /// with the run already at the cap.
    func testAWearerSentenceClearsTheAutonomousRunAndIsNeverHeldByIt() async {
        let harness = makeHarness(voiceSession: true)
        let cap = StopQuestionCoordinator.maxConsecutiveLoopInstructions
        for index in 1...cap {
            harness.mailbox.enqueue("autonomous \(index)", session: "s1", origin: .loop)
            XCTAssertNotNil(harness.coordinator.deliverInstruction(
                sessionID: "s1", agent: .claudeCode
            ))
        }

        // The run is at the cap. A sentence the wearer spoke goes out regardless.
        harness.mailbox.enqueue("actually, stop and show me", session: "s1")
        let dictated = harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)
        XCTAssertTrue(dictated?.contains("'actually, stop and show me'") == true)
        XCTAssertEqual(harness.announced(), [], "a wearer sentence trips no cap")

        // And the wearer having spoken, TapQ gets a fresh run of three.
        for index in 1...cap {
            harness.mailbox.enqueue("resumed \(index)", session: "s1", origin: .loop)
            XCTAssertTrue(
                harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)?
                    .contains("'resumed \(index)'") == true,
                "autonomous sentence \(index) after the reset"
            )
        }
        XCTAssertFalse(harness.sink.names.contains("instruction.autonomous_cap.suppressed"))
    }

    /// The cap is per session, like its sibling: TapQ working one agent hard is no reason
    /// to go quiet on another.
    func testTheAutonomousCapIsCountedPerSession() async {
        let harness = makeHarness(voiceSession: true)
        for index in 1...(StopQuestionCoordinator.maxConsecutiveLoopInstructions + 1) {
            harness.mailbox.enqueue("instruction \(index)", session: "s1", origin: .loop)
        }
        harness.mailbox.enqueue("other session work", session: "s2", origin: .loop)
        for _ in 1...StopQuestionCoordinator.maxConsecutiveLoopInstructions {
            _ = harness.coordinator.deliverInstruction(sessionID: "s1", agent: .claudeCode)
        }

        let other = harness.coordinator.deliverInstruction(sessionID: "s2", agent: .claudeCode)
        XCTAssertTrue(other?.contains("'other session work'") == true)
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
