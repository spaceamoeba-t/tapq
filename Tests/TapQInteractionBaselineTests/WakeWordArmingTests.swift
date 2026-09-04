import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// What a wake word does, and when a spotter is allowed to be listening for one
/// (`docs/WAKE_WORD_PLAN.md` §2 and §3).
///
/// Both halves are decidable with no microphone, no recognizer, and no Apple framework,
/// which is the reason they live here rather than beside the listener: the rule that TapQ
/// never shares its one microphone is a rule about state, and state can be driven.
@MainActor
final class WakeWordArmingTests: XCTestCase {
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

        /// The `reason=` fields of every suspension, in order — the line an operator reads
        /// when a spotter is unexpectedly deaf.
        var suspendReasons: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.name == "wake.suspended" }
                .compactMap { $0.fields["reason"] }
        }
    }

    @MainActor
    private final class FakeSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    /// An arbiter that ends the window at once, so a test of *whether* a window opened does
    /// not have to run one.
    @MainActor
    private final class SilentArbiter: InputArbitrating {
        private(set) var listens = 0
        func listen(timeout: TimeInterval) async -> InputIntent? {
            listens += 1
            return nil
        }
    }

    @MainActor
    private final class FakeSpotter: WakeWordSpotting {
        var isSpotting = false
        var onStopped: (@MainActor (String) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var onWake: (@MainActor (String) -> Void)?

        func start(onWake: @escaping @MainActor (String) -> Void) {
            starts += 1
            isSpotting = true
            self.onWake = onWake
        }

        func stop() {
            if isSpotting { stops += 1 }
            isSpotting = false
        }

        /// The wearer said it. Fired even when the spotter believes it is stopped, so a
        /// late callback racing a `stop()` can be reproduced.
        func fire(_ transcript: String = "hey tapq") {
            onWake?(transcript)
        }

        func giveUp(_ reason: String = "recognizer_unavailable") {
            isSpotting = false
            onStopped?(reason)
        }
    }

    private func arming(
        waits: SessionWaitRegistry,
        listening: @escaping @MainActor () -> Bool = { false },
        speech: FakeSpeech,
        sink: RecordingSink
    ) -> WakeWordArming {
        // Built here rather than as a default argument: a default is evaluated in a
        // nonisolated context, and every double in this file is main-actor isolated.
        let arbiter = SilentArbiter()
        return WakeWordArming(
            waits: waits,
            isVoiceSessionListening: listening,
            speak: { speech.speak($0, priority: .notification, onFinish: nil) },
            diagnosticSink: sink,
            makeController: {
                CommandWindowController(
                    speech: speech,
                    arbiter: arbiter,
                    gate: InteractionGate(),
                    cue: "Yes?",
                    kind: .voiceSession,
                    windowSeconds: CommandWindowController.wakeWindowSeconds
                )
            }
        )
    }

    /// Lets the window's own task run to its end, so `window.finished` and the arming's
    /// released flag are both observable.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    // MARK: - The arming's four branches

    /// The ordinary case: one wake word, one window, and the cue is a reply to the wearer
    /// rather than TapQ describing itself.
    func testAWakeWordOpensOneWindowWithItsCue() async {
        let sink = RecordingSink()
        let speech = FakeSpeech()
        let armed = arming(waits: SessionWaitRegistry(), speech: speech, sink: sink)

        armed.wakeWordHeard()
        XCTAssertTrue(armed.isWindowOpen)
        await settle()

        XCTAssertTrue(sink.names.contains("window.arming"), "\(sink.names)")
        XCTAssertTrue(sink.names.contains("window.finished"), "\(sink.names)")
        XCTAssertEqual(speech.spoken.first, "Yes?")
        XCTAssertFalse(armed.isWindowOpen, "the window never released the arming")
    }

    /// A request at the gate is a question the wearer is already being asked, and its own
    /// window has the microphone. Refused — and refused *out loud*, because the wearer said
    /// a word expecting an answer and silence is indistinguishable from a wake word that
    /// was not heard.
    func testARequestWaitingRefusesTheWakeWordOutLoud() async {
        let sink = RecordingSink()
        let speech = FakeSpeech()
        let waits = SessionWaitRegistry()
        _ = waits.begin(sessionID: "s1", agent: .claudeCode)
        let armed = arming(waits: waits, speech: speech, sink: sink)

        armed.wakeWordHeard()
        await settle()

        XCTAssertFalse(armed.isWindowOpen)
        XCTAssertEqual(speech.spoken, ["Something is waiting for you first."])
        XCTAssertTrue(sink.names.contains("wake.refused_request_waiting"), "\(sink.names)")
        XCTAssertFalse(sink.names.contains("window.arming"), "\(sink.names)")
    }

    /// A held-boundary loop is already listening, so the word was redundant. Nothing is
    /// said: an answer here would talk over the window that is doing the listening.
    func testAListeningLoopIgnoresTheWakeWordSilently() async {
        let sink = RecordingSink()
        let speech = FakeSpeech()
        let armed = arming(
            waits: SessionWaitRegistry(), listening: { true }, speech: speech, sink: sink
        )

        armed.wakeWordHeard()
        await settle()

        XCTAssertFalse(armed.isWindowOpen)
        XCTAssertTrue(speech.spoken.isEmpty, "\(speech.spoken)")
        XCTAssertTrue(sink.names.contains("wake.ignored_listening"), "\(sink.names)")
    }

    /// One wake word, one window. A second phrase heard while the first window is still
    /// open must not stack another behind it.
    func testASecondWakeWordDoesNotStackASecondWindow() async {
        let sink = RecordingSink()
        let speech = FakeSpeech()
        let armed = arming(waits: SessionWaitRegistry(), speech: speech, sink: sink)

        armed.wakeWordHeard()
        armed.wakeWordHeard()
        await settle()

        XCTAssertEqual(sink.names.filter { $0 == "window.arming" }.count, 1, "\(sink.names)")
        XCTAssertTrue(sink.names.contains("wake.ignored_window_open"), "\(sink.names)")
    }

    // MARK: - The gate's decision table

    private func gate(
        spotter: FakeSpotter,
        blocked: [String: () -> Bool],
        order: [String] = ["window", "attention", "waiting", "listening", "speaking"],
        onWake: @escaping @MainActor () -> Void = {},
        speech: FakeSpeech? = nil,
        sink: RecordingSink
    ) -> WakeWordGate {
        let speech = speech ?? FakeSpeech()
        return WakeWordGate(
            spotter: spotter,
            conditions: order.map { reason in
                .init(reason: reason) { blocked[reason]?() ?? false }
            },
            onWake: onWake,
            speak: { speech.speak($0, priority: .notification, onFinish: nil) },
            diagnosticSink: sink
        )
    }

    /// With nothing running at all, the spotter runs. This is the state the whole feature
    /// exists for, and it is also the state a runtime starts in.
    func testWithNothingHappeningTheSpotterIsArmed() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        let gated = gate(spotter: spotter, blocked: [:], sink: sink)

        gated.reevaluate()

        XCTAssertTrue(spotter.isSpotting)
        XCTAssertEqual(spotter.starts, 1)
        XCTAssertTrue(sink.names.contains("wake.armed"), "\(sink.names)")
    }

    /// Each condition on its own suspends the spotter, and clearing it resumes — the table
    /// written out one row at a time, because a gate that happened to be right about four
    /// of five booleans is a microphone shared on the fifth.
    func testEachConditionSuspendsAndThenResumes() async {
        for reason in ["window", "attention", "waiting", "listening", "speaking"] {
            let sink = RecordingSink()
            let spotter = FakeSpotter()
            var blocking = false
            let gated = gate(
                spotter: spotter, blocked: [reason: { blocking }], sink: sink
            )

            gated.reevaluate()
            XCTAssertTrue(spotter.isSpotting, "\(reason) never armed")

            blocking = true
            gated.reevaluate()
            XCTAssertFalse(spotter.isSpotting, "\(reason) did not suspend the spotter")
            XCTAssertEqual(spotter.stops, 1, "\(reason)")
            XCTAssertEqual(sink.suspendReasons, [reason])

            blocking = false
            gated.reevaluate()
            XCTAssertTrue(spotter.isSpotting, "\(reason) never resumed")
            XCTAssertEqual(spotter.starts, 2, "\(reason)")
            XCTAssertTrue(sink.names.contains("wake.resumed"), "\(reason): \(sink.names)")
        }
    }

    /// The reason reported is the first that holds, in the order the composition listed
    /// them. Otherwise the log would name whichever condition happened to be checked last,
    /// which is the least useful of the true ones.
    func testTheSuspensionNamesTheFirstConditionThatHolds() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        var waiting = false
        var listening = false
        let gated = gate(
            spotter: spotter,
            blocked: ["waiting": { waiting }, "listening": { listening }],
            sink: sink
        )
        gated.reevaluate()

        waiting = true
        listening = true
        gated.reevaluate()

        XCTAssertFalse(spotter.isSpotting)
        XCTAssertEqual(sink.suspendReasons, ["waiting"])
    }

    /// A gate armed into a runtime that is already busy stays quiet rather than starting a
    /// spotter and stopping it in the same breath. Nothing is suspended, because nothing was
    /// listening — the log's first wake line is the arming, whenever it comes.
    func testAGateThatIsBlockedFromTheStartNeverStartsTheSpotter() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        var listening = true
        let gated = gate(
            spotter: spotter, blocked: ["listening": { listening }], sink: sink
        )

        gated.reevaluate()
        XCTAssertEqual(spotter.starts, 0)
        XCTAssertTrue(sink.names.filter { $0.hasPrefix("wake.") }.isEmpty, "\(sink.names)")

        listening = false
        gated.reevaluate()
        XCTAssertEqual(spotter.starts, 1)
        XCTAssertTrue(sink.names.contains("wake.armed"), "\(sink.names)")
    }

    /// Re-asking with nothing changed says nothing and does nothing. The gate is called on
    /// every transition of five different objects, so a chatty one would bury its own log.
    func testReevaluatingWithNothingChangedIsSilent() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        let gated = gate(spotter: spotter, blocked: [:], sink: sink)

        gated.reevaluate()
        gated.reevaluate()
        gated.reevaluate()

        XCTAssertEqual(spotter.starts, 1)
        XCTAssertEqual(sink.names.filter { $0.hasPrefix("wake.") }, ["wake.armed"])
    }

    /// The wake word arrives, the window opens, and the spotter is off the microphone
    /// before that window wants it — from inside the spotter's own callback, which is what
    /// the listener schedules its restart ahead of the callback for.
    func testAWakeWordSuspendsTheSpotterInsideItsOwnCallback() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        var windowOpen = false
        var wakes = 0
        let gated = gate(
            spotter: spotter,
            blocked: ["window": { windowOpen }],
            onWake: {
                wakes += 1
                windowOpen = true
            },
            sink: sink
        )
        gated.reevaluate()

        spotter.fire()

        XCTAssertEqual(wakes, 1)
        XCTAssertFalse(spotter.isSpotting, "the window opened over a live spotter")
        XCTAssertEqual(sink.suspendReasons, ["window"])
    }

    /// A spotter that gave up says so once, in the wearer's ear. It is the one failure they
    /// cannot discover by trying: they say the phrase into a room that was never going to
    /// answer.
    func testASpotterThatGivesUpIsAnnouncedOnce() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        let speech = FakeSpeech()
        let gated = gate(spotter: spotter, blocked: [:], speech: speech, sink: sink)
        gated.reevaluate()

        spotter.giveUp()
        spotter.giveUp()

        XCTAssertEqual(speech.spoken, ["Wake word listening stopped."])
        XCTAssertFalse(gated.isSpotting)
    }

    /// And it stays given up. A later transition — a window closing, a sentence draining —
    /// must not restart a recognizer that has already been declared gone.
    func testAGivenUpSpotterIsNotRestartedByALaterTransition() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        let gated = gate(spotter: spotter, blocked: [:], sink: sink)
        gated.reevaluate()
        spotter.giveUp()

        gated.reevaluate()

        XCTAssertEqual(spotter.starts, 1)
        XCTAssertFalse(spotter.isSpotting)
    }

    /// Shutdown is final for the same reason: the runtime is tearing its voice down, and a
    /// spotter put back up by a late transition would hold a microphone under it.
    func testShutdownStopsTheSpotterForGood() async {
        let sink = RecordingSink()
        let spotter = FakeSpotter()
        let gated = gate(spotter: spotter, blocked: [:], sink: sink)
        gated.reevaluate()

        gated.shutdown()
        gated.reevaluate()

        XCTAssertFalse(spotter.isSpotting)
        XCTAssertEqual(spotter.starts, 1)
        XCTAssertEqual(spotter.stops, 1)
    }
}
