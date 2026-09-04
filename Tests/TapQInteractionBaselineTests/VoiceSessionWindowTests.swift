import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// The waiting window (RH1): the attention window with two differences, and no third.
///
/// A wearer standing at a held turn boundary is there to say the agent's next instruction,
/// so an unmatched sentence is dictation rather than silence, and there is a way to say
/// they are done. Everything else — the grammar, the eight seconds, the refusal to resolve
/// anything, the read-back before anything is queued — is the window Rung D shipped, and
/// half of this file is the assertion that it still is.
@MainActor
final class VoiceSessionWindowTests: XCTestCase {
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

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        func first(_ name: String) -> TapQDiagnosticEvent? {
            lock.lock()
            defer { lock.unlock() }
            return storage.first { $0.name == name }
        }
    }

    @MainActor
    private final class Inbox {
        var queued: [String] = []
        var outcome: InstructionQueueOutcome = .queued
        var enqueue: InstructionDictating {
            { [self] text in queued.append(text); return outcome }
        }
    }

    private func window(
        _ script: [InputIntent?],
        speech: FakeSpeech,
        inbox: Inbox? = nil,
        kind: CommandWindowKind,
        cue: String? = CommandWindowController.voiceSessionCue
    ) -> CommandWindowController {
        CommandWindowController(
            speech: speech,
            arbiter: ScriptedArbiter(script),
            gate: InteractionGate(),
            cue: cue,
            agentDisplayName: "Claude Code",
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox?.enqueue,
            kind: kind
        )
    }

    // MARK: - The window is a minute, not eight seconds

    /// A held boundary re-opens its window the instant it closes, so the deadline here is
    /// the rotation period, not the end of listening. Eight seconds rotated it for nothing
    /// (2026-09-01: 92 rotations in one run); a minute makes a rotation rare and keeps a
    /// hung listen noticeable. The attention window is unchanged.
    func testAVoiceSessionWindowRunsForAMinute() async {
        let sink = RecordingSink()
        let speech = FakeSpeech()
        let controller = CommandWindowController(
            speech: speech,
            arbiter: ScriptedArbiter([nil]),
            gate: InteractionGate(),
            cue: nil,
            agentDisplayName: "Claude Code",
            diagnosticSink: sink,
            instructionCapability: { true },
            wearerAttribution: { true },
            kind: .voiceSession
        )
        _ = await controller.run()

        XCTAssertEqual(sink.first("window.opened")?.fields["seconds"],
                       "\(CommandWindowController.voiceSessionWindowSeconds)")
        XCTAssertEqual(CommandWindowController.voiceSessionWindowSeconds, 60)
    }

    // MARK: - An unmatched sentence is the instruction

    /// The rung, in one window: no prefix, a read-back, a spoken yes, and the sentence is in
    /// the queue that a held boundary drains.
    func testAnUnmatchedSentenceIsDictatedWithNoPrefix() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let outcome = await window(
            [.freeform("also update the changelog"), .allow],
            speech: speech, inbox: inbox, kind: .voiceSession
        ).run()

        XCTAssertEqual(inbox.queued, ["also update the changelog"])
        XCTAssertTrue(speech.said(containing: "Instruction: 'also update the changelog.'"),
                      "spoke: \(speech.spoken)")
        XCTAssertTrue(speech.said(containing: "Queued for Claude Code."))
        XCTAssertEqual(outcome.dictations, 1)
        XCTAssertFalse(outcome.endedByWearer)
    }

    /// Nothing is queued on the strength of a sentence alone. The read-back is the whole
    /// safety of dictating without a prefix, so a declined one sends nothing.
    func testADeclinedReadBackQueuesNothing() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        _ = await window(
            [.freeform("delete the branch"), .deny],
            speech: speech, inbox: inbox, kind: .voiceSession
        ).run()

        XCTAssertEqual(inbox.queued, [])
        XCTAssertTrue(speech.said(containing: "Instruction discarded."))
    }

    /// The Rung D window is untouched: an overheard sentence there is still ignored in
    /// silence, and nothing reaches the queue.
    func testAnAttentionWindowStillIgnoresUnmatchedSpeech() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let outcome = await window(
            [.freeform("also update the changelog"), .allow],
            speech: speech, inbox: inbox, kind: .attention,
            cue: CommandWindowController.defaultCue
        ).run()

        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(outcome.dictations, 0)
        XCTAssertFalse(speech.said(containing: "Instruction:"))
    }

    /// The prefixes did not go anywhere. They still open dictation, in either window.
    func testThePrefixStillWorksInsideAWaitingWindow() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        _ = await window(
            [.beginInstruction("run the tests again"), .allow],
            speech: speech, inbox: inbox, kind: .voiceSession
        ).run()

        XCTAssertEqual(inbox.queued, ["run the tests again"])
    }

    // MARK: - The grammar still answers

    func testGrammarCommandsAnswerAsTheyAlwaysHave() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let controller = CommandWindowController(
            speech: speech,
            arbiter: ScriptedArbiter([.status, nil]),
            gate: InteractionGate(),
            cue: CommandWindowController.voiceSessionCue,
            recallResponder: { _ in "Nothing is waiting." },
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            kind: .voiceSession
        )

        let outcome = await controller.run()

        XCTAssertEqual(outcome.answers, 1)
        XCTAssertEqual(inbox.queued, [], "a matched command is not a dictation")
        XCTAssertTrue(speech.said(containing: "Nothing is waiting."))
    }

    /// A waiting window is still a window that cannot resolve anything: "yes" with nothing
    /// on the table is answered, not acted on.
    func testAWaitingWindowStillCannotApproveAnything() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [.allow, .select, nil], speech: speech, kind: .voiceSession
        ).run()

        XCTAssertEqual(outcome.ignored, 2)
        XCTAssertFalse(outcome.endedByWearer)
        XCTAssertTrue(speech.said(containing: CommandWindowController.nothingWaiting))
    }

    // MARK: - Ending the session

    func testEveryEndPhraseClosesTheLoop() async {
        for phrase in CommandWindowController.endPhrases {
            let speech = FakeSpeech()
            let inbox = Inbox()
            let outcome = await window(
                [.freeform(phrase), .allow],
                speech: speech, inbox: inbox, kind: .voiceSession
            ).run()

            XCTAssertTrue(outcome.endedByWearer, "'\(phrase)' must end the session")
            XCTAssertEqual(inbox.queued, [], "'\(phrase)' is not an instruction")
            XCTAssertTrue(speech.said(containing: CommandWindowController.voiceSessionEnded))
        }
    }

    func testAnEndPhraseIsMatchedThroughPunctuationAndCasing() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [.freeform("End voice session."), nil], speech: speech, kind: .voiceSession
        ).run()
        XCTAssertTrue(outcome.endedByWearer)
    }

    /// "Stop", "no", "cancel" all arrive as a denial, and at a held boundary the only thing
    /// there is to decline is the holding.
    func testADenialEndsTheSession() async {
        let speech = FakeSpeech()
        let outcome = await window([.deny, .allow], speech: speech, kind: .voiceSession).run()

        XCTAssertTrue(outcome.endedByWearer)
        XCTAssertTrue(speech.said(containing: CommandWindowController.voiceSessionEnded))
    }

    /// The same denial in an attention window means what it always did: there is no request
    /// here to say no to.
    func testADenialInAnAttentionWindowIsStillJustIgnored() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [.deny, nil], speech: speech, kind: .attention,
            cue: CommandWindowController.defaultCue
        ).run()

        XCTAssertFalse(outcome.endedByWearer)
        XCTAssertEqual(outcome.ignored, 1)
        XCTAssertTrue(speech.said(containing: CommandWindowController.nothingWaiting))
    }

    /// A sentence that merely mentions the words is not the phrase: ending the session is
    /// an exact thing to say, so an instruction about it is still an instruction.
    func testASentenceAboutEndingIsStillDictated() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let outcome = await window(
            [.freeform("write a test for the end voice session path"), .allow],
            speech: speech, inbox: inbox, kind: .voiceSession
        ).run()

        XCTAssertFalse(outcome.endedByWearer)
        XCTAssertEqual(inbox.queued, ["write a test for the end voice session path"])
    }

    /// Ending stops the window there and then: nothing after it is heard, because there is
    /// nothing left to hear it for.
    func testTheWindowStopsListeningOnceTheSessionEnds() async {
        let speech = FakeSpeech()
        let inbox = Inbox()
        let arbiter = ScriptedArbiter([.freeform("stop listening"),
                                       .freeform("also update the changelog"), .allow])
        let controller = CommandWindowController(
            speech: speech, arbiter: arbiter, gate: InteractionGate(),
            cue: CommandWindowController.voiceSessionCue,
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: inbox.enqueue,
            kind: .voiceSession
        )

        let outcome = await controller.run()

        XCTAssertTrue(outcome.endedByWearer)
        XCTAssertEqual(inbox.queued, [])
        XCTAssertEqual(arbiter.calls, 1, "the loop ended with the phrase")
    }

    // MARK: - The cue

    /// The boundary announces itself once; a re-opened window listens in silence, because a
    /// window that said "Listening." every eight seconds would talk over the wearer.
    func testAReopenedWindowSaysNothing() async {
        let speech = FakeSpeech()
        _ = await window([nil], speech: speech, kind: .voiceSession, cue: nil).run()
        XCTAssertEqual(speech.spoken, [])
    }

    func testTheFirstWindowSpeaksTheListeningCue() async {
        let speech = FakeSpeech()
        _ = await window([nil], speech: speech, kind: .voiceSession).run()
        XCTAssertEqual(speech.spoken, [CommandWindowController.voiceSessionCue])
    }
}
