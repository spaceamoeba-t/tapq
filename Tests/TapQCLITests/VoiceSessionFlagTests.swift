import Foundation
import XCTest
@testable import TapQCLI
import TapQInteractionBaseline

/// The command-line surface of the voice session (RH1): one flag, one dependency, and the
/// promise that a run which does not ask for it cannot end up in it.
final class VoiceSessionFlagTests: XCTestCase {
    // MARK: - Defaults

    func testVoiceSessionDefaultsOff() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"]) else {
            return XCTFail("Expected a serve command.")
        }
        XCTAssertFalse(options.voiceSessionEnabled)
    }

    func testRuntimeConfigurationDefaultsTheSessionOff() {
        let configuration = TapQRuntimeConfiguration(
            gestureProfileURL: URL(fileURLWithPath: "/tmp/g.json"),
            tapProfileURL: URL(fileURLWithPath: "/tmp/t.json")
        )
        XCTAssertFalse(configuration.voiceSessionEnabled)
    }

    // MARK: - Parsing and validation

    /// The lean pairing the mode was designed around: no earbuds, environment trust, and a
    /// boundary held open for the next sentence.
    func testTheVoiceOnlyPairingParses() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-trust", "environment", "--voice-instructions",
            "--voice-session",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertTrue(options.voiceSessionEnabled)
        XCTAssertTrue(options.voiceInstructionsEnabled)
        XCTAssertEqual(options.voiceTrust, .environment)
        XCTAssertFalse(options.wearerGateEnabled)
    }

    /// It also composes with the wearer-trust posture: a boundary held for someone who is
    /// wearing their AirPods is the same boundary.
    func testTheSessionComposesUnderWearerTrustToo() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--wearer-gate", "--voice-instructions", "--voice-session",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertTrue(options.voiceSessionEnabled)
        XCTAssertEqual(options.voiceTrust, .wearer)
    }

    /// The dependency that exists so a hook is never parked for ten minutes waiting on a
    /// queue this run does not have.
    func testTheSessionRequiresTheInstructionChannel() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--voice-session"])
        ) { error in
            let message = (error as? CLIUsageError)?.message ?? ""
            XCTAssertTrue(message.contains("--voice-session requires --voice-instructions"),
                          message)
        }
    }

    /// And it is refused even when the trust posture would otherwise have made the run
    /// legal — the missing piece is the queue, not the attribution.
    func testTheSessionIsRefusedUnderEnvironmentTrustWithoutInstructions() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--voice-trust", "environment", "--voice-session",
            ])
        )
    }

    /// A wearer-trust run still has to bring the gate, and the session flag does not excuse
    /// it: two independent refusals, and the instruction channel's own comes first.
    func testTheSessionDoesNotWaiveTheWearerTrustGateRequirement() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--voice-instructions", "--voice-session",
            ])
        ) { error in
            XCTAssertTrue(
                (error as? CLIUsageError)?.message.contains("requires --wearer-gate") == true
            )
        }
    }
}
