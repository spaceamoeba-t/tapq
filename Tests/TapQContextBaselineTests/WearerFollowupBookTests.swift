import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The one-shot follow-up kernel (`docs/TAPQ_AGENT_PLAN.md`, "Initiative (M3, the guarded
/// step)", scoped to one-shots 2026-08-31).
///
/// What is pinned here is the set of promises the book makes to the wearer: one per agent,
/// a replacement they hear about, a cancel that reaches it wherever it currently is —
/// including inside the announce grace, which is the whole reason the grace exists — and a
/// record complete enough that "did that ever happen?" is answerable tomorrow.
///
/// Every test method is `async`, including the ones with nothing to await: the Swift 6
/// test-discovery shim on Linux will not register a synchronous method on a `@MainActor`
/// case, and a test that silently does not run is worse than one that fails.
/// Collects the follow-up book's lifecycle record, so a test can assert on the file the
/// wearer's history is written to without going near a disk.
@MainActor final class RecordingFollowupLog {
    private(set) var entries: [(agent: String, instruction: String, event: String)] = []

    var events: [String] { entries.map(\.event) }

    func recorder() -> WearerFollowupBook.Recorder {
        { [self] agent, instruction, event in
            entries.append((agent, instruction, event))
        }
    }
}

@MainActor
final class WearerFollowupBookTests: XCTestCase {
    private func makeBook(
        log: RecordingFollowupLog,
        sink: TaskDiagnosticSink = TaskDiagnosticSink()
    ) -> WearerFollowupBook {
        WearerFollowupBook(record: log.recorder(), diagnosticSink: sink)
    }

    // MARK: - Setting

    func testASetFollowupIsPendingAndRecorded() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)

        let outcome = book.set(
            agent: "Claude Code", instruction: "rerun the tests", origin: .dictated
        )

        guard case .created(let followup) = outcome else {
            return XCTFail("a first follow-up is a creation: \(outcome)")
        }
        XCTAssertEqual(followup.agentDisplayName, "Claude Code")
        XCTAssertEqual(followup.instruction, "rerun the tests")
        XCTAssertEqual(followup.origin, .dictated)
        XCTAssertEqual(book.pending(for: "Claude Code")?.instruction, "rerun the tests")
        XCTAssertEqual(book.count, 1)
        XCTAssertEqual(log.entries.map(\.event), [WearerFollowupEvent.created])
        XCTAssertEqual(log.entries.first?.agent, "Claude Code")
        XCTAssertEqual(log.entries.first?.instruction, "rerun the tests")
    }

    /// One per agent. Two follow-ups on one boundary is a wearer being interrupted twice for
    /// one event, and keeping the older one would mean the sentence they just said lost to
    /// the one they have forgotten.
    func testASecondFollowupForTheSameAgentReplacesTheFirstAndSaysSo() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)

        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        let outcome = book.set(
            agent: "Claude Code", instruction: "just tell me what broke", origin: .dictated
        )

        guard case .replaced(let now, let previous) = outcome else {
            return XCTFail("a second follow-up for one agent replaces: \(outcome)")
        }
        XCTAssertEqual(now.instruction, "just tell me what broke")
        XCTAssertEqual(previous.instruction, "rerun the tests")
        XCTAssertEqual(book.count, 1, "one per agent, always")
        XCTAssertEqual(book.pending(for: "Claude Code")?.instruction, "just tell me what broke")
        // The replacement is one entry carrying the new sentence: the old one is already on
        // the record from its own `created` line.
        XCTAssertEqual(log.events, [WearerFollowupEvent.created, WearerFollowupEvent.replaced])
        XCTAssertEqual(log.entries.last?.instruction, "just tell me what broke")
    }

    func testDifferentAgentsEachGetTheirOwn() async {
        let book = makeBook(log: RecordingFollowupLog())
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        book.set(agent: "Codex", instruction: "tell me what it said", origin: .loop)

        XCTAssertEqual(book.count, 2)
        XCTAssertEqual(book.pending(for: "Codex")?.origin, .loop)
        XCTAssertEqual(book.all().map(\.agentDisplayName), ["Claude Code", "Codex"])
    }

    /// The name goes into the book by voice and comes back out of a notification, so the
    /// wearer's "claude code" and the roster's "Claude Code" have to be one agent. This is
    /// not name *resolution* — that is the roster's job — only the fold that keeps one agent
    /// from being two entries.
    func testAgentNamesFoldOnCaseAndSurroundingSpace() async {
        let book = makeBook(log: RecordingFollowupLog())
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)

        XCTAssertNotNil(book.pending(for: "claude code"))
        XCTAssertNotNil(book.pending(for: "  CLAUDE CODE  "))
        XCTAssertNil(book.pending(for: "Codex"))

        let outcome = book.set(agent: "claude code", instruction: "never mind", origin: .dictated)
        guard case .replaced = outcome else {
            return XCTFail("a folded name is the same agent: \(outcome)")
        }
        XCTAssertEqual(book.count, 1)
    }

    func testAnEmptyNameOrSentenceSetsNothing() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)

        guard case .notSet = book.set(agent: "  ", instruction: "x", origin: .dictated) else {
            return XCTFail("a follow-up with no agent has nothing to wait for")
        }
        guard case .notSet = book.set(agent: "Codex", instruction: " \n ", origin: .dictated)
        else {
            return XCTFail("a follow-up with no sentence has nothing to do")
        }
        XCTAssertEqual(book.count, 0)
        XCTAssertTrue(log.entries.isEmpty, "nothing was promised, so nothing is recorded")
    }

    // MARK: - Cancelling

    func testCancellingAPendingFollowupRemovesItAndRecordsIt() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)

        guard case .cancelled(let followup) = book.cancel(agent: "claude code") else {
            return XCTFail("a pending follow-up must cancel")
        }
        XCTAssertEqual(followup.instruction, "rerun the tests")
        XCTAssertEqual(book.count, 0)
        XCTAssertEqual(log.events, [WearerFollowupEvent.created, WearerFollowupEvent.cancelled])
    }

    func testCancellingWhenNothingIsPendingSaysSoAndRecordsNothing() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)

        XCTAssertEqual(book.cancel(agent: "Codex"), .nothingPending)
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - Firing

    /// Consumption takes it out of the book *before* the announcement, which is what makes a
    /// second boundary arriving mid-grace harmless: there is nothing left to fire.
    func testConsumingTakesItOutOfTheBookAndYieldsAClaimableToken() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)

        let delivery = book.consume(agent: "Claude Code")
        XCTAssertEqual(delivery?.followup.instruction, "rerun the tests")
        XCTAssertEqual(book.count, 0)
        XCTAssertNil(book.pending(for: "Claude Code"))
        XCTAssertNil(book.consume(agent: "Claude Code"), "a one-shot fires once")

        XCTAssertEqual(delivery?.claim()?.instruction, "rerun the tests")
        XCTAssertEqual(delivery?.isAborted, false)
        XCTAssertNil(delivery?.claim(), "a claimed delivery cannot be claimed twice")
        // Consumption is not an ending: the record gets the firing when the review does,
        // through `recordFiring`.
        XCTAssertEqual(log.events, [WearerFollowupEvent.created])
    }

    func testConsumingAnAgentWithNothingPendingYieldsNothing() async {
        let book = makeBook(log: RecordingFollowupLog())
        XCTAssertNil(book.consume(agent: "Claude Code"))
    }

    /// The grace is the announce-then-act reversal the plan requires: TapQ says what it is
    /// about to do, waits, and a "no" in that window retracts it. This is the mechanism —
    /// a cancel reaching a follow-up that is out of the book and not yet delivered.
    func testACancelDuringTheAnnounceGraceAbortsTheUndeliveredAction() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        let delivery = book.consume(agent: "Claude Code")

        guard case .aborted(let followup) = book.cancel(agent: "Claude Code") else {
            return XCTFail("a cancel must reach a delivery inside its grace")
        }
        XCTAssertEqual(followup.instruction, "rerun the tests")
        XCTAssertEqual(delivery?.isAborted, true)
        XCTAssertNil(delivery?.claim(), "the action must never be delivered")
        // Its own word: "cancelled" would tell a wearer asking tomorrow that nothing had
        // happened, and something did — TapQ spoke.
        XCTAssertEqual(log.events, [WearerFollowupEvent.created, WearerFollowupEvent.aborted])
    }

    /// The other side of the race: a cancel arriving after the grace ran out finds nothing,
    /// and cannot un-do an action already on its way.
    func testACancelAfterTheClaimFindsNothing() async {
        let book = makeBook(log: RecordingFollowupLog())
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        let delivery = book.consume(agent: "Claude Code")
        XCTAssertNotNil(delivery?.claim())

        XCTAssertEqual(book.cancel(agent: "Claude Code"), .nothingPending)
        XCTAssertEqual(delivery?.isAborted, false)
    }

    func testFiringIsRecordedWithItsOutcome() async throws {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        let followup = try XCTUnwrap(book.consume(agent: "Claude Code")?.claim())

        book.recordFiring(followup, disposition: .ran(.finished))

        XCTAssertEqual(log.events, [WearerFollowupEvent.created, "fired: finished"])
        XCTAssertEqual(log.entries.last?.agent, "Claude Code")
        XCTAssertEqual(log.entries.last?.instruction, "rerun the tests")
    }

    /// Every disposition has a word, and the three are distinguishable in the file: a wearer
    /// asking tomorrow has to be able to tell "it ran and said nothing" from "it never ran".
    func testEveryDispositionHasItsOwnWordInTheRecord() async {
        XCTAssertEqual(WearerFollowupDisposition.ran(.finished).recordedEvent, "fired: finished")
        XCTAssertEqual(WearerFollowupDisposition.ran(.refused).recordedEvent, "fired: refused")
        XCTAssertEqual(WearerFollowupDisposition.ran(.couldNotFinish).recordedEvent,
                       "fired: could not finish")
        XCTAssertEqual(WearerFollowupDisposition.ran(.canceled).recordedEvent, "fired: canceled")
        XCTAssertEqual(WearerFollowupDisposition.broke(reason: "timeout").recordedEvent,
                       WearerFollowupEvent.firedBroken)
        XCTAssertEqual(WearerFollowupDisposition.busy.recordedEvent,
                       WearerFollowupEvent.notRunBusy)
    }

    // MARK: - The session ending

    /// In memory only, deliberately, and this is the line that makes the bound honest: the
    /// follow-up does not survive, and the *record* of it does.
    func testTheSessionEndingExpiresEverythingAndRecordsIt() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)
        book.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)
        book.set(agent: "Codex", instruction: "tell me what it said", origin: .loop)
        let inFlight = book.consume(agent: "Codex")

        book.expireAll(reason: "runtime stopped")

        XCTAssertEqual(book.count, 0)
        XCTAssertEqual(inFlight?.isAborted, true,
                       "nothing lands on an agent after the thing that promised it is gone")
        XCTAssertNil(inFlight?.claim())
        XCTAssertEqual(log.events, [
            WearerFollowupEvent.created,
            WearerFollowupEvent.created,
            WearerFollowupEvent.expired,
            WearerFollowupEvent.expired,
        ])
    }

    func testExpiringAnEmptyBookRecordsNothing() async {
        let log = RecordingFollowupLog()
        makeBook(log: log).expireAll()
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - Diagnostics

    /// Agent display names are allowed in the log — the roster already calls them that, and
    /// `InteractionController` has logged them since rung E. The wearer's sentence is not.
    func testTheLogCarriesTheAgentAndTheLengthButNeverTheSentence() async {
        let sink = TaskDiagnosticSink()
        let book = makeBook(log: RecordingFollowupLog(), sink: sink)
        let secret = "push the release key to the staging box when it's done"

        book.set(agent: "Claude Code", instruction: secret, origin: .dictated)
        book.cancel(agent: "Claude Code")

        XCTAssertEqual(sink.first("set")?.fields["agent"], "Claude Code")
        XCTAssertEqual(sink.first("set")?.fields["length"], "\(secret.count)")
        for event in sink.events {
            for value in event.fields.values {
                XCTAssertFalse(value.contains("staging box"),
                               "\(event.name) put the wearer's sentence in the log")
            }
        }
    }

    // MARK: - Holding

    /// A finished boundary that is the turn ending rather than the work — the agent launched
    /// something in the background — leaves the follow-up armed and says so in the record.
    func testAHeldBoundaryLeavesTheFollowupPendingAndRecordsWhy() async {
        let log = RecordingFollowupLog()
        let sink = TaskDiagnosticSink()
        let book = makeBook(log: log, sink: sink)
        book.set(agent: "Claude Code", instruction: "tell me the test result", origin: .dictated)

        book.recordHeld(agent: "claude code")

        XCTAssertEqual(book.pending(for: "Claude Code")?.instruction, "tell me the test result")
        XCTAssertEqual(log.events, [WearerFollowupEvent.created, WearerFollowupEvent.heldWorkRunning])
        XCTAssertEqual(log.entries.last?.instruction, "tell me the test result")
        XCTAssertEqual(sink.first("held")?.fields["reason"], "work_running")

        // Held is not consumed: the next boundary fires it as usual.
        XCTAssertNotNil(book.consume(agent: "Claude Code"))
        XCTAssertNil(book.pending(for: "Claude Code"))
    }

    func testAHoldWithNothingPendingRecordsNothing() async {
        let log = RecordingFollowupLog()
        let book = makeBook(log: log)

        book.recordHeld(agent: "Claude Code")

        XCTAssertTrue(log.entries.isEmpty)
    }
}
