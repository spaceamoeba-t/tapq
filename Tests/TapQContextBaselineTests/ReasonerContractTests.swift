import XCTest
@testable import TapQContextBaseline

/// Pins the stage-2 decision contract. A failure here means the schema changed without a
/// new version string — which would make recorded corpora, diagnostics, and model
/// backends from different builds silently incomparable.
final class ReasonerContractTests: XCTestCase {
    func testContractVersionAndNoteLimitArePinned() {
        XCTAssertEqual(ReasonerDecisionContract.version, "tapq1-decision-v1")
        XCTAssertEqual(ReasonerDecisionContract.noteCharacterLimit, 140)
    }

    func testRiskTierCasesArePinned() {
        XCTAssertEqual(
            RiskTier.allCases.map(\.rawValue),
            ["routine", "sensitive", "destructive"]
        )
    }

    func testRequiredConfirmationCasesArePinned() {
        XCTAssertEqual(
            RequiredConfirmation.allCases.map(\.rawValue),
            ["standard", "double_gesture", "gesture_and_voice"]
        )
    }

    func testRationaleCodeCasesArePinned() {
        XCTAssertEqual(RationaleCode.allCases.map(\.rawValue), [
            "data_loss",
            "credential_exposure",
            "external_publication",
            "system_configuration",
            "bulk_or_unscoped_change",
            "unspecified",
        ])
    }

    func testConfirmationStrengthMatchesCaseOrder() {
        XCTAssertEqual(
            RequiredConfirmation.allCases.map(\.strength),
            Array(0..<RequiredConfirmation.allCases.count)
        )
        XCTAssertEqual(RequiredConfirmation.standard.strength, 0)
    }

    /// The escalation-only property: merging any two requirements never yields something
    /// weaker than either input.
    func testStrongestNeverWeakensEitherRequirement() {
        for lhs in RequiredConfirmation.allCases {
            for rhs in RequiredConfirmation.allCases {
                let merged = RequiredConfirmation.strongest(lhs, rhs)
                XCTAssertGreaterThanOrEqual(merged.strength, lhs.strength)
                XCTAssertGreaterThanOrEqual(merged.strength, rhs.strength)
                XCTAssertEqual(merged, RequiredConfirmation.strongest(rhs, lhs))
            }
        }
        XCTAssertEqual(
            RequiredConfirmation.strongest(.standard, .gestureAndVoice),
            .gestureAndVoice
        )
        XCTAssertEqual(
            RequiredConfirmation.strongest(.doubleGesture, .standard),
            .doubleGesture
        )
    }

    func testNoteIsTruncatedAtExactlyTheLimit() throws {
        let limit = ReasonerDecisionContract.noteCharacterLimit
        let long = String(repeating: "n", count: 200)
        let truncated = try XCTUnwrap(ReasonerRationale(code: .dataLoss, note: long).note)
        XCTAssertEqual(truncated.count, limit)
        XCTAssertEqual(truncated, String(long.prefix(limit)))

        let exact = String(repeating: "e", count: limit)
        XCTAssertEqual(ReasonerRationale(code: .dataLoss, note: exact).note, exact)

        let under = String(repeating: "u", count: limit - 1)
        XCTAssertEqual(ReasonerRationale(code: .dataLoss, note: under).note, under)
    }

    /// Normalization must be a fixed point, or a recorded corpus fixture stops comparing
    /// equal to its own encode/decode round trip.
    func testNoteNormalizationIsIdempotent() throws {
        let limit = ReasonerDecisionContract.noteCharacterLimit
        let inputs = [
            String(repeating: "a", count: limit - 1) + " overflow",
            String(repeating: "a", count: 200),
            "  spaced note  ",
            String(repeating: "é", count: 300),
            "\n\n",
        ]
        for input in inputs {
            let once = ReasonerRationale(code: .dataLoss, note: input).note
            let twice = ReasonerRationale(code: .dataLoss, note: once).note
            XCTAssertEqual(twice, once, "normalization must be a fixed point")
        }

        // The regression this ordering fixes: 139 characters plus a space truncates onto
        // a trailing space, which a second pass would strip.
        let borderline = String(repeating: "a", count: limit - 1) + " overflow"
        let normalized = try XCTUnwrap(
            ReasonerRationale(code: .dataLoss, note: borderline).note
        )
        XCTAssertEqual(normalized, String(repeating: "a", count: limit - 1))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    /// A `Character` is an unbounded grapheme cluster, so the character cap alone does
    /// not bound memory: 140 characters of combining marks would be ~84 KB.
    func testNoteIsBoundedInBytesBeforeCharacterTruncation() throws {
        let heavyCharacter = "e" + String(repeating: "\u{0301}", count: 300)
        let heavy = String(repeating: heavyCharacter, count: 200)
        XCTAssertGreaterThan(heavy.utf8.count, 100_000)

        let note = try XCTUnwrap(ReasonerRationale(code: .unspecified, note: heavy).note)
        XCTAssertLessThanOrEqual(note.utf8.count, ReasonerDecisionContract.noteByteLimit)
        XCTAssertLessThanOrEqual(note.count, ReasonerDecisionContract.noteCharacterLimit)
        XCTAssertEqual(ReasonerRationale(code: .unspecified, note: note).note, note)
    }

    func testNoteIsTrimmedAndBlankBecomesNil() {
        XCTAssertEqual(
            ReasonerRationale(code: .unspecified, note: "  deletes ~/Documents  ").note,
            "deletes ~/Documents"
        )
        XCTAssertNil(ReasonerRationale(code: .unspecified, note: "   \n ").note)
        XCTAssertNil(ReasonerRationale(code: .unspecified, note: "").note)
        XCTAssertNil(ReasonerRationale(code: .unspecified).note)
    }

    func testConfidenceIsClamped() {
        XCTAssertEqual(decision(confidence: -3.0).confidence, 0.0)
        XCTAssertEqual(decision(confidence: 0.0).confidence, 0.0)
        XCTAssertEqual(decision(confidence: 0.42).confidence, 0.42)
        XCTAssertEqual(decision(confidence: 1.0).confidence, 1.0)
        XCTAssertEqual(decision(confidence: 7.5).confidence, 1.0)
        // Non-finite scores are garbage, not certainty: every one of them must read as
        // "no confidence" so `minConfidence` discards the decision. NaN is asserted
        // explicitly because plain clamping only handled it by accident of the argument
        // order of the stdlib's `max(_:_:)`.
        XCTAssertEqual(decision(confidence: .nan).confidence, 0.0)
        XCTAssertEqual(decision(confidence: .signalingNaN).confidence, 0.0)
        XCTAssertEqual(decision(confidence: .infinity).confidence, 0.0)
        XCTAssertEqual(decision(confidence: -.infinity).confidence, 0.0)
    }

    /// Pins the exact wire shape. Field names here are the schema; renaming one is a new
    /// contract version.
    func testDecisionDecodesPinnedJSONFixture() throws {
        let json = """
            {
              "risk_tier": "destructive",
              "required_confirmation": "double_gesture",
              "rationale": {
                "code": "data_loss",
                "note": "Recursive delete outside the workspace."
              },
              "confidence": 0.82
            }
            """
        let decoded = try JSONDecoder().decode(
            ReasonerDecision.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded, ReasonerDecision(
            riskTier: .destructive,
            requiredConfirmation: .doubleGesture,
            rationale: ReasonerRationale(
                code: .dataLoss,
                note: "Recursive delete outside the workspace."
            ),
            confidence: 0.82
        ))
    }

    func testDecisionEncodesSnakeCaseKeysAndRoundTrips() throws {
        let original = ReasonerDecision(
            riskTier: .sensitive,
            requiredConfirmation: .gestureAndVoice,
            rationale: ReasonerRationale(code: .credentialExposure, note: "reads .netrc"),
            confidence: 0.5
        )
        let data = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["risk_tier", "required_confirmation", "rationale", "confidence"]
        )
        XCTAssertEqual(object["risk_tier"] as? String, "sensitive")
        XCTAssertEqual(object["required_confirmation"] as? String, "gesture_and_voice")
        let rationale = try XCTUnwrap(object["rationale"] as? [String: Any])
        XCTAssertEqual(rationale["code"] as? String, "credential_exposure")

        let decoded = try JSONDecoder().decode(ReasonerDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    /// Decoded values must obey the same bounds as constructed ones — model output
    /// arrives as JSON, so the initializer's guarantees have to survive the decoder.
    func testDecodingReappliesNoteCapAndConfidenceClamp() throws {
        let long = String(repeating: "x", count: 400)
        let json = """
            {
              "risk_tier": "routine",
              "required_confirmation": "standard",
              "rationale": {"code": "unspecified", "note": "\(long)"},
              "confidence": 9.5
            }
            """
        let decoded = try JSONDecoder().decode(
            ReasonerDecision.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.confidence, 1.0)
        XCTAssertEqual(
            decoded.rationale.note?.count,
            ReasonerDecisionContract.noteCharacterLimit
        )
    }

    func testUnknownRationaleCodeFailsToDecode() {
        let json = """
            {
              "risk_tier": "routine",
              "required_confirmation": "standard",
              "rationale": {"code": "bad_vibes"},
              "confidence": 0.1
            }
            """
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReasonerDecision.self, from: Data(json.utf8))
        )
    }

    func testRationaleOmitsAbsentNoteWhenEncoded() throws {
        let data = try JSONEncoder().encode(ReasonerRationale(code: .unspecified))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["code"])
    }

    func testContextDecodesPinnedJSONFixture() throws {
        let json = """
            {
              "tool_name": "Bash",
              "command_text": "rm -rf build",
              "cwd": "/Users/dev/project",
              "agent_name": "Claude Code",
              "summary": "Remove the build directory",
              "detail": "Deletes 412 files"
            }
            """
        let decoded = try JSONDecoder().decode(
            ReasonerContext.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded, ReasonerContext(
            toolName: "Bash",
            commandText: "rm -rf build",
            cwd: "/Users/dev/project",
            agentName: "Claude Code",
            summary: "Remove the build directory",
            detail: "Deletes 412 files"
        ))
    }

    func testContextDefaultsOptionalsAndRoundTrips() throws {
        let minimal = ReasonerContext(toolName: "Read", summary: "Read a file")
        XCTAssertNil(minimal.commandText)
        XCTAssertNil(minimal.cwd)
        XCTAssertNil(minimal.agentName)
        XCTAssertNil(minimal.detail)

        let data = try JSONEncoder().encode(minimal)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["tool_name", "summary"])
        XCTAssertEqual(
            try JSONDecoder().decode(ReasonerContext.self, from: data),
            minimal
        )
    }

    private func decision(confidence: Double) -> ReasonerDecision {
        ReasonerDecision(
            riskTier: .routine,
            requiredConfirmation: .standard,
            rationale: ReasonerRationale(code: .unspecified),
            confidence: confidence
        )
    }
}
