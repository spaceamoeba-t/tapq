import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The one place the follow-up's wording lives, and the loop's own door to the book.
///
/// A follow-up can be set three ways — the wearer says so, a running task registers a
/// continuation, or a composition sets one directly — and all three make the same promise, so
/// what the wearer hears has to be the same sentence. That is what this type exists for and
/// what this suite pins.
///
/// Every test method is `async` for the Linux test-discovery shim; see ``WearerTaskLoopTests``.
@MainActor
final class WearerFollowupSchedulerTests: XCTestCase {
    /// `log` is not defaulted: a default argument is evaluated in a `nonisolated` context,
    /// and every `@MainActor` type in this file would be unreachable from one.
    private func makeScheduler(
        log: RecordingFollowupLog,
        roster: [String] = ["Claude Code", "Codex"]
    ) -> (WearerFollowupScheduler, WearerFollowupBook) {
        let book = WearerFollowupBook(record: log.recorder())
        let scheduler = WearerFollowupScheduler(book: book, resolveAgent: { name in
            roster.first { $0.lowercased() == name.lowercased() }
        })
        return (scheduler, book)
    }

    // MARK: - The wearer's sentence

    /// The read-back, in the shape the plan's announce-on-create rule needs: the agent first,
    /// because a follow-up armed on the wrong one waits forever and fires never; then the
    /// sentence, so a mis-capture is recoverable; then "noted", so the wearer knows it is
    /// held rather than happening now.
    func testCreationIsAnnouncedWithTheAgentTheSentenceAndNoted() async {
        let (scheduler, _) = makeScheduler(log: RecordingFollowupLog())

        let acknowledgment = scheduler.set(
            agent: "claude code", instruction: "rerun the tests", origin: .dictated
        )

        XCTAssertEqual(acknowledgment,
                       .noted(spoken: "After Claude Code finishes: rerun the tests — noted."))
    }

    /// A replacement leads with what it displaced. A wearer who hears the familiar
    /// acknowledgment first has stopped listening by the time a trailing qualification
    /// arrives, and believing you have two follow-ups when you have one is exactly the
    /// mis-modelling the read-back rule exists to prevent.
    func testReplacementSaysSoBeforeItSaysAnythingElse() async {
        let (scheduler, _) = makeScheduler(log: RecordingFollowupLog())
        scheduler.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)

        let acknowledgment = scheduler.set(
            agent: "Claude Code", instruction: "just tell me what broke", origin: .dictated
        )

        XCTAssertEqual(acknowledgment, .replaced(
            spoken: "Instead of the last one — after Claude Code finishes: just tell me what "
                + "broke — noted."
        ))
        XCTAssertTrue(acknowledgment.spoken.hasPrefix("Instead of the last one"),
                      acknowledgment.spoken)
    }

    func testCancellingSaysWhatWasDroppedAndNamesTheAgentWhenThereWasNothing() async {
        let (scheduler, _) = makeScheduler(log: RecordingFollowupLog())
        scheduler.set(agent: "Claude Code", instruction: "rerun the tests", origin: .dictated)

        XCTAssertEqual(scheduler.cancel(agent: "Claude Code"),
                       .dropped(spoken: "Dropped the follow-up on Claude Code."))
        XCTAssertEqual(scheduler.cancel(agent: "Claude Code"),
                       .nothingPending(spoken: "There's no follow-up on Claude Code."))
    }

    /// The wearer's spoken name is read back in the refusal, so they can hear which name TapQ
    /// heard — the same reason every other read-back on this path exists.
    func testANameNothingAnswersToIsRefusedOutLoudAndNothingIsSet() async {
        let log = RecordingFollowupLog()
        let (scheduler, book) = makeScheduler(log: log)

        let acknowledgment = scheduler.set(
            agent: "Cursor", instruction: "rerun the tests", origin: .dictated
        )

        XCTAssertEqual(acknowledgment, .refused(
            spoken: "I don't know an agent called Cursor — nothing is set."
        ))
        XCTAssertEqual(book.count, 0)
        XCTAssertTrue(log.entries.isEmpty, "nothing was promised, so nothing is recorded")
    }

    /// Fail-closed on set, open on cancel, and the asymmetry is the point: refusing to arm a
    /// promise on an unknown name prevents one TapQ cannot keep, while refusing to *cancel*
    /// one would leave a follow-up armed because the agent it watches has since gone away.
    func testACancelGoesThroughOnANameTheRosterNoLongerKnows() async {
        let log = RecordingFollowupLog()
        let book = WearerFollowupBook(record: log.recorder())
        book.set(agent: "Cursor", instruction: "rerun the tests", origin: .dictated)
        let scheduler = WearerFollowupScheduler(book: book, resolveAgent: { _ in nil })

        XCTAssertEqual(scheduler.cancel(agent: "Cursor"),
                       .dropped(spoken: "Dropped the follow-up on Cursor."))
        XCTAssertEqual(book.count, 0)
    }

    func testAnEmptySentenceIsTheOrdinarySayItAgain() async {
        let (scheduler, book) = makeScheduler(log: RecordingFollowupLog())
        XCTAssertEqual(scheduler.set(agent: "Codex", instruction: "  ", origin: .dictated),
                       .refused(spoken: "I didn't catch that — say it again."))
        XCTAssertEqual(book.count, 0)
    }

    /// The read-back is shortened the way every other spoken read-back on this path is, and
    /// by the same function — two read-backs at two lengths would be two behaviors.
    func testALongSentenceIsReadBackAtTheOneSharedSpokenLength() async {
        let (scheduler, _) = makeScheduler(log: RecordingFollowupLog())
        let long = String(repeating: "rerun the failing suite and report back, ", count: 12)

        let acknowledgment = scheduler.set(
            agent: "Codex", instruction: long, origin: .dictated
        )

        XCTAssertTrue(acknowledgment.spoken.contains(WearerTaskLoop.spokenGoal(long)),
                      acknowledgment.spoken)
        XCTAssertLessThan(acknowledgment.spoken.count, long.count)
    }

    // MARK: - The loop's own continuation

    /// The M4 kernel: "tell Claude to run the tests, and when it's done, check the result" is
    /// one wearer sentence and two acts, and until this surface existed the loop could do the
    /// first and only hope about the second. What it registers is tagged `.loop`, because the
    /// origin has to say whose sentence it was end to end.
    func testARunningTaskRegistersAContinuationAndItIsAnnouncedAsTheLoops() async throws {
        let log = RecordingFollowupLog()
        let (scheduler, book) = makeScheduler(log: log)
        let surface = scheduler.taskSurface()

        let output = surface("Claude Code", "tell me what failed")

        XCTAssertEqual(output.announce,
                       "After Claude Code finishes: tell me what failed — noted.")
        // The model's copy is not the wearer's sentence: it needs to know the follow-up is
        // held and that a second would replace it, which is not what the wearer needs.
        XCTAssertNotEqual(output.text, output.announce)
        XCTAssertTrue(output.text.contains("once"), output.text)
        let followup = try XCTUnwrap(book.pending(for: "Claude Code"))
        XCTAssertEqual(followup.origin, .loop)
        XCTAssertEqual(log.events, [WearerFollowupEvent.created])
    }

    func testTheLoopsSurfaceAnnouncesAReplacementAsOne() async {
        let (scheduler, _) = makeScheduler(log: RecordingFollowupLog())
        let surface = scheduler.taskSurface()
        _ = surface("Claude Code", "tell me what failed")

        let output = surface("Claude Code", "just rerun it")

        XCTAssertEqual(output.announce, "Instead of the last one — after Claude Code "
            + "finishes: just rerun it — noted.")
        XCTAssertTrue(output.text.contains("replacing"), output.text)
    }

    /// A name nothing answers to is refused out loud here too, and the model is told plainly
    /// so it stops guessing rather than trying the name again with a different spelling.
    func testTheLoopsSurfaceRefusesAnUnknownAgentOutLoudAndTellsTheModelWhy() async {
        let (scheduler, book) = makeScheduler(log: RecordingFollowupLog())

        let output = scheduler.taskSurface()("Cursor", "tell me what failed")

        XCTAssertEqual(output.announce,
                       "I don't know an agent called Cursor — nothing is set.")
        XCTAssertTrue(output.text.contains("get_status"), output.text)
        XCTAssertEqual(book.count, 0)
    }

    /// A composition with no book at all still answers honestly rather than pretending, which
    /// is the whole reason the surface is defaulted rather than optional.
    func testACompositionWithNoBookSaysSoRatherThanPretending() async {
        let surfaces = RecordingTaskSurfaces().make()
        XCTAssertEqual(WearerTaskSurfaces(
            searchMemory: surfaces.searchMemory,
            readTranscript: surfaces.readTranscript,
            status: surfaces.status,
            queueInstruction: surfaces.queueInstruction,
            speak: surfaces.speak,
            askWearer: surfaces.askWearer,
            recordTask: surfaces.recordTask
        ).setFollowup("Codex", "rerun it").text, WearerTaskSurfaces.noFollowupBookText)
    }

    // MARK: - The voice seam

    /// The realtime tool's arm tags itself `.dictated`: it is reached only when the wearer
    /// spoke. Its sentence is the same one the loop's surface produces, because the promise
    /// is the same promise.
    func testTheVoiceSeamTagsTheWearerAndSaysTheSameSentence() async throws {
        let (scheduler, book) = makeScheduler(log: RecordingFollowupLog())

        let acknowledgment = await scheduler.setFollowup(
            agent: "Codex", instruction: "tell me what it said"
        )

        XCTAssertEqual(acknowledgment,
                       .noted(spoken: "After Codex finishes: tell me what it said — noted."))
        XCTAssertEqual(try XCTUnwrap(book.pending(for: "Codex")).origin, .dictated)

        let dropped = await scheduler.cancelFollowup(agent: "Codex")
        XCTAssertEqual(dropped, .dropped(spoken: "Dropped the follow-up on Codex."))
    }

    // MARK: - The held boundary

    /// Spoken right after "Claude Code finished." when that turn left background work
    /// running: it names the reason and says the promise is intact, because silence there
    /// reads as the follow-up being lost.
    func testTheHeldSentenceNamesTheAgentAndKeepsThePromise() async {
        XCTAssertEqual(
            WearerFollowupScheduler.heldNotice(agent: "Claude Code"),
            "Claude Code left work running in the background — your follow-up is still waiting."
        )
    }
}
