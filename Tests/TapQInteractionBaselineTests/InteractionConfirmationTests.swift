import XCTest
@testable import TapQInteractionBaseline
import TapQContracts

/// Risk-escalated confirmation in the approval loop.
///
/// The safety shape under test is one-directional: an escalated requirement can only
/// withhold an approval that `.standard` would have granted. It never grants one
/// `.standard` would have withheld, never delays or weakens a deny, and never turns an
/// unanswered request into anything but the `.ask` an unanswered request produces today.
@MainActor
final class InteractionConfirmationTests: XCTestCase {
    @MainActor
    final class FakeSpeech: SpeechPresenting {
        var spoken: [(text: String, priority: SpeechPriority)] = []
        func speak(_ text: String, priority: SpeechPriority, onFinish: (() -> Void)?) {
            spoken.append((text, priority))
            onFinish?()
        }
        func stopAll() {}
    }

    /// Reports provenance, like the real `InputArbiter`. Running off the end of the
    /// script is a timed-out window.
    @MainActor
    final class ChannelArbiter: InputArbitrating {
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

    /// Implements only `listen(timeout:)`, so it takes the protocol's provenance-free
    /// default — the shape every arbiter written before this packet has.
    @MainActor
    final class LegacyArbiter: InputArbitrating {
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
                        summary: "run rm -rf build", detail: "full detail")
    }

    private func gesture(_ intent: InputIntent) -> ResolvedInput {
        ResolvedInput(intent: intent, channel: .gesture)
    }

    private func voice(_ intent: InputIntent) -> ResolvedInput {
        ResolvedInput(intent: intent, channel: .voice)
    }

    private func cueCount(_ speech: FakeSpeech) -> Int {
        speech.spoken.filter { $0.text.contains("Risky action.") }.count
    }

    // MARK: - Standard is unchanged

    func testStandardRequirementIsTheDefaultAndResolvesOnTheFirstAllow() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ChannelArbiter([gesture(.allow)]))

        let decision = await controller.resolve(request())

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(cueCount(speech), 0, "standard never arms and never speaks a cue")
    }

    func testExplicitStandardMatchesTheDefault() async {
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ChannelArbiter([gesture(.allow)]))
        let decision = await controller.resolve(request(), requiredConfirmation: .standard)
        XCTAssertEqual(decision, .allow)
    }

    // MARK: - doubleGesture

    func testDoubleGestureRequiresTwoAllows() async {
        let speech = FakeSpeech()
        let arbiter = ChannelArbiter([gesture(.allow), gesture(.allow)])
        let controller = InteractionController(speech: speech, arbiter: arbiter)

        let decision = await controller.resolve(
            request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(arbiter.calls, 2, "the first allow armed rather than resolved")
    }

    func testDoubleGestureSpeaksTheArmingCueExactlyOnce() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ChannelArbiter([gesture(.allow), gesture(.allow)]))

        _ = await controller.resolve(request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(cueCount(speech), 1)
        XCTAssertTrue(speech.spoken.contains {
            $0.text == "Risky action. Approve again to confirm."
        })
    }

    func testSingleAllowThenTimeoutFallsThroughToTodaysTimeoutOutcome() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ChannelArbiter([gesture(.allow), nil]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(decision, .ask, "an armed request that is never confirmed is unanswered")
        XCTAssertTrue(speech.spoken.contains { $0.text.contains("screen") },
                      "the ordinary deferral notice, exactly as a plain timeout produces")
    }

    func testArmingSurvivesRepeatAndDetailsWithoutApproving() async {
        let arbiter = ChannelArbiter([
            gesture(.allow), .init(intent: .repeatRequest), .init(intent: .details), nil,
        ])
        let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)

        let decision = await controller.resolve(
            request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(decision, .ask, "re-speaking never stands in for the second allow")
    }

    func testDoubleGestureIsSatisfiedByArbitersThatDoNotReportProvenance() async {
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: LegacyArbiter([.allow, .allow]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(decision, .allow,
                       "doubling is about repetition, not about which channel repeated")
    }

    // MARK: - gestureAndVoice

    func testGestureThenVoiceCompletesGestureAndVoice() async {
        let arbiter = ChannelArbiter([gesture(.allow), gesture(.allow), voice(.allow)])
        let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .allow)
        XCTAssertEqual(arbiter.calls, 3,
                       "the second head movement did not complete the requirement")
    }

    func testVoiceThenGestureCompletesGestureAndVoice() async {
        let arbiter = ChannelArbiter([voice(.allow), gesture(.allow)])
        let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .allow, "either order satisfies two independent channels")
        XCTAssertEqual(arbiter.calls, 2)
    }

    func testTapThenVoiceCompletesGestureAndVoice() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([.init(intent: .allow, channel: .tap), voice(.allow)]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .allow, "a tap is the non-speech half")
    }

    /// The reason the requirement is defined as two channel *families*: repeated speech
    /// is one source of error, not two. A podcast, a conversation, or one misheard phrase
    /// heard twice must not clear the strongest rung on the ladder.
    func testRepeatedVoiceAllowsNeverCompleteGestureAndVoice() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([voice(.allow), voice(.allow), voice(.allow), nil]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .ask)
    }

    func testTheArmingCueNamesTheMissingChannel() async {
        let armedByGesture = FakeSpeech()
        _ = await InteractionController(
            speech: armedByGesture, arbiter: ChannelArbiter([gesture(.allow), nil])
        ).resolve(request(), requiredConfirmation: .gestureAndVoice)
        XCTAssertTrue(armedByGesture.spoken.contains {
            $0.text == "Risky action. Say yes to confirm."
        })
        XCTAssertFalse(armedByGesture.spoken.contains { $0.text.contains("Nod or tap") })

        let armedByVoice = FakeSpeech()
        _ = await InteractionController(
            speech: armedByVoice, arbiter: ChannelArbiter([voice(.allow), nil])
        ).resolve(request(), requiredConfirmation: .gestureAndVoice)
        XCTAssertTrue(armedByVoice.spoken.contains {
            $0.text == "Risky action. Nod or tap to confirm."
        })
        XCTAssertFalse(armedByVoice.spoken.contains { $0.text.contains("Say yes") })
    }

    func testGestureOnlyAllowsNeverCompleteGestureAndVoice() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([gesture(.allow), gesture(.allow), gesture(.allow), nil]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .ask)
    }

    func testTapChannelDoesNotStandInForVoice() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([
                gesture(.allow), .init(intent: .allow, channel: .tap), nil,
            ]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .ask)
    }

    func testUnreportedProvenanceNeverCompletesGestureAndVoice() async {
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: LegacyArbiter([.allow, .allow, .allow, nil]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .ask,
                       "an input that cannot say where it came from cannot prove two channels agreed")
    }

    func testGestureAndVoiceSpeaksItsCueWhenArming() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ChannelArbiter([gesture(.allow), voice(.allow)]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .allow)
        XCTAssertTrue(speech.spoken.contains {
            $0.text == "Risky action. Say yes to confirm."
        })
    }

    func testVoiceAllowAloneDoesNotApproveAGestureAndVoiceRequest() async {
        let controller = InteractionController(
            speech: FakeSpeech(), arbiter: ChannelArbiter([voice(.allow), nil]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .gestureAndVoice)

        XCTAssertEqual(decision, .ask, "one misheard phrase must not approve on its own")
    }

    // MARK: - Deny is never gated

    func testDenyIsImmediateInEveryRequirementAndEveryArmedState() async {
        let channels: [InputChannel] = [.gesture, .voice, .tap, .unspecified]
        for requirement in RequiredConfirmation.allCases {
            for channel in channels {
                let controller = InteractionController(
                    speech: FakeSpeech(),
                    arbiter: ChannelArbiter([.init(intent: .deny, channel: channel)]))
                let decision = await controller.resolve(
                    request(), requiredConfirmation: requirement)
                XCTAssertEqual(decision, .deny, "\(requirement) unarmed via \(channel)")
            }
        }

        // `.standard` has no armed state — its first allow already resolved — so the
        // armed case is only meaningful for the requirements that hold an allow back.
        for requirement in [RequiredConfirmation.doubleGesture, .gestureAndVoice] {
            for channel in channels {
                let arbiter = ChannelArbiter([
                    gesture(.allow), .init(intent: .deny, channel: channel),
                ])
                let controller = InteractionController(speech: FakeSpeech(), arbiter: arbiter)
                let decision = await controller.resolve(
                    request(), requiredConfirmation: requirement)
                XCTAssertEqual(decision, .deny, "\(requirement) armed via \(channel)")
                XCTAssertEqual(arbiter.calls, 2, "deny resolved on the input that carried it")
            }
        }
    }

    func testSkipStillDefersToThePromptWhileArmed() async {
        let controller = InteractionController(
            speech: FakeSpeech(),
            arbiter: ChannelArbiter([gesture(.allow), .init(intent: .deferToPrompt)]))

        let decision = await controller.resolve(
            request(), requiredConfirmation: .doubleGesture)

        XCTAssertEqual(decision, .ask)
    }

    // MARK: - Escalation cannot manufacture an approval

    func testNoEscalatedRequirementEverApprovesWithoutASecondQualifyingAllow() async {
        let scripts: [[ResolvedInput?]] = [
            [],
            [nil],
            [gesture(.allow)],
            [gesture(.allow), nil],
            [gesture(.allow), .init(intent: .repeatRequest), nil],
            [gesture(.allow), .init(intent: .next), .init(intent: .previous), nil],
        ]
        for requirement in [RequiredConfirmation.doubleGesture, .gestureAndVoice] {
            for script in scripts {
                let controller = InteractionController(
                    speech: FakeSpeech(), arbiter: ChannelArbiter(script))
                let decision = await controller.resolve(
                    request(), requiredConfirmation: requirement)
                XCTAssertNotEqual(decision, .allow, "\(requirement) with \(script.count) inputs")
                XCTAssertEqual(decision, .ask)
            }
        }
    }

    func testExpiredBudgetStaysSilentAndAsksEvenWhenEscalated() async {
        let speech = FakeSpeech()
        let controller = InteractionController(
            speech: speech, arbiter: ChannelArbiter([gesture(.allow), voice(.allow)]))

        let decision = await controller.resolve(
            request(),
            deadline: .now - .seconds(1),
            requiredConfirmation: .gestureAndVoice
        )

        XCTAssertEqual(decision, .ask)
        XCTAssertTrue(speech.spoken.isEmpty)
    }
}
