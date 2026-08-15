import XCTest
import TapQContracts
@testable import TapQInteractionBaseline

/// Quiet mode's whole routing table, and the one thing it must never do.
@MainActor
final class QuietSpeechTests: XCTestCase {
    private final class Recorder: SpeechPresenting {
        var spoken: [(text: String, priority: SpeechPriority)] = []
        var finishes = 0
        var stops = 0

        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append((text, priority))
            onFinish?()
        }

        func stopAll() { stops += 1 }
    }

    private var inner: Recorder!
    private var cues: [NotificationCue] = []
    private var quiet: QuietSpeech!

    override func setUp() {
        super.setUp()
        inner = Recorder()
        cues = []
        quiet = QuietSpeech(wrapping: inner) { [self] cue in cues.append(cue) }
    }

    func testNotificationsBecomeTheNotificationCue() async {
        quiet.speak("Deferring to the screen.", priority: .notification, onFinish: nil)

        XCTAssertEqual(cues, [.notification])
        XCTAssertTrue(inner.spoken.isEmpty, "a notification must not also be spoken")
    }

    func testAnArmedPromptBecomesThePromptCue() async {
        quiet.armPrompt()
        quiet.speak("Claude Code wants to run the tests.", priority: .approval, onFinish: nil)

        XCTAssertEqual(cues, [.prompt])
        XCTAssertTrue(inner.spoken.isEmpty)
    }

    /// The property the whole design exists for. A prompt and a recall answer share a
    /// priority and a speech path, so only the arming can tell them apart — and a wearer
    /// who asks a question out loud and hears a chime back has been given a worse answer
    /// than silence, because they cannot tell it from a misheard question.
    func testEverythingSaidAfterThePromptIsStillSpoken() async {
        quiet.armPrompt()
        quiet.speak("Claude Code wants to run the tests.", priority: .approval, onFinish: nil)
        quiet.speak("Claude Code: run the tests. Nothing else waiting.",
                    priority: .approval, onFinish: nil)
        quiet.speak("swift test --parallel", priority: .approval, onFinish: nil)

        XCTAssertEqual(cues, [.prompt])
        XCTAssertEqual(inner.spoken.map(\.text), [
            "Claude Code: run the tests. Nothing else waiting.",
            "swift test --parallel",
        ])
    }

    /// One arming, one cue. Two requests queued behind each other each arm their own, and
    /// a window that arms twice before speaking still owes exactly one prompt.
    func testArmingIsConsumedByOneUtteranceAndIsIdempotent() async {
        quiet.armPrompt()
        quiet.armPrompt()
        XCTAssertTrue(quiet.isPromptArmed)
        quiet.speak("first prompt", priority: .approval, onFinish: nil)
        XCTAssertFalse(quiet.isPromptArmed)
        quiet.speak("an answer", priority: .approval, onFinish: nil)

        quiet.armPrompt()
        quiet.speak("second prompt", priority: .approval, onFinish: nil)

        XCTAssertEqual(cues, [.prompt, .prompt])
        XCTAssertEqual(inner.spoken.map(\.text), ["an answer"])
    }

    func testAnUnarmedApprovalIsSpoken() async {
        quiet.speak("Nothing recorded yet.", priority: .approval, onFinish: nil)

        XCTAssertTrue(cues.isEmpty)
        XCTAssertEqual(inner.spoken.map(\.text), ["Nothing recorded yet."])
    }

    func testProgressIsForwardedUntouched() async {
        quiet.speak("still working", priority: .progress, onFinish: nil)

        XCTAssertTrue(cues.isEmpty)
        XCTAssertEqual(inner.spoken.map(\.priority), [.progress])
    }

    /// Every caller uses `onFinish` to mean "the channel is free again". A cue occupies a
    /// separate engine that never held the channel, so a window that waited on the tone
    /// would open late for no gain.
    func testACueCompletesItsCallerImmediately() async {
        var finished = 0
        quiet.speak("a notice", priority: .notification, onFinish: { finished += 1 })
        quiet.armPrompt()
        quiet.speak("a prompt", priority: .approval, onFinish: { finished += 1 })

        XCTAssertEqual(finished, 2)
    }

    func testStopAllReachesTheInnerPresenter() async {
        quiet.stopAll()
        XCTAssertEqual(inner.stops, 1)
    }
}
