import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class WearerGatedVoiceTests: XCTestCase {
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

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// A wearer-speech signal whose transitions and availability the test drives by hand.
    @MainActor
    final class FakeSignal: WearerSpeechSignaling {
        private(set) var isWearerSpeaking = false
        var isSignalAvailable = true
        var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?

        init(speaking: Bool = false, available: Bool = true) {
            isWearerSpeaking = speaking
            isSignalAvailable = available
        }

        func setSpeaking(_ speaking: Bool) {
            guard speaking != isWearerSpeaking else { return }
            isWearerSpeaking = speaking
            onWearerSpeakingChange?(speaking)
        }

        /// A detector that believes the wearer is silent and never changes its mind —
        /// the shape a wedged analyzer takes while still reporting itself available.
        func wedgeQuiet() {
            isWearerSpeaking = false
            isSignalAvailable = true
        }
    }

    /// stop() deliberately does NOT clear onCommand: it simulates the recognizer's
    /// main-actor Task hop, where a match can reach the decorator after teardown began.
    @MainActor
    final class FakeVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
            starts += 1
            self.onCommand = onCommand
        }
        func stop() { stops += 1 }
        func fire(_ command: VoiceCommand) { onCommand?(command) }
    }

    @MainActor
    final class FakeActivity: SpeechActivitySignaling {
        private(set) var isSpeaking = false
        var onSpeakingChange: (@MainActor (Bool) -> Void)?
        func setSpeaking(_ speaking: Bool) {
            guard speaking != isSpeaking else { return }
            isSpeaking = speaking
            onSpeakingChange?(speaking)
        }
    }

    /// Test-controlled monotonic clock; the attribution window looks backwards from
    /// delivery time, so tests must own "now".
    private final class Clock {
        var now: TimeInterval = 100
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func makeGate(inner: FakeVoice,
                          signal: FakeSignal,
                          clock: Clock,
                          window: TimeInterval = 2.0,
                          sink: RecordingSink = RecordingSink()) -> WearerGatedVoice {
        WearerGatedVoice(wrapping: inner, signal: signal, attributionWindow: window,
                         monotonicNow: { clock.now }, diagnosticSink: sink)
    }

    // MARK: - Fail open

    func testPassesThroughWhenSignalUnavailable() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let clock = Clock()
        let sink = RecordingSink()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, sink: sink)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes], "no signal must reproduce today's shipped behavior")
        XCTAssertEqual(sink.names, ["command.passed_signal_unavailable"])
    }

    func testWedgedSignalStillDeliversWhenUnavailable() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        // The analyzer never fires a single transition — the failure mode that would
        // otherwise silently swallow every command.
        clock.advance(600)
        inner.fire(.no)
        inner.fire(.yes)
        XCTAssertEqual(received, [.no, .yes])
    }

    func testAvailabilityLostMidWindowReopensTheGate() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        inner.fire(.yes)
        XCTAssertEqual(received, [], "silent wearer, signal healthy")
        signal.isSignalAvailable = false // AirPods sleep, stream goes stale
        inner.fire(.no)
        XCTAssertEqual(received, [.no], "degradation must fail open immediately")
    }

    // MARK: - Attribution

    func testPassesWhileWearerIsSpeaking() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        signal.setSpeaking(true)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    func testPassesWithinTrailingAttributionWindow() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        signal.setSpeaking(true)
        clock.advance(0.4)
        signal.setSpeaking(false)
        clock.advance(0.5) // recognizer latency: the match lands after the utterance ends
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    func testRejectsWhenWearerNeverSpoke() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let sink = RecordingSink()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, sink: sink)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        inner.fire(.yes) // a colleague across the desk said "yes"
        XCTAssertEqual(received, [])
        XCTAssertEqual(sink.names, ["command.rejected_nonwearer"])
        XCTAssertEqual(sink.events.first?.fields["since_wearer_speech_seconds"], "never")
    }

    func testRejectsAfterWindowExpiry() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let sink = RecordingSink()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0, sink: sink)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        clock.advance(2.5)
        inner.fire(.yes)
        XCTAssertEqual(received, [])
        XCTAssertEqual(sink.events.first?.fields["since_wearer_speech_seconds"], "2.500")
        XCTAssertEqual(sink.events.first?.fields["attribution_window_seconds"], "2.000")
    }

    func testWindowBoundaryIsInclusive() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        clock.advance(2.0)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    func testSpeechBeforeTheWindowOpenedStillAttributes() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        clock.advance(0.3)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) } // window opens after the wearer already spoke
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    func testComposedMidUtteranceAnchorsTheClock() async {
        let inner = FakeVoice()
        let signal = FakeSignal(speaking: true) // already talking when composed
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        signal.setSpeaking(false)
        clock.advance(0.1)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    // MARK: - Ownership and lifecycle

    func testClaimsTheSpeakingChangeObserver() async {
        let signal = FakeSignal()
        XCTAssertNil(signal.onWearerSpeakingChange)
        let clock = Clock()
        let gate = makeGate(inner: FakeVoice(), signal: signal, clock: clock)
        XCTAssertNotNil(signal.onWearerSpeakingChange,
                        "the wrapper must own the single-observer signal")
        withExtendedLifetime(gate) {}
    }

    func testStartAndStopForwardToInner() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        gate.start { _ in }
        XCTAssertEqual(inner.starts, 1)
        gate.stop()
        XCTAssertEqual(inner.stops, 1)
    }

    func testNeverTouchesTheMicrophoneOnSignalTransitions() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        gate.start { _ in }
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        signal.isSignalAvailable = false
        XCTAssertEqual(inner.starts, 1, "mic lifecycle belongs to SpeechGatedVoice")
        XCTAssertEqual(inner.stops, 0)
    }

    func testCommandAfterStopIsDropped() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        gate.stop()
        inner.fire(.yes) // in-flight match landing after teardown
        XCTAssertEqual(received, [])
    }

    func testAttributionSurvivesAcrossWindows() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        gate.start { _ in }
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        gate.stop()
        clock.advance(0.2)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    // MARK: - Composition with SpeechGatedVoice

    func testStackedWithSpeechGateBothPoliciesApply() async {
        let inner = FakeVoice()
        let signal = FakeSignal()
        let activity = FakeActivity()
        let clock = Clock()
        let attributed = makeGate(inner: inner, signal: signal, clock: clock, window: 2.0)
        let gated = SpeechGatedVoice(wrapping: attributed, activity: activity)
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 1, "outer gate opens the mic through the inner filter")

        // 1. Wearer silent: attribution rejects even though TTS is idle.
        inner.fire(.yes)
        XCTAssertEqual(received, [])

        // 2. Wearer speaks: the command survives both layers.
        signal.setSpeaking(true)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])

        // 3. TTS starts: the outer gate tears the session down and drops in-flight matches
        //    even though attribution would have accepted them.
        activity.setSpeaking(true)
        XCTAssertEqual(inner.stops, 1)
        inner.fire(.no)
        XCTAssertEqual(received, [.yes])
    }

    func testStackedWithSpeechGateFailsOpenWhenSignalUnavailable() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let activity = FakeActivity()
        let clock = Clock()
        let attributed = makeGate(inner: inner, signal: signal, clock: clock)
        let gated = SpeechGatedVoice(wrapping: attributed, activity: activity)
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes], "degraded attribution must not change shipped behavior")
    }

    /// The fail-open regression sentinel for the live composition: SpeechGatedVoice wrapping
    /// WearerGatedVoice wrapping the raw voice, with a *stale* signal (isSignalAvailable
    /// false). The gate must pass every command through verbatim — the exact behavior of a
    /// serve without --wearer-gate.
    func testFullStackWithStaleSignalIsVerbatimPassthrough() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let activity = FakeActivity()
        let clock = Clock()
        let sink = RecordingSink()
        let attributed = makeGate(inner: inner, signal: signal, clock: clock, sink: sink)
        let gated = SpeechGatedVoice(wrapping: attributed, activity: activity)
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }

        // Every command passes through without the wearer speaking.
        inner.fire(.yes)
        inner.fire(.no)
        XCTAssertEqual(received, [.yes, .no])

        // TTS gating still works on top of the stale attribution.
        activity.setSpeaking(true)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes, .no], "TTS gate still closes the mic")

        activity.setSpeaking(false)
        inner.fire(.no)
        XCTAssertEqual(received, [.yes, .no, .no], "mic reopens after TTS drains")

        // Every passed-through command records the fail-open diagnostic.
        let passCount = sink.names.filter { $0 == "command.passed_signal_unavailable" }.count
        XCTAssertEqual(passCount, 3, "each pass-through must be diagnostically visible")
    }
}
