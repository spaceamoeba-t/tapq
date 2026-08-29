import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Who may end a voice session, once a model resolves intent.
///
/// Ratified 2026-08-28, during live no-AirPods testing: no spoken input may end the voice
/// session on the realtime path. A transcript fragment matched `command=no`, arrived as
/// `.deny`, and ended a session mid-test — and negation words occur constantly in ordinary
/// speech and in dictation, so the fix is not a better rule about "no" but removing voice
/// from the set of things that can end the channel.
///
/// What is left is what was never voice: the session budget, a gesture, a tap, and shutting
/// the runtime down. The first and the last are the caller's; the two in the middle are
/// asserted here.
@MainActor
final class VoiceSessionEndPolicyTests: XCTestCase {
    @MainActor
    private final class FakeSpeech: SpeechPresenting {
        var spoken: [String] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append(text)
            onFinish?()
        }
        func stopAll() {}
    }

    /// An arbiter that reports the channel each input came from, which is the fact the
    /// policy turns on: the same `.deny` ends a session from a shake and does not from a
    /// spoken word.
    @MainActor
    private final class ChannelArbiter: InputArbitrating {
        private let script: [ResolvedInput?]
        private(set) var calls = 0
        init(_ script: [ResolvedInput?]) { self.script = script }

        func listen(timeout: TimeInterval) async -> InputIntent? {
            await listenForInput(timeout: timeout)?.intent
        }

        func listenForInput(timeout: TimeInterval) async -> ResolvedInput? {
            defer { calls += 1 }
            return calls < script.count ? script[calls] : nil
        }
    }

    private func window(_ script: [ResolvedInput?],
                        speech: FakeSpeech,
                        voiceMayEndSession: Bool) -> CommandWindowController {
        CommandWindowController(
            speech: speech,
            arbiter: ChannelArbiter(script),
            gate: InteractionGate(),
            cue: CommandWindowController.voiceSessionCue,
            agentDisplayName: "Claude Code",
            instructionCapability: { true },
            wearerAttribution: { true },
            instructionEnqueue: { _ in .queued },
            kind: .voiceSession,
            voiceMayEndSession: voiceMayEndSession
        )
    }

    // MARK: - Voice can no longer end it

    /// The exact defect, as a test. "No" spoken into a held boundary used to end the whole
    /// mode; now it is an intent about a request that does not exist, and the window says so
    /// and keeps listening.
    func testASpokenDenyNoLongerEndsTheSession() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [ResolvedInput(intent: .deny, channel: .voice)],
            speech: speech, voiceMayEndSession: false
        ).run()

        XCTAssertFalse(outcome.endedByWearer)
        XCTAssertEqual(outcome.ignored, 1, "it is an intent about nothing, not an ending")
        XCTAssertFalse(speech.spoken.contains(CommandWindowController.voiceSessionEnded))
    }

    /// The phrase list is a transcript matched against fixed sentences, which is precisely
    /// what a model-resolved session does not do. There is no tool that ends a session, so
    /// these sentences are dictation like any others.
    func testTheEndPhrasesNoLongerEndTheSession() async {
        for phrase in ["stop listening", "end voice session", "end the voice session"] {
            let speech = FakeSpeech()
            let outcome = await window(
                [ResolvedInput(intent: .freeform(phrase), channel: .voice)],
                speech: speech, voiceMayEndSession: false
            ).run()

            XCTAssertFalse(outcome.endedByWearer, "'\(phrase)' ended the session")
            XCTAssertEqual(outcome.dictations, 1,
                           "'\(phrase)' is a sentence like any other now")
        }
    }

    // MARK: - What still ends it

    /// A shake is not speech. The policy narrows the voice channel and nothing else, which is
    /// why the loop reads provenance rather than the intent alone.
    func testAGestureStillEndsTheSession() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [ResolvedInput(intent: .deny, channel: .gesture)],
            speech: speech, voiceMayEndSession: false
        ).run()

        XCTAssertTrue(outcome.endedByWearer)
        XCTAssertTrue(speech.spoken.contains(CommandWindowController.voiceSessionEnded))
    }

    /// An arbiter that cannot say where an input came from is treated as not-voice. The fail
    /// direction is safe: ending a held boundary resolves nothing and approves nothing — it
    /// is what the agent's own Stop event would have done unheld.
    func testAnArbiterWithNoProvenanceStillEndsTheSession() async {
        let speech = FakeSpeech()
        let outcome = await window(
            [ResolvedInput(intent: .deny)],
            speech: speech, voiceMayEndSession: false
        ).run()

        XCTAssertTrue(outcome.endedByWearer)
    }

    // MARK: - The Apple path is untouched

    /// Every assertion above, inverted, on the path that still has a grammar. The Apple
    /// backend has no model to reason with, so its transcript rules — including the end
    /// phrases — are exactly what they were.
    func testTheGrammarPathKeepsBothSpokenEndings() async {
        let byDeny = await window(
            [ResolvedInput(intent: .deny, channel: .voice)],
            speech: FakeSpeech(), voiceMayEndSession: true
        ).run()
        XCTAssertTrue(byDeny.endedByWearer)

        let byPhrase = await window(
            [ResolvedInput(intent: .freeform("stop listening"), channel: .voice)],
            speech: FakeSpeech(), voiceMayEndSession: true
        ).run()
        XCTAssertTrue(byPhrase.endedByWearer)
    }

    /// An attention window never ends anything, on either path. `endedByWearer` is documented
    /// as always false for `.attention`, and the policy flag does not change that.
    func testAnAttentionWindowNeverEndsBySpokenDeny() async {
        let controller = CommandWindowController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([ResolvedInput(intent: .deny, channel: .voice)]),
            gate: InteractionGate(),
            kind: .attention,
            voiceMayEndSession: true
        )
        let outcome = await controller.run()

        XCTAssertFalse(outcome.endedByWearer)
    }
}
