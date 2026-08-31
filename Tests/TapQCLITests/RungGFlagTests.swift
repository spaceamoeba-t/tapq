import Foundation
import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQInteractionBaseline

/// The command-line surface of Rung G: one new value on an existing flag, and the dependency
/// it carries.
///
/// `--attention` grew a third mode rather than a second flag, because what changes between
/// `imu` and `acoustic` is only which doorbell rings — the window on the other side of it is
/// the same object, with the same eight seconds and the same refusal to resolve anything. So
/// the assertions worth having here are the two ends of that: that the new value reaches the
/// runtime configuration intact, and that the *refusal* is right. `acoustic` opens a window
/// on an unattributed level in a room, and the run has to have said out loud that it trusts
/// the microphone as the user before it may.
final class RungGFlagTests: XCTestCase {
    private final class Buffer {
        var output = ""
        var error = ""

        var io: TapQCLIIO {
            TapQCLIIO(
                writeOutput: { self.output += $0 },
                writeError: { self.error += $0 },
                readInput: { nil }
            )
        }
    }

    /// Records the configuration `serve` was given and returns immediately, and reports the
    /// attention status the way the runtime is expected to: from the wording constant the
    /// policy owns, so the console line and the mode cannot drift apart.
    @MainActor
    private final class RecordingRuntime: TapQRuntimeServing {
        private(set) var configurations: [TapQRuntimeConfiguration] = []

        func serve(
            configuration: TapQRuntimeConfiguration,
            reasonerLoader: TapQReasonerLoading?,
            onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
        ) async throws {
            configurations.append(configuration)
            let attentionStatus: String?
            switch configuration.attentionMode {
            case .off: attentionStatus = nil
            case .imu: attentionStatus = "imu (8s command windows between requests)"
            case .acoustic: attentionStatus = AcousticAttentionPolicy.statusDescription
            }
            onReady(.init(
                socketPath: "/tmp/tapq.sock",
                discoveryPath: "/tmp/broker.json",
                gestureProfileLoaded: false,
                tapProfileLoaded: false,
                motionAvailable: true,
                voiceAvailable: true,
                attentionStatus: attentionStatus
            ))
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-rung-g-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func application(
        io: TapQCLIIO,
        runtime: (any TapQRuntimeServing)? = nil
    ) -> TapQCLIApplication {
        TapQCLIApplication(
            io: io,
            runtimeService: runtime,
            environment: ["TAPQ_CONFIG_DIR": directory.path],
            homeDirectory: directory,
            executableURL: directory.appendingPathComponent("tapq"),
            currentDirectory: directory
        )
    }

    // MARK: - Parsing

    func testAcousticAttentionParses() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-trust", "environment", "--attention", "acoustic",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.attentionMode, .acoustic)
        XCTAssertEqual(options.voiceTrust, .environment)
    }

    /// The default is still off, and adding a mode must not have moved it. Every run that
    /// says nothing about attention is the run it always was.
    func testAttentionStillDefaultsToOff() throws {
        guard case .serve(let options) = try CLICommandParser.parse(["serve"]) else {
            return XCTFail("Expected a serve command.")
        }
        XCTAssertEqual(options.attentionMode, .off)
    }

    func testTheUnknownModeMessageNamesEveryMode() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--attention", "always"])
        ) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "--attention must be 'off', 'imu', or 'acoustic'."
            )
        }
    }

    /// The mode reaches the runtime rather than stopping at the parser — a flag that parses
    /// and composes nothing is the shape of a feature that is silently off — and the operator
    /// is told, in the mode's own words, what the run is now doing with their microphone.
    @MainActor
    func testAcousticReachesTheRuntimeAndTheStatusLine() async {
        let buffer = Buffer()
        let runtime = RecordingRuntime()
        let status = await application(io: buffer.io, runtime: runtime).run(arguments: [
            "serve", "--voice-trust", "environment", "--attention", "acoustic",
        ])

        XCTAssertEqual(status, 0)
        XCTAssertEqual(runtime.configurations.first?.attentionMode, .acoustic)
        XCTAssertEqual(runtime.configurations.first?.voiceTrust, .environment)
        XCTAssertTrue(buffer.output.contains("Attention: acoustic"), buffer.output)
        XCTAssertTrue(
            buffer.output.contains("no audio leaves the machine while idle"), buffer.output)
    }

    // MARK: - The refusal

    /// The rung's one safety dependency. Under wearer trust the dictation path is fail-closed
    /// on an attribution signal an acoustic onset cannot carry, so a run composed this way
    /// would refuse everything it was opened for.
    func testAcousticRequiresEnvironmentTrust() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--attention", "acoustic"])
        ) { error in
            let message = (error as? CLIUsageError)?.message ?? ""
            XCTAssertTrue(message.contains("requires --voice-trust environment"), message)
        }
    }

    func testAcousticIsRefusedUnderExplicitWearerTrust() {
        XCTAssertThrowsError(
            try CLICommandParser.parse([
                "serve", "--voice-trust", "wearer", "--attention", "acoustic",
            ])
        )
    }

    /// A refusal that does not name the alternative leaves a wearer with no way to learn
    /// there is one, which is the standard the `--voice-instructions` refusal set.
    func testTheRefusalNamesTheOtherMode() {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--attention", "acoustic"])
        ) { error in
            let message = (error as? CLIUsageError)?.message ?? ""
            XCTAssertTrue(message.contains("--attention imu"),
                          "the refusal must name the attributed mode: \(message)")
        }
    }

    /// The wearer gate is not required and not forbidden. `acoustic` exists for a run with
    /// the AirPods in their case, but an operator who has them in and still wants an acoustic
    /// doorbell is composing something coherent, not something to be refused.
    func testAcousticNeedsNoWearerGateAndToleratesOne() throws {
        guard case .serve(let bare) = try CLICommandParser.parse([
            "serve", "--voice-trust", "environment", "--attention", "acoustic",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertFalse(bare.wearerGateEnabled)

        guard case .serve(let gated) = try CLICommandParser.parse([
            "serve", "--wearer-gate", "--voice-trust", "environment",
            "--attention", "acoustic",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertTrue(gated.wearerGateEnabled)
        XCTAssertEqual(gated.attentionMode, .acoustic)
    }

    /// The other half of the matrix, unmoved: `imu` still needs the gate, and environment
    /// trust does not stand in for it. Attribution is the thing that mode is built on.
    func testImuStillRequiresTheWearerGate() {
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

    /// `--attention off` names the default, so it must drag in neither dependency: an
    /// operator scripting the flag to a variable has to be able to pass `off`.
    func testAttentionOffCarriesNoDependency() throws {
        guard case .serve(let options) = try CLICommandParser.parse(
            ["serve", "--attention", "off"]
        ) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.attentionMode, .off)
        XCTAssertEqual(options.voiceTrust, .wearer)
        XCTAssertFalse(options.wearerGateEnabled)
    }

    // MARK: - Composition with the rest of the voice-only surface

    /// The run the rung was written for: no earbuds, an acoustic doorbell, a dictation
    /// channel, and a held boundary to dictate into.
    func testTheVoiceOnlyCompositionParses() throws {
        guard case .serve(let options) = try CLICommandParser.parse([
            "serve", "--voice-trust", "environment", "--voice-instructions",
            "--voice-session", "--attention", "acoustic",
        ]) else { return XCTFail("Expected a serve command.") }
        XCTAssertEqual(options.attentionMode, .acoustic)
        XCTAssertEqual(options.voiceTrust, .environment)
        XCTAssertTrue(options.voiceInstructionsEnabled)
        XCTAssertTrue(options.voiceSessionEnabled)
        XCTAssertFalse(options.wearerGateEnabled)
    }

    // MARK: - Help

    @MainActor
    func testServeHelpDocumentsTheAcousticMode() async {
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(arguments: ["help", "serve"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("acoustic"))
        XCTAssertTrue(buffer.output.contains("--voice-trust environment"),
                      "the help has to name the dependency the parser enforces")
        XCTAssertTrue(buffer.output.contains("Nothing leaves the machine while idle"),
                      "the privacy property is the reason the mode is acceptable at all")
        XCTAssertTrue(buffer.output.contains("TAPQ_ACOUSTIC_ONSET_LEVEL"),
                      "the tuning knobs have to be discoverable from the CLI")
    }
}
