import Foundation
import XCTest
import TapQContracts
@testable import TapQKernel

// The loop, one timeline per rule. Every method is `async`: on
// Linux the Swift 6 test-discovery shim cannot register a synchronous method on a
// `@MainActor` XCTestCase.

/// Invariant 5: one FIFO per agent; only the head is spoken and resolved.
@MainActor
final class KernelRequestTests: XCTestCase {
    func testTwoPermissionsAreAskedOneAtATimeInOrder() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        harness.claude.emit(.permission(.bash("p2", "npm test")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        await harness.settle()
        XCTAssertNil(harness.output.current, "the second request waits for the first")

        harness.say("Claude, yes")
        await harness.approve()
        await harness.hear("Allowed for Claude Code.")
        await harness.speaking("Claude Code wants to run npm test. Allow it?")
        XCTAssertEqual(harness.claude.permissions.map(\.id), ["p1"])
        XCTAssertEqual(harness.lastReport?.agents.first?.pending.map(\.id), ["p2"])
        await harness.finish()
    }

    func testAHeadWithdrawnWhileItsPromptPlaysIsToldAndTheNextIsAsked() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        harness.claude.emit(.permission(.bash("p2", "npm test")))
        await harness.speaking("Claude Code wants to run npm install. Allow it?")
        harness.claude.emit(.withdrawn(requestID: "p1"))
        await harness.waitForEntry("withdrawn") { $0 == .withdrawn(agent: .claude, requestID: "p1") }

        harness.output.play(at: harness.now(), verbatim: true)
        await harness.hear("Claude Code withdrew that request.")
        await harness.speaking("Claude Code wants to run npm test. Allow it?")
        XCTAssertEqual(harness.claude.permissions, [])
        await harness.finish()
    }

    func testADenyWithFeedbackIsPassedOn() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        harness.say("Claude, yes but use pnpm")
        await harness.decide { .deny(requestID: $0.pending?.requestID ?? "", feedback: "use pnpm") }

        await harness.speaking("Denied, and I told Claude Code why.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .deny(feedback: "use pnpm"))])
        await harness.finish()
    }

    /// A delegate contract violation: that agent is stopped, TapQ runs on (ruling 2026-10-12).
    func testATurnThatEndsWithARequestOpenStopsThatAgent() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        harness.claude.emit(.finished(text: "Done."))
        await harness.waitForEntry("lost request") { $0 == .lost(agent: .claude, .request(id: "p1")) }

        XCTAssertEqual(harness.fatal.reasons, [])
        XCTAssertFalse(harness.entries.contains(.finished(agent: .claude, text: "Done.")))
        XCTAssertTrue(harness.entries.contains(.lost(agent: .claude, .turn)))
        await waitUntil("the old delegate to be stopped") { harness.claudes[0].stopped }
        await harness.finish()
    }

    func testARequestWhileIdleMovesTheAgentToWorking() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: ""))
        await harness.hear("Claude Code is done.")
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .idle)

        harness.claude.emit(.question(QuestionRequest(id: "q1", questions: [
            Question(key: "k", header: nil, text: "Which one?", options: [], multiSelect: false,
                     allowsFreeText: true),
        ])))
        await harness.speaking("Claude Code asks: Which one?")
        XCTAssertEqual(harness.phase(.claude), .working)
        await harness.finish()
    }

    /// A delegate may start a turn TapQ did not ask for (Codex's deny feedback is a steer,
    /// which becomes `turn/start` once the turn has ended). Every event is accepted in idle.
    func testATurnTheKernelDidNotStartIsRelayed() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: "Done."))
        await harness.hear("Claude Code says: Done.")
        XCTAssertEqual(harness.phase(.claude), .idle)

        harness.claude.emit(.progress("Bash: npm test"))
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .working)
        harness.claude.emit(.finished(text: "Used pnpm."))
        await harness.hear("Claude Code says: Used pnpm.")
        XCTAssertEqual(harness.phase(.claude), .idle)

        harness.claude.emit(.stopped)
        await harness.hear("Claude Code stopped.")
        harness.claude.emit(.failed(reason: "Overloaded"))
        await harness.hear("Claude Code stopped: Overloaded.")
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertEqual(harness.fatal.reasons, [])
        await harness.finish()
    }

    /// The tool line is a host's to show; a spoken status is the turn summarized
    /// (KernelProgressTests).
    func testProgressIsStatusOnly() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.progress("Bash: swift test"))
        await harness.settle()

        XCTAssertEqual(harness.lastReport?.agents.first?.progress, "Bash: swift test")
        XCTAssertNil(harness.output.current)
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.summarizeProgress(.success("Claude Code is running the tests."))
        await harness.speaking("Claude Code is running the tests.")
        await harness.finish()
    }
}

/// An instruction to an agent that is off starts it at once, in the conversation the picker
/// infers from the words, or a new one (maintainer, 2026-10-24: the yes of D2 is gone).
@MainActor
final class KernelLaunchTests: XCTestCase {
    func testAnInstructionStartsTheAgentAtOnceAndSendsIt() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(task: "run the tests")

        XCTAssertEqual(harness.claude.starts, [.fresh])
        XCTAssertEqual(harness.claude.sent, ["run the tests"])
        XCTAssertEqual(try harness.sessions.sessionID(for: .claude), "session-new")
        XCTAssertTrue(harness.entries.contains(.launching(agent: .claude, target: .new, held: "run the tests")))
        XCTAssertTrue(harness.entries.contains(.started(agent: .claude, sessionID: "session-new")))
        XCTAssertFalse(harness.entries.contains { if case .launchAsked = $0 { true } else { false } }, "nothing is asked")
        XCTAssertEqual(harness.claudeCatalog.model.inputs, [KernelHarness.workspace], "its conversations were read")
        XCTAssertEqual(harness.picker.model.inputs, [], "none to pick from")
        XCTAssertEqual(harness.phase(.claude), .working)
        await harness.finish()
    }

    /// The conversation it was last in, when the words go on with it: resumed, and named.
    func testTheConversationTheWordsGoOnWithIsResumed() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s-1"])
        await harness.start()
        harness.say("Claude, carry on with the README")
        await harness.decide(.instruct(text: "carry on with the README"))
        await harness.offer(.claude, .success([.made("s-2", "speed up the tests"),
                                               .made("s-1", "fix the README", daysAgo: 1)]))
        let asked = await harness.pick(.success(ConversationPick(number: 2, name: "the README fix")))
        XCTAssertEqual(asked, PickInput(instruction: "carry on with the README", candidates: [
            ConversationCandidate(number: 1, title: "speed up the tests", age: "today", last: false),
            ConversationCandidate(number: 2, title: "fix the README", age: "yesterday", last: true),
        ], agent: .claude))
        await harness.hear("Okay, Claude Code continues the README fix.")
        XCTAssertEqual(harness.claude.starts, [.resume(id: "s-1")])
        XCTAssertEqual(harness.claude.sent, ["carry on with the README"])
        XCTAssertTrue(harness.entries.contains(.launching(agent: .claude, held: "carry on with the README")))
        await harness.finish()
    }

    /// Another of its conversations, when the words go on with that one: resumed, and kept as
    /// the one it is in.
    func testAnotherConversationThePickerFindsIsResumed() async throws {
        let harness = try KernelHarness(sessionIDs: [.codex: "s-1"])
        await harness.start()
        harness.say("Codex, make the tests faster still")
        await harness.decide(.instruct(text: "make the tests faster still"))
        await harness.offer(.codex, .success([.made("s-2", "speed up the tests"), .made("s-1", "fix the README")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "speeding up the tests")))
        await harness.hear("Okay, Codex continues speeding up the tests.")
        XCTAssertEqual(harness.codex.starts, [.resume(id: "s-2")])
        XCTAssertEqual(try harness.sessions.sessionID(for: .codex), "s-2")
        XCTAssertTrue(harness.entries.contains(.launching(agent: .codex, target: .conversation(id: "s-2"),
                                                          held: "make the tests faster still")))
        await harness.finish()
    }

    /// The five newest are offered, and the one it was last in when it is older.
    func testTheNewestFiveAndTheLastOneAreOffered() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s7"])
        await harness.start()
        harness.say("Claude, go on")
        await harness.decide(.instruct(text: "go on"))
        await harness.offer(.claude, .success((1...7).map { .made("s\($0)", "task \($0)", daysAgo: Double($0 - 1)) }))
        let asked = await harness.pick(.success(ConversationPick(number: 6, name: "")))
        XCTAssertEqual(asked?.candidates.map(\.title), ["task 1", "task 2", "task 3", "task 4", "task 5", "task 7"])
        XCTAssertEqual(asked?.candidates.map(\.last), [false, false, false, false, false, true])
        await harness.hear("Okay, Claude Code continues its last conversation.")
        XCTAssertEqual(harness.claude.starts, [.resume(id: "s7")])
        await harness.finish()
    }

    /// One open in another process is never offered (2026-10-12): with nothing else, a new
    /// conversation, and the user hears why.
    func testAConversationOpenElsewhereIsNeverOffered() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s-1"])
        harness.claudeCatalog.openNow = [OpenSession(id: "s-1", title: "fix the README", working: false)]
        await harness.start()
        harness.say("Claude, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.claude, .success([.made("s-1", "fix the README")]))
        await harness.hear("Okay, Claude Code starts a new conversation. Its last one is open elsewhere.")
        XCTAssertEqual(harness.picker.model.inputs, [])
        XCTAssertEqual(harness.claude.starts, [.fresh])
        await harness.finish()
    }

    func testWordsOnSomethingNewStartANewConversation() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s-1"])
        await harness.start()
        harness.say("Claude, write a release script")
        await harness.decide(.instruct(text: "write a release script"))
        await harness.offer(.claude, .success([.made("s-1", "fix the README")]))
        await harness.pick(.success(ConversationPick(number: nil, name: "")))
        await harness.hear("Okay, Claude Code starts a new conversation.")
        XCTAssertEqual(harness.claude.starts, [.fresh])
        XCTAssertEqual(try harness.sessions.sessionID(for: .claude), "session-new")
        await harness.finish()
    }

    /// A pick that fails carries on the conversation it was last in, as before 2026-10-24, and
    /// says so; with none, a new one.
    func testAFailedPickCarriesOnTheLastOneElseANewOne() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s-1"])
        await harness.start()
        harness.say("Claude, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.claude, .success([.made("s-1", "fix the README")]))
        await harness.pick(.failure(.callBound("timeout")))
        await harness.hear("I couldn't tell which conversation you meant, so Claude Code continues its last one.")
        XCTAssertEqual(harness.claude.starts, [.resume(id: "s-1")])

        harness.say("Codex, lint")
        await harness.decide(.instruct(text: "lint"))
        await harness.offer(.codex, .success([.made("c-1", "write the tests")]))
        await harness.pick(.failure(.callBound("timeout")))
        await harness.hear("I couldn't tell which conversation you meant, so Codex starts a new one.")
        XCTAssertEqual(harness.codex.starts, [.fresh])
        XCTAssertEqual(harness.sink.named("picker.call").map { $0.fields["outcome"] },
                       ["callBound: timeout", "callBound: timeout"])
        await harness.finish()
    }

    func testConversationsThatCannotBeReadStartANewOne() async throws {
        let harness = try KernelHarness(sessionIDs: [.claude: "s-1"])
        await harness.start()
        harness.say("Claude, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.claude, .failure(.callBound("the projects folder is unreadable")))
        await harness.hear("I couldn't read Claude Code's conversations, so it starts a new one.")
        XCTAssertEqual(harness.claude.starts, [.fresh])
        await harness.finish()
    }

    /// A number the agent was never offered is a contract failure: the words would go where the
    /// user never was.
    func testAPickOfAConversationNotOfferedIsFatal() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.claude, .success([.made("s-1", "fix the README")]))
        await harness.pick(.success(ConversationPick(number: 4, name: "something")))
        await harness.ended()
        XCTAssertEqual(harness.fatal.reasons.map(\.subsystem), [FatalReason.Subsystem.picker])
        XCTAssertEqual(harness.claude.starts, [])
    }

    /// The one start still asked is a switch (2026-10-24): words for the agent meanwhile are
    /// refused, and the switch is asked again.
    func testAnInstructionWhileASwitchIsAskedIsRefusedAndTheSwitchIsAskedAgain() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, what conversations do you have?")
        await harness.decide(.listConversations)
        await harness.list(.claude, .success([.made("a", "build milestone one"), .made("b", "fix the README", daysAgo: 1)]))
        await harness.hear("Claude Code has 2 conversations in workspace. "
            + "1, today: build milestone one. 2, yesterday: fix the README.")
        harness.say("Claude, the second one")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")
        let item = harness.say("Claude, lint instead")
        await harness.decide(.instruct(text: "lint instead"))

        await harness.hear("I'll ask again.")
        await harness.hear("Switch Claude Code to conversation 2: fix the README?")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .notHead)))
        XCTAssertEqual(harness.claude.starts, [])
        await harness.finish()
    }

    /// An agent `--agents` leaves out is answered by that, not by what is installed, and never
    /// started.
    func testAnAgentLeftOutByAgentsIsRefusedByName() async throws {
        let harness = try KernelHarness(installed: [.claude], notOnPlan: [.codex, .claudeChat, .chatgpt])
        await harness.start()
        let item = harness.say("Codex, run the tests")
        await harness.decide(.instruct(text: "run the tests"))

        await harness.speaking("Codex isn't turned on in TapQ.")
        XCTAssertEqual(harness.entries.prefix(3), [
            .heard(itemID: item, agent: nil, text: "Codex, run the tests"),
            .decided(itemID: item, agent: .codex, intent: .instruct(text: "run the tests")),
            .refused(itemID: item, reason: .notInstalled),
        ])
        XCTAssertEqual(harness.codex.starts, [])
        await harness.finish()
    }

    func testAnAgentThatIsNotInstalledIsRefused() async throws {
        let harness = try KernelHarness(installed: [.claude])
        await harness.start()
        let item = harness.say("Codex, run the tests")
        await harness.decide(.instruct(text: "run the tests"))

        await harness.speaking("Codex isn't installed on this Mac.")
        XCTAssertEqual(harness.entries.prefix(3), [
            .heard(itemID: item, agent: nil, text: "Codex, run the tests"),
            .decided(itemID: item, agent: .codex, intent: .instruct(text: "run the tests")),
            .refused(itemID: item, reason: .notInstalled),
        ])
        await harness.finish()
    }

    func testInstructingAWorkingAgentSteers() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.say("Claude, also update the README")
        await harness.decide(.instruct(text: "also update the README"))

        await harness.speaking("Okay, I'll add that.")
        XCTAssertEqual(harness.claude.sent, ["run the tests", "also update the README"])
        await harness.finish()
    }

    func testInterruptStopsAWorkingAgentOnly() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, stop")
        await harness.decide(.interrupt)
        await harness.hear("Claude Code isn't working on anything.")

        await harness.launch()
        harness.say("Claude, stop")
        await harness.decide(.interrupt)
        await harness.hear("Stopping Claude Code.")
        XCTAssertEqual(harness.claude.interrupts, 1)
        harness.claude.emit(.stopped)
        await harness.hear("Claude Code stopped.")
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .idle)
        await harness.finish()
    }
}

/// Invariant 7 and the summarizer (§4.4, §4.6).
@MainActor
final class KernelSpeechTests: XCTestCase {
    func testNothingIsSpokenWhileTheUserIsSpeaking() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.input.emit(.speechStarted(itemID: "talking", at: harness.now()))
        await harness.settle()
        harness.claude.emit(.finished(text: "Done."))
        await harness.settle()
        XCTAssertNil(harness.output.current)
        XCTAssertEqual(harness.lastReport?.userSpeaking, true)

        harness.input.emit(.speechStopped(itemID: "talking"))
        await harness.speaking("Claude Code says: Done.")
        await harness.finish()
    }

    func testAcksPlayBeforeRequestsBeforeResults() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.input.emit(.speechStarted(itemID: "talking", at: harness.now()))
        await harness.settle()
        harness.claude.emit(.finished(text: "Done."))
        await harness.settle()
        harness.say("Claude, what are you doing?")
        await harness.decide(.status)
        await harness.settle()
        harness.claude.emit(.permission(.bash("p1", "npm test")))
        await harness.settle()
        XCTAssertNil(harness.output.current)

        harness.input.emit(.speechStopped(itemID: "talking"))
        await harness.hear("Claude Code is idle.")
        await harness.hear("Claude Code wants to run npm test. Allow it?")
        await harness.hear("Claude Code says: Done.")
        await harness.finish()
    }

    func testAReplyOverTheThresholdIsSummarized() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let reply = String(repeating: "a", count: 121)
        harness.claude.emit(.finished(text: reply))
        await harness.summarize(.success("Tests pass."))

        await harness.speaking("Claude Code says, in short: Tests pass.")
        XCTAssertEqual(harness.summarizer.model.inputs, [reply])
        let finished = harness.store.appended.first { $0.entry == .finished(agent: .claude, text: reply) }
        XCTAssertTrue(harness.entries.contains(
            .summarized(agent: .claude, finishedSeq: finished?.seq ?? -1, summary: "Tests pass.")))
        await harness.finish()
    }

    /// The held reply rides the status line whole, so a screen can show what the voice
    /// summarized (2026-10-22).
    func testTheHeldReplyIsOnTheStatusLineWhole() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        XCTAssertNil(harness.agentReport(.claude)?.reply)
        let reply = String(repeating: "a", count: 121)
        harness.claude.emit(.finished(text: reply))
        await harness.summarize(.success("Tests pass."))

        await harness.speaking("Claude Code says, in short: Tests pass.")
        XCTAssertEqual(harness.agentReport(.claude)?.heldReply, true)
        XCTAssertEqual(harness.agentReport(.claude)?.reply, reply)
        await harness.finish()
    }

    func testAReplyAtTheThresholdIsSpokenWhole() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let reply = String(repeating: "a", count: 120)
        harness.claude.emit(.finished(text: reply))

        await harness.speaking("Claude Code says: \(reply)")
        XCTAssertTrue(harness.summarizer.model.inputs.isEmpty)
        await harness.finish()
    }

    /// The threshold counts what is spoken: a reply long only in its markdown is read whole. A
    /// link, which marks a name, is summarized whatever its length (2026-10-16).
    func testAReplyLongOnlyInItsMarkdownIsSpokenWhole() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let text = String(repeating: "**Tests:** pass. ", count: 8).trimmingCharacters(in: .whitespaces)
        XCTAssertGreaterThan(text.count, 120)
        XCTAssertLessThanOrEqual(SpokenText.plain(text).count, 120)
        harness.claude.emit(.finished(text: text))

        await harness.speaking("Claude Code says: " + SpokenText.plain(text))
        XCTAssertTrue(harness.summarizer.model.inputs.isEmpty)
        await harness.finish()
    }

    func testANewerReplySupersedesTheSummaryInFlight() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let first = String(repeating: "a", count: 121)
        let second = String(repeating: "b", count: 121)
        harness.claude.emit(.finished(text: first))
        await waitUntil("the first summary call") { harness.summarizer.model.inputs.count == 1 }
        harness.claude.emit(.finished(text: second))
        await waitUntil("the second summary call") { harness.summarizer.model.inputs.count == 2 }

        await harness.summarize(.success("First."))
        await harness.summarize(.success("Second."))
        await harness.speaking("Claude Code says, in short: Second.")
        XCTAssertFalse(harness.output.texts.contains("Claude Code says, in short: First."))
        // Not `hear`: the superseded call's reply never becomes an input, so nothing settles.
        harness.output.play(at: harness.now(), verbatim: true)
        harness.say("Claude, read it all")
        await harness.decide(.readAll)
        await harness.speaking("Claude Code said: \(second)")
        await harness.finish()
    }

    func testASummaryThatHitsItsBoundIsTold() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: String(repeating: "a", count: 200)))
        await harness.summarize(.failure(.callBound("timeout")))

        await harness.speaking(
            "Claude Code is done, but I couldn't summarize the reply. Say: Claude Code, read it all.")
        await harness.finish()
    }

    /// A summary with no words once plain is told as a failed one, out loud (2026-10-16): no
    /// longer fatal, and never "says, in short:" with nothing after it.
    func testAnEmptySummaryIsToldAsFailed() async throws {
        for empty in ["  ", "```\n```"] {
            let harness = try KernelHarness()
            await harness.start()
            await harness.launch()
            harness.claude.emit(.finished(text: String(repeating: "a", count: 200)))
            await harness.summarize(.success(empty))
            await harness.speaking(
                "Claude Code is done, but I couldn't summarize the reply. Say: Claude Code, read it all.")
            XCTAssertEqual(harness.fatal.reasons, [], empty)
            XCTAssertFalse(harness.entries.contains { if case .summarized = $0 { return true } else { return false } },
                           "nothing summarized is journaled: \(empty)")
            await harness.finish()
        }
    }

    /// A reply that marks a name the agents' way goes to the summarizer whatever its length,
    /// which describes the name (2026-10-16); a short one with none is read as written, and
    /// "read it all" reads the original.
    func testAShortReplyThatMarksANameIsSummarized() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.finished(text: "Ran `./check.sh 40`: it printed `done`."))
        await harness.summarize(.success("I ran the check script, and it printed done."))
        XCTAssertEqual(harness.summarizer.model.inputs, ["Ran `./check.sh 40`: it printed `done`."])
        await harness.hear("Claude Code says, in short: I ran the check script, and it printed done.")
        harness.say("Claude, read it all.")
        await harness.decide(.readAll)
        await harness.hear("Claude Code said: Ran ./check.sh 40: it printed done.")

        harness.say("Claude, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("Okay.")
        harness.claude.emit(.finished(text: "Paris."))
        await harness.hear("Claude Code says: Paris.")
        XCTAssertEqual(harness.summarizer.model.inputs.count, 1)
        await harness.finish()
    }

    func testReadAllWithNothingHeld() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, read it all")
        let input = await harness.decide { _ in .readAll }

        XCTAssertEqual(input?.context(.claude)?.hasHeldReply, false)
        await harness.speaking("There's no reply from Claude Code to read.")
        await harness.finish()
    }

    func testAFailedTurnIsSpokenAndTheAgentStaysUsable() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.failed(reason: "Usage limit reached"))

        await harness.hear("Claude Code stopped: Usage limit reached.")
        await harness.settle()
        XCTAssertEqual(harness.phase(.claude), .idle)
        XCTAssertTrue(harness.fatal.reasons.isEmpty)
        await harness.finish()
    }

    /// A delegate's notice is spoken verbatim as a result and journaled as what was said;
    /// nothing else changes.
    func testANoticeIsSpokenVerbatimAndChangesNothing() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        let sentence = "Claude Code's github server asked for input; I declined."
        harness.claude.emit(.notice(sentence))

        await harness.hear(sentence)
        await harness.settle()
        XCTAssertTrue(harness.entries.contains { entry in
            if case .spoke(_, let text) = entry { return text == sentence }
            return false
        })
        XCTAssertEqual(harness.phase(.claude), .working)
        XCTAssertEqual(harness.lastReport?.agents.first?.pending, [])
        XCTAssertTrue(harness.fatal.reasons.isEmpty)
        await harness.finish()
    }
}

/// §4.5: one intent call at a time, and its failure split.
@MainActor
final class KernelIntentTests: XCTestCase {
    func testOneCallAtATimeInArrivalOrder() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, stop")
        harness.say("Claude, run the tests")
        await harness.settle()
        XCTAssertEqual(harness.intent.model.inputs.map(\.message), ["Claude, stop"])

        await harness.decide(.unclear)
        let second = await harness.decide { _ in .unclear }
        XCTAssertEqual(second?.message, "Claude, run the tests")
        await harness.finish()
    }

    func testACallBoundFailureIsSpokenAndNothingIsDone() async throws {
        let harness = try KernelHarness()
        await harness.start()
        let item = harness.say("Claude, run the tests")
        await harness.failDecision(.callBound("HTTP 503"))

        await harness.speaking("Sorry, I missed that. Please say it again.")
        XCTAssertTrue(harness.entries.contains(.decisionFailed(itemID: item, reason: "HTTP 503")))
        XCTAssertFalse(harness.entries.contains { if case .launchAsked = $0 { return true }; return false })
        await harness.finish()
    }

    func testTheCallBoundIsACallBoundFailure() async throws {
        let harness = try KernelHarness(intentTimeout: .milliseconds(20))
        await harness.start()
        let item = harness.say("Claude, run the tests")

        await harness.speaking("Sorry, I missed that. Please say it again.")
        XCTAssertTrue(harness.entries.contains(.decisionFailed(itemID: item, reason: "timeout")))
        await harness.finish()
    }

    func testAContractFailureIsFatal() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("Claude, run the tests")
        await harness.failDecision(.contract("HTTP 401"))
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "intent", reason: "HTTP 401")])
    }

    func testTheInputCarriesTheHeadAndTheStatusShowsTheAction() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.claude.emit(.permission(PermissionRequest(
            id: "p1", tool: "Bash", inputJSON: #"{"command":"curl x"}"#, command: "curl x",
            reason: "network access",
            alwaysAllow: AlwaysAllowOffer(description: "allow curl", payloadJSON: "[]"))))
        let prompt = "Claude Code wants to run curl x. It says: network access. Allow it?"
        await harness.hear(prompt)
        harness.say("Claude, yes, and don't ask again")
        let input = await harness.decide { .approve(requestID: $0.pending?.requestID ?? "", always: true) }

        XCTAssertEqual(input, IntentInput(
            message: "Claude, yes, and don't ask again",
            agents: [AgentContext(agent: .claude, phase: .working,
                                  pending: PendingSummary(kind: .permission, requestID: "p1", prompt: prompt,
                                                          canAlwaysAllow: true, heard: true),
                                  hasHeldReply: false),
                     AgentContext(agent: .codex, phase: .none, pending: nil, hasHeldReply: false)]
                + AgentContext.chatsOff,
            spokenToLast: .claude, heardFromLast: .claude))
        await harness.speaking("Allowed for Claude Code, and it won't ask again for that.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .allow(always: true))])
        XCTAssertEqual(harness.lastReport?.lastHeard,
                       StatusReport.LastHeard(agent: .claude, text: "Claude, yes, and don't ask again",
                                              action: "approve"))
        await harness.finish()
    }

    /// Live 2026-10-12: Codex offered no session rule, and "yes, and don't ask me again" was
    /// decided as a deny. It is a yes, and the user hears that the agent will ask again.
    func testDontAskAgainWithoutAnOfferIsAYesThatSaysSo() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(.codex)
        harness.codex.emit(.permission(.bash("p1", "npm test")))
        await harness.hear("Codex wants to run npm test. Allow it?")
        harness.say("Codex, yes, and don't ask me again for that")
        await harness.decide { .approve(requestID: $0.pending?.requestID ?? "", always: true) }

        await harness.speaking("Allowed for Codex, but it will still ask next time.")
        XCTAssertEqual(harness.codex.permissions, [.init(id: "p1", decision: .allow(always: false))])
        XCTAssertTrue(harness.entries.contains(.resolved(agent: .codex, requestID: "p1",
                                                         decision: .permission(.allow(always: false)))))
        await harness.finish()
    }
}

/// Invariants 1, 2, 3 and 8.
@MainActor
final class KernelInvariantTests: XCTestCase {
    func testEveryActionIsJournaledBeforeItHappens() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()

        XCTAssertEqual(harness.log.calls, [
            "journal.heard", "journal.decided", "journal.launching", "journal.started", "claude.start",
            "journal.sent", "claude.send", "journal.spoke", "speak",
        ])
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        harness.say("Claude, yes")
        await harness.approve()
        await harness.speaking("Allowed for Claude Code.")
        XCTAssertEqual(Array(harness.log.calls.suffix(9)), [
            "journal.permission", "journal.spoke", "speak",
            "journal.heard", "journal.decided", "journal.resolved", "claude.resolve",
            "journal.spoke", "speak",
        ])
        await harness.finish()
    }

    func testAFailedAppendIsFatalAndTheActionDoesNotHappen() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        harness.store.failing = "sent"
        harness.say("Claude, also lint")
        await harness.decide(.instruct(text: "also lint"))
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons.map(\.subsystem), ["journal"])
        XCTAssertEqual(harness.claude.sent, ["run the tests"])
    }

    func testFatalHappensExactlyOnce() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.input.emit(.failed(reason: "the socket closed"))
        harness.input.emit(.failed(reason: "the socket closed again"))
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "speech-input",
                                                           reason: "the socket closed")])
    }

    func testAProducerThatEndsIsFatal() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.input.finishEvents()
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(
            subsystem: "kernel", reason: "inbox producer ended", context: ["producer": "speech-input"])])
    }

    /// A delegate's stream ending is that agent failing, not TapQ (ruling 2026-10-12).
    func testADelegateStreamThatEndsStopsThatAgentOnly() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.codex.finishEvents()
        await harness.hear("TapQ lost track of Codex, so it stopped it. Talk to Codex to start it again.")
        XCTAssertEqual(harness.fatal.reasons, [])
        XCTAssertEqual(harness.codexes.count, 2)
        await harness.finish()
    }

    // MARK: - Routing (§4.2): everything heard is the user's

    /// Routing by the model (2026-10-12): every sentence goes whole, with both agents, and
    /// nothing is matched by name first.
    func testEveryUtteranceGoesToTheModelWholeWithBothAgents() async throws {
        let harness = try KernelHarness()
        await harness.start()
        let item = harness.say("cloud storage is down")
        let input = await harness.decide(for: .claude) { _ in .unclear }
        await harness.settle()

        XCTAssertEqual(input, IntentInput(
            message: "cloud storage is down",
            agents: [AgentContext(agent: .claude, phase: .none, pending: nil, hasHeldReply: false),
                     AgentContext(agent: .codex, phase: .none, pending: nil, hasHeldReply: false)]
                + AgentContext.chatsOff))
        XCTAssertEqual(Array(harness.entries.prefix(2)), [
            .heard(itemID: item, agent: nil, text: "cloud storage is down"),
            .decided(itemID: item, agent: .claude, intent: .unclear),
        ])
        XCTAssertEqual(harness.sink.named("utterance.routed").map(\.fields), [["agent": "claude", "by": "model"]])
        XCTAssertEqual(harness.lastReport?.lastHeard,
                       StatusReport.LastHeard(agent: .claude, text: "cloud storage is down", action: "unclear"))
        await harness.finish()
    }

    /// Who was spoken to last, who was heard from last, and what each agent said last go with
    /// every sentence: the model weighs them, no rule does.
    func testTheConversationSoFarGoesWithEverySentence() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(.claude)
        harness.say("Codex, list the files")
        await harness.decide(.unclear)
        await harness.hear("I didn't catch what Codex should do. Say it again.")
        harness.claude.emit(.finished(text: "Done. Shall I commit?"))
        await harness.hear("Claude Code says: Done. Shall I commit?")
        harness.say("yes, commit it")
        let input = await harness.decide(for: .claude) { _ in .instruct(text: "yes, commit it") }

        XCTAssertEqual(input?.spokenToLast, .codex)
        XCTAssertEqual(input?.heardFromLast, .claude)
        XCTAssertEqual(input?.context(.claude)?.lastSaid, "Claude Code says: Done. Shall I commit?")
        XCTAssertNil(input?.context(.codex)?.lastSaid, "an ack is TapQ's, not the agent's")
        await harness.hear("Okay.")
        XCTAssertEqual(harness.claude.sent.last, "yes, commit it")

        // A read-all re-reads the reply whole; what the agent last said stays the reply as heard.
        harness.say("Claude, read it all")
        await harness.decide(.readAll)
        await harness.hear("Claude Code said: Done. Shall I commit?")
        harness.say("Claude, thanks")
        let after = await harness.decide { _ in .unclear }
        XCTAssertEqual(after?.context(.claude)?.lastSaid, "Claude Code says: Done. Shall I commit?")
        await harness.finish()
    }

    /// A yes the model cannot place, with both agents' requests heard, resolves nothing: TapQ
    /// asks which agent.
    func testAYesTheModelCannotPlaceIsAskedAbout() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch(.claude)
        await harness.launch(.codex)
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        harness.codex.emit(.permission(.bash("c1", "npm test")))
        await harness.hear("Codex wants to run npm test. Allow it?")
        let item = harness.say("yes")
        let input = await harness.decideWithoutAgent(.approve(requestID: "", always: false))

        XCTAssertEqual(input?.agents.map { $0.pending?.heard }, [true, true, nil, nil])
        await harness.speaking("For Claude Code or Codex? Say the name with your answer.")
        XCTAssertEqual(harness.claude.permissions, [])
        XCTAssertEqual(harness.codex.permissions, [])
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .agentUnclear)))
        XCTAssertEqual(harness.sink.named("utterance.routed").last?.fields, ["agent": "none", "by": "model"])

        harness.output.play(at: harness.now(), verbatim: true)
        harness.say("Yes, Claude.")
        await harness.approve()
        await harness.speaking("Allowed for Claude Code.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .allow(always: false))])
        XCTAssertEqual(harness.codex.permissions, [])
        await harness.finish()
    }

    /// A transcript with no words is dropped; a name with nothing after it is asked again.
    func testAnEmptyTranscriptIsDropped() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.say("  ")
        harness.say("…")
        harness.say(" . ")
        await harness.settle()

        XCTAssertEqual(harness.entries, [])
        XCTAssertTrue(harness.intent.model.inputs.isEmpty)
        XCTAssertEqual(harness.sink.named("utterance.empty").count, 3)
        await harness.finish()
    }

    func testShutdownStopsEverythingCleanly() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.finish()

        XCTAssertTrue(harness.output.cancelled)
        XCTAssertTrue(harness.input.closed)
        XCTAssertTrue(harness.claude.stopped)
        XCTAssertTrue(harness.codex.stopped)
        XCTAssertEqual(harness.fatal.reasons, [])
        XCTAssertEqual(harness.reports.first?.type, "ready")
    }

    /// A host shows "Starting…" until `ready`, which comes once, after input opened.
    func testReadyIsReportedOnceAfterInputOpens() async throws {
        let harness = try KernelHarness()
        await harness.start()
        await harness.launch()
        await harness.finish()

        XCTAssertEqual(harness.reports.first?.type, "ready")
        XCTAssertEqual(harness.reports.first?.agents.map(\.phase),
                       [AgentPhase.none, AgentPhase.none, .notInstalled, .notInstalled])
        XCTAssertGreaterThan(harness.reports.count, 1)
        XCTAssertEqual(harness.reports.dropFirst().filter { $0.type != "status" }.count, 0)
    }

    func testNoReadyWhenInputFailsToOpen() async throws {
        let harness = try KernelHarness()
        harness.input.openError = FakeError()
        await harness.start()
        await harness.ended()

        XCTAssertEqual(harness.reports, [])
        XCTAssertEqual(harness.fatal.reasons.map(\.subsystem), ["speech-input"])
    }

    func testAnExpiredSessionReopensInput() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.input.emit(.speechStarted(itemID: "cut", at: harness.now()))
        harness.input.emit(.sessionExpired)
        await harness.settle()

        XCTAssertEqual(harness.input.reopens, 1)
        XCTAssertEqual(harness.lastReport?.userSpeaking, false)
        XCTAssertEqual(harness.sink.named("stt.rollover").first?.fields, ["open_item": "cut"])
        await harness.finish()
    }

    func testAnInputFailureIsFatal() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.input.emit(.failed(reason: "peer closed 1006"))
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "speech-input",
                                                           reason: "peer closed 1006")])
    }

    /// V1 P1-1: a producer's end is ordered after its last event, so the fatal names the
    /// failure, not the end it caused.
    func testAFailureFollowedByTheStreamEndingReportsTheFailure() async throws {
        let harness = try KernelHarness()
        await harness.start()
        harness.input.emit(.failed(reason: "microphone unplugged"))
        harness.input.finishEvents()
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "speech-input",
                                                           reason: "microphone unplugged")])
    }

    /// V3 P2-2: the same while the kernel is awaiting inside a handler.
    func testAFailureWhileAStartIsAwaitedReportsTheFailure() async throws {
        let harness = try KernelHarness()
        harness.claude.holdsStart = true
        await harness.start()
        harness.say("Claude, run the tests")
        await harness.decide(.instruct(text: "run the tests"))
        await harness.offer(.claude, .success([]))
        await waitUntil("the start to be awaited") { harness.claude.startHeld }

        harness.input.emit(.failed(reason: "microphone unplugged"))
        harness.input.finishEvents()
        harness.claude.releaseStart()
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(subsystem: "speech-input",
                                                           reason: "microphone unplugged")])
        XCTAssertEqual(harness.claude.sent, ["run the tests"], "the start finished first")
    }
}

/// 01-2: the shipping fatal's order. The log line and the group kill come before anything
/// that can block or fail, and the exit comes last.
@MainActor
final class ProcessFatalTests: XCTestCase {
    private final class StepSink: TapQDiagnosticSink {
        let steps: Locked<[String]>

        init(_ steps: Locked<[String]>) { self.steps = steps }

        func record(_ event: TapQDiagnosticEvent) {
            steps.withValue { $0.append("record \(event.name): \(event.fields["reason"] ?? "")") }
        }
    }

    func testItRecordsThenRunsBeforeExitThenWritesStderrThenExits() async {
        let steps = Locked<[String]>([])
        let fatal = ProcessFatal(diagnostics: StepSink(steps),
                                 beforeExit: { steps.withValue { $0.append("beforeExit") } },
                                 writeStandardError: { text in steps.withValue { $0.append(text) } },
                                 exitProcess: { code in steps.withValue { $0.append("exit \(code)") } })
        fatal.crash(FatalReason(subsystem: "journal", reason: "disk full"))

        XCTAssertEqual(steps.withValue { $0 }, [
            "record fatal: disk full", "beforeExit", "tapq-kernel: fatal in journal: disk full\n", "exit 70",
        ])
    }

    /// Another executable exits through the same door and names itself on the line.
    func testAnotherExecutableNamesItselfOnTheStderrLine() async {
        let lines = Locked<[String]>([])
        let fatal = ProcessFatal(program: "tapq-recorder",
                                 writeStandardError: { text in lines.withValue { $0.append(text) } },
                                 exitProcess: { _ in })
        fatal.crash(FatalReason(subsystem: "microphone", reason: "the microphone is unavailable"))

        XCTAssertEqual(lines.withValue { $0 },
                       ["tapq-recorder: fatal in microphone: the microphone is unavailable\n"])
        XCTAssertEqual(ProcessFatal.message(for: FatalReason(subsystem: "model", reason: "no key")),
                       "tapq-kernel: fatal in model: no key", "the kernel's line is unchanged")
    }
}

/// §4.9: a restart marks what was in flight lost, says so once per agent, resends nothing.
@MainActor
final class KernelResumeTests: XCTestCase {
    func testARestartMarksLostWorkAndSaysOneSentencePerAgent() async throws {
        let harness = try KernelHarness(seed: [
            .started(agent: .claude, sessionID: "s-1"),
            .heard(itemID: "u1", agent: .claude, text: "run the tests"),
            .decided(itemID: "u1", intent: .instruct(text: "run the tests")),
            .sent(agent: .claude, text: "run the tests"),
            .spoke(id: SpeechID(raw: 7), text: "Okay."),
            .permission(agent: .claude, .bash("p1", "npm test")),
            .heard(itemID: "u2", agent: .claude, text: "yes"),
            .launchAsked(agent: .codex, requestID: "launch-8", folder: "workspace", resume: false,
                         held: "lint"),
        ], sessionIDs: [.claude: "s-1"])
        await harness.start()

        let claudeSentence = "TapQ restarted. Claude Code's unfinished task and 1 open request stopped, "
            + "and nothing was resent."
        let codexSentence = "TapQ restarted. Codex's unfinished task stopped, and nothing was resent."
        await harness.hear(claudeSentence)
        await harness.hear(codexSentence)
        await harness.settle()
        XCTAssertNil(harness.output.current, "one sentence per agent")
        XCTAssertEqual(harness.entries, [
            .lost(agent: .claude, .turn),
            .lost(agent: .claude, .request(id: "p1")),
            .lost(agent: .codex, .request(id: "launch-8")),
            .spoke(id: SpeechID(raw: 8), text: claudeSentence),
            .spoke(id: SpeechID(raw: 9), text: codexSentence),
        ])
        XCTAssertEqual(harness.claude.starts, [])
        XCTAssertEqual(harness.claude.sent, [])
        XCTAssertEqual(harness.codex.sent, [])
        XCTAssertEqual(harness.phase(.claude), AgentPhase.none)

        harness.say("Claude, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.claude, .success([.made("s-1", "run the tests")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.speaking("Okay, Claude Code continues its last conversation.")
        await harness.finish()
    }

    func testAHeldReplySurvivesARestart() async throws {
        let harness = try KernelHarness(seed: [
            .sent(agent: .claude, text: "run the tests"),
            .finished(agent: .claude, text: "All green."),
            .spoke(id: SpeechID(raw: 1), text: "Claude Code says: All green."),
        ])
        await harness.start()
        harness.say("Claude, read it all")
        let input = await harness.decide { _ in .readAll }

        XCTAssertEqual(input?.context(.claude)?.hasHeldReply, true)
        await harness.speaking("Claude Code said: All green.")
        XCTAssertEqual(harness.entries.count, 3, "heard, decided, spoke: nothing was lost")
        await harness.finish()
    }

    /// V1 P2-2 (a): a launch yes journaled with no `sent` after it.
    func testALaunchYesCutOffBeforeItsSendIsTold() async throws {
        let harness = try KernelHarness(seed: [
            .launchAsked(agent: .claude, requestID: "launch-1", folder: "workspace", resume: false,
                         held: "run the tests"),
            .resolved(agent: .claude, requestID: "launch-1", decision: .launch(yes: true)),
            .started(agent: .claude, sessionID: "s-1"),
        ], sessionIDs: [.claude: "s-1"])
        await harness.start()

        let sentence = "TapQ restarted. Claude Code's unfinished task stopped, and nothing was resent."
        await harness.hear(sentence)
        XCTAssertEqual(harness.entries, [.lost(agent: .claude, .turn), .spoke(id: SpeechID(raw: 1), text: sentence)])
        XCTAssertEqual(harness.claude.sent, [])
        await harness.finish()
    }

    /// A start without a yes (2026-10-24) cut off before its send is told as a launch yes is;
    /// one with no words opens no turn.
    func testAStartWithoutAYesCutOffBeforeItsSendIsTold() async throws {
        let harness = try KernelHarness(seed: [
            .launching(agent: .claude, target: .new, held: "run the tests"),
            .started(agent: .claude, sessionID: "s-1"),
            .launching(agent: .codex, target: .new, held: ""),
            .started(agent: .codex, sessionID: "c-1"),
        ], sessionIDs: [.claude: "s-1", .codex: "c-1"])
        await harness.start()

        let sentence = "TapQ restarted. Claude Code's unfinished task stopped, and nothing was resent."
        await harness.hear(sentence)
        XCTAssertEqual(harness.entries, [.lost(agent: .claude, .turn), .spoke(id: SpeechID(raw: 1), text: sentence)])
        await harness.finish()
    }

    /// V1 P2-2 (b): a reply journaled but never spoken.
    func testAReplyNeverSpokenIsToldOnResume() async throws {
        let harness = try KernelHarness(seed: [
            .sent(agent: .codex, text: "lint"),
            .finished(agent: .codex, text: "Lint is clean."),
        ])
        await harness.start()

        await harness.hear("Codex has a reply; say: Codex, read it all.")
        harness.say("Codex, read it all")
        await harness.decide(.readAll)
        await harness.speaking("Codex said: Lint is clean.")
        XCTAssertFalse(harness.entries.contains { if case .lost = $0 { return true }; return false })
        await harness.finish()
    }

    func testAnUnreadableJournalIsFatal() async throws {
        let harness = try KernelHarness()
        harness.store.loadError = JournalStoreError.olderTranscript
        await harness.start()
        await harness.ended()

        XCTAssertEqual(harness.fatal.reasons, [FatalReason(
            subsystem: "journal", reason: "this workspace has a transcript from an older TapQ; clear it")])
        XCTAssertEqual(harness.input.opens, 0)
    }
}
