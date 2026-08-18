import XCTest
@testable import TapQCLI
import TapQContextBaseline

/// The policy file's two load-bearing behaviors: absent means the strict defaults, and
/// anything unreadable means stop rather than guess.
///
/// The second one is the reason these tests exist. A store that fell back to defaults on a
/// malformed file would look more robust and be strictly worse: the user writes this file
/// to *narrow* what TapQ answers for them, so a typo in it must never quietly restore the
/// wider policy they were editing away from.
final class AutoAnswerPolicyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-auto-answer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func testStore() -> AutoAnswerPolicyStore {
        AutoAnswerPolicyStore(
            policyURL: directory.appendingPathComponent(AutoAnswerPolicyStore.fileName)
        )
    }

    private func write(_ json: String) throws {
        try Data(json.utf8).write(to: testStore().policyURL)
    }

    // MARK: - Location

    func testTheDefaultPathHonorsTheConfigOverrideAndSitsBesideTheProfiles() {
        let store = AutoAnswerPolicyStore.defaultStore(
            environment: ["TAPQ_CONFIG_DIR": directory.path],
            homeDirectory: URL(fileURLWithPath: "/unused")
        )
        XCTAssertEqual(
            store.policyURL,
            directory.appendingPathComponent("auto-answer-policy.json")
        )
        let calibration = CalibrationStore.defaultStore(
            environment: ["TAPQ_CONFIG_DIR": directory.path],
            homeDirectory: URL(fileURLWithPath: "/unused")
        )
        XCTAssertEqual(
            store.policyURL.deletingLastPathComponent(),
            calibration.gestureProfileURL.deletingLastPathComponent(),
            "one TAPQ_CONFIG_DIR must never split the policy from the calibration "
                + "it sits beside"
        )
    }

    // MARK: - Absent

    func testAnAbsentFileIsTheStrictDefaults() throws {
        let store = testStore()
        XCTAssertFalse(store.exists())
        XCTAssertEqual(try store.load(), AutoAnswerPolicy.defaults)
        XCTAssertEqual(try store.load().minimumConfidence, 0.8)
    }

    func testAnAbsentDirectoryIsAlsoTheDefaults() throws {
        let store = AutoAnswerPolicyStore(
            policyURL: directory
                .appendingPathComponent("nowhere", isDirectory: true)
                .appendingPathComponent(AutoAnswerPolicyStore.fileName)
        )
        XCTAssertEqual(try store.load(), AutoAnswerPolicy.defaults)
    }

    // MARK: - Round trip

    func testAPolicyRoundTripsAndIsWrittenReadableAndPrivate() throws {
        let store = testStore()
        let policy = AutoAnswerPolicy(
            minimumConfidence: 0.91,
            neverAutoTools: ["Bash", "WebFetch"]
        )

        try store.save(policy)
        XCTAssertTrue(store.exists())
        XCTAssertEqual(try store.load(), policy)

        let text = String(decoding: try Data(contentsOf: store.policyURL), as: UTF8.self)
        XCTAssertTrue(text.contains("\n"), "the file is hand-edited, so it is pretty-printed")
        XCTAssertTrue(text.hasSuffix("\n"), "a config file ends with a newline")
        let keys = ["minimum_confidence", "never_auto_tools", "schema_version"].sorted()
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        XCTAssertEqual(
            positions, positions.sorted(),
            "keys are sorted, so two saved policies diff cleanly"
        )

        let mode = try FileManager.default
            .attributesOfItem(atPath: store.policyURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    func testSavingCreatesAMissingDirectory() throws {
        let nested = directory
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        let store = AutoAnswerPolicyStore(
            policyURL: nested.appendingPathComponent(AutoAnswerPolicyStore.fileName)
        )
        try store.save(AutoAnswerPolicy(minimumConfidence: 0.5))
        XCTAssertEqual(try store.load().minimumConfidence, 0.5)
    }

    func testAStoredThresholdIsClampedOnTheWayBackIn() throws {
        try write(#"{"schema_version":1,"minimum_confidence":-2,"never_auto_tools":[]}"#)
        XCTAssertEqual(try testStore().load().minimumConfidence, 0.0)
    }

    // MARK: - Malformed

    func testMalformedJSONThrowsRatherThanFallingBackToDefaults() throws {
        try write("{ this is not json")
        XCTAssertThrowsError(try testStore().load())
    }

    func testAnEmptyFileThrows() throws {
        try write("")
        XCTAssertThrowsError(try testStore().load())
    }

    func testAFileMissingTheSchemaVersionThrows() throws {
        try write(#"{"minimum_confidence":0.5}"#)
        XCTAssertThrowsError(try testStore().load())
    }

    func testAWrongTypedFieldThrows() throws {
        try write(#"{"schema_version":1,"minimum_confidence":"high"}"#)
        XCTAssertThrowsError(try testStore().load())
    }

    func testAnUnknownSchemaThrowsANamedError() throws {
        try write(#"{"schema_version":2,"minimum_confidence":0.5}"#)
        XCTAssertThrowsError(try testStore().load()) { error in
            XCTAssertEqual(
                error as? AutoAnswerPolicyStoreError,
                .unsupportedSchema(2)
            )
            XCTAssertEqual(
                (error as? AutoAnswerPolicyStoreError)?.errorDescription,
                "The auto-answer policy schema 2 is not supported by this TapQ version."
            )
        }
    }

    func testSavingAnUnknownSchemaIsRefusedBeforeItTouchesDisk() {
        let store = testStore()
        XCTAssertThrowsError(
            try store.save(AutoAnswerPolicy(schemaVersion: 7, minimumConfidence: 0.5))
        ) { error in
            XCTAssertEqual(error as? AutoAnswerPolicyStoreError, .unsupportedSchema(7))
        }
        XCTAssertFalse(store.exists())
    }
}
