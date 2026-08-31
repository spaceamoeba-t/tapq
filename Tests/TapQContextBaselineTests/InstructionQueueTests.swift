import XCTest
import TapQContracts
@testable import TapQContextBaseline

/// The value type: bounds, order, and what it does to the text it is handed.
final class InstructionQueueTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeQueue() -> InstructionQueue {
        let tick = SteppingClock(origin: epoch)
        return InstructionQueue(clock: { tick.next() })
    }

    // MARK: - Order and bounds

    func testInstructionsDrainInTheOrderTheyWereDictated() {
        var queue = makeQueue()
        queue.enqueue("run the tests again", session: "s1")
        queue.enqueue("then push the branch", session: "s1")

        XCTAssertEqual(queue.count(session: "s1"), 2)
        XCTAssertEqual(queue.dequeue(session: "s1")?.text, "run the tests again")
        XCTAssertEqual(queue.dequeue(session: "s1")?.text, "then push the branch")
        XCTAssertNil(queue.dequeue(session: "s1"))
    }

    func testCapacityDropsTheOldestInstruction() {
        var queue = makeQueue()
        for index in 1...(InstructionQueue.capacity + 1) {
            queue.enqueue("instruction \(index)", session: "s1")
        }

        XCTAssertEqual(queue.count(session: "s1"), InstructionQueue.capacity)
        XCTAssertEqual(
            queue.pending(session: "s1").map(\.text),
            ["instruction 2", "instruction 3", "instruction 4", "instruction 5"],
            "the fifth instruction evicts the first, not itself"
        )
    }

    func testEnqueueReportsWhatItDropped() {
        var queue = makeQueue()
        for index in 1...InstructionQueue.capacity {
            XCTAssertEqual(
                queue.enqueue("instruction \(index)", session: "s1").accepted?.text,
                "instruction \(index)"
            )
        }

        let result = queue.enqueue("instruction 5", session: "s1")
        guard case let .queuedDroppingOldest(queued, dropped) = result else {
            return XCTFail("expected a drop at capacity, got \(result)")
        }
        XCTAssertEqual(queued.text, "instruction 5")
        XCTAssertEqual(dropped.text, "instruction 1")
    }

    func testSessionsAreIsolated() {
        var queue = makeQueue()
        queue.enqueue("run the tests", session: "s1")
        queue.enqueue("open a pull request", session: "s2")

        XCTAssertEqual(queue.count(session: "s1"), 1)
        XCTAssertEqual(queue.dequeue(session: "s2")?.text, "open a pull request")
        XCTAssertTrue(queue.hasPending(session: "s1"))
        XCTAssertFalse(queue.hasPending(session: "s2"))
    }

    func testDrainedSessionsAreForgotten() {
        var queue = makeQueue()
        queue.enqueue("run the tests", session: "s1")
        XCTAssertEqual(queue.trackedSessions, ["s1"])

        _ = queue.dequeue(session: "s1")
        XCTAssertTrue(
            queue.trackedSessions.isEmpty,
            "only sessions with undelivered instructions may occupy space"
        )
    }

    func testClearDiscardsEverythingForOneSession() {
        var queue = makeQueue()
        queue.enqueue("run the tests", session: "s1")
        queue.enqueue("push the branch", session: "s1")
        queue.enqueue("leave this one alone", session: "s2")

        XCTAssertEqual(queue.clear(session: "s1").count, 2)
        XCTAssertFalse(queue.hasPending(session: "s1"))
        XCTAssertEqual(queue.count(session: "s2"), 1)
    }

    // MARK: - Text safety

    func testTextIsWhitespaceNormalized() {
        var queue = makeQueue()
        queue.enqueue("  run the   tests\nagain  ", session: "s1")

        XCTAssertEqual(queue.dequeue(session: "s1")?.text, "run the tests again")
    }

    /// Rule 1 of NARRATION_MODEL_PLAN: the wearer's words are never clipped. This used to
    /// assert the opposite — a cap at the spoken-detail budget — and the cap is gone.
    func testLongDictationIsQueuedWhole() {
        var queue = makeQueue()
        let long = String(repeating: "word ", count: 200)
        queue.enqueue(long, session: "s1")

        let text = queue.dequeue(session: "s1")?.text ?? ""
        XCTAssertEqual(text, long.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(text.count, 999)
    }

    /// The trailing clause is the whole point: the old cap cut mid-sentence and inverted
    /// what the agent was asked to do.
    func testTrailingClauseSurvivesAnOverBudgetInstruction() {
        var queue = makeQueue()
        let filler = String(repeating: "run the tests ", count: 40)
        queue.enqueue(filler + "but not the slow ones", session: "s1")

        let text = queue.dequeue(session: "s1")?.text ?? ""
        XCTAssertTrue(text.hasSuffix("but not the slow ones"))
        XCTAssertGreaterThan(text.count, SpokenSummary.detailCharacterLimit)
    }

    func testEmptyDictationIsRejectedRatherThanQueued() {
        var queue = makeQueue()
        XCTAssertEqual(queue.enqueue("   \n  ", session: "s1"), .rejectedEmpty)
        XCTAssertFalse(queue.hasPending(session: "s1"))
    }

    // MARK: - Origin (M3)

    /// The compatibility claim the defaulted parameter exists to make: every enqueue site
    /// written before the loop existed keeps queueing the wearer's own sentences, and says
    /// nothing to do so.
    func testAnUntaggedEnqueueIsDictated() {
        var queue = makeQueue()
        queue.enqueue("run the tests again", session: "s1")

        XCTAssertEqual(queue.peek(session: "s1")?.origin, .dictated)
        XCTAssertEqual(
            QueuedInstruction(text: "typed by hand", enqueuedAt: epoch).origin, .dictated,
            "the value type defaults the same way the queue does"
        )
    }

    func testTheOriginSurvivesTheRoundTripThroughTheQueue() {
        var queue = makeQueue()
        queue.enqueue("rerun the failing suite", session: "s1", origin: .loop)
        queue.enqueue("and then push", session: "s1")

        XCTAssertEqual(
            queue.pending(session: "s1").map(\.origin), [.loop, .dictated],
            "the tag rides each instruction, not the session"
        )
        XCTAssertEqual(queue.dequeue(session: "s1")?.origin, .loop)
        XCTAssertEqual(queue.dequeue(session: "s1")?.origin, .dictated)
    }

    /// `peek` is the accessor the origin-aware cap needs: it must know whose sentence it is
    /// about to hold back *before* deciding to hold it, and holding means leaving it here.
    func testPeekReadsTheHeadWithoutTakingIt() {
        var queue = makeQueue()
        queue.enqueue("first", session: "s1", origin: .loop)
        queue.enqueue("second", session: "s1")

        XCTAssertEqual(queue.peek(session: "s1")?.text, "first")
        XCTAssertEqual(queue.peek(session: "s1")?.text, "first", "peeking is not taking")
        XCTAssertEqual(queue.count(session: "s1"), 2)
        XCTAssertNil(queue.peek(session: "s2"))
    }

    /// The drop-oldest rule is origin-blind — a loop sentence evicts a dictated one and
    /// vice versa — and the result says which was which, because the two cases sound
    /// different when read back.
    func testDisplacementExposesBothOrigins() {
        var queue = makeQueue()
        queue.enqueue("what the wearer said", session: "s1")
        for index in 2...InstructionQueue.capacity {
            queue.enqueue("filler \(index)", session: "s1")
        }

        let result = queue.enqueue("what TapQ decided", session: "s1", origin: .loop)
        XCTAssertEqual(result.accepted?.origin, .loop)
        XCTAssertEqual(result.displaced?.origin, .dictated)
        XCTAssertEqual(result.displaced?.text, "what the wearer said")
    }

    func testNothingIsDisplacedWithRoomToSpare() {
        var queue = makeQueue()
        XCTAssertNil(queue.enqueue("room to spare", session: "s1").displaced)
        XCTAssertNil(queue.enqueue("   ", session: "s1").displaced)
    }

    func testTimestampsComeFromTheInjectedClock() {
        var queue = makeQueue()
        queue.enqueue("run the tests", session: "s1")
        queue.enqueue("push the branch", session: "s1")

        let stamps = queue.pending(session: "s1").map(\.enqueuedAt)
        XCTAssertEqual(stamps.first, epoch)
        XCTAssertLessThan(stamps[0], stamps[1])
    }
}

/// The `@MainActor` owner: the same bounds seen through the shared object, plus the
/// diagnostics the runtime watches.
@MainActor
final class InstructionMailboxTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        var names: [String] { events.map(\.name) }
    }

    func testEnqueueAndDequeueShareOneQueueAcrossHolders() async {
        let mailbox = InstructionMailbox()
        // The point of the reference type: two holders, one queue. A captured value
        // type would give the deliverer an empty copy.
        let enqueuer = mailbox
        let deliverer = mailbox

        enqueuer.enqueue("run the tests again", session: "s1")
        XCTAssertTrue(deliverer.hasPending(session: "s1"))
        XCTAssertEqual(deliverer.dequeue(session: "s1")?.text, "run the tests again")
        XCTAssertFalse(enqueuer.hasPending(session: "s1"))
    }

    func testDropAtCapacityIsDiagnosed() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)
        for index in 1...(InstructionQueue.capacity + 1) {
            mailbox.enqueue("instruction \(index)", session: "s1")
        }

        XCTAssertEqual(
            sink.names.filter { $0 == "instruction.dropped_capacity" }.count, 1
        )
        XCTAssertEqual(mailbox.pendingCount(session: "s1"), InstructionQueue.capacity)
        XCTAssertEqual(mailbox.pending(session: "s1").first?.text, "instruction 2")
    }

    /// The displacement is *returned*, not only logged.
    ///
    /// Until 2026-08-28 the mailbox answered `QueuedInstruction?`, which said the fifth
    /// sentence was accepted and nothing about the first one being gone. The wearer heard
    /// "Queued" five times and the agent received four; the only record of the loss was a
    /// warning in a file they cannot read. The read-back can only say so if this says so,
    /// which is what the wider return type is for.
    func testTheMailboxReportsWhichEnqueueDisplacedAnOlderInstruction() async {
        let mailbox = InstructionMailbox()
        for index in 1...InstructionQueue.capacity {
            guard case .queued = mailbox.enqueue("instruction \(index)", session: "s1") else {
                return XCTFail("instruction \(index) displaced something with room to spare")
            }
        }

        guard case let .queuedDroppingOldest(accepted, dropped) =
            mailbox.enqueue("instruction 5", session: "s1") else {
            return XCTFail("the fifth instruction did not report the displacement")
        }
        XCTAssertEqual(accepted.text, "instruction 5", "the newest sentence is the kept one")
        XCTAssertEqual(dropped.text, "instruction 1", "the oldest is the dropped one")

        // A different session is untouched by another's capacity: the bound is per session,
        // so a wearer working two agents does not lose one agent's sentence to the other.
        guard case .queued = mailbox.enqueue("elsewhere", session: "s2") else {
            return XCTFail("a fresh session reported a displacement it could not have had")
        }
    }

    func testDiagnosticsCarryCountsAndLengthsButNeverTheWearersWords() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)
        mailbox.enqueue("delete the staging database", session: "s1")
        _ = mailbox.dequeue(session: "s1")

        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(
                    value.contains("staging"),
                    "an instruction is the wearer's speech; only its length is loggable"
                )
            }
        }
        XCTAssertEqual(sink.names, ["instruction.queued", "instruction.dequeued"])
    }

    func testEmptyDictationIsRejectedAndDiagnosed() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)

        XCTAssertEqual(mailbox.enqueue("  ", session: "s1"), .rejectedEmpty)
        XCTAssertEqual(sink.names, ["instruction.rejected_empty"])
        XCTAssertFalse(mailbox.hasPending(session: "s1"))
    }

    func testClearIsQuietWhenThereWasNothingToDiscard() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)

        XCTAssertTrue(mailbox.clear(session: "s1").isEmpty)
        XCTAssertTrue(sink.names.isEmpty)
    }

    // MARK: - Origin through the shared object (M3)

    func testTheMailboxDefaultsToDictatedAndCarriesWhatItIsTold() async {
        let mailbox = InstructionMailbox()
        mailbox.enqueue("the wearer said this", session: "s1")
        mailbox.enqueue("TapQ decided this", session: "s1", origin: .loop)

        XCTAssertEqual(mailbox.pending(session: "s1").map(\.origin), [.dictated, .loop])
        XCTAssertEqual(mailbox.peek(session: "s1")?.origin, .dictated,
                       "peek sees the head the next boundary would take")
        XCTAssertEqual(mailbox.dequeue(session: "s1")?.origin, .dictated)
        XCTAssertEqual(mailbox.dequeue(session: "s1")?.origin, .loop)
    }

    /// The composition announces a displacement differently depending on who lost a
    /// sentence, so both origins have to come back out of the result — not just a `Bool`
    /// saying something was dropped.
    func testDisplacementReportsTheOriginOnBothSides() async {
        let mailbox = InstructionMailbox()
        mailbox.enqueue("what the wearer said", session: "s1")
        for index in 2...InstructionQueue.capacity {
            mailbox.enqueue("filler \(index)", session: "s1")
        }

        let result = mailbox.enqueue("what TapQ decided", session: "s1", origin: .loop)
        guard case let .queuedDroppingOldest(accepted, dropped) = result else {
            return XCTFail("the fifth instruction did not report the displacement")
        }
        XCTAssertEqual(accepted.origin, .loop)
        XCTAssertEqual(dropped.origin, .dictated,
                       "TapQ's own sentence pushed out one the wearer spoke")
        XCTAssertEqual(result.accepted?.origin, .loop)
        XCTAssertEqual(result.displaced?.origin, .dictated)
    }

    /// The origin is a category, not speech: it is exactly the kind of thing the
    /// diagnostics may carry, and an operator hunting "did TapQ evict something the wearer
    /// said" has nowhere else to look.
    func testDiagnosticsCarryTheOriginWithoutCarryingTheWords() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)
        mailbox.enqueue("delete the staging database", session: "s1", origin: .loop)
        _ = mailbox.dequeue(session: "s1")

        XCTAssertEqual(sink.events.first?.fields["origin"], "loop")
        XCTAssertEqual(sink.events.last?.fields["origin"], "loop")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("staging"))
            }
        }
    }
}

/// One second per call, so queue order is provable without sleeping.
private final class SteppingClock: @unchecked Sendable {
    private let origin: Date
    private let lock = NSLock()
    private var step = 0

    init(origin: Date) {
        self.origin = origin
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = origin.addingTimeInterval(TimeInterval(step))
        step += 1
        return value
    }
}
