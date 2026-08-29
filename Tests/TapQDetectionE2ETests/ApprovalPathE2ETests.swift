import XCTest
import TapQBrokerRuntime
import TapQContracts
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Tier 1: the core approval loop, IMU samples in, decision out.
@MainActor
final class ApprovalPathE2ETests: XCTestCase {
    private func request() -> ApprovalRequest {
        ApprovalRequest(id: "r1", sessionID: "s1", toolName: "Bash",
                        summary: "run the test suite", detail: "swift test")
    }

    /// Bytes to bytes: an agent's approval request arrives on the wire, a nod arrives on
    /// the IMU, and the allow leaves on the wire. Everything between — broker, controller,
    /// arbiter, pipeline — is the shipping implementation.
    func testNodApprovesWireToWire() async throws {
        let harness = DetectionPathHarness()
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { [harness] in await harness.interaction.resolve($0) },
            onNotification: { _ in }
        )
        try server.start()
        defer { server.stop() }

        let exchange = Task { try await transport.deliver(Data(Self.approvalRequestJSON.utf8)) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")
        harness.feed(TraceGenerators.doubleNod())

        let responseData = try await exchange.value
        harness.assertWatchdogDidNotFire()
        let response = try JSONDecoder().decode(BrokerResponse.self, from: responseData)
        XCTAssertEqual(response, .decision(.allow, reason: nil))
        XCTAssertTrue(harness.speech.spoken.contains { $0.text.contains("run the test suite") },
                      "the request must have been spoken before the window opened")
    }

    func testShakeDenies() async {
        let harness = DetectionPathHarness()
        let decision = Task { await harness.interaction.resolve(self.request()) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.feed(TraceGenerators.doubleShake())

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny)
    }

    /// The wearer answers with the word the prompt is about. "approve" and "deny" reach the
    /// controller as the same `.allow`/`.deny` "yes" and "no" reach it as — through the real
    /// grammar, so this asserts the synonym is wired the whole way down rather than only in
    /// the matcher's own unit test.
    func testSpokenApproveAllows() async {
        let harness = DetectionPathHarness()
        let decision = Task { await harness.interaction.resolve(self.request()) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("approve")

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
    }

    func testSpokenDenyDenies() async {
        let harness = DetectionPathHarness()
        let decision = Task { await harness.interaction.resolve(self.request()) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("deny")

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny)
    }

    /// `gestureAndVoice` demands two independent channels. A nod arms it, a second nod
    /// does not complete it, and only a spoken "yes" — matched by the real grammar — does.
    func testGestureAndVoiceNeedsBothChannels() async {
        let harness = DetectionPathHarness()
        let decision = Task {
            await harness.interaction.resolve(
                self.request(), requiredConfirmation: .gestureAndVoice)
        }

        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow)
        harness.feed(TraceGenerators.doubleNod())

        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow, "a nod alone must arm the requirement, not resolve it")
        XCTAssertTrue(harness.speech.said("Risky action. Say yes to confirm."),
                      "the cue must name the missing half")
        harness.feed(TraceGenerators.doubleNod())

        let thirdWindow = await harness.waitForWindow(3)
        XCTAssertTrue(thirdWindow,
                      "a second head movement is one channel twice, not two channels")
        harness.hear("yes")

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
        XCTAssertEqual(harness.inputs.openedWindows, 3,
                       "the spoken half completed the requirement without a further window")
    }

    /// Wire protocol v4, `pre_tool_use` outside auto mode, so the broker delegates to the
    /// approval closure rather than auto-passing.
    private static let approvalRequestJSON = """
        {"type":"approval.request","token":"tok","protocol_version":4,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","tool_name":"Bash","tool_input":{"command":"swift test"},\
        "summary":"run the test suite","detail":"swift test",\
        "approval_source":"pre_tool_use","request_id":"r1"}
        """
}
