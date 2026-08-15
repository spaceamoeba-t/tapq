import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// `WearerGatedVoice` answers the same question twice and is expected to disagree with
/// itself. These tests pin the disagreement: for every state, what the approval channel
/// lets through and what the instruction channel accepts, side by side.
@MainActor
final class WearerAttributionTests: XCTestCase {
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
    }

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
    }

    @MainActor
    final class FakeVoice: VoiceCommandProviding {
        var onCommand: (@MainActor (VoiceCommand) -> Void)?
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
            self.onCommand = onCommand
        }
        func stop() {}
        func fire(_ command: VoiceCommand) { onCommand?(command) }
    }

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

    /// The whole point of the second reading. An unavailable analyzer passes approvals
    /// through untouched — that is the shipped fail-open behavior — and refuses to vouch
    /// for an instruction in the same breath.
    func testUnavailableSignalFailsOpenForApprovalsAndClosedForInstructions() async {
        let inner = FakeVoice()
        let signal = FakeSignal(available: false)
        let clock = Clock()
        let sink = RecordingSink()
        let gate = makeGate(inner: inner, signal: signal, clock: clock, sink: sink)
        var received: [VoiceCommand] = []
        gate.start { received.append($0) }

        inner.fire(.yes)
        XCTAssertEqual(received, [.yes], "approvals must behave exactly as they always did")
        XCTAssertFalse(gate.isWearerAttributedNow, "instructions have no on-screen backstop")
        XCTAssertTrue(sink.names.contains("attribution.query_signal_unavailable"))
    }

    func testAttributedWhileTheWearerIsSpeaking() async {
        let signal = FakeSignal()
        let gate = makeGate(inner: FakeVoice(), signal: signal, clock: Clock())
        XCTAssertFalse(gate.isWearerAttributedNow)
        signal.setSpeaking(true)
        XCTAssertTrue(gate.isWearerAttributedNow)
    }

    /// The window looks backwards, because recognition lands after the speech that produced
    /// it — the same window the approval gate uses, read the same way.
    func testAttributionSurvivesTheTrailingWindowAndThenExpires() async {
        let signal = FakeSignal()
        let clock = Clock()
        let sink = RecordingSink()
        let gate = makeGate(inner: FakeVoice(), signal: signal, clock: clock, window: 2.0,
                            sink: sink)
        signal.setSpeaking(true)
        signal.setSpeaking(false)

        clock.advance(1.9)
        XCTAssertTrue(gate.isWearerAttributedNow)
        clock.advance(0.2)
        XCTAssertFalse(gate.isWearerAttributedNow, "2.1s after the wearer stopped")
        XCTAssertTrue(sink.names.contains("attribution.query_nonwearer"))
    }

    /// A healthy analyzer that has never heard the wearer is the bystander case: the room's
    /// voice reaches the microphone, and nothing vouches for it.
    func testSilentWearerWithHealthySignalIsNotAttributed() async {
        let gate = makeGate(inner: FakeVoice(), signal: FakeSignal(), clock: Clock())
        XCTAssertFalse(gate.isWearerAttributedNow)
    }

    /// Reading the query does not consume or extend the attribution: dictation asks twice
    /// per instruction, and the second answer must not depend on the first having been read.
    func testQueryIsIdempotent() async {
        let signal = FakeSignal()
        let clock = Clock()
        let gate = makeGate(inner: FakeVoice(), signal: signal, clock: clock)
        signal.setSpeaking(true)
        signal.setSpeaking(false)
        XCTAssertTrue(gate.isWearerAttributedNow)
        XCTAssertTrue(gate.isWearerAttributedNow)
        clock.advance(1.0)
        XCTAssertTrue(gate.isWearerAttributedNow)
    }

    /// Composed as the protocol, which is how a controller's attribution closure sees it.
    func testConformsToWearerAttributionChecking() async {
        let gate = makeGate(inner: FakeVoice(), signal: FakeSignal(speaking: true),
                            clock: Clock())
        let checker: any WearerAttributionChecking = gate
        XCTAssertTrue(checker.isWearerAttributedNow)
    }
}
