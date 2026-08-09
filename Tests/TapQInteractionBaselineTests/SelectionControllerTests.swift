import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class SelectionControllerTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @MainActor
    final class FakeSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    @MainActor
    final class ScriptedArbiter: SelectionArbitrating {
        private let script: [InputIntent?]
        private(set) var calls = 0
        init(_ script: [InputIntent?]) { self.script = script }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    /// Records how many utterances had been enqueued when each window opened.
    @MainActor
    final class SpeechOrderSelectionArbiter: SelectionArbitrating {
        private let speech: FakeSpeech
        private let script: [InputIntent?]
        private(set) var spokenCountAtListen: [Int] = []
        private var calls = 0
        init(speech: FakeSpeech, script: [InputIntent?]) {
            self.speech = speech
            self.script = script
        }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            spokenCountAtListen.append(speech.spoken.count)
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    private func request(options: Int = 3) -> SelectionRequest {
        SelectionRequest(
            id: "1", sessionID: "s1",
            question: "Which color?",
            options: (1...options).map { SelectionOption(label: "Option \($0)", description: "Desc \($0)") })
    }

    func testSelectFirstOptionByDefault() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices.count, 1)
        XCTAssertEqual(result.choices[0].index, 0)
        XCTAssertEqual(result.choices[0].label, "Option 1")
    }

    func testNextThenSelect() async {
        // Navigation moves immediately (no follow-up window), then select confirms.
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 1)
        XCTAssertEqual(result.choices[0].label, "Option 2")
    }

    func testNextWrapsAround() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .next, .next, .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 0, "3 nexts on 3 options wraps to 0")
    }

    func testPreviousWrapsAround() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.previous, .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 2, "previous from 0 wraps to last")
    }

    func testTwoQuickTiltsNavigateTwice() async {
        // The old double-tilt-confirm is gone: two tilts move two options.
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .next, .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 2, "tilt-tilt means navigate twice, never select")
    }

    func testDenyAfterNavigateReturnsNoSelection() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .deny]))
        let result = await controller.resolve(request())
        XCTAssertTrue(result.timedOut)
    }

    func testSelectByNumber() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.selectByNumber(2)]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 1, "number 2 = index 1")
    }

    func testSelectByNumberOutOfRange() async {
        let speech = FakeSpeech()
        // Number 5 on a 3-option question should speak error, then timeout
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.selectByNumber(5), nil]))
        let result = await controller.resolve(request())
        XCTAssertTrue(result.timedOut)
    }

    func testTimeoutReturnsNoSelection() async {
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([nil]))
        let result = await controller.resolve(request())
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.choices.isEmpty)
    }

    func testSpeaksQuestionAndCurrentOption() async {
        let speech = FakeSpeech()
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.select]))
        _ = await controller.resolve(request())
        XCTAssertEqual(
            speech.spoken[0],
            "Which color? 1 of 3: Option 1. Volume, then nod twice or double-tap."
        )
    }

    func testSpeaksNewOptionAfterNext() async {
        let speech = FakeSpeech()
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.next, .select]))
        _ = await controller.resolve(request())
        XCTAssertTrue(speech.spoken.contains("2: Option 2."))
    }

    func testLongQuestionAndOptionAreBoundedForSpeech() async {
        let speech = FakeSpeech()
        let request = SelectionRequest(
            id: "1", sessionID: "s1",
            question: "Which implementation approach should be used for the next release given all of the constraints and tradeoffs described above?",
            options: [SelectionOption(
                label: "Use the comprehensive implementation with every optional compatibility layer",
                description: "full on-screen description"
            )]
        )
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.select]))
        _ = await controller.resolve(request)
        XCTAssertEqual(
            speech.spoken[0],
            "Which implementation approach should be used for the next release given all… 1 of 1: Use the comprehensive implementation with every… Volume, then nod twice or double-tap."
        )
    }

    func testControlsHintIsDroppedAfterTheFirstSelection() async {
        let speech = FakeSpeech()
        // One controller serves the whole runtime session, so the second resolve is a
        // second question asked of a user who has already been taught the controls.
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.select, .select]))
        _ = await controller.resolve(request())
        _ = await controller.resolve(request())
        XCTAssertEqual(speech.spoken[0], "Which color? 1 of 3: Option 1. \(SelectionController.controlsHint)")
        XCTAssertEqual(speech.spoken[1], "Which color? 1 of 3: Option 1.")
    }

    func testRepeatRestoresControlsHintOnLaterSelections() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.select, .repeatRequest, .select])
        )
        _ = await controller.resolve(request())
        _ = await controller.resolve(request())
        XCTAssertEqual(speech.spoken[1], "Which color? 1 of 3: Option 1.",
                       "the second question opens without the hint")
        XCTAssertEqual(speech.spoken[2], "Which color? 1 of 3: Option 1. \(SelectionController.controlsHint)",
                       "asking to repeat is the one signal that the user wants the controls again")
    }

    func testNavigationNeverSpeaksControlsHint() async {
        let speech = FakeSpeech()
        let controller = SelectionController(speech: speech, arbiter: ScriptedArbiter([.next, .next, .select]))
        _ = await controller.resolve(request())
        XCTAssertFalse(speech.spoken.dropFirst().contains { $0.contains(SelectionController.controlsHint) },
                       "only the opening prompt may carry the hint")
    }

    func testVoiceOnlyHintIsSpokenWhenTheProviderSaysSo() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.select]),
            controlsHint: { SelectionController.voiceOnlyControlsHint }
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(speech.spoken[0], "Which color? 1 of 3: Option 1. Say next, previous, or select.",
                       "with no motion device the hint must name only channels that can answer")
    }

    func testControlsHintProviderIsConsultedPerPrompt() async {
        // The upgrade path: AirPods connected mid-session. The provider is read when a hint
        // is actually spoken, so the repeat re-teaches the controls that now exist.
        let speech = FakeSpeech()
        var motionAvailable = false
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.select, .repeatRequest, .select]),
            controlsHint: {
                motionAvailable
                    ? SelectionController.controlsHint
                    : SelectionController.voiceOnlyControlsHint
            }
        )
        _ = await controller.resolve(request())
        motionAvailable = true
        _ = await controller.resolve(request())

        XCTAssertEqual(speech.spoken[0],
                       "Which color? 1 of 3: Option 1. \(SelectionController.voiceOnlyControlsHint)")
        XCTAssertEqual(speech.spoken[2],
                       "Which color? 1 of 3: Option 1. \(SelectionController.controlsHint)",
                       "a device that appeared between questions changes what repeat teaches")
    }

    func testDoubleTapConfirmsSelection() async {
        // .allow is what double-tap maps to; in selection context it means "confirm current"
        let controller = SelectionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .allow]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 1)
    }

    func testEveryIterationSpeaksBeforeItsWindowOpens() async {
        let speech = FakeSpeech()
        let arbiter = SpeechOrderSelectionArbiter(speech: speech, script: [.next, .select])
        let controller = SelectionController(speech: speech, arbiter: arbiter)
        _ = await controller.resolve(request())
        XCTAssertEqual(arbiter.spokenCountAtListen, [1, 2],
                       "prompt before window 1, option announcement before window 2")
    }

    // MARK: - Free-form read-back confirmation (WP8)

    func testFreeformConfirmReturnsResultWithText() async {
        let speech = FakeSpeech()
        // .freeform arrives, then .allow (nod) to confirm
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("deploy blue canary"), .allow]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.freeText, "deploy blue canary")
        XCTAssertTrue(result.choices.isEmpty)
        XCTAssertFalse(result.timedOut)
    }

    func testFreeformConfirmWithSelectIntent() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("answer"), .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.freeText, "answer")
        XCTAssertTrue(result.choices.isEmpty)
    }

    func testFreeformDiscardRelistens() async {
        let speech = FakeSpeech()
        // .freeform arrives, deny (shake) discards, then select the first option
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("wrong"), .deny, .select]))
        let result = await controller.resolve(request())
        // After discard, normal selection should work
        XCTAssertEqual(result.choices.count, 1)
        XCTAssertEqual(result.choices[0].index, 0)
        XCTAssertNil(result.freeText, "discarded freeform must not appear in result")
    }

    func testFreeformReadBackIsSpeoken() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("use option B"), .allow]))
        _ = await controller.resolve(request())
        // The read-back should be spoken after the initial prompt
        let readBack = speech.spoken.first { $0.contains("You said:") }
        XCTAssertNotNil(readBack, "a read-back utterance must be spoken")
        XCTAssertTrue(readBack?.contains("use option B") == true)
        XCTAssertTrue(readBack?.contains("Nod or say yes to send") == true)
    }

    func testFreeformTimeoutAfterReadBack() async {
        let speech = FakeSpeech()
        // .freeform arrives, then timeout (nil) during confirmation
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("answer"), nil]))
        let result = await controller.resolve(request())
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.freeText)
    }

    func testFreeformNavigationAfterDiscard() async {
        let speech = FakeSpeech()
        // freeform -> deny (discard) -> next -> select
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("wrong"), .deny, .next, .select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 1,
                       "navigation works after a freeform discard")
        XCTAssertNil(result.freeText)
    }

    func testExistingSelectionTestsPassUnmodified() async {
        // Verify basic selection still works identically (regression sentinel).
        let controller = SelectionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.select]))
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices.count, 1)
        XCTAssertEqual(result.choices[0].index, 0)
        XCTAssertNil(result.freeText)
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - Diagnostics

    @MainActor
    func testResolveConfirmEmitsGenericLifecycleDiagnostics() async {
        let sink = RecordingSink()
        let controller = SelectionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.select]), diagnosticSink: sink)
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 0)
        let names = sink.events.map(\.name)
        XCTAssertTrue(names.contains("resolve.started"))
        XCTAssertTrue(names.contains("selection.presented"))
        XCTAssertTrue(names.contains("selection.resolved"))
        XCTAssertTrue(names.contains("resolve.finished"))
    }

    @MainActor
    func testSelectByNumberEmitsResolvedDiagnostic() async {
        let sink = RecordingSink()
        let controller = SelectionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.selectByNumber(2)]),
            diagnosticSink: sink)
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices[0].index, 1, "number 2 = index 1")
        let resolved = sink.events.first { $0.name == "selection.resolved" }
        XCTAssertEqual(resolved?.fields["cursor"], "1")
        let finished = sink.events.first { $0.name == "resolve.finished" }
        XCTAssertEqual(finished?.fields["outcome"], "resolved")
    }
}
