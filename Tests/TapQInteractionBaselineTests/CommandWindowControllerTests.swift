import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The attention window: what the wearer can get out of it, and — the point of the whole
/// type — what they structurally cannot.
@MainActor
final class CommandWindowControllerTests: XCTestCase {
    @MainActor
    final class FakeSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    /// A virtual clock the arbiter advances, so a fixed eight-second deadline is tested in
    /// microseconds instead of raced against CI preemption.
    @MainActor
    final class VirtualClock {
        var instant = ContinuousClock.now
        func advance(_ seconds: TimeInterval) { instant = instant + .seconds(seconds) }
    }

    @MainActor
    final class ScriptedArbiter: InputArbitrating {
        private let script: [InputIntent?]
        /// Returned forever once the script runs out, when set. `nil` ends the window.
        private let thereafter: InputIntent?
        private let clock: VirtualClock?
        private let advance: TimeInterval
        private(set) var calls = 0
        private(set) var timeouts: [TimeInterval] = []

        init(_ script: [InputIntent?], thereafter: InputIntent? = nil,
             clock: VirtualClock? = nil, advance: TimeInterval = 0) {
            self.script = script
            self.thereafter = thereafter
            self.clock = clock
            self.advance = advance
        }

        func listen(timeout: TimeInterval) async -> InputIntent? {
            timeouts.append(timeout)
            defer {
                calls += 1
                if advance > 0 { clock?.advance(advance) }
            }
            return calls < script.count ? script[calls] : thereafter
        }
    }

    /// Records the interleaving of listen windows, so gate serialization is an assertion
    /// about a sequence rather than about a stopwatch.
    @MainActor
    final class ProbeArbiter: InputArbitrating {
        var trace: [String] = []
        private var index = 0

        func listen(timeout: TimeInterval) async -> InputIntent? {
            index += 1
            let id = index
            trace.append("start-\(id)")
            for _ in 0..<4 { await Task.yield() }
            trace.append("end-\(id)")
            return nil
        }
    }

    private func controller(_ arbiter: InputArbitrating,
                            speech: FakeSpeech,
                            gate: InteractionGate? = nil,
                            clock: VirtualClock? = nil,
                            cue: String = CommandWindowController.defaultCue,
                            recall: RecallResponding? = nil,
                            capability: InstructionCapabilityChecking? = nil,
                            attribution: WearerAttributionQuerying? = nil,
                            enqueue: InstructionDictating? = nil) -> CommandWindowController {
        let controller = CommandWindowController(
            speech: speech, arbiter: arbiter, gate: gate ?? InteractionGate(), cue: cue,
            recallResponder: recall,
            instructionCapability: capability,
            wearerAttribution: attribution,
            instructionEnqueue: enqueue
        )
        if let clock { controller.now = { clock.instant } }
        return controller
    }

    // MARK: - It cannot resolve anything

    /// The type-level half of the claim. Every stored property is a count or the
    /// end-of-listening marker: there is no field an allow, a deny, or a chosen option
    /// could ride out on. `endedByWearer` is a `Bool` by design — a flag can say "stop
    /// re-opening windows", and nothing else; a payload could not be smuggled through it.
    func testOutcomeCannotCarryADecision() async {
        let outcome = CommandWindowOutcome(
            answers: 1, ignored: 2, dictations: 3, endedByWearer: true
        )
        let children = Array(Mirror(reflecting: outcome).children)
        XCTAssertEqual(children.count, 4)
        for child in children {
            if child.label == "endedByWearer" {
                XCTAssertTrue(child.value is Bool,
                              "endedByWearer must stay a bare flag — anything richer could carry a decision")
            } else {
                XCTAssertTrue(child.value is Int,
                              "\(child.label ?? "?") is not a count — the window may have grown a way to resolve something")
            }
        }
    }

    /// The behavioral half: the intents that resolve requests elsewhere resolve nothing
    /// here, and each one is answered out loud so the wearer is never left guessing.
    func testResolutionIntentsAreTurnedAway() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.allow, .deny, .select, .selectByNumber(2), nil])
        let outcome = await controller(arbiter, speech: speech).run()
        XCTAssertEqual(outcome, CommandWindowOutcome(ignored: 4))
        XCTAssertEqual(outcome.answers, 0)
        XCTAssertEqual(
            speech.spoken.filter { $0 == CommandWindowController.nothingWaiting }.count, 4
        )
    }

    /// The rest of the request-scoped vocabulary lands in the same place. "Details" about
    /// what, when nothing was asked.
    func testRequestScopedNavigationIsTurnedAwayToo() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.details, .deferToPrompt, .next, .previous, nil])
        let outcome = await controller(arbiter, speech: speech).run()
        XCTAssertEqual(outcome.ignored, 4)
        XCTAssertEqual(outcome.dictations, 0)
    }

    // MARK: - What it does accept

    func testCueOpensTheWindowAndSilenceClosesIt() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([nil])
        let outcome = await controller(arbiter, speech: speech).run()
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(speech.spoken, ["Yes?"])
        XCTAssertEqual(arbiter.calls, 1)
    }

    func testTheCueIsInjected() async {
        let speech = FakeSpeech()
        let outcome = await controller(ScriptedArbiter([nil]), speech: speech,
                                       cue: "Go on.").run()
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(speech.spoken, ["Go on."])
    }

    func testStatusAndWhatChangedAreAnswered() async {
        let speech = FakeSpeech()
        var asked: [String] = []
        let arbiter = ScriptedArbiter([.status, .whatChanged, nil])
        let outcome = await controller(arbiter, speech: speech, recall: { intent in
            asked.append("\(intent)")
            return intent == .status ? "Nothing waiting." : "Allowed run npm test."
        }).run()
        XCTAssertEqual(outcome.answers, 2)
        XCTAssertEqual(outcome.ignored, 0)
        XCTAssertEqual(asked, ["status", "whatChanged"])
        XCTAssertEqual(speech.spoken, ["Yes?", "Nothing waiting.", "Allowed run npm test."])
    }

    /// No responder is still an answer. Silence is indistinguishable from a misheard
    /// question to someone with no screen.
    func testRecallWithoutAResponderSaysSo() async {
        let speech = FakeSpeech()
        let outcome = await controller(ScriptedArbiter([.status, nil]), speech: speech).run()
        XCTAssertEqual(outcome.answers, 1)
        XCTAssertTrue(speech.spoken.contains(SpokenRecall.nothingRecorded))
    }

    func testRepeatRepeatsTheLastThingSaid() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.status, .repeatRequest, nil])
        let outcome = await controller(arbiter, speech: speech,
                                       recall: { _ in "Claude Code is waiting." }).run()
        XCTAssertEqual(outcome.answers, 2)
        XCTAssertEqual(speech.spoken,
                       ["Yes?", "Claude Code is waiting.", "Claude Code is waiting."])
    }

    /// Nothing said yet but the cue: "repeat" is a question about what happened before the
    /// window opened, and only the responder knows.
    func testRepeatBeforeAnythingIsSaidAsksTheResponder() async {
        let speech = FakeSpeech()
        var asked: [String] = []
        let arbiter = ScriptedArbiter([.repeatRequest, nil])
        _ = await controller(arbiter, speech: speech, recall: { intent in
            asked.append("\(intent)")
            return "Allowed run npm test."
        }).run()
        XCTAssertEqual(asked, ["repeatRequest"])
        XCTAssertEqual(speech.spoken, ["Yes?", "Allowed run npm test."])
    }

    /// Free text with nothing to answer it: ignored without a sound, so a recognizer that
    /// overheard the room does not make TapQ talk back at it.
    func testFreeformIsIgnoredInSilence() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.freeform("the weather is nice"), nil])
        let outcome = await controller(arbiter, speech: speech).run()
        XCTAssertTrue(outcome.isEmpty)
        XCTAssertEqual(speech.spoken, ["Yes?"])
    }

    // MARK: - Dictation

    func testDictationQueuesAnInstruction() async {
        let speech = FakeSpeech()
        var queued: [String] = []
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests again"), .allow, nil])
        let outcome = await controller(
            arbiter, speech: speech,
            capability: { true }, attribution: { true },
            enqueue: { queued.append($0) }
        ).run()
        XCTAssertEqual(queued, ["run the tests again"])
        XCTAssertEqual(outcome.dictations, 1)
        XCTAssertEqual(outcome.ignored, 0, "the confirming yes belongs to the dictation, not the window")
        XCTAssertTrue(speech.spoken.contains("Queued for the agent."))
    }

    /// Nowhere for an instruction to go is how dictation stays inert: heard, and nothing
    /// said about it.
    func testDictationIsInertWithoutAnEnqueue() async {
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([.beginInstruction("run the tests"), nil])
        let outcome = await controller(arbiter, speech: speech,
                                       capability: { true }, attribution: { true }).run()
        XCTAssertEqual(outcome.dictations, 1)
        XCTAssertEqual(speech.spoken, ["Yes?"])
    }

    /// Fail-closed, exactly as inside an approval window: an attention window is not a
    /// looser door into the agent's inbox.
    func testDictationRefusesUnattributedSpeech() async {
        let speech = FakeSpeech()
        var queued: [String] = []
        let arbiter = ScriptedArbiter([.beginInstruction("delete the branch"), nil])
        _ = await controller(arbiter, speech: speech,
                             capability: { true }, attribution: { false },
                             enqueue: { queued.append($0) }).run()
        XCTAssertTrue(queued.isEmpty)
        XCTAssertTrue(speech.spoken.contains(InstructionDictation.unattributedRefusal))
    }

    // MARK: - The window is short and bounded

    func testTheWindowIsFixedAtEightSeconds() async {
        XCTAssertEqual(CommandWindowController.windowSeconds, 8)
        XCTAssertNotEqual(CommandWindowController.windowSeconds, InteractionBudget.total)
        XCTAssertNotEqual(CommandWindowController.windowSeconds,
                          InteractionBudget.maxListenWindow)
        let clock = VirtualClock()
        let arbiter = ScriptedArbiter([nil], clock: clock)
        _ = await controller(arbiter, speech: FakeSpeech(), clock: clock).run()
        XCTAssertEqual(arbiter.timeouts, [8])
    }

    /// The deadline is the bound, and it shrinks: three turns of three seconds each is all
    /// eight seconds buys, however much the wearer keeps saying.
    func testTheDeadlineEndsTheWindowMidConversation() async {
        let clock = VirtualClock()
        let speech = FakeSpeech()
        let arbiter = ScriptedArbiter([], thereafter: .status, clock: clock, advance: 3)
        let outcome = await controller(arbiter, speech: speech, clock: clock,
                                       recall: { _ in "Nothing waiting." }).run()
        XCTAssertEqual(outcome.answers, 3)
        XCTAssertEqual(arbiter.timeouts, [8, 5, 2])
        XCTAssertEqual(speech.spoken.last, "Nothing waiting.",
                       "the last answer is spoken even though no listen follows it")
    }

    /// The backstop the deadline cannot see: intents arriving faster than the clock moves.
    func testAChatteringRecognizerIsBoundedByTheTurnCap() async {
        let clock = VirtualClock()
        let arbiter = ScriptedArbiter([], thereafter: .status, clock: clock)
        let outcome = await controller(arbiter, speech: FakeSpeech(), clock: clock,
                                       recall: { _ in "Nothing waiting." }).run()
        XCTAssertEqual(outcome.answers, CommandWindowController.maxTurns)
    }

    // MARK: - Serialization

    /// Two attention windows on one gate take turns. The same gate holds the agent
    /// windows, which is why "nothing is waiting" is true by construction rather than by
    /// luck.
    func testWindowsAreSerializedByTheSharedGate() async {
        let gate = InteractionGate()
        let probe = ProbeArbiter()
        let first = controller(probe, speech: FakeSpeech(), gate: gate)
        let second = controller(probe, speech: FakeSpeech(), gate: gate)
        async let a = first.run()
        async let b = second.run()
        _ = await (a, b)
        XCTAssertEqual(probe.trace, ["start-1", "end-1", "start-2", "end-2"])
    }
}
