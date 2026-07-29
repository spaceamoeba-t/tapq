import XCTest
@testable import TapQContextBaseline

/// The deadline is the property that makes a stage-2 reasoner safe to run while the user
/// is mid-gesture, and it is tested here — outside the `canImport(FoundationModels)`
/// guard — because CI never compiles the on-device adapter at all.
final class ReasonerDeadlineTests: XCTestCase {
    /// Work that ignores cancellation completely, standing in for a backend that is slow
    /// to notice it lost the race. The detached task does not inherit cancellation and a
    /// continuation does not observe it, so nothing about this finishes early.
    private static func stubbornWork(seconds: Double) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            Task.detached {
                try? await Task.sleep(for: .seconds(seconds))
                continuation.resume(returning: "late")
            }
        }
    }

    func testWorkThatFinishesInTimeIsReturned() async throws {
        let result = await ReasonerDeadline.run(seconds: 5.0) { "on time" }
        guard case .completed(let value) = result else {
            return XCTFail("expected completion, got \(result)")
        }
        XCTAssertEqual(value, "on time")
    }

    /// The regression this whole type exists for. A task group would report `timedOut`
    /// on schedule and then sit on the caller until the stubborn work finished; the
    /// assertion that matters is the elapsed time, not the returned case.
    func testTimeoutReturnsWithoutWaitingForStubbornWork() async {
        let started = ContinuousClock.now
        let result = await ReasonerDeadline.run(seconds: 0.05) {
            await Self.stubbornWork(seconds: 2.0)
        }
        let elapsed = started.duration(to: .now)

        guard case .timedOut = result else {
            return XCTFail("expected a timeout, got \(result)")
        }
        XCTAssertLessThan(
            elapsed,
            .seconds(1.0),
            "the deadline must not wait for work that ignores cancellation"
        )
    }

    /// `ReasonerConfig` documents a zero budget as an immediate timeout, which means the
    /// budget can fire before the continuation has even been handed over.
    func testZeroBudgetTimesOutImmediately() async {
        for _ in 0..<20 {
            let result = await ReasonerDeadline.run(seconds: 0.0) {
                await Self.stubbornWork(seconds: 2.0)
            }
            guard case .timedOut = result else {
                return XCTFail("expected a timeout, got \(result)")
            }
        }
    }

    func testCallerCancellationIsReportedAndDoesNotHang() async {
        let started = ContinuousClock.now
        let task = Task {
            await ReasonerDeadline.run(seconds: 30.0) {
                await Self.stubbornWork(seconds: 2.0)
            }
        }
        // Let the race arm itself before cancelling, so this exercises the cancellation
        // handler rather than the already-cancelled fast path.
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.value
        let elapsed = started.duration(to: .now)

        guard case .cancelled = result else {
            return XCTFail("expected cancellation, got \(result)")
        }
        XCTAssertLessThan(elapsed, .seconds(1.0))
    }

    /// Only one outcome may ever be delivered: resuming a continuation twice traps, so a
    /// budget that expires at the same moment the work finishes has to pick a winner.
    func testConcurrentOutcomesResolveToExactlyOneResult() async {
        for _ in 0..<50 {
            let result = await ReasonerDeadline.run(seconds: 0.001) { "raced" }
            switch result {
            case .completed(let value): XCTAssertEqual(value, "raced")
            case .timedOut: break
            case .cancelled: XCTFail("nothing cancelled this call")
            }
        }
    }
}
