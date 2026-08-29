import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Dictation while a selection is open. The selection window has its own answer-shaped
/// input — the free-text read-back — so the claim under test is that dictating runs beside
/// it without ever choosing an option or ending the question.
@MainActor
final class SelectionInstructionTests: XCTestCase {
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
        func said(containing needle: String) -> Bool {
            spoken.contains { $0.contains(needle) }
        }
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

    @MainActor
    final class Inbox {
        var queued: [String] = []
        var outcome: InstructionQueueOutcome = .queued
        var enqueue: InstructionDictating {
            { [self] text in queued.append(text); return outcome }
        }
    }

    private func request() -> SelectionRequest {
        SelectionRequest(id: "s", sessionID: "s1", agent: .codex,
                         question: "Which branch?",
                         options: [SelectionOption(label: "main", description: ""),
                                   SelectionOption(label: "develop", description: "")])
    }

    /// The cursor is where the wearer left it, the option they then choose is the one they
    /// navigated to, and the "yes" that confirmed the read-back selected nothing.
    func testDictationLeavesTheSelectionExactlyWhereItWas() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.beginInstruction("rebase onto main"), .allow,
                                       .next, .select])
        let controller = SelectionController(
            speech: speech, arbiter: arbiter,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue
        )
        let result = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["rebase onto main"])
        XCTAssertTrue(speech.said(containing: "Queued for Codex."))
        XCTAssertEqual(result.choices.map(\.label), ["develop"],
                       "the confirmation was spent on the instruction, not on option 1")
    }

    /// The dictated sentence is captured by the flow, not mistaken for the free-text answer
    /// the selection window also accepts.
    func testCapturedTextIsNotTakenAsTheSelectionAnswer() async {
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.beginInstruction(nil), .freeform("use the release branch"),
                                       .allow, .select])
        let controller = SelectionController(
            speech: FakeSpeech(), arbiter: arbiter,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue
        )
        let result = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["use the release branch"])
        XCTAssertEqual(result.freeText, nil, "the sentence went to the agent, not to the answer")
        XCTAssertEqual(result.choices.map(\.label), ["main"])
    }

    func testUnattributedDictationIsRefusedAndTheQuestionStands() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.beginInstruction("force push"), .select])
        let controller = SelectionController(
            speech: speech, arbiter: arbiter, diagnosticSink: sink,
            instructionCapability: { true },
            wearerAttribution: { false },
            instructionEnqueue: inbox.enqueue
        )
        let result = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "I can't confirm that was you"))
        XCTAssertTrue(sink.names.contains("instruction.rejected_unattributed"))
        XCTAssertEqual(result.choices.map(\.label), ["main"])
    }

    func testUnsupportedAgentIsRefusedByName() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests"), .select])
        let controller = SelectionController(
            speech: speech, arbiter: arbiter,
            instructionCapability: { false },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue
        )
        _ = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "Instructions aren't supported for Codex."))
    }

    /// Flag absent: the selection window has no mailbox to dictate into, refuses out loud,
    /// and keeps asking its question. The refusal resolves nothing — the list is still the
    /// wearer's to choose from — which is the same guarantee every dictation exit has.
    ///
    /// Asserted here as well as in the approval window because the two windows run the same
    /// flow and must never drift into refusing on different terms.
    func testDictationRefusesOutLoudWhenNoMailboxIsComposed() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests"), .select])
        let controller = SelectionController(speech: speech, arbiter: arbiter)
        let result = await controller.resolve(request())

        XCTAssertEqual(result.choices.map(\.label), ["main"])
        XCTAssertEqual(speech.spoken.count, 2,
                       "the question, then the refusal: \(speech.spoken)")
        XCTAssertTrue(speech.said(containing: InstructionDictation.noMailboxRefusal))
        XCTAssertEqual(arbiter.calls, 2)
    }
}
