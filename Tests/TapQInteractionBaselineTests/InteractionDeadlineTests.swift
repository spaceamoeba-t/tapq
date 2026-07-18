import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Deadline behavior under a virtual clock: the controllers read time through their
/// injectable `now` provider, so these tests advance time explicitly. (Real 0.1–0.5s
/// deadlines flaked whenever CI preemption outran them between deadline creation and
/// the controller's entry guard.)
@MainActor
final class InteractionDeadlineTests: XCTestCase {
    /// Test stand-in for ContinuousClock: time moves only when an arbiter says so.
    @MainActor
    final class VirtualClock {
        private(set) var now: ContinuousClock.Instant = .now
        func advance(by seconds: TimeInterval) { now = now.advanced(by: .seconds(seconds)) }
    }

    @MainActor
    final class FakeSpeech: SpeechPresenting {
        var spoken: [(text: String, priority: SpeechPriority)] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append((text, priority))
            onFinish?()
        }
        func stopAll() {}
    }

    /// Always answers `repeat` — models a user (or noise) that never settles — and
    /// advances the virtual clock per listen, standing in for elapsed TTS + listen time.
    @MainActor
    final class RepeatForeverArbiter: InputArbitrating {
        private(set) var timeouts: [TimeInterval] = []
        private let clock: VirtualClock
        private let secondsPerListen: TimeInterval
        init(clock: VirtualClock, advancing secondsPerListen: TimeInterval) {
            self.clock = clock
            self.secondsPerListen = secondsPerListen
        }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            timeouts.append(timeout)
            clock.advance(by: secondsPerListen)
            return .repeatRequest
        }
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    func testRepeatLoopStopsAtDeadlineAndSpeaksDeferral() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = RepeatForeverArbiter(clock: clock, advancing: 60)
        let controller = InteractionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(InteractionBudget.total)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(decision, .ask)
        XCTAssertEqual(arbiter.timeouts.count, 2,
                       "105s budget at 60s per repeat-listen is exactly two windows")
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("screen") },
                      "deadline expiry must be announced")
    }

    func testListenTimeoutIsCappedByRemainingBudget() async {
        let clock = VirtualClock()
        let arbiter = RepeatForeverArbiter(clock: clock, advancing: 30)
        let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)
        controller.now = { clock.now }
        controller.timeout = 100
        let deadline = clock.now + .seconds(50)

        _ = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(arbiter.timeouts.count, 2)
        XCTAssertEqual(arbiter.timeouts[0], 50, accuracy: 1e-9,
                       "first window is capped to the full remaining budget, not `timeout`")
        XCTAssertEqual(arbiter.timeouts[1], 20, accuracy: 1e-9,
                       "second window shrinks by what the first consumed")
    }

    func testAlreadyExpiredDeadlineReturnsAskSilently() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: RepeatForeverArbiter(clock: clock, advancing: 60))
        controller.now = { clock.now }
        let deadline = clock.now - .seconds(1)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(decision, .ask)
        XCTAssertTrue(speech.spoken.isEmpty,
                      "a request that expired in the queue must not speak at all")
    }

    func testEntryWithInsufficientBudgetReturnsAskSilently() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: RepeatForeverArbiter(clock: clock, advancing: 60))
        controller.now = { clock.now }
        // Default entryMargin (12s) applies; 5s remaining is not enough to start.
        let deadline = clock.now + .seconds(5)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(decision, .ask)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    @MainActor
    final class NavigateForeverArbiter: SelectionArbitrating {
        private(set) var timeouts: [TimeInterval] = []
        private let clock: VirtualClock
        private let secondsPerListen: TimeInterval
        init(clock: VirtualClock, advancing secondsPerListen: TimeInterval) {
            self.clock = clock
            self.secondsPerListen = secondsPerListen
        }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            timeouts.append(timeout)
            clock.advance(by: secondsPerListen)
            return .repeatRequest   // re-speaks the prompt and loops, like approval's repeat
        }
    }

    private func selectionRequest() -> SelectionRequest {
        SelectionRequest(id: "1", sessionID: "s1", question: "Which format?",
                         options: [.init(label: "PDF", description: ""),
                                   .init(label: "PNG", description: "")],
                         multiSelect: false)
    }

    func testSelectionLoopStopsAtDeadlineAndSpeaksDeferral() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = NavigateForeverArbiter(clock: clock, advancing: 60)
        let controller = SelectionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(InteractionBudget.total)

        let result = await controller.resolve(selectionRequest(), deadline: deadline)

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.choices.isEmpty)
        XCTAssertEqual(arbiter.timeouts.count, 2)
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("screen") })
    }

    func testExpiredSelectionDeadlineReturnsNoSelectionSilently() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech, arbiter: NavigateForeverArbiter(clock: clock, advancing: 60))
        controller.now = { clock.now }
        let deadline = clock.now - .seconds(1)

        let result = await controller.resolve(selectionRequest(), deadline: deadline)

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func testSelectionListenTimeoutIsCappedByRemainingBudget() async {
        let clock = VirtualClock()
        let arbiter = NavigateForeverArbiter(clock: clock, advancing: 30)
        let controller = SelectionController(speech: FakeSpeech(), arbiter: arbiter)
        controller.now = { clock.now }
        controller.timeout = 100
        let deadline = clock.now + .seconds(50)

        _ = await controller.resolve(selectionRequest(), deadline: deadline)

        XCTAssertEqual(arbiter.timeouts.count, 2)
        XCTAssertEqual(arbiter.timeouts[0], 50, accuracy: 1e-9)
        XCTAssertEqual(arbiter.timeouts[1], 20, accuracy: 1e-9)
    }

    func testSelectionEntryWithInsufficientBudgetReturnsNoSelectionSilently() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech, arbiter: NavigateForeverArbiter(clock: clock, advancing: 60))
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(5)

        let result = await controller.resolve(selectionRequest(), deadline: deadline)

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}
