import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The ways a held turn boundary can end, the renewal that is not one of them, and the
/// counting that drives the listening loop. Every test drives a real `wait` through a real
/// continuation — the only thing substituted is the timer, because neither a poll bound nor
/// a lease grace is a thing a test can sit through.
@MainActor
final class InstructionWaitRegistryTests: XCTestCase {
    /// A registry whose timers never fire inside a test: the sleep is a real, cancellable
    /// suspension, and the registry cancels it the moment the wait ends. Tests that are
    /// about anything other than a timer use this one.
    private func patientRegistry() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })
    }

    /// A registry whose budget expires as soon as it is reached. It stands in for ten
    /// minutes of silence, which is not a thing a test can sit through.
    private func impatientRegistry() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { _ in })
    }

    /// A registry in which exactly one duration expires at once — the poll bound — and
    /// every other timer, the lease grace included, is patient.
    ///
    /// That is the arrangement every renewal test needs: a poll has to come back so the
    /// shim can re-park, and the lease has to survive until the test itself ends it. A test
    /// that wants a poll to stay *parked* asks for `parkedPoll` seconds instead.
    ///
    /// Every sleep here is bounded — an unbounded one would outlive the suite.
    private func renewingRegistry() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { seconds in
            guard seconds != VoiceSessionBudget.brokerPoll else { return }
            try? await Task.sleep(for: .seconds(60))
        })
    }

    /// The poll bound, which `renewingRegistry` expires the instant it is reached.
    private let pollBound = VoiceSessionBudget.brokerPoll
    /// A bound that registry is patient about, for tests that need a poll still parked.
    private let parkedPoll: TimeInterval = 999

    /// Lets every pending task reach its next suspension, so a `wait` started in a task has
    /// certainly registered before the test acts on it.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    /// The delivery path: an instruction arrives for the held session and the boundary is
    /// let go immediately.
    func testAQueuedInstructionReleasesTheBoundary() async {
        let waits = patientRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: 600) }
        await settle()

        XCTAssertTrue(waits.isWaiting)
        waits.noteInstructionQueued(session: "s1")

        let outcome = await held.value
        XCTAssertEqual(outcome, .instructionQueued)
        XCTAssertFalse(waits.isWaiting, "a released boundary is no longer held")
    }

    /// An instruction for a session nobody is holding must not wake the one that is: two
    /// agents can be in voice mode at once, and each boundary carries its own session's
    /// sentences or none at all.
    func testAnInstructionForAnotherSessionLeavesTheBoundaryHeld() async {
        let waits = patientRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: 600) }
        await settle()

        waits.noteInstructionQueued(session: "s2")
        await settle()
        XCTAssertTrue(waits.isWaiting)

        waits.noteInstructionQueued(session: "s1")
        let outcome = await held.value
        XCTAssertEqual(outcome, .instructionQueued)
    }

    /// The budget: one long-poll round, and then the session idles normally. This is a clean
    /// exit from the mode, which is why it is indistinguishable from a release.
    func testAnExpiredBudgetEndsTheWait() async {
        let waits = impatientRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: 600) }

        let outcome = await held.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(waits.isWaiting)
    }

    /// "End voice session": the wearer is done, and the boundary goes with nothing on it.
    func testReleasingASessionEndsItsWaitWithNoInstruction() async {
        let waits = patientRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: 600) }
        await settle()

        waits.release(session: "s1")

        let outcome = await held.value
        XCTAssertEqual(outcome, .released)
    }

    /// Shutdown. A runtime that exits without doing this leaves a hook parked against a
    /// socket nobody is listening on, which is the one failure this feature must not have.
    func testReleasingEverythingAnswersEveryHeldBoundary() async {
        let waits = patientRegistry()
        let first = Task { await waits.wait(session: "s1", timeout: 600) }
        let second = Task { await waits.wait(session: "s2", timeout: 600) }
        await settle()
        XCTAssertEqual(waits.waitingCount, 2)

        waits.releaseAll()

        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.released, .released])
        XCTAssertFalse(waits.isWaiting)
        XCTAssertTrue(waits.waitingSessions.isEmpty)
    }

    /// The listening loop's trigger. It has to fire on the way up *and* on the way down, or
    /// TapQ would either listen with nobody waiting or wait with nobody listening.
    func testTheWaitingCountIsReportedInBothDirections() async {
        let waits = patientRegistry()
        var counts: [Int] = []
        waits.onWaitingChanged = { counts.append($0) }

        let held = Task { await waits.wait(session: "s1", timeout: 600) }
        await settle()
        waits.noteInstructionQueued(session: "s1")
        _ = await held.value

        XCTAssertEqual(counts, [1, 0])
    }

    func testTheHeldSessionsAreReadableWhileTheyAreHeld() async {
        let waits = patientRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: 600) }
        await settle()

        XCTAssertEqual(waits.waitingSessions, ["s1"])

        waits.releaseAll()
        _ = await held.value
    }

    /// Nothing held, nothing to release: the calls are no-ops rather than errors, because
    /// the shutdown path runs whether or not a session was ever in voice mode.
    func testReleasingWithNothingHeldIsHarmless() async {
        let waits = patientRegistry()
        waits.releaseAll()
        waits.release(session: "s1")
        waits.noteInstructionQueued(session: "s1")
        XCTAssertFalse(waits.isWaiting)
    }

    // MARK: - Renewable leases

    /// Drives one lease through `count` expired polls, exactly as the shim does: park,
    /// be told to renew, park again. Returns every outcome it was given.
    private func poll(
        _ waits: InstructionWaitRegistry,
        session: String,
        lease: String,
        times count: Int
    ) async -> [InstructionWaitOutcome] {
        var outcomes: [InstructionWaitOutcome] = []
        for _ in 0..<count {
            outcomes.append(
                await waits.wait(session: session, timeout: pollBound, lease: lease)
            )
        }
        return outcomes
    }

    /// The claim the whole decision rests on: a leased boundary is not ended by time. Ten
    /// polls expire, ten renewals come back, and the boundary is held throughout.
    func testALeasedBoundarySurvivesEveryPollExpiryAndIsStillHeld() async {
        let waits = renewingRegistry()
        let outcomes = await poll(waits, session: "s1", lease: "L", times: 10)

        XCTAssertEqual(outcomes, Array(repeating: .renew, count: 10))
        XCTAssertTrue(waits.isWaiting, "renewing is not ending")
        XCTAssertEqual(waits.waitingCount, 1, "ten polls are one held boundary")
        XCTAssertEqual(waits.waitingSessions, ["s1"])
        XCTAssertTrue(waits.isHeld(lease: "L"))
    }

    /// The same boundary through the same renewals, and the microphone never hears about
    /// any of them. A host that was told the count changed once a minute would close and
    /// reopen its listening window for the life of the session.
    func testRenewalsNeverReportAChangeToTheHost() async {
        let waits = renewingRegistry()
        var counts: [Int] = []
        waits.onWaitingChanged = { counts.append($0) }

        _ = await poll(waits, session: "s1", lease: "L", times: 5)
        XCTAssertEqual(counts, [1], "the boundary arrived once and never left")

        waits.releaseAll()
        XCTAssertEqual(counts, [1, 0])
    }

    /// A one-shot wait — a shim from before leases — is untouched by any of this. Its
    /// budget still expires, and expiring it still ends the wait.
    func testAWaitWithNoLeaseKeepsTheOneShotBudget() async {
        let waits = impatientRegistry()
        let outcome = await waits.wait(
            session: "s1", timeout: VoiceSessionBudget.brokerWait
        )
        XCTAssertEqual(outcome, .timedOut, "no lease, no renewal")
        XCTAssertFalse(waits.isWaiting)
    }

    /// The delivery path through a lease: the instruction arrives while a poll is parked,
    /// and the boundary ends rather than renewing.
    func testAQueuedInstructionEndsALeasedBoundary() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L", times: 2)

        let held = Task { await waits.wait(session: "s1", timeout: parkedPoll, lease: "L") }
        await settle()
        waits.noteInstructionQueued(session: "s1")

        let outcome = await held.value
        XCTAssertEqual(outcome, .instructionQueued)
        XCTAssertFalse(waits.isWaiting, "a delivered boundary is over")
        XCTAssertFalse(waits.isHeld(lease: "L"))
    }

    /// An instruction that lands between two polls wakes nothing, and must not need to:
    /// the boundary stays held, and the mailbox still has the sentence for the poll that
    /// is a microsecond away.
    func testAnInstructionBetweenPollsLeavesTheBoundaryHeld() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L", times: 1)

        waits.noteInstructionQueued(session: "s1")

        XCTAssertTrue(waits.isWaiting, "nothing was parked, so nothing was ended")
        XCTAssertTrue(waits.isHeld(lease: "L"))
    }

    // MARK: - Ending a leased boundary

    /// The wearer ended the session while a poll was parked. The parked poll is answered,
    /// and — the part a lease makes necessary — the *next* poll is answered too, rather
    /// than quietly re-establishing the boundary that was just let go.
    func testAReleasedLeaseStaysReleasedForThePollAlreadyOnItsWay() async {
        let waits = renewingRegistry()
        let held = Task { await waits.wait(session: "s1", timeout: parkedPoll, lease: "L") }
        await settle()

        waits.release(session: "s1")
        let released = await held.value
        XCTAssertEqual(released, .released)
        XCTAssertFalse(waits.isWaiting)

        let next = await waits.wait(session: "s1", timeout: parkedPoll, lease: "L")
        XCTAssertEqual(next, .released, "a re-poll must not resurrect an ended session")
        XCTAssertFalse(waits.isWaiting)
    }

    /// The release that landed in the gap between two polls, which is the case a lease
    /// exists to get wrong. Nothing is parked to answer, and the next poll still has to be
    /// told the session is over.
    func testALeaseReleasedBetweenPollsIsNotResurrected() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L", times: 1)
        XCTAssertTrue(waits.isWaiting)

        waits.releaseAll()
        XCTAssertFalse(waits.isWaiting)

        let rePoll = await waits.wait(session: "s1", timeout: parkedPoll, lease: "L")
        XCTAssertEqual(rePoll, .released)
        XCTAssertFalse(waits.isWaiting)
    }

    /// The voice-break latch and shutdown are the same call, so this is both of them: a
    /// boundary that is held indefinitely still has to go when the thing it was waiting
    /// for cannot happen any more.
    func testReleasingEverythingEndsLeasedBoundariesToo() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L1", times: 1)
        _ = await poll(waits, session: "s2", lease: "L2", times: 1)
        XCTAssertEqual(waits.waitingCount, 2)

        waits.releaseAll()

        XCTAssertFalse(waits.isWaiting)
        XCTAssertTrue(waits.waitingSessions.isEmpty)
        XCTAssertFalse(waits.isHeld(lease: "L1"))
        XCTAssertFalse(waits.isHeld(lease: "L2"))
    }

    /// Releasing one session leaves the other agent's boundary exactly where it was.
    func testReleasingOneSessionLeavesAnotherLeaseHeld() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L1", times: 1)
        _ = await poll(waits, session: "s2", lease: "L2", times: 1)

        waits.release(session: "s1")

        XCTAssertEqual(waits.waitingCount, 1)
        XCTAssertEqual(waits.waitingSessions, ["s2"])
        XCTAssertTrue(waits.isHeld(lease: "L2"))
    }

    /// The poll that never parks: an instruction was already queued when it arrived, so the
    /// host answered it on the spot. Nothing will end that lease later, so the host ends it
    /// here — otherwise TapQ would go on listening at a boundary it had already answered.
    func testALeaseAnsweredWithoutParkingIsEndedByTheHost() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L", times: 1)
        XCTAssertTrue(waits.isWaiting)

        waits.release(lease: "L")

        XCTAssertFalse(waits.isWaiting)
        XCTAssertFalse(waits.isHeld(lease: "L"))
        let rePoll = await waits.wait(session: "s1", timeout: parkedPoll, lease: "L")
        XCTAssertEqual(rePoll, .released, "the shim is not coming back for a delivered one")
    }

    /// And it ends only the one named. A second agent's boundary is not collateral.
    func testEndingOneLeaseLeavesAnother() async {
        let waits = renewingRegistry()
        _ = await poll(waits, session: "s1", lease: "L1", times: 1)
        _ = await poll(waits, session: "s2", lease: "L2", times: 1)

        waits.release(lease: "L1")

        XCTAssertEqual(waits.waitingCount, 1)
        XCTAssertTrue(waits.isHeld(lease: "L2"))
    }

    /// The hook was killed — Claude Code's own ceiling, or a closed terminal. Nobody
    /// disconnects a Unix socket loudly enough for the broker to notice mid-handler, so a
    /// lease that stops being polled is what has to end the hold. This is the leak the
    /// feature would otherwise have.
    func testALeaseThatStopsBeingPolledExpiresOnItsOwn() async {
        // Impatient about everything: the poll comes back at once, and the grace that
        // follows it runs out at once too — which is a hook that never polled again.
        let waits = impatientRegistry()
        var counts: [Int] = []
        waits.onWaitingChanged = { counts.append($0) }

        let outcome = await waits.wait(session: "s1", timeout: pollBound, lease: "L")
        XCTAssertEqual(outcome, .renew, "the poll itself ended in the ordinary way")
        await settle()

        XCTAssertFalse(waits.isWaiting, "an unpolled lease must not be held forever")
        XCTAssertFalse(waits.isHeld(lease: "L"))
        XCTAssertEqual(counts, [1, 0])
    }

    /// And a lease that expired is remembered as gone, so a poll that was somehow still in
    /// flight cannot bring back a boundary nothing is listening behind.
    func testAnExpiredLeaseIsNotResurrectedEither() async {
        let waits = impatientRegistry()
        _ = await waits.wait(session: "s1", timeout: pollBound, lease: "L")
        await settle()
        XCTAssertFalse(waits.isWaiting)

        let rePoll = await waits.wait(session: "s1", timeout: parkedPoll, lease: "L")
        XCTAssertEqual(rePoll, .released)
        XCTAssertFalse(waits.isWaiting)
    }
}
