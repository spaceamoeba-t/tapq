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
        XCTAssertEqual(arbiter.timeouts.count, 4,
                       """
                       245s budget at 60s per repeat-listen leaves 5s after the fourth. \
                       A fifth listen used to open there and re-speak the whole prompt \
                       into it; the prompt alone outlasts 5s, so the repeat is refused \
                       instead of asked into nothing.
                       """)
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

    /// F5(1). A request that arrives under the floor is refused *out loud*.
    ///
    /// It used to be refused in silence, and silence is the one answer a wearer cannot read:
    /// with no screen in front of them, a question that went to the screen and a question
    /// that was never asked sound exactly alike. The expired case above stays silent, and
    /// the difference is whether anyone is still waiting on the other end.
    func testEntryWithInsufficientBudgetIsRefusedAudibly() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = RepeatForeverArbiter(clock: clock, advancing: 60)
        let controller = InteractionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }
        // Under the derived floor (~26s at the Apple pace), over zero.
        let deadline = clock.now + .seconds(5)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(decision, .ask)
        XCTAssertTrue(arbiter.timeouts.isEmpty, "no window may open under the floor")
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertTrue(speech.spoken[0].text.contains("screen"),
                      "the refusal must say where the question went: \(speech.spoken)")
    }

    /// F5(3). The floor is characters divided by a speaking rate, so the faster voice needs
    /// less of the budget for the same prompt — and a request the Apple path refuses is one
    /// the realtime path can still ask.
    func testTheFloorScalesWithTheSpeechPath() async {
        let apple = InteractionController(speech: FakeSpeech(), arbiter: NeverArbiter())
        apple.speechPath = .apple
        let realtime = InteractionController(speech: FakeSpeech(), arbiter: NeverArbiter())
        realtime.speechPath = .realtime

        XCTAssertGreaterThan(apple.entryMargin, realtime.entryMargin,
                             "the slower voice needs more budget to ask the same prompt")
        let unstated = InteractionController(speech: FakeSpeech(), arbiter: NeverArbiter())
        XCTAssertEqual(apple.entryMargin, unstated.entryMargin,
                       "a composition that says nothing is assumed to use the slower voice")

        // And the difference is load-bearing, not decorative: a budget between the two
        // floors is refused by one and accepted by the other.
        let between = (apple.entryMargin + realtime.entryMargin) / 2
        let clock = VirtualClock()
        let appleSpeech = FakeSpeech()
        let refusing = InteractionController(
            speech: appleSpeech, arbiter: RepeatForeverArbiter(clock: clock, advancing: 60))
        refusing.now = { clock.now }
        refusing.speechPath = .apple
        _ = await refusing.resolve(request(), deadline: clock.now + .seconds(between))

        let fasterClock = VirtualClock()
        let fasterArbiter = RepeatForeverArbiter(clock: fasterClock, advancing: 60)
        let asking = InteractionController(speech: FakeSpeech(), arbiter: fasterArbiter)
        asking.now = { fasterClock.now }
        asking.speechPath = .realtime
        _ = await asking.resolve(request(), deadline: fasterClock.now + .seconds(between))

        XCTAssertEqual(appleSpeech.spoken.count, 1, "Apple path: refused before any window")
        XCTAssertFalse(fasterArbiter.timeouts.isEmpty,
                       "realtime path: the same budget is enough to ask")
    }

    /// F5(2). `repeat` re-speaks the whole prompt, and the budget it re-speaks it into has
    /// been shrinking for every turn the wearer has taken. Checked again each time, against
    /// the sentence actually in hand.
    func testMidLoopRepeatWithoutRoomIsRefusedAudibly() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        // One listen, long enough to leave a residue that is over zero and under the
        // prompt's own playback plus an answering window.
        let arbiter = RepeatForeverArbiter(clock: clock, advancing: 47)
        let controller = InteractionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(50)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(decision, .ask)
        XCTAssertEqual(arbiter.timeouts.count, 1,
                       "the repeat must not open a second window it cannot fill")
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("screen") },
                      "a mid-loop refusal is spoken, never a silent stop: \(speech.spoken)")
        XCTAssertFalse(speech.spoken.dropFirst().contains { $0.text.contains("Approve?") },
                       "and the unanswerable prompt is not spoken into the residue")
    }

    /// An arbiter that never answers: for assertions about margins, where no window should
    /// open at all.
    @MainActor
    final class NeverArbiter: InputArbitrating {
        func listen(timeout: TimeInterval) async -> InputIntent? { nil }
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
        XCTAssertEqual(arbiter.timeouts.count, 4,
                       "the fifth listen would have re-read question, option, and controls "
                           + "into the 5s left; refused instead")
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

    /// The selection half of F5(1): same split, same reason.
    func testSelectionEntryWithInsufficientBudgetIsRefusedAudibly() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = NavigateForeverArbiter(clock: clock, advancing: 60)
        let controller = SelectionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(5)

        let result = await controller.resolve(selectionRequest(), deadline: deadline)

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(arbiter.timeouts.isEmpty)
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertTrue(speech.spoken[0].text.contains("screen"), "\(speech.spoken)")
    }

    /// A selection's floor is the larger of the two: it reads a question, a position, an
    /// option label, and the controls, where an approval reads one summary.
    func testSelectionFloorIsWiderThanAnApprovalsAndScalesToo() async {
        let selection = SelectionController(speech: FakeSpeech(),
                                            arbiter: NoNavigationArbiter())
        let approval = InteractionController(speech: FakeSpeech(), arbiter: NeverArbiter())
        XCTAssertGreaterThan(selection.entryMargin, approval.entryMargin)

        selection.speechPath = .realtime
        let faster = selection.entryMargin
        selection.speechPath = .apple
        XCTAssertGreaterThan(selection.entryMargin, faster)
    }

    /// F5(2), selection side: `repeat` re-reads the question, the option, *and* the
    /// controls — the longest thing this flow ever says — into whatever navigating has left.
    func testSelectionMidLoopRepeatWithoutRoomIsRefusedAudibly() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = NavigateForeverArbiter(clock: clock, advancing: 47)
        let controller = SelectionController(speech: speech, arbiter: arbiter)
        controller.now = { clock.now }

        let result = await controller.resolve(selectionRequest(),
                                              deadline: clock.now + .seconds(50))

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(arbiter.timeouts.count, 1)
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("screen") },
                      "\(speech.spoken)")
    }

    @MainActor
    final class NoNavigationArbiter: SelectionArbitrating {
        func listen(timeout: TimeInterval) async -> InputIntent? { nil }
    }
}
