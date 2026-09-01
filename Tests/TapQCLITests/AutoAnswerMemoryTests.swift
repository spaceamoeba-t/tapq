import Foundation
import XCTest
@testable import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline

/// What conversation memory gained in Rung D: a count of the approvals nobody was asked
/// about, and an addressee for a window nobody opened.
@MainActor
final class AutoAnswerMemoryTests: XCTestCase {
    private let claude = AgentIdentity(id: "claude-code", displayName: "Claude Code")
    private let cursor = AgentIdentity(id: "cursor", displayName: "Cursor")

    private func approval(
        _ id: String = "r1",
        session: String = "s1",
        agent: AgentIdentity? = nil
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id, sessionID: session, agent: agent ?? claude,
            toolName: "Bash", summary: "run the tests", detail: "swift test"
        )
    }

    // MARK: - The count

    func testAutoAnswersAreCountedAndSpokenInTheStatusLine() async {
        let memory = ConversationMemory()
        XCTAssertEqual(memory.autoAnsweredCount, 0)

        memory.noteAutoAnswer()
        memory.noteAutoAnswer()
        XCTAssertEqual(memory.autoAnsweredCount, 2)

        await memory.withWindow(
            sessionID: "s1", agent: claude, summary: "delete the cache"
        ) {
            XCTAssertEqual(
                memory.recallAnswer(for: .status),
                "Claude Code: delete the cache. "
                    + "Auto-answered 2 this session."
            )
        }
    }

    /// A run without the filter says exactly what Rung C said. This is the memory-side half
    /// of the byte-identical promise.
    func testStatusIsUnchangedWhenNothingWasAutoAnswered() async {
        let memory = ConversationMemory()
        await memory.withWindow(
            sessionID: "s1", agent: claude, summary: "delete the cache"
        ) {
            XCTAssertEqual(
                memory.recallAnswer(for: .status),
                "Claude Code: delete the cache."
            )
        }
    }

    /// An auto-allow is a resolved approval like any other, so it belongs in the event ring
    /// too: "what changed?" must be able to say what was approved while nobody was asked.
    func testAnAutoAnsweredApprovalIsStillRecordedAsAnApproval() async {
        let memory = ConversationMemory()
        await memory.withWindow(
            sessionID: "s1", agent: claude, summary: "run the tests"
        ) {
            memory.noteAutoAnswer()
        }
        memory.record(approval: approval(), decision: .allow)

        XCTAssertEqual(memory.events(session: "s1").count, 1)
        XCTAssertEqual(
            SessionRecall.whatChanged(
                memory.events(session: "s1").reversed()
            ),
            "Claude Code approved run the tests."
        )
    }

    // MARK: - The standing dictation target

    /// An attention window happens between requests, so the open-window target is nil and
    /// the last agent TapQ served is the only agent the wearer can mean.
    func testTheStandingTargetOutlivesTheWindowThatSetIt() async {
        let memory = ConversationMemory(instructions: InstructionMailbox())
        XCTAssertNil(memory.standingAgentDisplayName)
        XCTAssertFalse(memory.standingInstructionCapability())

        await memory.withWindow(sessionID: "s1", agent: claude, summary: "run the tests") {}

        XCTAssertEqual(memory.standingAgentDisplayName, "Claude Code")
        XCTAssertTrue(memory.standingInstructionCapability())
        memory.standingInstructionEnqueue?("also run the linter")
        XCTAssertEqual(memory.instructions?.pendingCount(session: "s1"), 1)
    }

    /// The capability table still applies between windows: an attention window at a Cursor
    /// session is refused for the same reason an in-prompt dictation there is.
    func testTheStandingTargetHonorsTheAgentCapabilityTable() async {
        let memory = ConversationMemory(instructions: InstructionMailbox())
        await memory.withWindow(sessionID: "s9", agent: cursor, summary: "write a file") {}

        XCTAssertEqual(memory.standingAgentDisplayName, "Cursor")
        XCTAssertFalse(memory.standingInstructionCapability())
    }

    /// Without a mailbox the closure is absent, which is what makes dictation from an
    /// attention window inert on every run without `--voice-instructions`.
    func testTheStandingEnqueueIsAbsentWithoutAMailbox() async {
        let memory = ConversationMemory()
        await memory.withWindow(sessionID: "s1", agent: claude, summary: "run the tests") {}

        XCTAssertNil(memory.standingInstructionEnqueue)
    }

    /// An open window still wins: the request in hand is what a wearer standing in a prompt
    /// means, and the fallback exists only for when there is no prompt.
    func testAnOpenWindowTakesPrecedenceOverTheLastServedSession() async {
        let memory = ConversationMemory(instructions: InstructionMailbox())
        await memory.withWindow(sessionID: "s1", agent: claude, summary: "one") {}
        await memory.withWindow(sessionID: "s2", agent: claude, summary: "two") {
            memory.standingInstructionEnqueue?("do the thing")
        }

        XCTAssertEqual(memory.instructions?.pendingCount(session: "s2"), 1)
        XCTAssertEqual(memory.instructions?.pendingCount(session: "s1"), 0)
    }
}
