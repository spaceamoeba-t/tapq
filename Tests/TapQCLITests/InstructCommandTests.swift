import Foundation
import XCTest
import TapQWireProtocol
@testable import TapQCLI

/// `--voice-instructions` at startup and `tapq instruct` at a terminal: the two ways this
/// rung is reachable without a microphone.
@MainActor
final class InstructCommandTests: XCTestCase {
    private final class Buffer {
        var out = ""
        var error = ""
        var io: TapQCLIIO {
            TapQCLIIO(
                writeOutput: { [self] in out += $0 },
                writeError: { [self] in error += $0 },
                readInput: { nil }
            )
        }
    }

    /// Records what the command tried to send, and answers with whatever the test scripted.
    private final class FakeBroker: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String: Any]] = []
        var connection: BrokerConnection? = BrokerConnection(
            socketPath: "/tmp/tapq-test.sock",
            token: "t0ken",
            protocolVersion: WireProtocol.version
        )
        var response: BrokerResponse = .ok

        var sent: [[String: Any]] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func submitter() -> InstructionSubmitter {
            InstructionSubmitter(
                connect: { [self] _ in
                    guard let connection else { throw InstructionSubmitError.brokerUnavailable }
                    return connection
                },
                request: { [self] payload, _ in
                    lock.lock()
                    storage.append(
                        (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
                    )
                    lock.unlock()
                    return response.encoded()
                },
                makeRequestID: { "req-1" }
            )
        }
    }

    private func application(_ io: TapQCLIIO, broker: FakeBroker) -> TapQCLIApplication {
        let directory = FileManager.default.temporaryDirectory
        return TapQCLIApplication(
            io: io,
            instructionSubmitter: broker.submitter(),
            environment: [:],
            homeDirectory: directory,
            executableURL: directory.appendingPathComponent("tapq"),
            currentDirectory: directory
        )
    }

    // MARK: - The flag

    func testVoiceInstructionsRequiresTheWearerGate() throws {
        XCTAssertThrowsError(
            try CLICommandParser.parse(["serve", "--voice-instructions"])
        ) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message.contains("requires --wearer-gate"), true,
                "the refusal must name the flag that fixes it"
            )
        }
    }

    func testVoiceInstructionsIsAcceptedWithTheWearerGate() throws {
        let command = try CLICommandParser.parse([
            "serve", "--wearer-gate", "--voice-instructions",
        ])
        guard case let .serve(options) = command else { return XCTFail("expected serve") }
        XCTAssertTrue(options.voiceInstructionsEnabled)
        XCTAssertTrue(options.wearerGateEnabled)
    }

    func testServeDefaultsInstructionsOff() throws {
        let command = try CLICommandParser.parse(["serve"])
        guard case let .serve(options) = command else { return XCTFail("expected serve") }
        XCTAssertFalse(options.voiceInstructionsEnabled)
    }

    // MARK: - Parsing

    func testInstructTakesASessionAndTheRestOfTheLineAsText() throws {
        let command = try CLICommandParser.parse([
            "instruct", "s-1", "run", "the", "tests", "again",
        ])
        XCTAssertEqual(
            command,
            .instruct(InstructOptions(sessionID: "s-1", text: "run the tests again"))
        )
    }

    func testInstructAcceptsOptionsAroundTheText() throws {
        let command = try CLICommandParser.parse([
            "instruct", "--agent", "codex", "s-1", "push the branch", "--broker-dir", "/tmp/x",
        ])
        XCTAssertEqual(
            command,
            .instruct(InstructOptions(
                sessionID: "s-1",
                text: "push the branch",
                brokerDirectoryPath: "/tmp/x",
                agentID: "codex"
            ))
        )
    }

    func testInstructRequiresBothASessionAndText() {
        XCTAssertThrowsError(try CLICommandParser.parse(["instruct"]))
        XCTAssertThrowsError(try CLICommandParser.parse(["instruct", "s-1"]))
        XCTAssertThrowsError(try CLICommandParser.parse(["instruct", "s-1", "--unknown"]))
    }

    // MARK: - Submitting

    func testASubmittedInstructionIsAWireV5MessageForThatSession() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "s-1", "run the tests again"])

        XCTAssertEqual(status, 0)
        XCTAssertEqual(broker.sent.count, 1)
        let message = broker.sent[0]
        XCTAssertEqual(message["type"] as? String, WireType.instructionSubmit)
        XCTAssertEqual(message["session_id"] as? String, "s-1")
        XCTAssertEqual(message["text"] as? String, "run the tests again")
        XCTAssertEqual(message["token"] as? String, "t0ken")
        XCTAssertEqual(message["protocol_version"] as? Int, WireProtocol.version)
        XCTAssertEqual(message["request_id"] as? String, "req-1")
        XCTAssertTrue(buffer.out.contains("next turn boundary"))
    }

    /// The two failures an operator can actually fix, kept apart by exit status: nothing is
    /// running (69, the unavailable-service code every other command uses) versus a broker
    /// that answered no (1).
    func testNoRunningRuntimeIsReportedAsAnUnavailableService() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        broker.connection = nil
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "s-1", "run the tests"])

        XCTAssertEqual(status, 69)
        XCTAssertTrue(buffer.error.contains("no running TapQ runtime"))
        XCTAssertTrue(buffer.error.contains("--voice-instructions"),
                      "the error must name the flags that make the channel exist")
        XCTAssertTrue(broker.sent.isEmpty)
    }

    func testARuntimeWithoutTheChannelIsReportedWithItsRemedy() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        broker.response = .error("instruction_unavailable")
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "s-1", "run the tests"])

        XCTAssertEqual(status, 1)
        XCTAssertTrue(buffer.error.contains("accepts no instructions"))
    }

    /// A v4 runtime is a fine peer for everything else on this wire. Sending it an
    /// instruction would earn an unknown-message-type error, so the command does not.
    func testAPreV5RuntimeIsRefusedBeforeAnythingIsSent() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        broker.connection = BrokerConnection(
            socketPath: "/tmp/tapq-test.sock",
            token: "t0ken",
            protocolVersion: WireProtocol.previousAcceptedVersion
        )
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "s-1", "run the tests"])

        XCTAssertEqual(status, 1)
        XCTAssertTrue(buffer.error.contains("predates the instruction channel"))
        XCTAssertTrue(broker.sent.isEmpty)
    }

    /// RC6 at the command line: an agent with no turn boundary is refused here, with the
    /// same fact the wearer would hear spoken, and no socket is opened.
    func testAnAgentThatCannotBeInstructedIsRefusedAsAUsageError() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "--agent", "opencode", "s-1", "run the tests"])

        XCTAssertEqual(status, 64)
        XCTAssertTrue(buffer.error.contains("instructions aren't supported for OpenCode"),
                      "refused by the wearer-facing name: \(buffer.error)")
        XCTAssertTrue(broker.sent.isEmpty)
    }

    func testAnAgentThatCanBeInstructedPassesThrough() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["instruct", "--agent", "claude-code", "s-1", "run the tests"])

        XCTAssertEqual(status, 0)
        XCTAssertEqual(broker.sent.count, 1)
    }

    func testInstructHelpNamesItselfADebugSeam() async {
        let buffer = Buffer()
        let broker = FakeBroker()
        let status = await application(buffer.io, broker: broker)
            .run(arguments: ["help", "instruct"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.out.contains("debug and device-adapter seam"))
        XCTAssertTrue(buffer.out.contains("authorizes nothing"))
    }
}
