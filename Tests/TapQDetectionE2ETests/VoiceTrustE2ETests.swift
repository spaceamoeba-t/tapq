import Foundation
import XCTest
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQWireProtocol
@testable import TapQInteractionBaseline

/// Rung E end to end: the run a wearer starts with their AirPods in the case.
///
/// The composition is the runtime's own minus the microphone, exactly as
/// `InstructionPathE2ETests` composes it — same grammar, same queue, same coordinator, same
/// wire — with one difference and one difference only: `--voice-trust environment`, and
/// therefore no attribution signal at all. The suite exists to pin what that buys (a
/// dictation that reaches the agent) and what it must not cost (an approval that behaves
/// any differently).
@MainActor
final class VoiceTrustE2ETests: XCTestCase {
    private static let session = "s1"

    private func request(summary: String = "run npm test") -> ApprovalRequest {
        ApprovalRequest(
            id: "r1", sessionID: Self.session, agent: .claudeCode, toolName: "Bash",
            summary: summary, detail: "npm test"
        )
    }

    /// The whole rung, wire to wire: no AirPods, no attribution, a spoken sentence, a spoken
    /// yes, and an agent that is told about it at its next turn boundary.
    ///
    /// Note what is *not* here: a nod. There is no motion device in this session, so the
    /// read-back never mentions one and the confirmation is the wearer's own "yes" through
    /// the real grammar.
    func testEnvironmentTrustDictationReachesTheAgentWithNoAttributionSignal() async throws {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let harness = DetectionPathHarness(
            instructionCapability: memory.instructionCapability,
            // The fail-closed answer, every time it is asked. Under environment trust it is
            // never asked, which is the claim.
            wearerAttribution: { false },
            instructionEnqueue: memory.instructionEnqueue,
            motionAvailable: false,
            voiceTrust: .environment,
            gestureConfirmation: { false }
        )

        let approval = request()
        let decision = Task {
            await memory.withWindow(
                sessionID: approval.sessionID,
                agent: approval.agent,
                summary: approval.summary,
                detail: approval.detail
            ) {
                await harness.interaction.resolve(approval)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened, "the approval opened no input window")

        harness.hear("tell it to run the tests again")

        let readBackWindow = await harness.waitForWindow(2)
        XCTAssertTrue(readBackWindow, "the read-back must re-listen")
        XCTAssertTrue(
            harness.speech.said("Instruction: 'run the tests again.' Say yes to queue it."),
            "the read-back must not ask for a gesture nobody can make: "
                + "\(harness.speech.spoken.map(\.text))"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty,
                      "nothing may be queued before the wearer confirms it")

        harness.hear("yes")
        let resumed = await harness.waitForWindow(3)
        XCTAssertTrue(resumed, "queueing must resume the window")
        XCTAssertTrue(harness.speech.said("Queued for Claude Code."))
        XCTAssertEqual(mailbox.pending(session: Self.session).map(\.text),
                       ["run the tests again"])
        XCTAssertTrue(harness.diagnostics.events.contains {
            $0.name == "instruction.trusted_environment"
        }, "the bypass must be diagnosable")
        XCTAssertFalse(harness.diagnostics.events.contains {
            $0.name == "instruction.rejected_unattributed"
        })

        // The approval the wearer was asked about is untouched by all of it, and answering
        // it is still what ends the window.
        harness.hear("no")
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny, "dictation must never resolve the request")

        // The turn boundary, on the wire, over the runtime's own coordinator.
        let coordinator = StopQuestionCoordinator(
            classifier: NeverAQuestion(),
            instructions: mailbox,
            recordInstruction: memory.instructionRecorder,
            runSelection: { _, _ in .noSelection },
            runApproval: { _, _ in .ask }
        )
        let transport = InMemoryBrokerTransport()
        let server = BrokerServer(
            transport: transport,
            token: "tok",
            onApproval: { _ in .ask },
            onNotification: { _ in },
            onStopQuestion: { await coordinator.handle($0) }
        )
        try server.start()
        defer { server.stop() }

        let responseData = try await transport.deliver(Data(Self.stopQuestionJSON.utf8))
        let response = try JSONDecoder().decode(BrokerResponse.self, from: responseData)
        XCTAssertEqual(
            response,
            .stopQuestion(reply: "The user dictated a new instruction via TapQ hands-free: "
                + "'run the tests again'. Proceed accordingly."),
            "the boundary must carry the instruction the room dictated"
        )
    }

    /// The same session, the same missing signal, under the default posture: refused out
    /// loud and queued nowhere. This is the test that would fail if environment trust ever
    /// leaked into a default-flag run.
    func testTheSameDictationIsStillRefusedUnderWearerTrust() async {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let harness = DetectionPathHarness(
            instructionCapability: memory.instructionCapability,
            wearerAttribution: { false },
            instructionEnqueue: memory.instructionEnqueue,
            motionAvailable: false
        )

        let approval = request()
        let decision = Task {
            await memory.withWindow(
                sessionID: approval.sessionID,
                agent: approval.agent,
                summary: approval.summary
            ) {
                await harness.interaction.resolve(approval)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("tell it to run the tests again")

        let refusalWindow = await harness.waitForWindow(2)
        XCTAssertTrue(refusalWindow, "a refusal must re-listen, not resolve")
        XCTAssertTrue(
            harness.speech.said("I can't confirm that was you — instruction discarded."),
            "spoke: \(harness.speech.spoken.map(\.text))"
        )
        XCTAssertTrue(mailbox.pending(session: Self.session).isEmpty)

        harness.hear("yes")
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "the wearer's own request still answers normally")
    }

    /// Trust is a policy about instructions. An approval spoken into an environment-trust
    /// run resolves through exactly the path it always did, including the fail-open one.
    func testEnvironmentTrustLeavesTheApprovalPathAlone() async {
        let harness = DetectionPathHarness(
            motionAvailable: false,
            voiceTrust: .environment,
            gestureConfirmation: { false }
        )
        let decision = Task { await harness.interaction.resolve(self.request()) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("no")

        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny)
        XCTAssertTrue(harness.speech.spoken.contains { $0.text.contains("run npm test") })
    }

    // MARK: - Fixtures

    /// The wire message a Claude stop hook sends at the end of a turn.
    private static let stopQuestionJSON = """
        {"type":"stop.question","token":"tok","protocol_version":5,\
        "agent":{"id":"claude-code","display_name":"Claude Code"},\
        "session_id":"s1","text":"All done — the tests are green.","request_id":"q1"}
        """

    /// The classifier that finds no question in the agent's reply, so the only reply the
    /// boundary can produce is the queued sentence.
    private struct NeverAQuestion: ResponseQuestionClassifying {
        func classify(_ text: String) async -> ResponseQuestionClassification? { nil }
    }
}
