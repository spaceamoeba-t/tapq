import XCTest
@testable import TapQContextBaseline
import TapQContracts

/// The complete specification of when TapQ answers an approval without asking.
///
/// `AutoAnswerPolicy.decision(for:toolName:)` is pure and total, so this matrix is not a
/// sample of its behavior — it is all of it. Anything that would let a request through
/// silently has to show up here as a row, which is why the matrix is written as an
/// explicit table of inputs to expected verdicts rather than as a handful of scenarios: a
/// new way to auto-allow that nobody wrote a row for is a hole in the audit, not a gap in
/// coverage.
final class AutoAnswerPolicyTests: XCTestCase {
    private func decided(
        tier: RiskTier = .routine,
        confidence: Double = 0.95,
        code: RationaleCode = .unspecified
    ) -> ReasonerAssessment {
        ReasonerAssessment(
            outcome: .decided(ReasonerDecision(
                riskTier: tier,
                requiredConfirmation: .standard,
                rationale: ReasonerRationale(code: code),
                confidence: confidence
            )),
            latencyMilliseconds: 42
        )
    }

    private func abstained(_ reason: ReasonerAbstention) -> ReasonerAssessment {
        ReasonerAssessment(outcome: .abstained(reason), latencyMilliseconds: 7)
    }

    // MARK: - The one path that says yes

    func testAConfidentRoutineDecisionOnAnUnlistedToolIsTheOnlyAutoAllow() {
        let policy = AutoAnswerPolicy()
        XCTAssertEqual(policy.decision(for: decided(), toolName: "Bash"), .autoAllow)
    }

    func testConfidenceExactlyAtTheThresholdQualifies() {
        let policy = AutoAnswerPolicy(minimumConfidence: 0.8)
        XCTAssertEqual(
            policy.decision(for: decided(confidence: 0.8), toolName: "Read"),
            .autoAllow,
            "the threshold is a floor the decision may sit on, not one it must clear"
        )
    }

    // MARK: - The verdict matrix

    func testTheVerdictMatrixIsExhaustiveAndEveryRefusalIsNamed() {
        let policy = AutoAnswerPolicy(minimumConfidence: 0.8, neverAutoTools: ["Write"])
        let rows: [(String, ReasonerAssessment, String, AutoAnswerVerdict)] = [
            (
                "no decision at all",
                abstained(.reasonerAbstained), "Bash", .ask(.reasonerAbstained)
            ),
            (
                "the reasoner's own confidence floor discarded it",
                abstained(.lowConfidence), "Bash", .ask(.reasonerLowConfidence)
            ),
            (
                "the outer deadline fired",
                abstained(.timedOut), "Bash", .ask(.reasonerTimedOut)
            ),
            (
                "sensitive is not routine",
                decided(tier: .sensitive), "Bash", .ask(.notRoutine)
            ),
            (
                "destructive is not routine",
                decided(tier: .destructive), "Bash", .ask(.notRoutine)
            ),
            (
                "routine but under the user's threshold",
                decided(confidence: 0.79), "Bash", .ask(.belowMinimumConfidence)
            ),
            (
                "routine and confident but on the never-list",
                decided(), "Write", .ask(.neverAutoTool)
            ),
            (
                "routine, confident, unlisted",
                decided(), "Bash", .autoAllow
            ),
        ]

        for (description, assessment, toolName, expected) in rows {
            XCTAssertEqual(
                policy.decision(for: assessment, toolName: toolName),
                expected,
                description
            )
        }

        let refused = Set(rows.compactMap { $0.3.refusal })
        XCTAssertEqual(
            refused,
            Set(AutoAnswerRefusal.allCases),
            "every refusal reason the type can name must have a row that produces it"
        )
    }

    func testEveryAbstentionHasItsOwnRefusalReason() {
        let policy = AutoAnswerPolicy()
        let reasons = ReasonerAbstention.allCases.map { abstention in
            policy.decision(for: abstained(abstention), toolName: "Bash").refusal
        }
        XCTAssertEqual(
            Set(reasons.compactMap { $0 }).count,
            ReasonerAbstention.allCases.count,
            "collapsing two abstentions onto one reason would hide a slow backend "
                + "behind an unsure one"
        )
        XCTAssertFalse(reasons.contains(nil), "an abstention can never auto-allow")
    }

    func testNoTierOtherThanRoutineCanEverAutoAllowAtAnyConfidence() {
        let permissive = AutoAnswerPolicy(minimumConfidence: 0.0)
        for tier in RiskTier.allCases where tier != .routine {
            XCTAssertEqual(
                permissive.decision(for: decided(tier: tier, confidence: 1.0),
                                    toolName: "Bash"),
                .ask(.notRoutine),
                "\(tier.rawValue) must be unreachable even with the threshold at zero"
            )
        }
    }

    // MARK: - The never-list

    func testTheNeverListMatchesCaseAndWhitespaceInsensitively() {
        let policy = AutoAnswerPolicy(neverAutoTools: ["  bash ", "WebFetch"])
        for spelling in ["Bash", "bash", "BASH", " Bash  "] {
            XCTAssertEqual(
                policy.decision(for: decided(), toolName: spelling),
                .ask(.neverAutoTool),
                "\(spelling) must match the listed entry"
            )
        }
        XCTAssertEqual(
            policy.decision(for: decided(), toolName: "webfetch"),
            .ask(.neverAutoTool)
        )
        XCTAssertEqual(policy.decision(for: decided(), toolName: "Read"), .autoAllow)
    }

    func testTheNeverListIsNotAPrefixOrSubstringMatch() {
        let policy = AutoAnswerPolicy(neverAutoTools: ["Bash"])
        XCTAssertEqual(policy.decision(for: decided(), toolName: "BashOutput"), .autoAllow)
        XCTAssertFalse(policy.forbidsAutoAnswer("Ba"))
    }

    func testAnUnnamedToolIsNeverAutoAnswered() {
        let policy = AutoAnswerPolicy(minimumConfidence: 0.0)
        for blank in ["", "   "] {
            XCTAssertEqual(
                policy.decision(for: decided(confidence: 1.0), toolName: blank),
                .ask(.neverAutoTool),
                "a request nobody can name is not one to answer silently"
            )
        }
    }

    func testAnEmptyNeverListForbidsNothing() {
        XCTAssertFalse(AutoAnswerPolicy().forbidsAutoAnswer("Bash"))
    }

    // MARK: - Clause precedence

    func testTheFirstFailingClauseIsTheReportedReason() {
        let policy = AutoAnswerPolicy(minimumConfidence: 0.9, neverAutoTools: ["Bash"])
        XCTAssertEqual(
            policy.decision(
                for: decided(tier: .destructive, confidence: 0.1),
                toolName: "Bash"
            ),
            .ask(.notRoutine),
            "tier is reported ahead of confidence and the never-list"
        )
        XCTAssertEqual(
            policy.decision(for: decided(confidence: 0.1), toolName: "Bash"),
            .ask(.belowMinimumConfidence),
            "confidence is reported ahead of the never-list"
        )
        XCTAssertEqual(
            policy.decision(for: abstained(.timedOut), toolName: "Bash"),
            .ask(.reasonerTimedOut),
            "an absent decision is reported ahead of everything about the request"
        )
    }

    // MARK: - Threshold normalization

    func testTheDefaultsAreStrictAndNamed() {
        XCTAssertEqual(AutoAnswerPolicy.defaults, AutoAnswerPolicy())
        XCTAssertEqual(AutoAnswerPolicy.defaults.minimumConfidence, 0.8)
        XCTAssertTrue(AutoAnswerPolicy.defaults.neverAutoTools.isEmpty)
        XCTAssertEqual(AutoAnswerPolicy.defaults.schemaVersion, 1)
    }

    func testANonFiniteThresholdQualifiesNothing() {
        for value in [Double.nan, .infinity, -.infinity] {
            let policy = AutoAnswerPolicy(minimumConfidence: value)
            XCTAssertEqual(policy.minimumConfidence, 1.0)
            XCTAssertEqual(
                policy.decision(for: decided(confidence: 0.999), toolName: "Bash"),
                .ask(.belowMinimumConfidence),
                "garbage in the threshold must resolve toward asking the human"
            )
        }
    }

    func testAnOutOfRangeThresholdIsClampedLikeTheReasonersOwn() {
        XCTAssertEqual(AutoAnswerPolicy(minimumConfidence: 2.5).minimumConfidence, 1.0)
        XCTAssertEqual(AutoAnswerPolicy(minimumConfidence: -1.0).minimumConfidence, 0.0)
    }

    // MARK: - Round trip

    func testAPolicyRoundTripsThroughJSONWithSnakeCaseKeys() throws {
        let policy = AutoAnswerPolicy(minimumConfidence: 0.93, neverAutoTools: ["Bash"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(policy)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"minimum_confidence\""))
        XCTAssertTrue(text.contains("\"never_auto_tools\""))
        XCTAssertTrue(text.contains("\"schema_version\""))
        XCTAssertEqual(try JSONDecoder().decode(AutoAnswerPolicy.self, from: data), policy)
    }

    func testDecodingReAppliesTheClampAndFillsAbsentKnobs() throws {
        let json = Data(#"{"schema_version":1,"minimum_confidence":-4}"#.utf8)
        let policy = try JSONDecoder().decode(AutoAnswerPolicy.self, from: json)
        XCTAssertEqual(policy.minimumConfidence, 0.0, "a hand-edited value is clamped too")
        XCTAssertTrue(policy.neverAutoTools.isEmpty)

        let bare = Data(#"{"schema_version":1}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(AutoAnswerPolicy.self, from: bare),
            AutoAnswerPolicy.defaults
        )
    }

    func testAPolicyWithoutASchemaVersionDoesNotDecode() {
        let json = Data(#"{"minimum_confidence":0.5}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AutoAnswerPolicy.self, from: json))
    }
}
