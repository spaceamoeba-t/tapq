import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQContracts

/// The audit trail for the one thing TapQ does without telling anyone.
///
/// These tests hold the file to the `ReasonerShadowLog` discipline it copies — one JSON
/// object per line, sorted keys, `0600`, two generations, and never a thrown error — and
/// to the one property that is specific to this log: an auto-allow row has to say enough
/// about what was approved, and under which threshold, to still make sense a week later
/// when the threshold has changed.
@MainActor
final class AutoAnswerLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-auto-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func request(id: String = "req-1") -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            sessionID: "session-1",
            agent: .claudeCode,
            toolName: "Bash",
            summary: "run npm test",
            detail: "npm test --silent",
            toolInput: ["command": .string("npm test --silent")],
            cwd: "/Users/someone/project"
        )
    }

    private func context(
        toolName: String = "Bash",
        summary: String = "run npm test",
        toolInput: [String: JSONValue]? = nil
    ) -> ReasonerContext {
        ReasonerContext(
            toolName: toolName,
            commandText: "npm test --silent",
            toolInput: toolInput,
            cwd: "/Users/someone/project",
            agentName: "Claude Code",
            summary: summary
        )
    }

    private func decided(
        tier: RiskTier = .routine,
        confidence: Double = 0.94
    ) -> ReasonerAssessment {
        ReasonerAssessment(
            outcome: .decided(ReasonerDecision(
                riskTier: tier,
                requiredConfirmation: .standard,
                rationale: ReasonerRationale(code: .unspecified),
                confidence: confidence
            )),
            latencyMilliseconds: 312
        )
    }

    private func lines(_ url: URL) throws -> [String] {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func object(_ line: String) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: Data(line.utf8))
        return try XCTUnwrap(parsed as? [String: Any])
    }

    // MARK: - Shape

    func testAnAutoAllowRowSaysWhatWasApprovedAndUnderWhichThreshold() async throws {
        let log = AutoAnswerLog(directory: directory)
        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: AutoAnswerPolicy(minimumConfidence: 0.8)
        )

        let rows = try lines(log.fileURL)
        XCTAssertEqual(rows.count, 1)
        let row = try object(rows[0])
        XCTAssertEqual(row["verdict"] as? String, "auto_allow")
        XCTAssertEqual(row["request_id"] as? String, "req-1")
        XCTAssertEqual(row["agent_name"] as? String, "Claude Code")
        XCTAssertEqual(row["tool_name"] as? String, "Bash")
        XCTAssertEqual(row["summary"] as? String, "run npm test")
        XCTAssertEqual(row["risk_tier"] as? String, "routine")
        XCTAssertEqual(row["code"] as? String, "unspecified")
        XCTAssertEqual(row["confidence"] as? Double, 0.94)
        XCTAssertEqual(row["minimum_confidence"] as? Double, 0.8)
        XCTAssertEqual(row["reasoner_latency_ms"] as? Int, 312)
        XCTAssertNotNil(row["ts"] as? String)
        XCTAssertNil(row["reason"], "an auto-allow has nothing to explain")
        XCTAssertNil(row["abstain_reason"])
    }

    func testTheRowNeverCarriesTheCommandLineTheWorkingDirectoryOrTheDetail() async throws {
        let log = AutoAnswerLog(directory: directory)
        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )

        let text = String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self)
        XCTAssertFalse(text.contains("--silent"), "the full command line stays out")
        XCTAssertFalse(text.contains("/Users/someone/project"), "the cwd stays out")
        XCTAssertFalse(text.contains("session-1"), "the session id is not review signal")
    }

    func testARefusalRowNamesItsReasonAndTheAbstentionBehindIt() async throws {
        let log = AutoAnswerLog(directory: directory)
        let assessment = ReasonerAssessment(
            outcome: .abstained(.timedOut),
            latencyMilliseconds: 2_250
        )
        log.append(
            request: request(id: "req-2"),
            context: context(),
            assessment: assessment,
            verdict: AutoAnswerPolicy.defaults.decision(for: assessment, toolName: "Bash"),
            policy: .defaults
        )

        let row = try object(try XCTUnwrap(lines(log.fileURL).first))
        XCTAssertEqual(row["verdict"] as? String, "ask")
        XCTAssertEqual(row["reason"] as? String, "reasoner_timeout")
        XCTAssertEqual(row["abstain_reason"] as? String, "timeout")
        XCTAssertNil(row["risk_tier"], "there was no decision to have a tier")
        XCTAssertNil(row["confidence"])
        XCTAssertEqual(row["reasoner_latency_ms"] as? Int, 2_250)
    }

    func testAnOpenSchemaContextWithholdsTheModelsConfidence() async throws {
        let log = AutoAnswerLog(directory: directory)
        log.append(
            request: request(),
            context: context(
                toolName: "mcp__notion__create_page",
                summary: "create a page",
                toolInput: ["title": .string("Q3 plan")]
            ),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )

        let row = try object(try XCTUnwrap(lines(log.fileURL).first))
        XCTAssertNil(
            row["confidence"],
            "numeric precision from a connector context is an echo channel"
        )
        XCTAssertEqual(row["risk_tier"] as? String, "routine", "the closed values remain")
        XCTAssertEqual(row["verdict"] as? String, "auto_allow")
    }

    func testKeysAreSortedAndEachAppendIsOneLine() async throws {
        let log = AutoAnswerLog(directory: directory)
        for index in 0..<3 {
            log.append(
                request: request(id: "req-\(index)"),
                context: context(),
                assessment: decided(),
                verdict: .autoAllow,
                policy: .defaults
            )
        }

        let rows = try lines(log.fileURL)
        XCTAssertEqual(rows.count, 3)
        let keys = try object(rows[0]).keys.sorted()
        let positions = keys.compactMap { rows[0].range(of: "\"\($0)\":")?.lowerBound }
        XCTAssertEqual(positions.count, keys.count)
        XCTAssertEqual(positions, positions.sorted(), "sorted keys keep the file greppable")
        XCTAssertEqual(
            try lines(log.fileURL).map { try object($0)["request_id"] as? String },
            ["req-0", "req-1", "req-2"],
            "appends preserve order"
        )
    }

    func testTheFileIsCreatedPrivate() async throws {
        let log = AutoAnswerLog(directory: directory)
        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )
        let mode = try FileManager.default
            .attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    // MARK: - Rotation

    func testTheLiveFileRotatesBeforeItCrossesTheCap() async throws {
        let log = AutoAnswerLog(directory: directory)
        try growLiveFile(of: log, to: AutoAnswerLog.maximumBytes)

        log.append(
            request: request(id: "after-rotation"),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.rotatedFileURL.path))
        let rows = try lines(log.fileURL)
        XCTAssertEqual(rows.count, 1, "the live file starts over")
        XCTAssertEqual(try object(rows[0])["request_id"] as? String, "after-rotation")
        XCTAssertLessThan(try liveSize(of: log), AutoAnswerLog.maximumBytes)
    }

    func testAppendingBelowTheCapDoesNotRotate() async throws {
        let log = AutoAnswerLog(directory: directory)
        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )
        log.append(
            request: request(id: "req-2"),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: log.rotatedFileURL.path))
        XCTAssertEqual(try lines(log.fileURL).count, 2)
    }

    func testOnlyTwoGenerationsSurviveAndTheOlderOneIsReplaced() async throws {
        let log = AutoAnswerLog(directory: directory)
        try Data("stale generation\n".utf8).write(to: log.rotatedFileURL)
        try growLiveFile(of: log, to: AutoAnswerLog.maximumBytes)

        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )

        let rotated = try Data(contentsOf: log.rotatedFileURL)
        XCTAssertEqual(rotated.count, AutoAnswerLog.maximumBytes,
                       "the previous rotation was replaced, not kept alongside")
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("auto-answer-log") }
        XCTAssertEqual(Set(siblings), [AutoAnswerLog.fileName, AutoAnswerLog.rotatedFileName])
    }

    // MARK: - Failure is silent

    func testAnUnwritableDirectoryCostsTheArtifactAndNothingElse() async throws {
        let log = AutoAnswerLog(
            directory: directory.appendingPathComponent("missing", isDirectory: true)
        )
        log.append(
            request: request(),
            context: context(),
            assessment: decided(),
            verdict: .autoAllow,
            policy: .defaults
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: log.fileURL.path),
            "nothing was written, and nothing was thrown: the approval already happened"
        )
    }

    // MARK: - Helpers

    private func growLiveFile(of log: AutoAnswerLog, to bytes: Int) throws {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.createFile(
            atPath: log.fileURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))
        let handle = try FileHandle(forWritingTo: log.fileURL)
        defer { try? handle.close() }
        // Sparse: the cap is read from the file's reported size, so the test does not have
        // to actually write five megabytes to reach it.
        try handle.truncate(atOffset: UInt64(bytes))
    }

    private func liveSize(of log: AutoAnswerLog) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }
}
