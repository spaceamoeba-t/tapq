import Foundation
import XCTest
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Tier 1 for Rung D: an agent's approval arrives on the wire and is answered — or is not —
/// without the wearer, through the real policy, the real audit log, and the real
/// interaction stack behind it.
///
/// The composition mirrors the runtime's `runApproval` primary path exactly: assess, price
/// the confirmation, consult the filter, and only then enter the gate. That ordering is the
/// feature — answering before the gate is what makes an auto-allow silent — so it is what
/// these tests drive, rather than calling `AutoAnswerPolicy.decision` directly, which would
/// prove only that a pure function is pure.
@MainActor
final class DelegationFilterE2ETests: XCTestCase {
    /// A stage-2 backend that always says the same thing. The reasoner protocol is portable,
    /// so the stub is the only faked piece in the path — everything downstream of the
    /// decision is the shipping implementation.
    private struct ScriptedReasoner: ContextReasoning {
        let decision: ReasonerDecision?
        func assess(_ context: ReasonerContext) async -> ReasonerDecision? { decision }
    }

    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-rungd-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    // MARK: - The filter answering

    /// Wire to wire with nobody asked: the request arrives as bytes, the reasoner calls it
    /// routine, and `allow` leaves on the wire without a window ever opening or a word being
    /// spoken. The row in the audit log is the only trace, which is the whole point of the
    /// row.
    func testRoutineTierIsAutoAllowedWireToWireAndLogged() async throws {
        let path = FilterPath(
            directory: directory,
            reasoner: ScriptedReasoner(decision: Self.decision(tier: .routine, confidence: 0.9)),
            policy: AutoAnswerPolicy()
        )
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport, token: "tok",
            onApproval: { [path] in await path.resolve($0) },
            onNotification: { _ in }
        )
        try server.start()
        defer { server.stop() }

        let response = try JSONDecoder().decode(
            BrokerResponse.self,
            from: try await transport.deliver(Data(Self.approvalRequestJSON.utf8))
        )

        XCTAssertEqual(response, .decision(.allow, reason: nil))
        XCTAssertEqual(path.harness.inputs.openedWindows, 0,
                       "an auto-answer must never open an input window")
        XCTAssertTrue(path.harness.speech.spoken.isEmpty,
                      "an auto-answer is silent; that is the feature")

        // Recorded three ways, each answering a different question.
        XCTAssertEqual(path.memory.autoAnsweredCount, 1)
        XCTAssertEqual(path.memory.events(session: "s1").count, 1,
                       "an auto-allow is still a resolved approval in session memory")

        let row = try XCTUnwrap(self.rows(in: path.logURL).first)
        XCTAssertEqual(row["verdict"] as? String, "auto_allow")
        XCTAssertEqual(row["tool_name"] as? String, "Bash")
        XCTAssertEqual(row["risk_tier"] as? String, "routine")
        XCTAssertEqual(row["minimum_confidence"] as? Double, 0.8)
        XCTAssertNil(row["reason"], "an auto-allow has no refusal to name")
    }

    // MARK: - The filter declining

    /// A sensitive action is exactly as interruptive as it was before the filter existed:
    /// the window opens, the prompt is spoken, and a nod answers it.
    func testNonRoutineTierOpensTheWindowUnchanged() async throws {
        try await assertOpensAWindow(
            reasoner: ScriptedReasoner(
                decision: Self.decision(tier: .sensitive, confidence: 0.99)),
            policy: AutoAnswerPolicy()
        )
    }

    /// The failure shape that matters most: no decision at all. Fail = ask the human.
    func testAnAbstainingReasonerOpensTheWindow() async throws {
        try await assertOpensAWindow(
            reasoner: ScriptedReasoner(decision: nil),
            policy: AutoAnswerPolicy()
        )
    }

    /// Routine, and confident enough for the *reasoner's* floor (`ReasonerConfig
    /// .minConfidence`, 0.5) so the decision survives `assess` and reaches the policy — but
    /// short of the user's stricter 0.8. The second threshold is the one under test, and it
    /// only exists as a distinct check when a decision can clear the first and fail it.
    func testARoutineDecisionBelowTheUsersFloorOpensTheWindow() async throws {
        try await assertOpensAWindow(
            reasoner: ScriptedReasoner(
                decision: Self.decision(tier: .routine, confidence: 0.6)),
            policy: AutoAnswerPolicy()
        )
    }

    /// Routine and confident, but the user named the tool.
    func testANeverAutoToolOpensTheWindow() async throws {
        try await assertOpensAWindow(
            reasoner: ScriptedReasoner(
                decision: Self.decision(tier: .routine, confidence: 0.99)),
            policy: AutoAnswerPolicy(neverAutoTools: ["bash"])
        )
    }

    // MARK: - The flag off

    /// The byte-identical promise, end to end: the same routine, high-confidence assessment
    /// that is answered silently above opens an ordinary window when no policy is composed.
    /// Nothing else about the path differs — same reasoner, same request, same stack.
    func testWithTheFilterOffARoutineDecisionStillOpensTheWindow() async throws {
        try await assertOpensAWindow(
            reasoner: ScriptedReasoner(
                decision: Self.decision(tier: .routine, confidence: 0.99)),
            policy: nil
        )
    }

    /// And leaves no file behind. A run without `--auto-answer` must not create an audit
    /// artifact for a filter it never ran.
    func testWithTheFilterOffNoAuditFileIsCreated() async throws {
        let path = FilterPath(
            directory: directory,
            reasoner: ScriptedReasoner(
                decision: Self.decision(tier: .routine, confidence: 0.99)),
            policy: nil
        )
        let decision = Task { await path.resolve(Self.request()) }
        let opened = await path.harness.waitForWindow(1)
        XCTAssertTrue(opened)
        path.harness.feed(TraceGenerators.doubleNod())
        _ = await decision.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.logURL.path))
    }

    // MARK: - Helpers

    /// Drives one request all the way through and asserts the wearer was asked: a window
    /// opened, the request was spoken, a nod answered it, and the filter recorded nothing.
    private func assertOpensAWindow(
        reasoner: ScriptedReasoner,
        policy: AutoAnswerPolicy?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let path = FilterPath(directory: directory, reasoner: reasoner, policy: policy)
        let decision = Task { await path.resolve(Self.request()) }

        let opened = await path.harness.waitForWindow(1)
        XCTAssertTrue(opened, "the request must have opened an input window",
                      file: file, line: line)
        path.harness.feed(TraceGenerators.doubleNod())

        let outcome = await decision.value
        path.harness.assertWatchdogDidNotFire(file: file, line: line)
        XCTAssertEqual(outcome, .allow, file: file, line: line)
        XCTAssertTrue(
            path.harness.speech.spoken.contains { $0.text.contains("run the test suite") },
            "the wearer must have been told what they were answering",
            file: file, line: line
        )
        XCTAssertEqual(path.memory.autoAnsweredCount, 0, file: file, line: line)
        XCTAssertTrue(self.rows(in: path.logURL).isEmpty,
                      "a declined request leaves no auto-answer row",
                      file: file, line: line)
    }

    private func rows(in url: URL) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    private static func decision(tier: RiskTier, confidence: Double) -> ReasonerDecision {
        ReasonerDecision(
            riskTier: tier,
            requiredConfirmation: .standard,
            rationale: ReasonerRationale(code: tier == .routine ? .unspecified : .dataLoss),
            confidence: confidence
        )
    }

    private static func request() -> ApprovalRequest {
        ApprovalRequest(
            id: "r1", sessionID: "s1",
            agent: AgentIdentity(id: "claude-code", displayName: "Claude Code"),
            toolName: "Bash", summary: "run the test suite", detail: "swift test"
        )
    }

    private static let approvalRequestJSON = """
        {"type":"approval.request","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","tool_name":"Bash","tool_input":{"command":"swift test"},\
        "summary":"run the test suite","detail":"swift test",\
        "approval_source":"pre_tool_use","request_id":"r1"}
        """
}

/// The runtime's primary approval path, restated over the portable pieces.
///
/// Every layer here is the shipping one — `ReasonerEscalation`, `AutoAnswerPolicy`,
/// `AutoAnswerLog`, `ConversationMemory`, `InteractionGate`, and the detection harness's
/// real controller and arbiter. What is restated is only the *order* the executable composes
/// them in, because that executable is macOS-only and this target is portable on purpose:
/// a wiring regression in the order has to fail on Linux too.
@MainActor
final class FilterPath {
    let harness = DetectionPathHarness()
    let memory = ConversationMemory()
    let gate = InteractionGate()
    let log: AutoAnswerLog
    let logURL: URL

    private let reasoner: any ContextReasoning
    private let policy: AutoAnswerPolicy?
    private let config = ReasonerConfig()

    init(directory: URL, reasoner: any ContextReasoning, policy: AutoAnswerPolicy?) {
        self.reasoner = reasoner
        self.policy = policy
        self.log = AutoAnswerLog(directory: directory)
        self.logURL = log.fileURL
    }

    func resolve(_ request: ApprovalRequest) async -> Decision {
        let decision = await memory.withWindow(
            sessionID: request.sessionID,
            agent: request.agent,
            summary: request.summary,
            detail: request.detail
        ) {
            await self.runApproval(request)
        }
        memory.record(approval: request, decision: decision)
        return decision
    }

    private func runApproval(_ request: ApprovalRequest) async -> Decision {
        let context = ReasonerContext(approvalRequest: request)
        let observed = await ReasonerEscalation.assess(
            context, using: reasoner, under: config)
        let requirement = ReasonerEscalation.requiredConfirmation(
            for: observed.decision, under: config, voiceAvailable: true)

        if let policy {
            let verdict = policy.decision(for: observed, toolName: context.toolName)
            if verdict.isAutoAllow {
                log.append(
                    request: request, context: context, assessment: observed,
                    verdict: verdict, policy: policy
                )
                memory.noteAutoAnswer()
                return .allow
            }
        }

        return await gate.run {
            await self.harness.interaction.resolve(
                request, requiredConfirmation: requirement)
        }
    }
}
