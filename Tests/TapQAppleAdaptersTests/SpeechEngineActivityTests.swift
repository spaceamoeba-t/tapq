import XCTest
@testable import TapQAppleAdapters
import TapQContracts
import TapQDetectionBaseline
import TapQInteractionBaseline

@MainActor
final class SpeechEngineActivityTests: XCTestCase {
    @MainActor
    private final class FakeVoice: VoiceCommandProviding {
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
    /// The seam replaces actual synthesis: no AVSpeechSynthesizer audio ever starts,
    /// and tests drive utterance completion via finishCurrentUtteranceForTesting().
    private func makeEngine() -> SpeechEngine {
        let engine = SpeechEngine()
        engine.synthesisForTesting = { _ in }
        return engine
    }

    func testIdleUntilFirstUtterance() {
        XCTAssertFalse(makeEngine().isSpeaking)
    }

    func testBusyWhileSpeakingIdleAfterFinish() {
        let engine = makeEngine()
        engine.speak("Approve?", priority: .approval, onFinish: nil)
        XCTAssertTrue(engine.isSpeaking)
        engine.finishCurrentUtteranceForTesting()
        XCTAssertFalse(engine.isSpeaking)
    }

    func testBusyHoldsWhileBacklogDrains() {
        // Rapid tilts queue option announcements (.approval does not preempt .approval);
        // the signal must stay busy until the whole backlog drains.
        let engine = makeEngine()
        engine.speak("Option 2: build.", priority: .approval, onFinish: nil)
        engine.speak("Option 3: test.", priority: .approval, onFinish: nil)
        engine.finishCurrentUtteranceForTesting()
        XCTAssertTrue(engine.isSpeaking, "queue not drained yet")
        engine.finishCurrentUtteranceForTesting()
        XCTAssertFalse(engine.isSpeaking)
    }

    func testObserverFiresOnlyOnTransitions() {
        let engine = makeEngine()
        var events: [Bool] = []
        engine.onSpeakingChange = { events.append($0) }
        engine.speak("one", priority: .notification, onFinish: nil)
        engine.speak("two", priority: .notification, onFinish: nil)
        engine.finishCurrentUtteranceForTesting()
        engine.finishCurrentUtteranceForTesting()
        XCTAssertEqual(events, [true, false], "one busy edge, one idle edge — no per-utterance noise")
    }

    func testPreemptionStaysBusyUntilQueueDrains() {
        let engine = makeEngine()
        var events: [Bool] = []
        engine.speak("Claude finished.", priority: .notification, onFinish: nil)
        engine.onSpeakingChange = { events.append($0) }
        engine.speak("Claude wants to run tests. Approve?", priority: .approval, onFinish: nil)
        XCTAssertTrue(engine.isSpeaking, "preemption swaps utterances without an idle gap")
        engine.finishCurrentUtteranceForTesting()
        XCTAssertFalse(engine.isSpeaking)
        XCTAssertEqual(events, [false])
    }

    func testStopAllGoesIdle() {
        let engine = makeEngine()
        engine.speak("one", priority: .notification, onFinish: nil)
        engine.speak("two", priority: .notification, onFinish: nil)
        engine.stopAll()
        XCTAssertFalse(engine.isSpeaking)
    }

    func testPortableSpeechGateTracksRealEngineActivity() {
        let engine = makeEngine()
        let voice = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: voice, activity: engine)
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }

        engine.speak("All two tests passed, ok.", priority: .notification, onFinish: nil)
        XCTAssertEqual(voice.stops, 1)
        voice.fire(.number(2))
        XCTAssertTrue(received.isEmpty)

        engine.finishCurrentUtteranceForTesting()
        XCTAssertEqual(voice.starts, 2)
        voice.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }
}
