import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Recall inside a selection. The distinction these tests exist to hold is the one the
/// selection flow makes and the approval flow does not: `.details` abandons the question
/// and returns to the screen, while a recall question does not. Grouping them would turn
/// "what did you just do?" into a cancelled selection.
@MainActor
final class SelectionRecallTests: XCTestCase {
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

    private func request() -> SelectionRequest {
        SelectionRequest(
            id: "q1", sessionID: "s1", question: "Which branch?",
            options: [SelectionOption(label: "main", description: "the trunk"),
                      SelectionOption(label: "develop", description: "the integration branch")]
        )
    }

    func testStatusSpeaksAndTheSelectionSurvives() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.status, .select])
        let controller = SelectionController(
            speech: speech, arbiter: arbiter,
            recallResponder: { _ in "Codex: apply the patch. 1 more waiting." }
        )
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices.map(\.index), [0])
        XCTAssertTrue(speech.spoken.contains("Codex: apply the patch. 1 more waiting."))
    }

    /// The cursor is interaction state, and a question is not navigation.
    func testWhatChangedKeepsTheCursorWhereItWas() async {
        let controller = SelectionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.next, .whatChanged, .select]),
            recallResponder: { _ in "Denied delete the build directory." }
        )
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices.map(\.label), ["develop"])
    }

    func testRecallWithoutResponderSaysNothingRecorded() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech, arbiter: ScriptedArbiter([.whatChanged, .select])
        )
        let result = await controller.resolve(request())
        XCTAssertEqual(result.choices.map(\.index), [0])
        XCTAssertTrue(speech.spoken.contains("Nothing recorded yet."))
    }

    /// The bail-out group is unchanged, and this is the test that would fail if a recall
    /// case were ever folded into it.
    func testDetailsAndDenialStillEndTheSelection() async {
        for intent in [InputIntent.details, .deny, .deferToPrompt] {
            let controller = SelectionController(
                speech: FakeSpeech(), arbiter: ScriptedArbiter([intent]),
                recallResponder: { _ in "recorded" }
            )
            let result = await controller.resolve(request())
            XCTAssertEqual(result, .noSelection, "\(intent) still returns no selection")
        }
    }

    /// Free-form read-back is untouched by the recall seam: the wearer's answer is still
    /// spoken back and still needs a confirmation.
    func testFreeformReadBackIsUnchangedWithARecallResponder() async {
        let speech = FakeSpeech()
        let controller = SelectionController(
            speech: speech,
            arbiter: ScriptedArbiter([.freeform("use the staging bucket"), .allow]),
            recallResponder: { _ in "recorded" }
        )
        let result = await controller.resolve(request())
        XCTAssertEqual(result.freeText, "use the staging bucket")
        XCTAssertTrue(speech.spoken.contains { $0.hasPrefix("You said: 'use the staging bucket") })
    }

    /// Recall alone never resolves a selection; the window runs out and defers, which is
    /// where an unanswered selection has always gone.
    func testRecallAloneTimesOut() async {
        let arbiter = ScriptedArbiter([.status, .whatChanged, nil])
        let controller = SelectionController(speech: FakeSpeech(), arbiter: arbiter)
        let result = await controller.resolve(request())
        XCTAssertTrue(result.choices.isEmpty)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(arbiter.calls, 3)
    }
}
