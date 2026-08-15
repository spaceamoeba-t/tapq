import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Dictation inside an approval window. Two claims run through every test here: an
/// instruction reaches the queue only after the wearer heard it read back and confirmed
/// it, and nothing that happens inside the flow can decide the request the window was
/// opened for.
@MainActor
final class InstructionDictationTests: XCTestCase {
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

        func fields(of name: String) -> [[String: String]] {
            lock.lock()
            defer { lock.unlock() }
            return storage.filter { $0.name == name }.map(\.fields)
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
    final class ScriptedArbiter: InputArbitrating {
        private let script: [InputIntent?]
        private(set) var calls = 0
        init(_ script: [InputIntent?]) { self.script = script }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    /// Collects what the runtime would have queued.
    @MainActor
    final class Inbox {
        var queued: [String] = []
        var enqueue: InstructionDictating { { [self] text in queued.append(text) } }
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", agent: .claudeCode, toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    private func controller(
        _ script: [InputIntent?],
        speech: FakeSpeech? = nil,
        sink: RecordingSink = RecordingSink(),
        inbox: Inbox,
        capable: Bool = true,
        attributed: Bool = true
    ) -> (InteractionController, ScriptedArbiter) {
        let arbiter = ScriptedArbiter(script)
        let controller = InteractionController(
            speech: speech ?? FakeSpeech(), arbiter: arbiter, diagnosticSink: sink,
            instructionCapability: { capable },
            wearerAttribution: { attributed },
            instructionEnqueue: inbox.enqueue
        )
        return (controller, arbiter)
    }

    // MARK: - The whole cycle

    func testDictateConfirmQueueAndResume() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let (controller, arbiter) = self.controller(
            [.beginInstruction("run the tests again"), .allow, .allow],
            speech: speech, sink: sink, inbox: inbox
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["run the tests again"])
        XCTAssertTrue(speech.said(containing: "Instruction: 'run the tests again.'"),
                      "the wearer must hear what the agent is about to be told")
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code."))
        XCTAssertEqual(decision, .allow,
                       "the window resumed where it was and the third input answered it")
        XCTAssertEqual(arbiter.calls, 3)
        XCTAssertTrue(sink.names.contains("instruction.queued"))
    }

    /// The load-bearing separation: the "yes" that confirms a read-back is spent inside the
    /// flow. If it leaked into the allow path this request would have been approved, and
    /// the deny that follows would never have been reached.
    func testConfirmationDoesNotApproveTheRequest() async {
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction("open a pull request"), .allow, .deny], inbox: inbox
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .deny)
        XCTAssertEqual(inbox.queued, ["open a pull request"])
    }

    /// Opening the flow with no text: the wearer is cued, and the next free-form turn is
    /// taken as the instruction rather than offered to Q&A.
    func testWindowedCaptureAfterTheCue() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        var questionsOffered = 0
        let arbiter = ScriptedArbiter([.beginInstruction(nil),
                                       .freeform("what is left to do?"),
                                       .allow, .deny])
        let controller = InteractionController(
            speech: speech, arbiter: arbiter,
            freeformResponder: { _ in
                questionsOffered += 1
                return true
            },
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue
        )
        let decision = await controller.resolve(request())

        XCTAssertTrue(speech.said(containing: "Go ahead."))
        XCTAssertEqual(inbox.queued, ["what is left to do?"],
                       "inside the flow, free text is the instruction")
        XCTAssertEqual(questionsOffered, 0, "and is never also asked as a question")
        XCTAssertEqual(decision, .deny)
    }

    /// A transcript that arrives as newlines and padding is queued and read back as one
    /// spoken line.
    func testDictatedTextIsCollapsedToOneLine() async {
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction("  run the tests\n  then push  "), .allow, .deny], inbox: inbox
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(inbox.queued, ["run the tests then push"])
    }

    // MARK: - Refusals and discards

    func testDeclinedReadBackQueuesNothingAndKeepsTheWindow() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction("delete the branch"), .deny, .allow],
            speech: speech, sink: sink, inbox: inbox
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [], "a declined read-back sends nothing")
        XCTAssertTrue(speech.said(containing: "Instruction discarded."))
        XCTAssertEqual(decision, .allow,
                       "and declining the instruction did not deny the request")
        XCTAssertEqual(sink.fields(of: "instruction.discarded").map { $0["reason"] },
                       ["declined"])
    }

    /// A matched command is not free text. The wearer hears the discard and can dictate the
    /// same sentence with "tell it to …", which captures it whole.
    func testCommandDuringCaptureDiscardsTheDictation() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction(nil), .repeatRequest, .allow], speech: speech, inbox: inbox
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "Instruction discarded."))
        XCTAssertEqual(decision, .allow)
    }

    /// Silence discards and hands the window back; the window itself ends the way it always
    /// has, on the caller's own next listen.
    func testSilenceDuringDictationDiscardsAndDefers() async {
        let sink = RecordingSink()
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction("ship it"), nil], sink: sink, inbox: inbox
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(decision, .ask)
        XCTAssertEqual(sink.fields(of: "instruction.discarded").map { $0["reason"] },
                       ["silence"])
    }

    // MARK: - Fail closed

    /// The inverse of the approval gate: an instruction that cannot be attributed to the
    /// wearer is refused out loud, and no text is captured at all.
    func testUnattributedDictationIsRefused() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let (controller, arbiter) = self.controller(
            [.beginInstruction("wire me money"), .allow],
            speech: speech, sink: sink, inbox: inbox, attributed: false
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "I can't confirm that was you"))
        XCTAssertEqual(sink.fields(of: "instruction.rejected_unattributed").map { $0["stage"] },
                       ["begin"])
        XCTAssertEqual(decision, .allow, "the refusal did not end the window")
        XCTAssertEqual(arbiter.calls, 2)
    }

    /// Attribution is asked again for the dictated sentence: the wearer opening the flow
    /// does not make the next voice in the room theirs.
    func testAttributionIsRecheckedForTheCapturedText() async {
        let sink = RecordingSink()
        let inbox = Inbox()
        var answers = [true, false]
        let arbiter = ScriptedArbiter([.beginInstruction(nil), .freeform("push to main"), .allow])
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: arbiter, diagnosticSink: sink,
            instructionCapability: { true },
            wearerAttribution: { answers.isEmpty ? false : answers.removeFirst() },
            instructionEnqueue: inbox.enqueue
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(sink.fields(of: "instruction.rejected_unattributed").map { $0["stage"] },
                       ["text"])
    }

    /// No attribution closure at all is the same answer as a negative one. A runtime that
    /// cannot attribute speech has no business accepting dictation, and the default must
    /// not be the permissive one.
    func testMissingAttributionClosureRefuses() async {
        let inbox = Inbox()
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ScriptedArbiter([.beginInstruction("do it"), .allow]),
            instructionCapability: { true },
            instructionEnqueue: inbox.enqueue
        )
        _ = await controller.resolve(request())
        XCTAssertEqual(inbox.queued, [])
    }

    /// End to end against the real gate: an unavailable signal answers "no" on the
    /// instruction path, where the very same gate answers "yes" on the approval path.
    func testSignalUnavailableRefusesEvenThoughApprovalsFailOpen() async {
        let signal = UnavailableSignal()
        let gate = WearerGatedVoice(wrapping: SilentVoice(), signal: signal)
        let inbox = Inbox()
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ScriptedArbiter([.beginInstruction("rm -rf tmp"), .allow]),
            instructionCapability: { true },
            wearerAttribution: { gate.isWearerAttributedNow },
            instructionEnqueue: inbox.enqueue
        )
        let decision = await controller.resolve(request())

        XCTAssertFalse(gate.isWearerAttributedNow, "no signal, no instruction")
        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "I can't confirm that was you"))
        XCTAssertEqual(decision, .allow, "approvals still resolve the way they always did")
    }

    // MARK: - Capability and composition

    func testUnsupportedAgentIsRefusedByName() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let (controller, _) = self.controller(
            [.beginInstruction("run the tests"), .allow],
            speech: speech, sink: sink, inbox: inbox, capable: false
        )
        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "Instructions aren't supported for Claude Code."))
        XCTAssertTrue(sink.names.contains("instruction.unsupported_agent"))
        XCTAssertEqual(decision, .allow)
    }

    /// The flag-absent shape: no enqueue closure, so `.beginInstruction` is an intent the
    /// window does not know. Nothing is spoken, nothing is asked, and the window behaves
    /// exactly as it did before the grammar learned the phrase.
    func testDictationIsInertWhenNotComposed() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests"), .allow])
        let controller = InteractionController(speech: speech, arbiter: arbiter,
                                               diagnosticSink: sink)
        let decision = await controller.resolve(request())

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(speech.spoken, ["Claude Code: run npm test. Approve?"])
        XCTAssertEqual(arbiter.calls, 2)
        XCTAssertTrue(sink.names.allSatisfy { !$0.hasPrefix("instruction.") })
    }

    // MARK: - The window's clock

    /// Dictation borrows the window's remaining budget and never extends it: a flow that
    /// runs past the deadline ends where an unanswered prompt ends, at the screen.
    func testDictationDoesNotExtendTheDeadline() async {
        let clock = VirtualClock()
        let inbox = Inbox()
        let arbiter = ClockAdvancingArbiter(
            clock: clock,
            script: [.beginInstruction("run the tests"), .allow, .allow],
            secondsPerListen: 120
        )
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: arbiter,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue
        )
        controller.now = { clock.now }
        let deadline = clock.now + .seconds(200)

        let decision = await controller.resolve(request(), deadline: deadline)

        XCTAssertEqual(inbox.queued, ["run the tests"],
                       "the read-back was confirmed inside the budget")
        XCTAssertEqual(decision, .ask,
                       "and the two minutes it took still came out of the window")
        XCTAssertEqual(arbiter.calls, 2)
    }

    @MainActor
    final class VirtualClock {
        private(set) var now: ContinuousClock.Instant = .now
        func advance(by seconds: TimeInterval) { now = now.advanced(by: .seconds(seconds)) }
    }

    @MainActor
    final class ClockAdvancingArbiter: InputArbitrating {
        private let clock: VirtualClock
        private let script: [InputIntent?]
        private let secondsPerListen: TimeInterval
        private(set) var calls = 0
        init(clock: VirtualClock, script: [InputIntent?], secondsPerListen: TimeInterval) {
            self.clock = clock
            self.script = script
            self.secondsPerListen = secondsPerListen
        }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            clock.advance(by: secondsPerListen)
            return calls < script.count ? script[calls] : nil
        }
    }

    /// A wearer-speech signal that admits it cannot answer — a stopped motion stream, or
    /// AirPods in a case.
    @MainActor
    final class UnavailableSignal: WearerSpeechSignaling {
        var isWearerSpeaking = false
        var isSignalAvailable = false
        var onWearerSpeakingChange: (@MainActor (Bool) -> Void)?
    }

    @MainActor
    final class SilentVoice: VoiceCommandProviding {
        func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {}
        func stop() {}
    }
}
