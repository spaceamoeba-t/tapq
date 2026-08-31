import Foundation
import XCTest
@testable import TapQCLI
import TapQContextBaseline

/// `tapq memory clear` — the on-demand wipe of TapQ's own conversation memory.
///
/// The command exists because the record is a private log of what its wearer said out
/// loud, and a person must be able to end it without editing a path by hand or knowing
/// where the runtime keeps its state.
final class MemoryCommandTests: XCTestCase {
    private final class Buffer {
        var output = ""
        var error = ""
        /// What the confirmation prompt is answered with. `nil` is an EOF stdin, which is
        /// what the packaged runtime's launcher gives a prompt — and which must therefore
        /// keep the file rather than remove it.
        var answer: String?

        var io: TapQCLIIO {
            TapQCLIIO(
                writeOutput: { self.output += $0 },
                writeError: { self.error += $0 },
                readInput: { self.answer }
            )
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-memory-cmd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Parsing

    func testClearIsTheOnlyMemoryAction() throws {
        XCTAssertEqual(
            try CLICommandParser.parse(["memory", "clear"]),
            .memory(.clear(MemoryClearOptions()))
        )
        XCTAssertEqual(
            try CLICommandParser.parse(["memory", "clear", "--yes"]),
            .memory(.clear(MemoryClearOptions(confirmed: true)))
        )
        XCTAssertEqual(
            try CLICommandParser.parse(["memory", "clear", "--broker-dir", "/tmp/x"]),
            .memory(.clear(MemoryClearOptions(brokerDirectoryPath: "/tmp/x")))
        )
        XCTAssertEqual(try CLICommandParser.parse(["memory"]), .help(.memory))
        XCTAssertEqual(try CLICommandParser.parse(["help", "memory"]), .help(.memory))
    }

    /// Refused by name rather than falling through to help: a verb whose whole job is to
    /// destroy something must not read as a command that quietly did nothing.
    func testAnUnknownMemoryActionIsRefused() {
        XCTAssertThrowsError(try CLICommandParser.parse(["memory", "show"])) { error in
            XCTAssertEqual(
                (error as? CLIUsageError)?.message,
                "Unknown memory action 'show'. Available actions: 'clear'."
            )
        }
        XCTAssertThrowsError(try CLICommandParser.parse(["memory", "clear", "--all"]))
    }

    // MARK: - Clearing

    @MainActor
    func testClearRemovesTheRecordTheRuntimeWrites() async {
        let store = WearerConversationStore(directory: directory)
        store.recordWearerUtterance("something I would rather not keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))

        let buffer = Buffer()
        let status = await application(io: buffer.io)
            .run(arguments: ["memory", "clear", "--yes"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Conversation memory cleared"), buffer.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// The prompt is answered, not assumed. An EOF stdin — which is what the packaged
    /// runtime's `open -n -W` launcher gives an interactive prompt — keeps the file.
    @MainActor
    func testTheConfirmationPromptMustBeAnswered() async {
        let store = WearerConversationStore(directory: directory)
        store.recordWearerUtterance("keep me")

        let buffer = Buffer()
        buffer.answer = nil
        let status = await application(io: buffer.io).run(arguments: ["memory", "clear"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("Conversation memory kept."), buffer.output)
        XCTAssertTrue(buffer.error.contains("remembered exchange(s)"), buffer.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @MainActor
    func testAYesAtThePromptClearsTheRecord() async {
        let store = WearerConversationStore(directory: directory)
        store.recordWearerUtterance("go ahead")

        let buffer = Buffer()
        buffer.answer = "y"
        let status = await application(io: buffer.io).run(arguments: ["memory", "clear"])

        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    /// Nothing to clear is not a failure; it is a different sentence, and it names the
    /// path so an operator who cleared the wrong directory can see that they did.
    @MainActor
    func testClearSaysWhenThereWasNothingThere() async {
        let buffer = Buffer()
        let status = await application(io: buffer.io)
            .run(arguments: ["memory", "clear", "--yes"])

        XCTAssertEqual(status, 0)
        XCTAssertTrue(buffer.output.contains("No conversation memory found"), buffer.output)
        XCTAssertTrue(
            buffer.output.contains(WearerConversationStore.fileName),
            buffer.output
        )
    }

    /// `--broker-dir` clears the record a runtime served with the same override wrote,
    /// rather than the default one it never touched.
    @MainActor
    func testBrokerDirSelectsTheRecordToClear() async throws {
        let other = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let defaultStore = WearerConversationStore(directory: directory)
        defaultStore.recordWearerUtterance("in the default directory")
        let overrideStore = WearerConversationStore(directory: other)
        overrideStore.recordWearerUtterance("in the override")

        let buffer = Buffer()
        let status = await application(io: buffer.io)
            .run(arguments: ["memory", "clear", "--broker-dir", other.path, "--yes"])

        XCTAssertEqual(status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: overrideStore.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultStore.fileURL.path))
    }

    // MARK: - Helpers

    @MainActor
    private func application(io: TapQCLIIO) -> TapQCLIApplication {
        TapQCLIApplication(
            io: io,
            environment: ["TAPQ_BROKER_DIR": directory.path],
            homeDirectory: directory,
            executableURL: directory.appendingPathComponent("tapq"),
            currentDirectory: directory
        )
    }
}
