import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The three ways a held turn boundary can end, and the counting that drives the listening
/// loop. Every test drives a real `wait` through a real continuation — the only thing
/// substituted is the budget's timer, because a ten-minute default is not a thing a test
/// can sit through.
@MainActor
final class InstructionWaitRegistryTests: XCTestCase {
    /// A registry whose budget never expires inside a test: the sleep is a real,
    /// cancellable suspension, and the registry cancels it the moment the wait ends. Tests
    /// that are about anything other than the budget use this one.
    private func patientRegistry() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })
    }

    /// A registry whose budget expires as soon as it is reached. It stands in for ten
    /// minutes of silence, which is not a thing a test can sit through.
    private func impatientRegistry() -> InstructionWaitRegistry {
        InstructionWaitRegistry(sleep: { _ in })
    }

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
}
