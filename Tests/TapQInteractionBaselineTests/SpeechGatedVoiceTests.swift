import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class SpeechGatedVoiceTests: XCTestCase {
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

    func testStartsInnerImmediatelyWhenIdle() async {
        let inner = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: inner, activity: FakeActivity())
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }
        XCTAssertEqual(inner.starts, 1)
        inner.fire(.yes)
        XCTAssertEqual(received, [.yes])
    }

    func testHoldsMicWhileSpeakingThenOpensOnIdle() async {
        let inner = FakeVoice()
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: inner, activity: activity)
        activity.setSpeaking(true) // prompt TTS enqueued before the window opened
        gated.start { _ in }
        XCTAssertEqual(inner.starts, 0, "mic must not open while the engine is busy")
        activity.setSpeaking(false)
        XCTAssertEqual(inner.starts, 1, "mic opens when the engine drains")
    }

    func testSpeechStartingMidWindowTearsDownMic() async {
        let inner = FakeVoice()
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: inner, activity: activity)
        gated.start { _ in }
        XCTAssertEqual(inner.starts, 1)
        activity.setSpeaking(true) // e.g. another session's "Claude finished. <summary>"
        XCTAssertEqual(inner.stops, 1, "contaminated recognition session is discarded")
    }

    func testMicReopensFreshAfterSpeechEnds() async {
        let inner = FakeVoice()
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: inner, activity: activity)
        gated.start { _ in }
        activity.setSpeaking(true)
        activity.setSpeaking(false)
        XCTAssertEqual(inner.starts, 2, "fresh session: cumulative transcripts must not carry TTS tokens")
    }

    func testCommandWhileSpeakingIsDropped() async {
        let inner = FakeVoice()
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: inner, activity: activity)
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }
        activity.setSpeaking(true)
        inner.fire(.no) // in-flight match from the announcement ("…stop…")
        XCTAssertEqual(received, [], "TTS tokens must never resolve a window")
    }

    func testStopCancelsPendingReopen() async {
        let inner = FakeVoice()
        let activity = FakeActivity()
        let gated = SpeechGatedVoice(wrapping: inner, activity: activity)
        activity.setSpeaking(true)
        gated.start { _ in }
        gated.stop() // window resolved by gesture/timeout while TTS still speaking
        activity.setSpeaking(false)
        XCTAssertEqual(inner.starts, 0, "no mic after the window is gone")
    }

    func testCommandAfterStopIsDropped() async {
        let inner = FakeVoice()
        let gated = SpeechGatedVoice(wrapping: inner, activity: FakeActivity())
        var received: [VoiceCommand] = []
        gated.start { received.append($0) }
        gated.stop()
        inner.fire(.yes)
        XCTAssertEqual(received, [])
        XCTAssertEqual(inner.stops, 1)
    }
}
