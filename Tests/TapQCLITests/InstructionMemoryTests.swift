import Foundation
import XCTest
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline
@testable import TapQCLI

/// The runtime's instruction seams: which session a dictation is addressed to, which
/// agents may receive one, what recall says while one is waiting, and what it says once it
/// has been delivered.
@MainActor
final class InstructionMemoryTests: XCTestCase {
    /// A dictation is addressed to the window the wearer is standing in — the same one
    /// recall answers about — and to no other session.
    func testEnqueueTargetsTheOpenWindowsSession() async {
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
    func testEnqueueOutsideAWindowQueuesNothing() async {
        let mailbox = InstructionMailbox()
        let memory = ConversationMemory(instructions: mailbox)

        memory.instructionEnqueue?("run the tests again")

        XCTAssertTrue(mailbox.trackedSessionsAreEmpty)
    }

    /// The switch that makes the dictation grammar inert: without a mailbox there is no
    /// closure at all, so the flow returns before it speaks.
    func testWithoutAMailboxThereIsNoEnqueueClosure() async {
        let memory = ConversationMemory()
        XCTAssertNil(memory.instructionEnqueue)
    }

    func testCapabilityFollowsTheAgentInTheOpenWindow() async {
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
    func testStatusCountsThisSessionsQueuedInstructions() async {
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
    func testADeliveredInstructionIsRecalledAsSomethingTheAgentWasToldToDo() async {
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

    // MARK: - The roster behind name-addressed dictation

    /// The map is filled from traffic conversation memory already watches: a window
    /// opening puts that session on the roster under its agent's name.
    func testAWindowPutsItsSessionOnTheRoster() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())

        let claude = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        memory.endWindow(claude)
        let codex = memory.beginWindow(
            sessionID: "s2", agent: .codex, summary: "push the branch"
        )
        memory.endWindow(codex)

        XCTAssertEqual(memory.rosterEntry(agentID: AgentIdentity.claudeCode.id)?.sessionID,
                       "s1")
        XCTAssertEqual(memory.rosterEntry(agentID: AgentIdentity.codex.id)?.sessionID, "s2")
        XCTAssertNil(memory.rosterEntry(agentID: AgentIdentity.cursor.id),
                     "an agent TapQ has never heard from is not addressable")
    }

    /// The other way an agent reaches TapQ. A session that has only ever announced things
    /// is still a session the wearer can name.
    func testANotificationAlsoPutsASessionOnTheRoster() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())

        memory.record(
            notification: AgentNotification(sessionID: "s9", agent: .codex, kind: .finished)
        )

        XCTAssertEqual(memory.rosterEntry(agentID: AgentIdentity.codex.id)?.sessionID, "s9")
    }

    /// Entries expire on silence, because nothing on the wire ever says a session ended.
    /// Past the liveness window the name stops resolving rather than routing a sentence
    /// into a terminal that was closed an hour ago.
    func testAQuietSessionAgesOffTheRoster() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())
        memory.endWindow(
            memory.beginWindow(sessionID: "s1", agent: .codex, summary: "push the branch")
        )
        XCTAssertNotNil(resolve("Codex", with: memory))

        clock.advance(by: AgentRoster.liveness + 1)

        XCTAssertNil(memory.rosterEntry(agentID: AgentIdentity.codex.id))
        XCTAssertNil(resolve("Codex", with: memory),
                     "a name nothing live answers to resolves to nothing")
    }

    /// The guard. A second session for one adapter breaks the one-session-per-adapter
    /// assumption the whole feature rests on, and the honest answer is to refuse the name
    /// rather than pick the newer session.
    func testASecondSessionMakesTheAgentsNameAmbiguous() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())
        memory.endWindow(
            memory.beginWindow(sessionID: "s1", agent: .claudeCode, summary: "run npm test")
        )
        XCTAssertFalse(memory.isAgentAmbiguous(AgentIdentity.claudeCode.id))

        memory.endWindow(
            memory.beginWindow(sessionID: "s2", agent: .claudeCode, summary: "push it")
        )

        XCTAssertTrue(memory.isAgentAmbiguous(AgentIdentity.claudeCode.id))
        switch resolve("Claude", with: memory) {
        case .ambiguous(let name):
            XCTAssertEqual(name, "Claude Code")
        default:
            XCTFail("two live sessions must not resolve to either of them")
        }
    }

    /// Two requests from the *same* session are what parallel tool calls look like, and
    /// they must not make the agent unaddressable.
    func testTwoWindowsOnOneSessionAreNotAmbiguous() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())
        let first = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        let second = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "read the file"
        )
        defer {
            memory.endWindow(first)
            memory.endWindow(second)
        }

        XCTAssertFalse(memory.isAgentAmbiguous(AgentIdentity.claudeCode.id))
        XCTAssertNotNil(resolve("Claude Code", with: memory))
    }

    /// Ambiguity is a fact about *now*, read from the clock rather than latched: once the
    /// rival session has gone quiet the name picks out one session again.
    func testAmbiguityClearsOnceTheOtherSessionAgesOut() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())
        memory.endWindow(
            memory.beginWindow(sessionID: "s1", agent: .claudeCode, summary: "run npm test")
        )
        memory.endWindow(
            memory.beginWindow(sessionID: "s2", agent: .claudeCode, summary: "push it")
        )
        XCTAssertTrue(memory.isAgentAmbiguous(AgentIdentity.claudeCode.id))

        clock.advance(by: AgentRoster.liveness + 1)
        // The surviving session speaks again; the one it displaced has expired out.
        memory.endWindow(
            memory.beginWindow(sessionID: "s2", agent: .claudeCode, summary: "run it again")
        )

        XCTAssertFalse(memory.isAgentAmbiguous(AgentIdentity.claudeCode.id))
        switch resolve("claude", with: memory) {
        case .resolved(let addressee):
            XCTAssertEqual(addressee.agentDisplayName, "Claude Code")
        default:
            XCTFail("one live session answers to the name again")
        }
    }

    /// What the resolver hands back can reach exactly one thing: the named session's
    /// queue. Nothing lands in the window the wearer is standing in.
    func testTheResolvedAddresseeQueuesForTheNamedSession() async {
        let mailbox = InstructionMailbox()
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: mailbox)
        memory.endWindow(
            memory.beginWindow(sessionID: "s2", agent: .codex, summary: "push the branch")
        )
        let token = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        defer { memory.endWindow(token) }

        switch resolve("codex", with: memory) {
        case .resolved(let addressee):
            XCTAssertTrue(addressee.acceptsInstructions)
            addressee.enqueue("run the tests")
        default:
            return XCTFail("Codex is live and unambiguous")
        }

        XCTAssertEqual(mailbox.pending(session: "s2").map(\.text), ["run the tests"])
        XCTAssertEqual(mailbox.pendingCount(session: "s1"), 0,
                       "the open window's session was not the addressee")
    }

    /// RC6 by another route. The per-adapter table follows the agent a sentence is going
    /// *to*, so a name-routed dictation at Cursor is refused exactly as an in-window one
    /// would be.
    func testAnAgentWithNoTurnBoundaryResolvesButRefusesInstructions() async {
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: InstructionMailbox())
        memory.endWindow(
            memory.beginWindow(sessionID: "s3", agent: .cursor, summary: "edit the file")
        )

        switch resolve("Cursor", with: memory) {
        case .resolved(let addressee):
            XCTAssertFalse(addressee.acceptsInstructions)
        default:
            XCTFail("Cursor is live; it just cannot be instructed")
        }
    }

    /// The same switch that makes the dictation grammar inert makes addressing inert:
    /// without a mailbox there is nothing to route to, so there is no resolver at all.
    func testWithoutAMailboxThereIsNoResolver() async {
        let memory = ConversationMemory()
        memory.endWindow(
            memory.beginWindow(sessionID: "s1", agent: .codex, summary: "push the branch")
        )
        XCTAssertNil(memory.instructionAddressResolver)
    }

    /// The resolver is a fact about the fleet, never about the request in hand. Nothing on
    /// it can answer a question the interaction gate asks — there is no `Decision` and no
    /// `SelectionResult` anywhere in its shape — and the window's own target is untouched
    /// by anything the roster knows.
    func testRoutingDoesNotDisturbTheWindowsOwnTarget() async {
        let mailbox = InstructionMailbox()
        let clock = SettableClock()
        let memory = ConversationMemory(clock: clock.read, instructions: mailbox)
        memory.endWindow(
            memory.beginWindow(sessionID: "s2", agent: .codex, summary: "push the branch")
        )
        let token = memory.beginWindow(
            sessionID: "s1", agent: .claudeCode, summary: "run npm test"
        )
        defer { memory.endWindow(token) }

        memory.instructionEnqueue?("run the tests again")

        XCTAssertEqual(memory.standingAgentDisplayName, "Claude Code")
        XCTAssertTrue(memory.instructionCapability())
        XCTAssertEqual(mailbox.pendingCount(session: "s1"), 1,
                       "an unaddressed dictation still goes to the open window")
        XCTAssertEqual(mailbox.pendingCount(session: "s2"), 0)
    }

    private func resolve(
        _ name: String,
        with memory: ConversationMemory
    ) -> InstructionAddressResolution? {
        memory.instructionAddressResolver?(name)
    }
}

/// A clock a test can move by hand, so the roster's half-hour liveness window can be
/// crossed without waiting for it.
private final class SettableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Date(timeIntervalSince1970: 1_700_000_000)

    var read: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return now
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        now = now.addingTimeInterval(seconds)
    }
}

private extension InstructionMailbox {
    /// No session is tracked once nothing is queued for it, which is the property that
    /// keeps a long-running fleet from accumulating empty entries.
    var trackedSessionsAreEmpty: Bool { pendingCount(session: "s1") == 0 }
}
