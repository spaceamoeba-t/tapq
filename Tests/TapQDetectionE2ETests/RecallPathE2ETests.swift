import XCTest
import TapQCLI
import TapQContextBaseline
import TapQContracts
@testable import TapQInteractionBaseline

/// Rung B end to end: an IMU nod resolves an approval, the runtime's own conversation
/// memory records it, and a question spoken into the *next* window is answered out of
/// that memory without disturbing the window it was asked in.
///
/// Nothing between the sample and the sentence is faked. The gesture is a generated trace
/// through the real pipeline, the question is a transcript through the real grammar, the
/// memory is the `ConversationMemory` the runtime composes, and the prose is the
/// deterministic composition the wearer would hear.
@MainActor
final class RecallPathE2ETests: XCTestCase {
    private static func request(
        id: String,
        summary: String,
        session: String = "s1"
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            sessionID: session,
            agent: .claudeCode,
            toolName: "Bash",
            summary: summary,
            detail: "swift test",
            toolInput: ["command": .string("swift test --package-path /Users/someone/x")],
            cwd: "/Users/someone/x",
            permissionMode: "acceptEdits"
        )
    }

    /// Nod-approve, then ask what changed: the answer names the approved request, and the
    /// window the question was asked in still resolves on the next nod.
    func testWhatChangedSpeaksTheApprovalTheNodJustGave() async {
        let memory = ConversationMemory()
        let harness = DetectionPathHarness(recallResponder: memory.recallResponder)

        let first = Self.request(id: "r1", summary: "run the test suite")
        let firstDecision = Task {
            await memory.withWindow(
                sessionID: first.sessionID,
                agent: first.agent,
                summary: first.summary,
                detail: first.detail
            ) {
                await harness.interaction.resolve(first)
            }
        }
        let firstWindow = await harness.waitForWindow(1)
        XCTAssertTrue(firstWindow, "the approval opened no input window")
        harness.feed(TraceGenerators.doubleNod())
        let allowed = await firstDecision.value
        XCTAssertEqual(allowed, .allow)
        memory.record(approval: first, decision: allowed)

        let second = Self.request(id: "r2", summary: "push the branch")
        let secondDecision = Task {
            await memory.withWindow(
                sessionID: second.sessionID,
                agent: second.agent,
                summary: second.summary,
                detail: second.detail
            ) {
                await harness.interaction.resolve(second)
            }
        }
        let secondWindow = await harness.waitForWindow(2)
        XCTAssertTrue(secondWindow)

        harness.hear("what did you just do")

        let reopened = await harness.waitForWindow(3)
        XCTAssertTrue(reopened, "a recall question must reopen the window, not resolve it")
        XCTAssertTrue(
            harness.speech.said("Claude Code approved run the test suite."),
            "recall spoke: \(harness.speech.spoken.map(\.text))"
        )

        // The window is still the one that was asked, and it still answers.
        harness.feed(TraceGenerators.doubleNod())
        let outcome = await secondDecision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow, "the recall must not have consumed the approval")
    }

    /// "Who's waiting?" counts the queue behind the request in hand. The second request is
    /// registered as waiting the moment it arrives, which is before the gate reaches it.
    func testStatusCountsTheQueuedRequest() async {
        let memory = ConversationMemory()
        let harness = DetectionPathHarness(recallResponder: memory.recallResponder)

        let open = Self.request(id: "r1", summary: "run the test suite")
        let decision = Task {
            await memory.withWindow(
                sessionID: open.sessionID, agent: open.agent, summary: open.summary
            ) {
                await harness.interaction.resolve(open)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)
        // A second agent's request arrives while the first is being answered; on the
        // runtime it would be parked in the interaction gate exactly like this.
        let queued = memory.beginWindow(
            sessionID: "s2", agent: .codex, summary: "delete the cache"
        )
        defer { memory.endWindow(queued) }

        harness.hear("who's waiting")

        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened, "the status answer must not resolve the window")
        XCTAssertTrue(
            harness.speech.said("Claude Code: run the test suite. 1 more waiting."),
            "status spoke: \(harness.speech.spoken.map(\.text))"
        )

        harness.feed(TraceGenerators.doubleShake())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny)
    }

    /// With no memory wired — every composition that predates Rung B, and the Apple path
    /// without a backend — the question is still heard and still answered, with the
    /// honest sentence. It must not fall through to the affirmative guard.
    func testRecallWithoutAResponderSaysNothingIsRecordedAndKeepsTheWindow() async {
        let harness = DetectionPathHarness()
        let request = Self.request(id: "r1", summary: "run the test suite")
        let decision = Task { await harness.interaction.resolve(request) }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("what changed")

        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened)
        XCTAssertTrue(harness.speech.said("Nothing recorded yet."))

        harness.feed(TraceGenerators.doubleShake())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny, "a question must never approve anything")
    }

    /// A question spoken into an approval window is answered by the backend, out of a
    /// digest TapQ composed — and the approval is still waiting for its answer afterwards.
    func testAGroundedQuestionIsRoutedAndTheApprovalStillStands() async {
        let memory = ConversationMemory()
        memory.record(
            approval: Self.request(id: "r0", summary: "run the test suite"), decision: .allow
        )
        var routed: [String] = []
        let harness = DetectionPathHarness(
            freeformResponder: memory.freeformResponder(speak: { instructions in
                routed.append(instructions)
                return true
            })
        )

        let request = Self.request(id: "r1", summary: "push the branch")
        let decision = Task {
            await memory.withWindow(
                sessionID: request.sessionID,
                agent: request.agent,
                summary: request.summary,
                detail: request.detail
            ) {
                await harness.interaction.resolve(request)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hearFreeform("did the tests pass")

        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened, "an answered question must leave the window open")
        XCTAssertEqual(routed.count, 1)
        XCTAssertTrue(routed[0].contains("Claude Code approved run the test suite."))
        XCTAssertTrue(routed[0].hasSuffix("Question: did the tests pass"))
        // The answer is the backend's audio; TapQ's own synthesizer says nothing new.
        XCTAssertEqual(harness.speech.spoken.count, 1)

        harness.feed(TraceGenerators.doubleNod())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .allow)
    }

    /// A statement is not a question. Without the interrogative shape nothing is routed,
    /// which is what keeps an overheard sentence from becoming a prompt.
    func testAStatementInTheWindowIsIgnored() async {
        let memory = ConversationMemory()
        var routed = 0
        let harness = DetectionPathHarness(
            freeformResponder: memory.freeformResponder(speak: { _ in
                routed += 1
                return true
            })
        )

        let request = Self.request(id: "r1", summary: "push the branch")
        let decision = Task {
            await memory.withWindow(
                sessionID: request.sessionID, agent: request.agent, summary: request.summary
            ) {
                await harness.interaction.resolve(request)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hearFreeform("the coffee machine broke down last week")

        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened)
        XCTAssertEqual(routed, 0)

        harness.feed(TraceGenerators.doubleShake())
        let outcome = await decision.value
        harness.assertWatchdogDidNotFire()
        XCTAssertEqual(outcome, .deny)
    }

    /// The spoken answer is composed from event fields that cannot hold a tool input, a
    /// working directory, or a permission mode — so a request carrying all three recalls
    /// as none of them.
    func testRecalledSpeechCarriesNothingUnspeakable() async {
        let memory = ConversationMemory()
        let request = Self.request(id: "r1", summary: "run the test suite")
        memory.record(approval: request, decision: .allow)
        let harness = DetectionPathHarness(recallResponder: memory.recallResponder)

        let second = Self.request(id: "r2", summary: "push the branch")
        let decision = Task {
            await memory.withWindow(
                sessionID: second.sessionID,
                agent: second.agent,
                summary: second.summary,
                detail: second.detail
            ) {
                await harness.interaction.resolve(second)
            }
        }
        let opened = await harness.waitForWindow(1)
        XCTAssertTrue(opened)

        harness.hear("what changed")
        let reopened = await harness.waitForWindow(2)
        XCTAssertTrue(reopened)

        let spoken = harness.speech.spoken.map(\.text).joined(separator: "\n")
        XCTAssertFalse(spoken.contains("/Users/"))
        XCTAssertFalse(spoken.contains("acceptEdits"))

        harness.feed(TraceGenerators.doubleNod())
        _ = await decision.value
        harness.assertWatchdogDidNotFire()
    }
}
