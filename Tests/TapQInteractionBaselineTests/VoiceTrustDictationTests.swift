import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Rung E at the controller level: what `--voice-trust environment` changes about a
/// dictation, and — the larger half of the suite — everything it must leave alone.
///
/// Two claims run through it. An environment-trust run accepts the sentence a wearer-trust
/// run would have refused, and says in the diagnostics that it did. And nothing about an
/// *approval* moves: the cues, the confirmation channels, and the fail-open timeout are the
/// ones this repo has always had, because trust is a policy about instructions and an
/// instruction has never authorized anything.
@MainActor
final class VoiceTrustDictationTests: XCTestCase {
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
    private final class FakeSpeech: SpeechPresenting {
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
    private final class ScriptedArbiter: InputArbitrating {
        private let script: [InputIntent?]
        private(set) var calls = 0
        init(_ script: [InputIntent?]) { self.script = script }
        func listen(timeout: TimeInterval) async -> InputIntent? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    @MainActor
    private final class Inbox {
        var queued: [String] = []
        /// What the mailbox reports back. Default `.queued`; a test that exercises the
        /// drop-oldest read-back sets it to `.queuedDroppingOldest`.
        var outcome: InstructionQueueOutcome = .queued
        var enqueue: InstructionDictating {
            { [self] text in queued.append(text); return outcome }
        }
    }

    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "1", sessionID: "s1", agent: .claudeCode, toolName: "Bash",
                        summary: "run npm test", detail: "full detail")
    }

    private func controller(
        _ script: [InputIntent?],
        speech: FakeSpeech,
        sink: RecordingSink = RecordingSink(),
        inbox: Inbox,
        trust: VoiceTrust,
        gestures: GestureConfirmationQuerying? = nil
    ) -> InteractionController {
        InteractionController(
            speech: speech, arbiter: ScriptedArbiter(script), diagnosticSink: sink,
            instructionCapability: { true },
            // Deliberately the refusing answer everywhere in this file: it is what makes
            // "environment trust queued it anyway" mean something.
            wearerAttribution: { false },
            instructionEnqueue: inbox.enqueue,
            voiceTrust: trust,
            gestureConfirmation: gestures
        )
    }

    // MARK: - The bypass

    /// The rung: a dictation no attribution signal would have accepted reaches the queue,
    /// after the same read-back and the same spoken confirmation as always.
    func testEnvironmentTrustQueuesADictationAttributionWouldHaveRefused() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("run the tests again"), .allow, .deny],
            speech: speech, sink: sink, inbox: inbox, trust: .environment
        )

        let decision = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, ["run the tests again"])
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code."))
        XCTAssertEqual(decision, .deny,
                       "the confirming yes was spent inside the flow, as it always is")
    }

    /// The bypass is never silent: both stages the wearer-trust path would have checked
    /// record that trust was environmental instead, so a log can always say which posture
    /// a queued instruction was accepted under.
    func testTheBypassIsRecordedAtEveryStageAttributionWouldHaveChecked() async {
        let sink = RecordingSink()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("open a pull request"), .allow, .deny],
            speech: FakeSpeech(), sink: sink, inbox: inbox, trust: .environment
        )

        _ = await controller.resolve(request())

        XCTAssertEqual(sink.fields(of: "instruction.trusted_environment").map { $0["stage"] },
                       ["begin", "text"])
        XCTAssertFalse(sink.names.contains("instruction.rejected_unattributed"),
                       "there is nothing to reject when nothing was checked")
    }

    /// The regression guard for every default-flag run: the identical script under wearer
    /// trust is still refused out loud, and still queues nothing.
    func testWearerTrustStillRefusesTheSameDictation() async {
        let speech = FakeSpeech()
        let sink = RecordingSink()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("run the tests again"), .allow, .deny],
            speech: speech, sink: sink, inbox: inbox, trust: .wearer
        )

        _ = await controller.resolve(request())

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "I can't confirm that was you"))
        XCTAssertEqual(sink.fields(of: "instruction.rejected_unattributed").map { $0["stage"] },
                       ["begin"])
        XCTAssertFalse(sink.names.contains("instruction.trusted_environment"))
    }

    // MARK: - Read-back wording

    /// The default composition — every run before this rung — asks for the nod exactly as
    /// it always did.
    func testTheDefaultReadBackStillAsksForANod() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("ship it"), .allow, .deny],
            speech: speech, inbox: inbox, trust: .environment
        )

        _ = await controller.resolve(request())

        XCTAssertTrue(speech.said(containing: "Instruction: 'ship it.' Nod or say yes to queue it."),
                      "spoke: \(speech.spoken)")
    }

    /// With no earbuds there is no nod and no tap, and a read-back that asks for one is
    /// telling the wearer to do something that cannot resolve anything.
    func testTheReadBackNeverMentionsNoddingWhenNoddingIsImpossible() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("ship it"), .allow, .deny],
            speech: speech, inbox: inbox, trust: .environment, gestures: { false }
        )

        _ = await controller.resolve(request())

        XCTAssertTrue(speech.said(containing: "Instruction: 'ship it.' Say yes to queue it."),
                      "spoke: \(speech.spoken)")
        XCTAssertFalse(speech.spoken.contains { $0.contains("Nod") })
        XCTAssertEqual(inbox.queued, ["ship it"], "and the spoken yes still queues it")
    }

    /// AirPods that are in: the gesture half is offered again, because it works again.
    func testTheReadBackOffersTheNodWhileGesturesCanStillArrive() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.beginInstruction("ship it"), .allow, .deny],
            speech: speech, inbox: inbox, trust: .environment, gestures: { true }
        )

        _ = await controller.resolve(request())

        XCTAssertTrue(speech.said(containing: "Nod or say yes to queue it."))
    }

    // MARK: - Approvals are untouched

    /// The invariant this whole rung is written under. Trust says who may *instruct*; an
    /// escalated approval still collects two independent channels, and the cues that ask
    /// for them are the ones the repo already shipped.
    func testEnvironmentTrustChangesNothingAboutAnEscalatedApproval() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = self.controller(
            [.allow, .allow, nil], speech: speech, inbox: inbox, trust: .environment
        )

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice
        )

        XCTAssertEqual(decision, .ask,
                       "two provenance-free allows may not satisfy two channels")
        XCTAssertTrue(speech.said(containing: "Risky action. Say yes to confirm."))
        XCTAssertTrue(speech.said(containing: "Deferring to the screen."))
        XCTAssertEqual(inbox.queued, [])
    }

    /// And the ordinary approval still resolves on the first allow under either posture.
    func testEnvironmentTrustLeavesAStandardApprovalAlone() async {
        let inbox = Inbox()
        let controller = self.controller(
            [.allow], speech: FakeSpeech(), inbox: inbox, trust: .environment
        )
        let decision = await controller.resolve(request())
        XCTAssertEqual(decision, .allow)
    }
}
