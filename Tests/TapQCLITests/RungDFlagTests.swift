import Foundation
import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQInteractionBaseline

/// The command-line surface of Rung D: four flags, their refusals, and what reaches the
/// runtime configuration.
///
/// The flags are default-off and each one has a dependency that exists for safety rather
/// than for composition, so the interesting assertions here are the *refusals*: a run that
/// asks to delegate over a shadow reasoner, or to listen between requests without
/// attribution, has to stop at the command line rather than start with a feature quietly
/// switched off.
final class RungDFlagTests: XCTestCase {
    // MARK: - Defaults

    /// The byte-identical-behavior promise starts here: `tapq serve` with no arguments
    /// composes none of the four legs, and the runtime configuration it produces says so.
    func testEveryRungDFlagDefaultsOff() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"]) else {
            return XCTFail("Expected a serve command.")
        }
        XCTAssertEqual(options.autoAnswerMode, .off)
        XCTAssertEqual(options.attentionMode, .off)
        XCTAssertFalse(options.voiceProcessingEnabled)
        XCTAssertFalse(options.quietEnabled)
    }

    func testRuntimeConfigurationDefaultsMatchTheFlagDefaults() {
        let configuration = TapQRuntimeConfiguration(
            gestureProfileURL: URL(fileURLWithPath: "/tmp/g.json"),
            tapProfileURL: URL(fileURLWithPath: "/tmp/t.json")
        )
        XCTAssertEqual(configuration.autoAnswerMode, .off)
        XCTAssertEqual(configuration.attentionMode, .off)
        XCTAssertFalse(configuration.voiceProcessingEnabled)
        XCTAssertFalse(configuration.quietEnabled)
    }

    // MARK: - Parsing

    func testAllFourFlagsParse() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--reasoner", "apple", "--reasoner-mode", "primary",
            "--auto-answer", "routine", "--wearer-gate", "--attention", "imu",
            "--voice-processing", "--quiet",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.autoAnswerMode, .routine)
        XCTAssertEqual(options.attentionMode, .imu)
        XCTAssertTrue(options.voiceProcessingEnabled)
        XCTAssertTrue(options.quietEnabled)
    }

    func testAutoAnswerRejectsAnUnknownMode() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--reasoner", "apple", "--reasoner-mode", "primary",
                "--auto-answer", "everything",
            ])
        ) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--auto-answer must be 'off' or 'routine'."
            )
        }
    }

    func testAttentionRejectsAnUnknownMode() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--wearer-gate", "--attention", "always"])
        ) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--attention must be 'off' or 'imu'."
            )
        }
    }

    // MARK: - Refusals

    func testAutoAnswerRequiresAReasoner() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--auto-answer", "routine"])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains(
                    "requires a --reasoner provider other than 'off'") == true,
                "\(error)"
            )
        }
    }

    /// The one that matters most. Shadow mode exists so an operator can watch the model
    /// without acting on it; silently approving on the strength of a shadow decision would
    /// be the single largest way to act on it.
    func testAutoAnswerRequiresPrimaryReasonerMode() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--reasoner", "apple", "--auto-answer", "routine",
            ])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains(
                    "requires --reasoner-mode primary") == true,
                "\(error)"
            )
        }
    }

    func testAttentionRequiresTheWearerGate() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--attention", "imu"])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains("requires --wearer-gate") == true,
                "\(error)"
            )
        }
    }

    /// `--auto-answer off` names the default, so it must not drag the dependency in with
    /// it: an operator scripting the flag to a variable has to be able to pass `off`.
    func testAutoAnswerOffNeedsNoReasoner() throws {
        guard case .serve(let options) = try CLICommandParser.parse(
            ["serve", "--auto-answer", "off"]
        ) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.autoAnswerMode, .off)
        XCTAssertEqual(options.reasonerProvider, .off)
    }

    func testAttentionOffNeedsNoWearerGate() throws {
        guard case .serve(let options) = try CLICommandParser.parse(
            ["serve", "--attention", "off"]
        ) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.attentionMode, .off)
        XCTAssertFalse(options.wearerGateEnabled)
    }

    // MARK: - Policy command

    func testPolicyShowParses() throws {
        XCTAssertEqual(
            try CLICommandParser.parse(["policy", "show", "--json"]),
            .policy(.show(PolicyShowOptions(json: true)))
        )
        XCTAssertEqual(
            try CLICommandParser.parse(["policy", "show", "--policy", "p.json"]),
            .policy(.show(PolicyShowOptions(policyPath: "p.json")))
        )
    }

    func testPolicyWithoutAnActionShowsHelp() throws {
        XCTAssertEqual(try CLICommandParser.parse(["policy"]), .help(.policy))
        XCTAssertEqual(try CLICommandParser.parse(["help", "policy"]), .help(.policy))
    }

    /// There is deliberately no `policy set`: widening what TapQ may answer without asking
    /// should take an editor, not a shell one-liner.
    func testPolicySetIsNotACommand() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["policy", "set", "--minimum-confidence", "0.1"])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains("Unknown policy action 'set'")
                    == true,
                "\(error)"
            )
        }
    }
}
