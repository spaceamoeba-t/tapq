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

    func testTextIsCappedAtTheSpokenBudget() {
        var queue = makeQueue()
        let long = String(repeating: "word ", count: 200)
        queue.enqueue(long, session: "s1")

        let text = queue.dequeue(session: "s1")?.text ?? ""
        XCTAssertLessThanOrEqual(text.count, QueuedInstruction.textCharacterLimit)
        XCTAssertFalse(text.isEmpty)
    }

    func testEmptyDictationIsRejectedRatherThanQueued() {
        var queue = makeQueue()
        XCTAssertEqual(queue.enqueue("   \n  ", session: "s1"), .rejectedEmpty)
        XCTAssertFalse(queue.hasPending(session: "s1"))
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

        XCTAssertNil(mailbox.enqueue("  ", session: "s1"))
        XCTAssertEqual(sink.names, ["instruction.rejected_empty"])
        XCTAssertFalse(mailbox.hasPending(session: "s1"))
    }

    func testClearIsQuietWhenThereWasNothingToDiscard() async {
        let sink = RecordingSink()
        let mailbox = InstructionMailbox(diagnosticSink: sink)

        XCTAssertTrue(mailbox.clear(session: "s1").isEmpty)
        XCTAssertTrue(sink.names.isEmpty)
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
