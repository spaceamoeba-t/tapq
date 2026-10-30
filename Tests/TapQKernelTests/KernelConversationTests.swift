import Foundation
import XCTest
@testable import TapQKernel

/// Listing an agent's conversations, five at a time, and switching it to one of them behind a
/// spoken yes (maintainer, 2026-10-12), or to a new one at once (2026-10-24).
@MainActor
final class KernelConversationTests: XCTestCase {
    private var harness: KernelHarness!

    override func setUp() async throws {
        harness = try KernelHarness()
    }

    override func tearDown() async throws {
        await harness.finish()
        harness = nil
    }

    /// Seven, newest first: today, yesterday, Friday, Tuesday, October 4, and two from 2025.
    private static let seven: [SessionSummary] = [
        .made("s1", "build milestone one", daysAgo: 0),
        .made("s2", "fix the README", daysAgo: 1),
        .made("s3", "add an export button", daysAgo: 3),
        .made("s4", "speed up the tests", daysAgo: 6),
        .made("s5", "rename the parser.", daysAgo: 8),
        .made("s6", "set up CI", daysAgo: 400),
        .made("s7", "first try", daysAgo: 401),
    ]

    private func listClaude(_ sessions: [SessionSummary], heard: String) async {
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success(sessions))
        await harness.hear(heard)
    }

    /// Drives Claude Code to idle, in session "session-new", after one finished task.
    private func idleClaude() async {
        await harness.launch()
        harness.claude.emit(.finished(text: "Tests pass."))
        await harness.hear("Claude Code says: Tests pass.")
    }

    // MARK: - Listing

    func testFiveAreReadNewestFirstAndTheRestOnlyWhenAsked() async throws {
        await harness.start()
        await listClaude(Self.seven, heard: "Claude Code has 7 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday: fix the README. 3, on Friday: add an export button. "
            + "4, on Tuesday: speed up the tests. 5, on October 4: rename the parser. There are 2 more.")
        XCTAssertEqual(harness.claudeCatalog.model.inputs, [KernelHarness.workspace])

        harness.say("More.")
        let input = await harness.decide { _ in .moreConversations }
        let claude = try XCTUnwrap(input?.context(.claude))
        XCTAssertEqual(claude.conversations.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(claude.conversations[1], ConversationChoice(number: 2, title: "fix the README",
                                                                   age: "yesterday", current: false))
        XCTAssertEqual(claude.moreConversations, 2)
        XCTAssertEqual(input?.heardFromLast, .claude, "the list is Claude Code's words")
        await harness.hear("6, on September 7, 2025: set up CI. 7, on September 6, 2025: first try. That's all.")

        harness.say("More.")
        await harness.decide(.moreConversations)
        await harness.hear("That's all of Claude Code's conversations.")
        XCTAssertEqual(harness.claudeCatalog.model.inputs.count, 1, "more reads the list already listed")
    }

    // MARK: - On the status channel

    /// What was read goes on the status channel, so the panel can show the numbers: nothing
    /// until a page has been read, and the one the agent is in moves with a switch.
    func testTheConversationsReadAreOnTheStatusChannel() async throws {
        await harness.start()
        await idleClaude()
        XCTAssertNil(harness.agentReport(.claude)?.conversations)
        await listClaude([.made("session-new", "run the tests"), .made("old-1", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations, StatusReport.Conversations(read: [
            .init(number: 1, title: "run the tests", age: "today", current: true),
            .init(number: 2, title: "fix the README", age: "yesterday", current: false),
        ], more: 0))
        XCTAssertFalse(harness.reports.contains { $0.agents.contains { $0.conversations?.read.isEmpty == true } },
                       "a listing still being named writes no line")

        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")
        harness.say("Claude, yes.")
        await harness.approve()
        await harness.hear("Claude Code is in conversation 2 now.")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.read.map(\.current), [false, true])
    }

    func testTheStatusCountsTheConversationsLeftToRead() async throws {
        await harness.start()
        await listClaude(Self.seven, heard: "Claude Code has 7 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday: fix the README. 3, on Friday: add an export button. "
            + "4, on Tuesday: speed up the tests. 5, on October 4: rename the parser. There are 2 more.")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.read.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.more, 2)

        harness.say("More.")
        await harness.decide(.moreConversations)
        await harness.hear("6, on September 7, 2025: set up CI. 7, on September 6, 2025: first try. That's all.")
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.read.map(\.number), [1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(harness.agentReport(.claude)?.conversations?.more, 0)
        XCTAssertNil(harness.agentReport(.codex)?.conversations)
    }

    func testTheConversationTheAgentIsInIsMarked() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "s2"])
        await harness.start()
        await listClaude(Array(Self.seven.prefix(2)), heard: "Claude Code has 2 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday, the current one: fix the README.")
    }

    func testNoneAndAFailedListingAreSaid() async throws {
        await harness.start()
        await listClaude([], heard: "Claude Code has no conversations in workspace yet.")

        harness.say("Codex, list your conversations.")
        await harness.decide(.listConversations)
        await harness.list(.codex, .failure(.callBound("codex app-server exited with code 1")))
        await harness.hear("I couldn't list Codex's conversations: codex app-server exited with code 1.")
    }

    /// The names TapQ reads are the titler's; a name with no words, or a failed call, reads the
    /// agent's own title.
    func testTheTitlerNamesWhatIsRead() async throws {
        harness.titler.manual = true
        await harness.start()
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success([.made("a", "**Read** the `spec.md` and build milestone one"),
                                              .made("b", "fix the README", daysAgo: 1)]))
        let titles = await harness.name(.success(["Milestone one from the spec", " "]))
        XCTAssertEqual(titles, ["Read the spec.md and build milestone one", "fix the README"])
        await harness.hear("Claude Code has 2 conversations in workspace. "
            + "1, today: Milestone one from the spec. 2, yesterday: fix the README.")

        harness.say("Codex, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.codex, .success([.made("c", "run the check script")]))
        await harness.name(.failure(.callBound("timeout")))
        await harness.hear("Codex has 1 conversation in workspace. 1, today: run the check script.")
    }

    func testNamesThatDoNotMatchTheConversationsAreFatal() async throws {
        harness.titler.manual = true
        await harness.start()
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success(Array(Self.seven.prefix(2))))
        await harness.name(.success(["only one"]))
        await harness.ended()
        XCTAssertEqual(harness.fatal.reasons.map(\.subsystem), [FatalReason.Subsystem.titler])
    }

    // MARK: - Switching

    func testAnIdleAgentIsAskedThenStoppedAndResumedInTheChosenConversation() async throws {
        await harness.start()
        await idleClaude()
        await listClaude([.made("session-new", "run the tests"), .made("old-1", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")

        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")
        XCTAssertEqual(harness.phase(.claude), .awaitingYes)
        XCTAssertFalse(harness.claude.stopped, "nothing changes before the yes")

        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.hear("Claude Code is idle. It's waiting on you: Switch Claude Code to conversation 2: fix the README?")

        harness.say("Claude, yes.")
        await harness.approve()
        await harness.hear("Claude Code is in conversation 2 now.")
        XCTAssertTrue(harness.claudes[0].stopped, "the old conversation's process is gone first")
        XCTAssertEqual(harness.claudes.count, 2)
        XCTAssertEqual(harness.claude.starts, [.resume(id: "old-1")])
        XCTAssertEqual(harness.claude.sent, [], "a switch with nothing to say sends nothing")
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertEqual(try harness.sessions.sessionID(for: .claude), "old-1")
        XCTAssertTrue(harness.entries.contains {
            if case .launchAsked(.claude, _, "workspace", true, "", .conversation(id: "old-1")) = $0 { return true }
            return false
        }, "\(harness.entries)")

        harness.say("Claude, read it all.")
        await harness.decide(.readAll)
        await harness.hear("There's no reply from Claude Code to read.")
    }

    func testANoLeavesTheAgentRunningInItsConversation() async throws {
        await harness.start()
        await idleClaude()
        await listClaude([.made("session-new", "run the tests"), .made("old-1", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")
        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")

        harness.say("Claude, no.")
        await harness.decide { .deny(requestID: $0.pending?.requestID ?? "", feedback: nil) }
        await harness.hear("Okay, Claude Code stays in its conversation.")
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertEqual(harness.claudes.count, 1)
        XCTAssertFalse(harness.claude.stopped)

        harness.say("Claude, read it all.")
        await harness.decide(.readAll)
        await harness.hear("Claude Code said: Tests pass.")
    }

    func testAnAgentThatIsOffStartsInTheChosenConversationWithTheWordsSaid() async throws {
        await harness.start()
        await listClaude([.made("a", "build milestone one"), .made("b", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today: build milestone one. 2, yesterday: fix the README.")
        harness.say("Claude, go back to conversation 2 and add tests for it.")
        await harness.decide(.switchConversation(number: 2, text: "add tests for it"))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")
        harness.say("Claude, yes.")
        await harness.approve()
        await harness.hear("Okay.")
        XCTAssertEqual(harness.claude.starts, [.resume(id: "b")])
        XCTAssertEqual(harness.claude.sent, ["add tests for it"])
        XCTAssertEqual(harness.phase(.claude), .working)
    }

    /// Said, it is done (2026-10-24): no yes, and nothing read or picked first.
    func testANewConversationStartsFresh() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "gone"])
        await harness.start()
        harness.say("Claude, start a new conversation.")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("Claude Code is in a new conversation.")
        XCTAssertEqual(harness.claudeCatalog.model.inputs, [], "nothing is read for an explicit new one")
        XCTAssertTrue(harness.entries.contains(.launching(agent: .claude, target: .new, held: "")))
        XCTAssertEqual(harness.claude.starts, [.fresh])
        XCTAssertEqual(try harness.sessions.sessionID(for: .claude), "session-new")
        XCTAssertEqual(harness.phase(.claude), .idle)
    }

    /// The way out of a conversation the agent can no longer resume is said with the failure.
    func testAFailedResumeSaysHowToStartOver() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "gone"])
        harness.claude.startError = FakeError()
        await harness.start()
        harness.say("Claude, run the tests")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("gone", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Claude Code couldn't start: FakeError(). "
            + "If that conversation is gone, say: Claude Code, new conversation.")
    }

    /// Claude Code resuming a session its store no longer has exits at once: an exit before
    /// any event of a resumed process says the way out too; one after it has worked does not.
    func testAResumedAgentThatEndsBeforeSayingAnythingSaysHowToStartOver() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "gone"])
        await harness.start()
        harness.say("Claude, run the tests")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("gone", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Claude Code continues its last conversation.")
        harness.claude.emit(.exited(code: 1, stderrTail: ["No conversation found with session ID: gone"]))
        await harness.hear("Claude Code quit unexpectedly. Its unfinished task stopped, and nothing was resent. "
            + "Talk to Claude Code to start it again. If that conversation is gone, say: Claude Code, new conversation.")

        harness.say("Claude, run the tests")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("gone", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Claude Code continues its last conversation.")
        harness.claude.emit(.progress("Bash: swift test"))
        harness.claude.emit(.exited(code: 1, stderrTail: []))
        await harness.hear("Claude Code quit unexpectedly. Its unfinished task stopped, and nothing was resent. "
            + "Talk to Claude Code to start it again.")
    }

    /// A resumed conversation whose first turn fails (an error result, then the exit) says the
    /// way out with the failure, once.
    func testAResumedAgentWhoseFirstTurnFailsSaysHowToStartOverOnce() async throws {
        harness = try KernelHarness(sessionIDs: [.claude: "gone"])
        await harness.start()
        harness.say("Claude, run the tests")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([.made("gone", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Claude Code continues its last conversation.")
        harness.claude.emit(.failed(reason: "No conversation found with session ID: gone"))
        await harness.hear("Claude Code stopped: No conversation found with session ID: gone. "
            + "If that conversation is gone, say: Claude Code, new conversation.")
        harness.claude.emit(.exited(code: 1, stderrTail: []))
        await harness.hear("Claude Code quit unexpectedly. Talk to Claude Code to start it again.")
    }

    func testAnAgentAtWorkIsNotSwitched() async throws {
        await harness.start()
        await harness.launch()
        await listClaude([.made("session-new", "run the tests"), .made("b", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")
        let switching = harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Claude Code is working. To switch conversations, first say: Claude Code, stop.")
        let starting = harness.say("Claude, start a new conversation.")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("Claude Code is working. To switch conversations, first say: Claude Code, stop.")
        XCTAssertEqual(harness.entries.filter { $0 == .refused(itemID: switching, reason: .busy)
                                                || $0 == .refused(itemID: starting, reason: .busy) }.count, 2)
        XCTAssertEqual(harness.claudes.count, 1)
    }

    func testOnlyAConversationReadCanBeChosen() async throws {
        await harness.start()
        harness.say("Claude, switch to conversation 3.")
        await harness.decide(.switchConversation(number: 3, text: nil))
        await harness.hear("Ask for Claude Code's conversations first, then choose one by its number.")

        await listClaude(Array(Self.seven.prefix(2)), heard: "Claude Code has 2 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday: fix the README.")
        harness.say("Claude, switch to conversation 5.")
        await harness.decide(.switchConversation(number: 5, text: nil))
        await harness.hear("I didn't read a conversation 5 for Claude Code.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: "item-1", reason: .noSuchConversation)))
    }

    func testTheConversationItIsInNeedsNoSwitch() async throws {
        await harness.start()
        await idleClaude()
        await listClaude([.made("session-new", "run the tests")], heard: "Claude Code has 1 conversation in workspace. "
            + "1, today, the current one: run the tests.")
        harness.say("Claude, switch to conversation 1.")
        await harness.decide(.switchConversation(number: 1, text: nil))
        await harness.hear("Claude Code is already in conversation 1.")
        harness.say("Claude, go to conversation 1 and lint it.")
        await harness.decide(.switchConversation(number: 1, text: "lint it"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.claude.sent, ["run the tests", "lint it"])
        XCTAssertEqual(harness.claudes.count, 1)
    }

    /// A step ending is no sign of work: a command can end after the turn it ran in (Codex's
    /// background terminal, 2026-10-15), and the switch stays asked.
    func testAStepEndingWhileTheSwitchIsAskedLeavesItAsked() async throws {
        await harness.start()
        await idleClaude()
        await listClaude([.made("session-new", "run the tests"), .made("old-1", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")
        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")

        harness.claude.emit(.stepEnded(step: "item-cmd", .done))
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .awaitingYes)
        XCTAssertFalse(harness.entries.contains { if case .withdrawn = $0 { return true } else { return false } })
        XCTAssertFalse(harness.output.texts.contains("Claude Code started working, so it stays in its conversation."))
    }

    /// The old conversation came alive while the switch was asked: the switch is withdrawn.
    func testWorkBegunInTheOldConversationWithdrawsTheSwitch() async throws {
        await harness.start()
        await idleClaude()
        await listClaude([.made("session-new", "run the tests"), .made("old-1", "fix the README", daysAgo: 1)],
                         heard: "Claude Code has 2 conversations in workspace. "
                            + "1, today, the current one: run the tests. 2, yesterday: fix the README.")
        harness.say("Claude, switch to the second one.")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")

        harness.claude.emit(.progress("Bash: ls"))
        await harness.hear("Claude Code started working, so it stays in its conversation.")
        XCTAssertEqual(harness.phase(.claude), .working)
        XCTAssertTrue(harness.entries.contains {
            if case .withdrawn(.claude, let id) = $0 { return id.hasPrefix("launch-") }
            return false
        }, "\(harness.entries)")

        harness.claude.emit(.finished(text: "Listed."))
        await harness.hear("Claude Code says: Listed.")
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertTrue(harness.fatal.reasons.isEmpty)
    }
}
