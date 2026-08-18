import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Recall and grounded Q&A inside an approval window: both are things the controller
/// *says*, and neither is a thing it *decides*. Every test here checks the second half as
/// well as the first — the window survives the question.
@MainActor
final class InteractionRecallTests: XCTestCase {
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
    final class FakeSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    @MainActor
    final class ScriptedArbiter: InputArbitrating {
        private let script: [InputIntent?]
        private(set) var calls = 0
        init(_ script: [InputIntent?]) { self.script = script }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    // MARK: - Recall

    func testStatusSpeaksTheAnswerAndKeepsTheWindowOpen() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.status, .allow])
        let controller = InteractionController(
            speech: speech, arbiter: arbiter,
            recallResponder: { _ in "Claude Code: run npm test. 2 more waiting." }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow, "a question does not answer the question")
        XCTAssertEqual(arbiter.calls, 2)
        XCTAssertTrue(speech.spoken.contains("Claude Code: run npm test. 2 more waiting."))
    }

    func testWhatChangedIsInformationalToo() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.whatChanged, .deny])
        let controller = InteractionController(
            speech: speech, arbiter: arbiter,
            recallResponder: { _ in "Allowed run npm test." }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .deny)
        XCTAssertTrue(speech.spoken.contains("Allowed run npm test."))
    }

    /// The responder is told which question was asked, so one closure can answer both.
    func testResponderReceivesTheIntent() async {
        var asked: [InputIntent] = []
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.status, .whatChanged, .allow]),
            recallResponder: { intent in
                asked.append(intent)
                return "ok"
            }
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(asked, [.status, .whatChanged])
    }

    /// No responder is the default composition, and the wearer still hears an answer:
    /// silence is indistinguishable from a missed question when there is no screen.
    func testRecallWithoutResponderSaysNothingRecorded() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ScriptedArbiter([.status, .allow])
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertTrue(speech.spoken.contains("Nothing recorded yet."))
    }

    func testEmptyResponderAnswerSaysNothingRecorded() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ScriptedArbiter([.status, .whatChanged, .allow]),
            recallResponder: { intent in intent == .status ? nil : "   " }
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(speech.spoken.filter { $0 == "Nothing recorded yet." }.count, 2)
    }

    /// Recall can never end a window by itself: asked repeatedly and never answered, the
    /// request runs out its listens and defers to the screen — the same place an
    /// unanswered request has always gone.
    func testRecallAloneTimesOutToAsk() async {
        let arbiter = ScriptedArbiter([.status, .whatChanged, .status, nil])
        let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .ask)
        XCTAssertEqual(arbiter.calls, 4)
    }

    // MARK: - Grounded Q&A

    func testQuestionIsOfferedAndTheWindowContinuesSilently() async {
        let speech = FakeSpeech()
        var offered: [String] = []
        let arbiter = ScriptedArbiter([.freeform("what did you decide?"), .allow])
        let controller = InteractionController(
            speech: speech, arbiter: arbiter,
            freeformResponder: { text in
                offered.append(text)
                return true
            }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(offered, ["what did you decide?"])
        XCTAssertEqual(speech.spoken, ["The agent: run npm test. Approve?"],
                       "the backend audio is the answer; the controller says nothing")
    }

    /// A statement is not a question. The responder never sees it, and the transcript is
    /// ignored exactly as it was before this seam existed.
    func testNonQuestionFreeformIsIgnored() async {
        var offered = 0
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ScriptedArbiter([.freeform("run the tests again later"), .allow]),
            freeformResponder: { _ in
                offered += 1
                return true
            }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(offered, 0)
    }

    /// Without a responder — every composition that has no realtime backend — a spoken
    /// question is what it always was: an unmatched transcript that keeps the window open.
    func testQuestionWithoutResponderIsTodaysBehavior() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.freeform("what did you decide?"), .allow])
        let controller = InteractionController(speech: speech, arbiter: arbiter)
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(speech.spoken, ["The agent: run npm test. Approve?"])
        XCTAssertEqual(arbiter.calls, 2)
    }

    /// A responder that declines spends nothing: the wearer can ask again, and the window
    /// behaves as if the seam were absent.
    func testDeclinedQuestionsDoNotSpendTheBudget() async {
        var offered = 0
        let questions: [InputIntent?] = Array(repeating: .freeform("what now?"), count: 5)
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter(questions + [.allow]),
            freeformResponder: { _ in
                offered += 1
                return false
            }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(offered, 5)
    }

    func testWindowAnswersAtMostThreeQuestions() async {
        let sink = RecordingSink()
        var offered = 0
        let questions: [InputIntent?] = Array(repeating: .freeform("what now?"), count: 5)
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter(questions + [.allow]),
            diagnosticSink: sink,
            freeformResponder: { _ in
                offered += 1
                return true
            }
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow, "an exhausted budget still leaves the window open")
        XCTAssertEqual(offered, InteractionController.groundedAnswerBudget)
        XCTAssertEqual(sink.names.filter { $0 == "qa.budget_exhausted" }.count, 2)
    }

    /// The budget is the window's, not the session's: the next request the wearer is asked
    /// about can be asked about too.
    func testBudgetResetsWithEachWindow() async {
        var offered = 0
        let responder: FreeformQuestionResponding = { _ in
            offered += 1
            return true
        }
        let questions: [InputIntent?] = Array(repeating: .freeform("what now?"), count: 4)
        let first = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter(questions + [.allow]),
            freeformResponder: responder
        )
        _ = await first.resolve(request())
        XCTAssertEqual(offered, 3)
        let second = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter(questions + [.allow]),
            freeformResponder: responder
        )
        _ = await second.resolve(request())
        XCTAssertEqual(offered, 6)
    }

    // MARK: - Question detection

    func testQuestionDetectionIsDeterministic() async {
        for question in ["what did you decide?", "Did you run the tests",
                         "how far along is it", "is the build green",
                         "  what's left?  ", "Would that break anything"] {
            XCTAssertTrue(FreeformQuestion.isQuestion(question), question)
        }
        for statement in ["run the tests", "ship it", "looks good to me", "",
                          "   ", "tell me later"] {
            XCTAssertFalse(FreeformQuestion.isQuestion(statement), statement)
        }
    }
}
