import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// Pins the reasoner's composition surface: the mode ladder, the config defaults, and
/// the escalation-only tier mapping. These values are what a backend and the runtime
/// agree on before any model exists.
final class ContextReasoningTests: XCTestCase {
    /// A reasoner that returns whatever it was handed — including `nil`, which is the
    /// "cannot answer" case every failure mode collapses to.
    private struct StubReasoner: ContextReasoning {
        let decision: ReasonerDecision?

        func assess(_ context: ReasonerContext) async -> ReasonerDecision? {
            decision
        }
    }

    private let context = ReasonerContext(
        toolName: "Bash",
        commandText: "git push --force origin main",
        cwd: "/Users/dev/project",
        agentName: "Claude Code",
        summary: "Force-push to main"
    )

    func testReasonerModeCasesArePinned() {
        XCTAssertEqual(ReasonerMode.off.rawValue, "off")
        XCTAssertEqual(ReasonerMode.shadow.rawValue, "shadow")
        XCTAssertEqual(ReasonerMode.primary.rawValue, "primary")
        XCTAssertEqual(ReasonerMode(rawValue: "shadow"), .shadow)
        XCTAssertNil(ReasonerMode(rawValue: "on"))
    }

    func testConfigDefaults() {
        let config = ReasonerConfig()
        XCTAssertEqual(config.timeoutSeconds, 2.0)
        XCTAssertEqual(config.minConfidence, 0.5)
        XCTAssertEqual(config.sensitiveConfirmation, .standard)
        XCTAssertEqual(config.destructiveConfirmation, .doubleGesture)
    }

    func testConfigEncodesPinnedSnakeCaseKeysAndRoundTrips() throws {
        let config = ReasonerConfig(
            timeoutSeconds: 1.25,
            minConfidence: 0.8,
            sensitiveConfirmation: .doubleGesture,
            destructiveConfirmation: .gestureAndVoice
        )
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), [
            "timeout_seconds",
            "min_confidence",
            "sensitive_confirmation",
            "destructive_confirmation",
        ])
        XCTAssertEqual(object["timeout_seconds"] as? Double, 1.25)
        XCTAssertEqual(object["min_confidence"] as? Double, 0.8)
        XCTAssertEqual(object["sensitive_confirmation"] as? String, "double_gesture")
        XCTAssertEqual(object["destructive_confirmation"] as? String, "gesture_and_voice")
        XCTAssertEqual(try JSONDecoder().decode(ReasonerConfig.self, from: data), config)
    }

    /// Tolerant decoding: a config persisted before a knob existed still loads, with the
    /// absent keys taking today's defaults rather than throwing the whole config away.
    func testConfigDecodesAbsentKeysToDefaults() throws {
        let empty = try JSONDecoder().decode(
            ReasonerConfig.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(empty, ReasonerConfig())

        let partial = try JSONDecoder().decode(
            ReasonerConfig.self,
            from: Data(#"{"min_confidence": 0.9}"#.utf8)
        )
        XCTAssertEqual(partial, ReasonerConfig(minConfidence: 0.9))
        XCTAssertEqual(partial.timeoutSeconds, ReasonerConfig().timeoutSeconds)
        XCTAssertEqual(
            partial.destructiveConfirmation,
            ReasonerConfig().destructiveConfirmation
        )
    }

    /// Out-of-range knobs resolve toward "behave like today", never toward more model
    /// influence — and decoded values are clamped exactly like constructed ones.
    func testConfigClampsInvalidValues() throws {
        XCTAssertEqual(ReasonerConfig(timeoutSeconds: -4.0).timeoutSeconds, 0.0)
        XCTAssertEqual(ReasonerConfig(timeoutSeconds: .nan).timeoutSeconds, 0.0)
        XCTAssertEqual(ReasonerConfig(timeoutSeconds: .infinity).timeoutSeconds, 0.0)
        XCTAssertEqual(ReasonerConfig(timeoutSeconds: 0.25).timeoutSeconds, 0.25)

        XCTAssertEqual(ReasonerConfig(minConfidence: -1.0).minConfidence, 0.0)
        XCTAssertEqual(ReasonerConfig(minConfidence: 2.0).minConfidence, 1.0)
        XCTAssertEqual(ReasonerConfig(minConfidence: .nan).minConfidence, 1.0)
        XCTAssertEqual(ReasonerConfig(minConfidence: .infinity).minConfidence, 1.0)

        let decoded = try JSONDecoder().decode(
            ReasonerConfig.self,
            from: Data(#"{"timeout_seconds": -9, "min_confidence": 4}"#.utf8)
        )
        XCTAssertEqual(decoded.timeoutSeconds, 0.0)
        XCTAssertEqual(decoded.minConfidence, 1.0)
    }

    func testConfirmationMappingUsesConfiguredEscalation() {
        let config = ReasonerConfig(
            sensitiveConfirmation: .doubleGesture,
            destructiveConfirmation: .gestureAndVoice
        )
        XCTAssertEqual(config.confirmation(for: .routine), .standard)
        XCTAssertEqual(config.confirmation(for: .sensitive), .doubleGesture)
        XCTAssertEqual(config.confirmation(for: .destructive), .gestureAndVoice)
    }

    /// Routine has no knob: an unremarkable action can never change what the user does,
    /// whatever the other two tiers are configured to demand.
    func testRoutineTierHasNoEscalationKnob() {
        for sensitive in RequiredConfirmation.allCases {
            for destructive in RequiredConfirmation.allCases {
                let config = ReasonerConfig(
                    sensitiveConfirmation: sensitive,
                    destructiveConfirmation: destructive
                )
                XCTAssertEqual(config.confirmation(for: .routine), .standard)
            }
        }
    }

    /// The escalation-only guarantee, asserted on the blessed merge path over every
    /// (deterministic, decision, config) combination: the result is never weaker than
    /// what the deterministic policy already demanded, and never weaker than either of
    /// the two things the decision contributes.
    func testEffectiveConfirmationNeverWeakensAnyInput() {
        for sensitive in RequiredConfirmation.allCases {
            for destructive in RequiredConfirmation.allCases {
                let config = ReasonerConfig(
                    sensitiveConfirmation: sensitive,
                    destructiveConfirmation: destructive
                )
                for tier in RiskTier.allCases {
                    for asked in RequiredConfirmation.allCases {
                        let decision = ReasonerDecision(
                            riskTier: tier,
                            requiredConfirmation: asked,
                            rationale: ReasonerRationale(code: .unspecified),
                            confidence: 1.0
                        )
                        for deterministic in RequiredConfirmation.allCases {
                            let effective = decision.effectiveConfirmation(
                                deterministic: deterministic,
                                under: config
                            )
                            XCTAssertGreaterThanOrEqual(
                                effective.strength,
                                deterministic.strength
                            )
                            XCTAssertGreaterThanOrEqual(effective.strength, asked.strength)
                            XCTAssertGreaterThanOrEqual(
                                effective.strength,
                                config.confirmation(for: tier).strength
                            )
                        }
                    }
                }
            }
        }
    }

    func testEffectiveConfirmationTakesTheStrongestOfItsThreeInputs() {
        let config = ReasonerConfig(
            sensitiveConfirmation: .doubleGesture,
            destructiveConfirmation: .gestureAndVoice
        )

        // The tier mapping wins when the model understates its own ask.
        let understated = ReasonerDecision(
            riskTier: .destructive,
            requiredConfirmation: .standard,
            rationale: ReasonerRationale(code: .dataLoss),
            confidence: 0.9
        )
        XCTAssertEqual(
            understated.effectiveConfirmation(deterministic: .standard, under: config),
            .gestureAndVoice
        )

        // The model's own ask wins when it is stronger than the tier mapping.
        let overstated = ReasonerDecision(
            riskTier: .routine,
            requiredConfirmation: .gestureAndVoice,
            rationale: ReasonerRationale(code: .unspecified),
            confidence: 0.9
        )
        XCTAssertEqual(
            overstated.effectiveConfirmation(deterministic: .standard, under: config),
            .gestureAndVoice
        )

        // A routine decision cannot lower a stronger deterministic requirement.
        let routine = ReasonerDecision(
            riskTier: .routine,
            requiredConfirmation: .standard,
            rationale: ReasonerRationale(code: .unspecified),
            confidence: 0.9
        )
        XCTAssertEqual(
            routine.effectiveConfirmation(deterministic: .doubleGesture, under: config),
            .doubleGesture
        )
        XCTAssertEqual(
            routine.effectiveConfirmation(deterministic: .standard, under: config),
            .standard
        )
    }

    func testAbstainingReasonerReturnsNil() async {
        let result = await StubReasoner(decision: nil).assess(context)
        XCTAssertNil(result)
    }

    func testDecidingReasonerReturnsItsDecision() async {
        let decision = ReasonerDecision(
            riskTier: .destructive,
            requiredConfirmation: .doubleGesture,
            rationale: ReasonerRationale(
                code: .dataLoss,
                note: "Force-push rewrites shared history."
            ),
            confidence: 0.9
        )
        let result = await StubReasoner(decision: decision).assess(context)
        XCTAssertEqual(result, decision)
    }

    /// The existential is what the runtime will store, so it has to compile and stay
    /// usable through the protocol alone.
    func testProtocolIsUsableAsAnExistential() async {
        let reasoners: [any ContextReasoning] = [
            StubReasoner(decision: nil),
            StubReasoner(decision: ReasonerDecision(
                riskTier: .sensitive,
                requiredConfirmation: .gestureAndVoice,
                rationale: ReasonerRationale(code: .credentialExposure),
                confidence: 0.6
            )),
        ]
        var decided = 0
        for reasoner in reasoners {
            if await reasoner.assess(context) != nil { decided += 1 }
        }
        XCTAssertEqual(decided, 1)
    }
}
