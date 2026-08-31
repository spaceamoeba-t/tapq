import Foundation
import XCTest
@testable import TapQCLI
import TapQInteractionBaseline

/// The command-line surface of Rung E: one flag, and the startup validation it moves.
///
/// `--voice-instructions` has always been refused without `--wearer-gate`, because the
/// dictation path is fail-closed on an attribution signal only the gate composes. The whole
/// of Rung E's CLI change is that `--voice-trust environment` is the operator saying they
/// do not want that signal, which makes the pairing meaningless rather than unsafe — so the
/// matrix below is the feature, and the `wearer` half of it must not have moved at all.
final class VoiceTrustFlagTests: XCTestCase {
    // MARK: - Defaults

    /// The byte-identical promise: a run that says nothing about trust is a wearer-trust run.
    func testVoiceTrustDefaultsToWearer() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"]) else {
            return XCTFail("Expected a serve command.")
        }
        XCTAssertEqual(options.voiceTrust, .wearer)
    }

    func testRuntimeConfigurationDefaultsToWearerTrust() {
        let configuration = TapQRuntimeConfiguration(
            gestureProfileURL: URL(fileURLWithPath: "/tmp/g.json"),
            tapProfileURL: URL(fileURLWithPath: "/tmp/t.json")
        )
        XCTAssertEqual(configuration.voiceTrust, .wearer)
    }

    // MARK: - Parsing

    func testEnvironmentTrustParses() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-trust", "environment", "--voice-instructions",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.voiceTrust, .environment)
        XCTAssertTrue(options.voiceInstructionsEnabled)
    }

    func testWearerTrustParsesExplicitly() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-trust", "wearer", "--wearer-gate", "--voice-instructions",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.voiceTrust, .wearer)
    }

    func testUnknownTrustModeIsRefused() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--voice-trust", "anyone"])
        ) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--voice-trust must be 'wearer' or 'environment'."
            )
        }
    }

    func testTrustModeRequiresAValue() {
        XCTAssertThrowsError(try CLICommandParser.parse(["serve", "--voice-trust"]))
    }

    // MARK: - The validation matrix

    /// Unchanged from Rung C, and the reason the error text now names the alternative: a
    /// wearer-trust run without the gate would refuse every dictation it accepted the flag
    /// for.
    func testInstructionsStillRequireTheGateUnderWearerTrust() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--voice-instructions"])
        ) { error in
            let message = (error as? CLIUsageError)?.message ?? ""
            XCTAssertTrue(message.contains("requires --wearer-gate"), message)
            XCTAssertTrue(message.contains("--voice-trust environment"),
                          "the refusal must name the way out: \(message)")
        }
    }

    func testInstructionsStillRequireTheGateWhenWearerTrustIsExplicit() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--voice-instructions", "--voice-trust", "wearer",
            ])
        )
    }

    /// The rung, in one assertion: with the microphone trusted as the user there is no
    /// attribution to be fail-closed about, so the pairing is dropped rather than tolerated.
    func testInstructionsNeedNoGateUnderEnvironmentTrust() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-instructions", "--voice-trust", "environment",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertFalse(options.wearerGateEnabled)
        XCTAssertTrue(options.voiceInstructionsEnabled)
    }

    /// Trust does not stand in for attribution on the IMU path: a window that opens on a
    /// wearer-speech onset still needs the signal that says whose onset it was. (Rung G's
    /// `--attention acoustic` is the mode that has no such onset to attribute, and it is
    /// `RungGFlagTests` that pins what it asks for instead.)
    func testAttentionStillRequiresTheGateUnderEnvironmentTrust() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--voice-trust", "environment", "--attention", "imu",
            ])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains("requires --wearer-gate") == true
            )
        }
    }

    /// Both flags together stay legal: environment trust drops a requirement, it does not
    /// forbid the gate for anyone who still wants attribution on the command path.
    func testEnvironmentTrustAndTheGateComposeTogether() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--wearer-gate", "--voice-instructions",
            "--voice-trust", "environment", "--attention", "imu",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertTrue(options.wearerGateEnabled)
        XCTAssertEqual(options.voiceTrust, .environment)
        XCTAssertEqual(options.attentionMode, .imu)
    }
}
