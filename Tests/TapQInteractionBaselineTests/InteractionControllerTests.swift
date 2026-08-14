import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

@MainActor
final class InteractionControllerTests: XCTestCase {
    @MainActor
    final class FakeSpeech: SpeechPresenting {
        var spoken: [(text: String, priority: SpeechPriority)] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append((text, priority))
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
                        summary: "run npm test", detail: "full detail: npm test")
    }

    func testTimeoutResolvesToAsk() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([nil]))
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .ask)
    }

    func testNodResolvesToAllow() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.allow]))
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
    }

    func testDeferResolvesToAsk() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([.deferToPrompt]))
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .ask)
    }

    func testRepeatThenDeny() async {
        let speech = FakeSpeech()
        let controller = InteractionController(speech: speech, arbiter: ScriptedArbiter([.repeatRequest, .deny]))
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .deny)
        let prompts = speech.spoken.filter { $0.text.contains("Approve?") }.count
        XCTAssertEqual(prompts, 2)
    }

    func testDetailsThenAllow() async {
        let speech = FakeSpeech()
        let controller = InteractionController(speech: speech, arbiter: ScriptedArbiter([.details, .allow]))
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("full detail") })
    }

    /// Records, at each listen, whether the prompt utterance had already been enqueued —
    /// the same-turn "speak then open the window" barge-in contract.
    @MainActor
    final class SpeechOrderArbiter: InputArbitrating {
        private let speech: FakeSpeech
        private let script: [InputIntent?]
        private(set) var promptSpokenAtListen: [Bool] = []
        private var calls = 0
        init(speech: FakeSpeech, script: [InputIntent?]) {
            self.speech = speech
            self.script = script
        }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            promptSpokenAtListen.append(speech.spoken.contains { $0.text.contains("Approve?") })
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    func testPromptEnqueuedBeforeWindowOpens() async {
        let speech = FakeSpeech()
        let arbiter = SpeechOrderArbiter(speech: speech, script: [.allow])
        let controller = InteractionController(speech: speech, arbiter: arbiter)
        _ = await controller.resolve(request())
        XCTAssertEqual(arbiter.promptSpokenAtListen, [true],
                       "barge-in: the prompt is enqueued before the window opens")
    }

    func testPromptPhrasingByKind() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let approval = ApprovalRequest(id: "1", sessionID: "s", toolName: "Bash",
                                       summary: "run npm test", detail: "")
        XCTAssertEqual(controller.promptText(for: approval),
                       "The agent: run npm test. Approve?")
        let question = ApprovalRequest(id: "2", sessionID: "s", toolName: "StopQuestion",
                                       summary: "Apply the fix", detail: "", kind: .question)
        XCTAssertEqual(controller.promptText(for: question),
                       "The agent: Apply the fix. Yes or no?")
    }

    func testAgentTextIsBoundedForSpeech() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let request = ApprovalRequest(
            id: "1", sessionID: "s", toolName: "Bash",
            summary: "run a very long command with many arguments that should stay on screen",
            detail: "full detail"
        )
        XCTAssertEqual(controller.promptText(for: request),
                       "The agent: run a very long command with… Approve?")
        XCTAssertEqual(controller.detailText(for: request), "full detail")
    }

    func testNotificationsDoNotReadRawAgentMessage() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let notification = AgentNotification(
            sessionID: "s",
            kind: .waitingForInput,
            summary: "A long raw message that remains available to the agent UI"
        )
        XCTAssertEqual(controller.notificationText(for: notification), "The agent is waiting.")
    }

    // MARK: - Spoken summaries (Rung A)

    /// The preamble is context in front of the prompt. Every word that names what is
    /// being authorized — and the condensation applied to it — is what it was without one.
    func testPreamblePrecedesThePromptSentence() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let question = ApprovalRequest(
            id: "1", sessionID: "s", toolName: "StopQuestion",
            summary: "Apply the fix", detail: "", kind: .question,
            spokenPreamble: "The parser drops trailing commas"
        )
        XCTAssertEqual(
            controller.promptText(for: question),
            "The agent: The parser drops trailing commas. Apply the fix. Yes or no?"
        )
        let approval = ApprovalRequest(
            id: "2", sessionID: "s", toolName: "Bash",
            summary: "run npm test", detail: "",
            spokenPreamble: "The build finished."
        )
        XCTAssertEqual(
            controller.promptText(for: approval),
            "The agent: The build finished. run npm test. Approve?"
        )
    }

    func testEmptyPreambleSpeaksTheUnchangedPrompt() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let request = ApprovalRequest(
            id: "1", sessionID: "s", toolName: "Bash",
            summary: "run npm test", detail: "", spokenPreamble: "   "
        )
        XCTAssertEqual(controller.promptText(for: request),
                       "The agent: run npm test. Approve?")
    }

    /// A host cannot spend the wearer's patience through this field.
    func testPreambleIsBoundedForSpeech() async {
        let controller = InteractionController(speech: FakeSpeech(), arbiter: ScriptedArbiter([]))
        let request = ApprovalRequest(
            id: "1", sessionID: "s", toolName: "Bash",
            summary: "run npm test", detail: "",
            spokenPreamble: String(repeating: "context ", count: 40)
        )
        let prompt = controller.promptText(for: request)
        XCTAssertTrue(prompt.contains("context context"))
        XCTAssertTrue(prompt.contains("…"), "an over-long preamble is truncated, not spoken")
        XCTAssertTrue(prompt.hasSuffix("run npm test. Approve?"))
        XCTAssertLessThan(prompt.count, 180)
    }

    /// RA5: the summary an adapter already sends is spoken, without a model anywhere near
    /// it — but only for a host that asked for spoken summaries.
    func testNotificationSpeaksItsSummaryWhenEnabled() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ScriptedArbiter([]),
            presenter: DefaultApprovalRequestPresenter(speaksNotificationSummary: true)
        )
        XCTAssertEqual(
            controller.notificationText(for: AgentNotification(
                sessionID: "s", kind: .waitingForInput,
                summary: "Needs a decision on the retry policy"
            )),
            "The agent is waiting: Needs a decision on the retry policy."
        )
        XCTAssertEqual(
            controller.notificationText(for: AgentNotification(
                sessionID: "s", kind: .finished,
                summary: "Rewrote the importer and its tests"
            )),
            "The agent finished: Rewrote the importer and its tests."
        )
    }

    func testNotificationWithoutSummaryIsUnchangedWhenEnabled() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ScriptedArbiter([]),
            presenter: DefaultApprovalRequestPresenter(speaksNotificationSummary: true)
        )
        XCTAssertEqual(
            controller.notificationText(for: AgentNotification(
                sessionID: "s", kind: .waitingForInput
            )),
            "The agent is waiting."
        )
        XCTAssertEqual(
            controller.notificationText(for: AgentNotification(
                sessionID: "s", kind: .permissionWaiting, summary: "  "
            )),
            "The agent needs approval."
        )
    }

    func testSpokenNotificationSummaryIsBounded() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ScriptedArbiter([]),
            presenter: DefaultApprovalRequestPresenter(speaksNotificationSummary: true)
        )
        let text = controller.notificationText(for: AgentNotification(
            sessionID: "s", kind: .waitingForInput,
            summary: String(repeating: "word ", count: 40)
        ))
        XCTAssertTrue(text.hasPrefix("The agent is waiting: word word"))
        XCTAssertTrue(text.hasSuffix("…"))
        XCTAssertLessThanOrEqual(text.count, 96 + "The agent is waiting: ".count)
    }
}
