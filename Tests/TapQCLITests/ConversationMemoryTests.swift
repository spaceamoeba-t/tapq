import XCTest
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline
@testable import TapQCLI

/// The runtime's memory as the runtime composes it: windows opened around the gate,
/// resolutions recorded, and the two closures the controllers are handed.
///
/// Every test drives it the way `AppleTapQRuntimeService` does — `withWindow` around the
/// resolution, `record` after it — so a wiring change that stops recording, or one that
/// leaves a window open, fails here rather than on hardware.
@MainActor
final class ConversationMemoryTests: XCTestCase {
    private let agent = AgentIdentity.claudeCode

    private func approval(
        session: String = "s1",
        summary: String = "run npm test",
        detail: String = ""
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID().uuidString,
            sessionID: session,
            agent: agent,
            toolName: "Bash",
            summary: summary,
            detail: detail,
            toolInput: ["command": .string("rm -rf /Users/someone/build")],
            cwd: "/Users/someone/project",
            permissionMode: "acceptEdits"
        )
    }

    private func selection(
        session: String = "s1",
        question: String = "Which merge strategy?"
    ) -> SelectionRequest {
        SelectionRequest(
            id: UUID().uuidString,
            sessionID: session,
            agent: agent,
            question: question,
            options: [
                SelectionOption(label: "Rebase", description: "replay the commits"),
                SelectionOption(label: "Merge", description: "keep both histories"),
            ]
        )
    }

    // MARK: - Recording

    func testAResolvedApprovalIsRecalledInTheNextWindow() async {
        let memory = ConversationMemory()
        let request = approval()

        _ = await memory.withWindow(
            sessionID: request.sessionID, agent: agent, summary: request.summary
        ) { Decision.allow }
        memory.record(approval: request, decision: .allow)

        let token = memory.beginWindow(
            sessionID: "s1", agent: agent, summary: "push the branch"
        )
        defer { memory.endWindow(token) }
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code approved run npm test."
        )
    }

    func testDeniedAndDeferredApprovalsAreRecalledAsThemselves() async {
        let memory = ConversationMemory()
        memory.record(approval: approval(summary: "delete the cache"), decision: .deny)
        memory.record(approval: approval(summary: "push the branch"), decision: .ask)

        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "open one")
        defer { memory.endWindow(token) }
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code deferred push the branch. Before that, denied delete the cache."
        )
    }

    func testASelectionIsRecalledByItsChosenLabels() async {
        let memory = ConversationMemory()
        let request = selection()

        memory.record(
            selection: request,
            result: SelectionResult(choices: [SelectionResult.Choice(index: 0, label: "Rebase")])
        )

        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "open one")
        defer { memory.endWindow(token) }
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code chose Rebase for Which merge strategy."
        )
    }

    /// A spoken answer to a stop question is a different kind of memory from a label
    /// picked off a menu, and `recordStopSelection` is where the two part.
    func testAFreeTextStopAnswerIsRecordedAsAStopAnswer() async {
        let memory = ConversationMemory()
        let request = selection(question: "How should I split the module?")

        memory.recordStopSelection(
            request, result: SelectionResult(choices: [], freeText: "by feature")
        )

        XCTAssertEqual(memory.events(session: "s1").map(\.kind), [.stopAnswer])
        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "open one")
        defer { memory.endWindow(token) }
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code answered by feature to How should I split the module."
        )
    }

    func testAChosenLabelReachingTheStopPathIsStillASelection() async {
        let memory = ConversationMemory()

        memory.recordStopSelection(
            selection(),
            result: SelectionResult(choices: [SelectionResult.Choice(index: 1, label: "Merge")])
        )

        XCTAssertEqual(memory.events(session: "s1").map(\.kind), [.selection])
    }

    func testANotificationIsRecalledAsSomethingReported() async {
        let memory = ConversationMemory()

        memory.record(notification: AgentNotification(
            sessionID: "s1", agent: agent, kind: .finished, summary: "the importer landed"
        ))

        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "open one")
        defer { memory.endWindow(token) }
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code reported the importer landed."
        )
    }

    func testRecallIsScopedToTheOpenWindowsSession() async {
        let memory = ConversationMemory()
        memory.record(
            approval: approval(session: "other", summary: "delete production"),
            decision: .allow
        )

        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "open one")
        defer { memory.endWindow(token) }
        XCTAssertEqual(memory.recallAnswer(for: .whatChanged), SessionRecall.nothingRecorded)
    }

    // MARK: - Redaction by construction

    func testNothingUnspeakableFromTheRequestSurvivesIntoRecallOrGrounding() async {
        let memory = ConversationMemory()
        let request = approval(detail: "the build folder is stale")
        memory.record(approval: request, decision: .allow)

        let token = memory.beginWindow(
            sessionID: "s1", agent: agent, summary: request.summary, detail: request.detail
        )
        defer { memory.endWindow(token) }

        let spoken = [
            memory.recallAnswer(for: .whatChanged),
            memory.recallAnswer(for: .status),
            memory.groundedAnswer(for: "what is it doing?"),
        ].compactMap { $0 }.joined(separator: "\n")

        XCTAssertFalse(spoken.contains("/Users/"))
        XCTAssertFalse(spoken.contains("rm -rf"))
        XCTAssertFalse(spoken.contains("acceptEdits"))
    }

    // MARK: - Status and the wait registry

    func testStatusNamesTheRequestInHandAndCountsTheQueue() async {
        let memory = ConversationMemory()
        let first = memory.beginWindow(
            sessionID: "s1", agent: agent, summary: "run npm test"
        )
        let second = memory.beginWindow(
            sessionID: "s2",
            agent: .codex,
            summary: "push the branch"
        )
        defer {
            memory.endWindow(first)
            memory.endWindow(second)
        }

        XCTAssertEqual(
            memory.recallAnswer(for: .status),
            "Claude Code: run npm test. 1 more waiting."
        )
        XCTAssertEqual(memory.waitRegistry.waitingCount, 2)
        XCTAssertEqual(memory.waitRegistry.waitingAgentNames, ["Claude Code", "Codex"])
    }

    /// The gate is FIFO, so once the first window closes the second is the one the wearer
    /// is being asked about — and recall must follow it, including into a different
    /// session's history.
    func testRecallFollowsTheGateToTheNextWindow() async {
        let memory = ConversationMemory()
        memory.record(
            approval: approval(session: "s2", summary: "read the changelog"), decision: .allow
        )
        let first = memory.beginWindow(sessionID: "s1", agent: agent, summary: "run npm test")
        let second = memory.beginWindow(
            sessionID: "s2", agent: agent, summary: "push the branch"
        )
        defer { memory.endWindow(second) }

        memory.endWindow(first)

        XCTAssertEqual(
            memory.recallAnswer(for: .status),
            "Claude Code: push the branch."
        )
        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code approved read the changelog."
        )
    }

    func testWithWindowClosesTheWindowWhateverTheBodyDoes() async {
        let memory = ConversationMemory()

        _ = await memory.withWindow(
            sessionID: "s1", agent: agent, summary: "run npm test"
        ) { Decision.allow }

        XCTAssertEqual(memory.waitRegistry.waitingCount, 0)
        XCTAssertNil(memory.recallAnswer(for: .status))
    }

    func testEndingAWindowTwiceIsHarmless() async {
        let memory = ConversationMemory()
        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "run npm test")

        memory.endWindow(token)
        memory.endWindow(token)

        XCTAssertEqual(memory.waitRegistry.waitingCount, 0)
    }

    // MARK: - The responders the controllers get

    func testTheRecallResponderAnswersNothingWithNoOpenWindow() async {
        let memory = ConversationMemory()
        memory.record(approval: approval(), decision: .allow)

        // Recall is only reachable from inside a window; with none open the responder
        // declines, and the controller speaks its own "Nothing recorded yet."
        XCTAssertNil(memory.recallResponder(.whatChanged))
        XCTAssertNil(memory.recallResponder(.status))
    }

    func testTheRecallResponderDeclinesEveryDecidingIntent() async {
        let memory = ConversationMemory()
        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "run npm test")
        defer { memory.endWindow(token) }

        for intent in [InputIntent.allow, .deny, .deferToPrompt, .select, .next,
                       .selectByNumber(2), .freeform("yes please")] {
            XCTAssertNil(memory.recallResponder(intent), "recall answered \(intent)")
        }
    }

    func testTheFreeformResponderRoutesGroundedInstructionsAndReportsTheRoute() async {
        let memory = ConversationMemory()
        memory.record(approval: approval(summary: "run npm test"), decision: .allow)
        let token = memory.beginWindow(
            sessionID: "s1",
            agent: agent,
            summary: "delete the build folder",
            detail: "it has not been rebuilt since Tuesday"
        )
        defer { memory.endWindow(token) }

        var routed: [String] = []
        let responder = memory.freeformResponder(speak: { text in
            routed.append(text)
            return true
        })

        XCTAssertTrue(responder("did the tests pass?"))
        XCTAssertEqual(routed.count, 1)
        let instructions = routed[0]
        XCTAssertTrue(instructions.hasPrefix(SessionRecall.answeringPreamble))
        XCTAssertTrue(instructions.contains("Open request: delete the build folder"))
        XCTAssertTrue(instructions.contains("Claude Code approved run npm test."))
        XCTAssertTrue(instructions.hasSuffix("Question: did the tests pass?"))
    }

    /// `speakViaBackend` returns `false` whenever the session cannot take the text. That
    /// has to reach the controller unchanged, because `false` is what keeps the window
    /// behaving exactly as it did before Rung B.
    func testTheFreeformResponderReportsARefusedRoute() async {
        let memory = ConversationMemory()
        let token = memory.beginWindow(sessionID: "s1", agent: agent, summary: "run npm test")
        defer { memory.endWindow(token) }

        let responder = memory.freeformResponder(speak: { _ in false })

        XCTAssertFalse(responder("did the tests pass?"))
    }

    func testTheFreeformResponderDeclinesWithNoOpenWindow() async {
        let memory = ConversationMemory()
        var routed = 0
        let responder = memory.freeformResponder(speak: { _ in
            routed += 1
            return true
        })

        XCTAssertFalse(responder("did the tests pass?"))
        XCTAssertEqual(routed, 0, "nothing may be sent about a session nobody is in")
    }
}
