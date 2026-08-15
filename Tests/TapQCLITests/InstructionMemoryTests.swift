import Foundation
import XCTest
import TapQContextBaseline
import TapQContracts
@testable import TapQCLI

/// The runtime's instruction seams: which session a dictation is addressed to, which
/// agents may receive one, what recall says while one is waiting, and what it says once it
/// has been delivered.
@MainActor
final class InstructionMemoryTests: XCTestCase {
    /// A dictation is addressed to the window the wearer is standing in — the same one
    /// recall answers about — and to no other session.
    func testEnqueueTargetsTheOpenWindowsSession() {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let token = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )

        memory.instructionEnqueue?("run the tests again")

        XCTAssertEqual(mailbox.pendingCount(session: "s1"), 1)
        XCTAssertEqual(mailbox.pending(session: "s1").first?.text, "run the tests again")
        memory.endWindow(token)
    }

    /// With no window open there is no session to address, and the fail-closed answer is
    /// to queue nothing rather than to guess.
    func testEnqueueOutsideAWindowQueuesNothing() {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)

        memory.instructionEnqueue?("run the tests again")

        XCTAssertTrue(mailbox.trackedSessionsAreEmpty)
    }

    /// The switch that makes the dictation grammar inert: without a mailbox there is no
    /// closure at all, so the flow returns before it speaks.
    func testWithoutAMailboxThereIsNoEnqueueClosure() {
        let memory = ConversationMemory()
        XCTAssertNil(memory.instructionEnqueue)
    }

    func testCapabilityFollowsTheAgentInTheOpenWindow() {
        let memory = ConversationMemory(instructions: InstructionMailbox())
        XCTAssertFalse(memory.instructionCapability(), "no window, no agent, no instruction")

        let claude = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        XCTAssertTrue(memory.instructionCapability())
        memory.endWindow(claude)

        let openCode = memory.beginWindow(
            sessionID: "s2", agent: .openCode, summary: "delete the cache"
        )
        XCTAssertFalse(memory.instructionCapability(),
                       "OpenCode has no turn boundary to deliver into")
        memory.endWindow(openCode)
    }

    /// RC7: the status line gains a clause while an instruction waits, and loses it again
    /// once the instruction has been delivered.
    func testStatusCountsThisSessionsQueuedInstructions() {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)
        let token = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        defer { memory.endWindow(token) }

        XCTAssertEqual(
            memory.recallAnswer(for: .status),
            "Claude Code: run npm test. Nothing else waiting."
        )

        memory.instructionEnqueue?("run the tests again")
        // A different session's queue is not this wearer's business.
        mailbox.enqueue("push the branch", session: "s2")

        XCTAssertEqual(
            memory.recallAnswer(for: .status),
            "Claude Code: run npm test. Nothing else waiting. 1 instruction queued."
        )

        _ = mailbox.dequeue(session: "s1")
        XCTAssertEqual(
            memory.recallAnswer(for: .status),
            "Claude Code: run npm test. Nothing else waiting."
        )
    }

    /// Delivered instructions are recalled as work handed over, never as work done.
    func testADeliveredInstructionIsRecalledAsSomethingTheAgentWasToldToDo() {
        let memory = ConversationMemory(instructions: InstructionMailbox())
        memory.instructionRecorder("s1", .claudeCode, "run the tests again")

        let token = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "push the branch"
        )
        defer { memory.endWindow(token) }

        XCTAssertEqual(
            memory.recallAnswer(for: .whatChanged),
            "Claude Code was told to run the tests again."
        )
        XCTAssertEqual(memory.events(session: "s1").first?.kind, .instruction)
    }
}

private extension InstructionMailbox {
    /// No session is tracked once nothing is queued for it, which is the property that
    /// keeps a long-running fleet from accumulating empty entries.
    var trackedSessionsAreEmpty: Bool { pendingCount(session: "s1") == 0 }
}
