import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The safety suite for the caller half of the stage-2 contract.
///
/// Every test here is a fault injection: an absent model, an unsure one, one that answers
/// nonsense, one that never answers at all. The assertion is always the same shape — the
/// requirement that comes out is the deterministic one, or stronger, and never weaker.
/// Nothing a backend does can produce an approval, because nothing in this layer returns
/// a `Decision` at all.
final class ReasonerEscalationTests: XCTestCase {
    /// Returns whatever it was handed, including `nil` — the "cannot answer" case every
    /// failure mode collapses to.
    private struct StubReasoner: ContextReasoning {
        let decision: ReasonerDecision?
        func assess(_ context: ReasonerContext) async -> ReasonerDecision? { decision }
    }

    /// Never returns, and deliberately never observes cancellation: the outer bound has
    /// to hold whether or not the backend cooperates, which is the whole reason it is not
    /// implemented as a task group.
    private struct HangingReasoner: ContextReasoning {
        func assess(_ context: ReasonerContext) async -> ReasonerDecision? {
            await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    continuation.resume()
                }
            }
            return nil
        }
    }

    private let context = ReasonerContext(
        toolName: "Bash",
        commandText: "rm -rf ~/Documents",
        cwd: "/Users/dev",
        agentName: "Claude Code",
        summary: "run rm -rf ~/Documents"
    )

    private func decision(
        tier: RiskTier = .destructive,
        confirmation: RequiredConfirmation = .doubleGesture,
        confidence: Double = 0.9
    ) -> ReasonerDecision {
        ReasonerDecision(
            riskTier: tier,
            requiredConfirmation: confirmation,
            rationale: ReasonerRationale(code: .dataLoss, note: "deletes documents"),
            confidence: confidence
        )
    }

    // MARK: - Bound

    func testOuterBoundGraceIsPinned() {
        XCTAssertEqual(ReasonerEscalation.outerBoundGraceSeconds, 0.25)
    }

    func testHangingReasonerIsCutOffAndLeavesTheDeterministicRequirement() async {
        let config = ReasonerConfig(timeoutSeconds: 0.05)
        let started = ContinuousClock.now
        let assessment = await ReasonerEscalation.assess(
            context,
            using: HangingReasoner(),
            under: config
        )
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .seconds(3),
                          "a backend that never returns must not outlive the outer bound")
        XCTAssertEqual(assessment.outcome, .abstained(.timedOut))
        XCTAssertNil(assessment.decision)
        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: assessment.decision,
                under: config,
                voiceAvailable: true
            ),
            .standard,
            "a hung reasoner is indistinguishable from .off"
        )
    }

    func testZeroTimeoutStillReturnsAnAbstentionRatherThanWaiting() async {
        let started = ContinuousClock.now
        let assessment = await ReasonerEscalation.assess(
            context,
            using: HangingReasoner(),
            under: ReasonerConfig(timeoutSeconds: 0)
        )
        XCTAssertLessThan(started.duration(to: .now), .seconds(3))
        XCTAssertEqual(assessment.outcome, .abstained(.timedOut))
    }

    // MARK: - Abstention and confidence

    func testAbstainingReasonerLeavesTheDeterministicRequirement() async {
        let config = ReasonerConfig()
        let assessment = await ReasonerEscalation.assess(
            context,
            using: StubReasoner(decision: nil),
            under: config
        )
        XCTAssertEqual(assessment.outcome, .abstained(.reasonerAbstained))
        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: assessment.decision,
                under: config,
                voiceAvailable: true
            ),
            .standard
        )
    }

    func testSubThresholdConfidenceIsDiscardedExactlyLikeAnAbstention() async {
        let config = ReasonerConfig(minConfidence: 0.5)
        let assessment = await ReasonerEscalation.assess(
            context,
            using: StubReasoner(decision: decision(confidence: 0.49)),
            under: config
        )
        XCTAssertEqual(assessment.outcome, .abstained(.lowConfidence))
        XCTAssertNil(assessment.decision, "an unsure decision must not reach the merge")
        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: assessment.decision,
                under: config,
                voiceAvailable: true
            ),
            .standard
        )
    }

    func testConfidenceExactlyAtTheThresholdIsKept() async {
        let assessment = await ReasonerEscalation.assess(
            context,
            using: StubReasoner(decision: decision(confidence: 0.5)),
            under: ReasonerConfig(minConfidence: 0.5)
        )
        XCTAssertEqual(assessment.decision?.confidence, 0.5)
    }

    /// A backend answering nonsense — a `destructive` tier on a `ls` — still cannot do
    /// anything except ask for more confirmation.
    func testConfidentGarbageCanOnlyRaiseTheRequirement() async {
        let config = ReasonerConfig()
        let assessment = await ReasonerEscalation.assess(
            context,
            using: StubReasoner(decision: decision(confidence: 1.0)),
            under: config
        )
        let requirement = ReasonerEscalation.requiredConfirmation(
            for: assessment.decision,
            under: config,
            voiceAvailable: true
        )
        XCTAssertEqual(requirement, .doubleGesture)
        XCTAssertGreaterThanOrEqual(requirement.strength, RequiredConfirmation.standard.strength)
    }

    func testLatencyIsRecordedForEveryOutcome() async {
        for stub: any ContextReasoning in [
            StubReasoner(decision: decision()),
            StubReasoner(decision: nil),
        ] {
            let assessment = await ReasonerEscalation.assess(
                context,
                using: stub,
                under: ReasonerConfig()
            )
            XCTAssertGreaterThanOrEqual(assessment.latencyMilliseconds, 0)
        }
    }

    // MARK: - Escalation-only merge

    func testResultIsNeverWeakerThanTheDeterministicRequirement() {
        let configs = [
            ReasonerConfig(),
            ReasonerConfig(
                sensitiveConfirmation: .gestureAndVoice,
                destructiveConfirmation: .gestureAndVoice
            ),
            ReasonerConfig(
                sensitiveConfirmation: .standard,
                destructiveConfirmation: .standard
            ),
        ]
        for config in configs {
            for tier in RiskTier.allCases {
                for asked in RequiredConfirmation.allCases {
                    for deterministic in RequiredConfirmation.allCases {
                        for voiceAvailable in [true, false] {
                            let result = ReasonerEscalation.requiredConfirmation(
                                for: decision(tier: tier, confirmation: asked),
                                deterministic: deterministic,
                                under: config,
                                voiceAvailable: voiceAvailable
                            )
                            XCTAssertGreaterThanOrEqual(
                                result.strength,
                                deterministic.strength,
                                "tier \(tier) asked \(asked) under \(deterministic)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testNilDecisionAlwaysReturnsTheDeterministicRequirementUnchanged() {
        for deterministic in RequiredConfirmation.allCases {
            for voiceAvailable in [true, false] {
                XCTAssertEqual(
                    ReasonerEscalation.requiredConfirmation(
                        for: nil,
                        deterministic: deterministic,
                        under: ReasonerConfig(),
                        voiceAvailable: voiceAvailable
                    ),
                    deterministic
                )
            }
        }
    }

    // MARK: - Voice degradation

    func testGestureAndVoiceDegradesToDoubleGestureWithoutAVoiceChannel() {
        let config = ReasonerConfig(destructiveConfirmation: .gestureAndVoice)
        let asked = decision(tier: .destructive, confirmation: .gestureAndVoice)

        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: asked,
                under: config,
                voiceAvailable: true
            ),
            .gestureAndVoice
        )
        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: asked,
                under: config,
                voiceAvailable: false
            ),
            .doubleGesture,
            "without a voice channel the requirement could never be met"
        )
    }

    func testDegradationNeverDropsBelowTheDeterministicRequirement() {
        XCTAssertEqual(
            ReasonerEscalation.requiredConfirmation(
                for: decision(confirmation: .gestureAndVoice),
                deterministic: .gestureAndVoice,
                under: ReasonerConfig(destructiveConfirmation: .gestureAndVoice),
                voiceAvailable: false
            ),
            .gestureAndVoice,
            "degrading what the reasoner asked for must not weaken the deterministic floor"
        )
    }

    func testDoubleGestureIsUnaffectedByVoiceAvailability() {
        for voiceAvailable in [true, false] {
            XCTAssertEqual(
                ReasonerEscalation.requiredConfirmation(
                    for: decision(confirmation: .doubleGesture),
                    under: ReasonerConfig(),
                    voiceAvailable: voiceAvailable
                ),
                .doubleGesture
            )
        }
    }
}
