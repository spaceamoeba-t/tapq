import Foundation
import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQInteractionBaseline

/// `tapq policy show`, and what the Rung D flags put into the runtime configuration.
///
/// The command exists because an auto-answer is the one thing TapQ does that the wearer is
/// not present for, so "what would it answer for me?" has to be a question anyone can ask
/// without starting a runtime — and has to be answered by the same store the runtime reads,
/// including when that store refuses to read at all.
final class PolicyCommandTests: XCTestCase {
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

    /// Records the configuration `serve` was given and returns immediately, so a CLI test
    /// can assert on plumbing without a broker, a socket, or any hardware.
    @MainActor
    private final class RecordingRuntime: TapQRuntimeServing {
        private(set) var configurations: [TapQRuntimeConfiguration] = []

        func serve(
            configuration: TapQRuntimeConfiguration,
            reasonerLoader: TapQReasonerLoading?,
            onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
        ) async throws {
            configurations.append(configuration)
            onReady(.init(
                socketPath: "/tmp/tapq.sock",
                discoveryPath: "/tmp/broker.json",
                gestureProfileLoaded: false,
                tapProfileLoaded: false,
                motionAvailable: true,
                voiceAvailable: true,
                autoAnswerStatus: configuration.autoAnswerMode == .off
                    ? nil : "routine (min confidence 0.8, 0 never-auto tools)",
                attentionStatus: configuration.attentionMode == .off
                    ? nil : "imu (8s command windows between requests)",
                voiceProcessingStatus: configuration.voiceProcessingEnabled
                    ? "experimental, enabled (half-duplex unchanged)" : nil,
                quietStatus: configuration.quietEnabled
                    ? "cues for prompts and notifications; answers still spoken" : nil
            ))
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - policy show

    @MainActor
    func testShowReportsTheDefaultsWhenNoFileExists() async {
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(arguments: ["policy", "show"])

        XCTAssertEqual(status, 0)
        // The distinction is spoken out loud because the two states behave identically:
        // an operator who edited the wrong path would otherwise read their own defaults
        // back and believe the file had been found.
        XCTAssertTrue(buffer.output.contains("Source: defaults (no file)"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Minimum confidence: 0.8"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Never auto-answer: (none)"), buffer.output)
    }

    @MainActor
    func testShowReadsAFileAndNamesItAsTheSource() async throws {
        try write(#"{"schema_version":1,"minimum_confidence":0.95,"never_auto_tools":["Bash"]}"#)
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(arguments: ["policy", "show"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Source: file"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Minimum confidence: 0.95"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Never auto-answer: Bash"), buffer.output)
    }

    @MainActor
    func testShowJSONEmitsTheEffectivePolicy() async throws {
        try write(#"{"schema_version":1,"minimum_confidence":0.9}"#)
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(
            arguments: ["policy", "show", "--json"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("\"minimum_confidence\" : 0.9"), buffer.output)
        XCTAssertTrue(buffer.output.contains("\"schema_version\" : 1"), buffer.output)
    }

    /// The same refusal `serve` would make, surfaced where an operator can act on it: a
    /// typo in a list written to *narrow* what gets answered must never silently widen it
    /// back out to the defaults.
    @MainActor
    func testShowFailsOnAnUnknownSchemaRatherThanFallingBackToDefaults() async throws {
        try write(#"{"schema_version":99,"minimum_confidence":0.5}"#)
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(arguments: ["policy", "show"])

        XCTAssertEqual(status, 1)
        XCTAssertTrue(buffer.error.contains("schema 99 is not supported"), buffer.error)
        XCTAssertFalse(buffer.output.contains("Minimum confidence"), buffer.output)
    }

    @MainActor
    func testShowFailsOnAMalformedFile() async throws {
        try write("{ not json")
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(arguments: ["policy", "show"])

        XCTAssertEqual(status, 1)
        XCTAssertFalse(buffer.output.contains("Minimum confidence"), buffer.output)
    }

    @MainActor
    func testShowHonorsAnExplicitPolicyPath() async throws {
        let elsewhere = directory.appendingPathComponent("elsewhere.json")
        try Data(#"{"schema_version":1,"minimum_confidence":0.42}"#.utf8).write(to: elsewhere)
        let buffer = Buffer()
        let status = await application(io: buffer.io).run(
            arguments: ["policy", "show", "--policy", elsewhere.path])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Minimum confidence: 0.42"), buffer.output)
    }

    // MARK: - serve plumbing

    @MainActor
    func testFlagsReachTheRuntimeConfiguration() async {
        let buffer = Buffer()
        let runtime = RecordingRuntime()
        let status = await application(io: buffer.io, runtime: runtime).run(arguments: [
            "serve", "--reasoner", "apple", "--reasoner-mode", "primary",
            "--auto-answer", "routine", "--wearer-gate", "--attention", "imu",
            "--voice-processing", "--quiet",
        ])

        XCTAssertEqual(status, 0)
        let configuration = try? XCTUnwrap(runtime.configurations.first)
        XCTAssertEqual(configuration?.autoAnswerMode, .routine)
        XCTAssertEqual(configuration?.attentionMode, .imu)
        XCTAssertEqual(configuration?.voiceProcessingEnabled, true)
        XCTAssertEqual(configuration?.quietEnabled, true)
        XCTAssertTrue(buffer.output.contains("Auto-answer: routine"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Attention: imu"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Voice processing: experimental"), buffer.output)
        XCTAssertTrue(buffer.output.contains("Quiet output:"), buffer.output)
    }

    /// A bare `serve` reports none of the four lines, which is what "byte-identical" looks
    /// like from the operator's side: nothing on the console says a new feature exists.
    @MainActor
    func testABareServeReportsNoneOfTheRungDLines() async {
        let buffer = Buffer()
        let runtime = RecordingRuntime()
        let status = await application(io: buffer.io, runtime: runtime).run(
            arguments: ["serve"])

        XCTAssertEqual(status, 0)
        XCTAssertFalse(buffer.output.contains("Auto-answer:"), buffer.output)
        XCTAssertFalse(buffer.output.contains("Attention:"), buffer.output)
        XCTAssertFalse(buffer.output.contains("Voice processing:"), buffer.output)
        XCTAssertFalse(buffer.output.contains("Quiet output:"), buffer.output)
    }

    // MARK: - Helpers

    private func write(_ json: String) throws {
        try Data(json.utf8).write(
            to: directory.appendingPathComponent(AutoAnswerPolicyStore.fileName))
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
}
