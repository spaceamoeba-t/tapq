import Foundation
import XCTest
@testable import TapQKernel

/// Claude chat and ChatGPT: the user's real chats in the Claude and ChatGPT apps, through the
/// same loop as the coding agents (2026-10-13). A chat's first words
/// carry on the chat its app shows, when the picker finds them going on with it, or open a new
/// one (2026-10-24); it never resumes a chat of its own, cannot be steered while it answers, and
/// its chats are not listed. Everything else is the coding agents' path.
@MainActor
final class KernelChatAgentTests: XCTestCase {
    private var harness: KernelHarness!

    private static let everyAgent = Set(AgentID.mac)

    override func setUp() async throws {
        harness = try KernelHarness(installed: Self.everyAgent)
    }

    override func tearDown() async throws {
        await harness.finish()
        harness = nil
    }

    /// Drives `agent` from none to answering `question`, in a new chat: its app shows none.
    private func ask(_ agent: AgentID = .chatgpt, _ question: String = "what's the capital of France?") async {
        harness.say("\(agent.displayName), \(question)")
        await harness.decide(.instruct(text: question))
        await harness.hear("Okay.")
    }

    /// ChatGPT answered "Paris." and is idle.
    private func answered() async {
        await ask()
        harness.chatgpt.emit(.finished(text: "Paris."))
        await harness.hear("ChatGPT says: Paris.")
    }

    /// A start record (2026-10-24: none is asked).
    private struct Launched: Equatable {
        let held: String
        let target: LaunchTarget

        init(_ held: String, target: LaunchTarget = .new) {
            self.held = held
            self.target = target
        }
    }

    /// Every start journaled for `agent` this run, in order.
    private func launched(_ agent: AgentID) -> [Launched] {
        harness.entries.compactMap { entry in
            guard case .launching(agent, let target, let held) = entry else { return nil }
            return Launched(held, target: target)
        }
    }

    // MARK: - Starting

    /// The first words start the chat at once (2026-10-24): the app shows no chat, so nothing is
    /// picked, and a new chat opens with them.
    func testTheFirstWordsOpenANewChatAtOnce() async throws {
        await harness.start()
        harness.say("ChatGPT, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("Okay.")
        XCTAssertEqual(launched(.chatgpt), [Launched("what's the capital of France?")])
        XCTAssertEqual(harness.chatgpt.shownReads, 1, "the chat its app shows is looked at first")
        XCTAssertEqual(harness.picker.model.inputs, [], "nothing to pick from")
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?"])
        XCTAssertEqual(harness.phase(.chatgpt), .working)
        XCTAssertTrue(harness.entries.contains(.started(agent: .chatgpt, sessionID: "session-new", chats: .app)))
        XCTAssertNil(try harness.sessions.sessionID(for: .chatgpt), "a chat keeps no session to resume")
        XCTAssertEqual(harness.log.calls, [
            "journal.heard", "journal.decided", "chatgpt.shown", "journal.launching", "journal.started",
            "chatgpt.start", "journal.sent", "chatgpt.send", "journal.spoke", "speak",
        ])
    }

    /// The chat the app shows is offered to the picker; words that go on with it are sent into it,
    /// and the user hears which (the maintainer's case, 2026-10-24).
    func testTheChatTheAppShowsIsCarriedOnWhenTheWordsGoOnWithIt() async throws {
        harness.chatgpt.shown = "Downtown Toronto rentals"
        await harness.start()
        let words = "继续帮我对比一下今天我们讨论的三个房源"
        harness.say("ChatGPT, \(words)")
        await harness.decide(.instruct(text: words))
        let asked = await harness.pick(.success(ConversationPick(number: 1, name: "the Toronto rentals comparison")))
        XCTAssertEqual(asked, PickInput(instruction: words,
                                        candidates: [ConversationCandidate(number: 1, title: "Downtown Toronto rentals",
                                                                           age: "", last: true)],
                                        agent: .chatgpt))
        await harness.hear("Okay, ChatGPT continues the Toronto rentals comparison.")
        XCTAssertEqual(harness.chatgpt.starts, [.resume(id: "shown")])
        XCTAssertEqual(harness.chatgpt.sent, [words])
        XCTAssertEqual(launched(.chatgpt), [Launched(words, target: .shown)])
        XCTAssertNil(try harness.sessions.sessionID(for: .chatgpt), "still no session of its own")
    }

    /// Words on something else open a new chat even while the app shows one.
    func testANewSubjectOpensANewChatWhateverTheAppShows() async throws {
        harness.claudeChat.shown = "Capital of Portugal"
        await harness.start()
        harness.say("Claude chat, write a poem about autumn")
        await harness.decide(.instruct(text: "write a poem about autumn"))
        await harness.pick(.success(ConversationPick(number: nil, name: "")))
        await harness.hear("Okay, Claude chat starts a new chat.")
        XCTAssertEqual(harness.claudeChat.starts, [.fresh])
        XCTAssertEqual(launched(.claudeChat), [Launched("write a poem about autumn")])
    }

    /// A pick that fails carries on the chat the app shows, and says so.
    func testAFailedPickCarriesOnTheChatTheAppShows() async throws {
        harness.chatgpt.shown = "Portugal Capital Question"
        await harness.start()
        harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.pick(.failure(.callBound("timeout")))
        await harness.hear("I couldn't tell which chat you meant, so ChatGPT continues its last one.")
        XCTAssertEqual(harness.chatgpt.starts, [.resume(id: "shown")])
        XCTAssertEqual(harness.chatgpt.sent, ["and of Spain?"])
    }

    /// Claude chat is the chat in the Claude app; the user's words reach it, and its answer is read.
    func testClaudeChatOpensANewChatInTheClaudeApp() async throws {
        await harness.start()
        await ask(.claudeChat, "what's the capital of France?")
        XCTAssertEqual(harness.claudeChat.starts, [.fresh])
        XCTAssertEqual(harness.claudeChat.sent, ["what's the capital of France?"])
        XCTAssertEqual(harness.claude.starts, [], "Claude chat is not Claude Code")

        let item = harness.say("Claude chat, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("Claude chat is still answering. Say it again when it's done, or say: Claude chat, stop.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .busy)))
        harness.claudeChat.emit(.finished(text: "Paris."))
        await harness.hear("Claude chat says: Paris.")
        XCTAssertNil(try harness.sessions.sessionID(for: .claudeChat))
    }

    /// The app's own refusal to start (here, no Accessibility access) fails ChatGPT alone, and
    /// never says the way out of a conversation that is gone: a chat is never resumed.
    func testAStartThatFailsIsToldWithoutAResumeHint() async throws {
        struct NoAccess: Error, CustomStringConvertible {
            var description: String { "TapQ needs Accessibility access to use ChatGPT." }
        }
        harness.chatgpt.startError = NoAccess()
        await harness.start()
        harness.say("ChatGPT, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("ChatGPT couldn't start: TapQ needs Accessibility access to use ChatGPT.")
        XCTAssertEqual(harness.phase(.chatgpt), AgentPhase.none)
        XCTAssertEqual(harness.fatal.reasons, [])
    }

    // MARK: - Words while idle and while answering

    func testWordsWhileIdleAreSentWithNoPrompt() async throws {
        await harness.start()
        await answered()
        harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?", "and of Spain?"])
        XCTAssertEqual(harness.chatgpt.starts, [.fresh], "the same chat")
        XCTAssertEqual(harness.phase(.chatgpt), .working)
        XCTAssertEqual(launched(.chatgpt), [Launched("what's the capital of France?")])
    }

    /// A chat app's answer cannot be steered: the words are refused out loud and never sent.
    func testWordsWhileItAnswersAreRefusedAndNotSent() async throws {
        await harness.start()
        await ask()
        let item = harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("ChatGPT is still answering. Say it again when it's done, or say: ChatGPT, stop.")
        await harness.settle()
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?"])
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .busy)))
        XCTAssertFalse(harness.entries.contains(.sent(agent: .chatgpt, text: "and of Spain?")))
        XCTAssertEqual(harness.phase(.chatgpt), .working)

        harness.chatgpt.emit(.finished(text: "Paris."))
        await harness.hear("ChatGPT says: Paris.")
        harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?", "and of Spain?"])
    }

    func testStopInterruptsTheAnswer() async throws {
        await harness.start()
        await ask()
        harness.say("ChatGPT, stop")
        await harness.decide(.interrupt)
        await harness.hear("Stopping ChatGPT.")
        XCTAssertEqual(harness.chatgpt.interrupts, 1)
        XCTAssertTrue(harness.entries.contains(.interruptSent(agent: .chatgpt)))

        harness.chatgpt.emit(.stopped)
        await harness.hear("ChatGPT stopped.")
        await harness.settle()
        XCTAssertEqual(harness.phase(.chatgpt), .idle)
        harness.say("ChatGPT, stop")
        await harness.decide(.interrupt)
        await harness.hear("ChatGPT isn't working on anything.")
        XCTAssertEqual(harness.chatgpt.interrupts, 1)
    }

    // MARK: - Replies

    func testAReplyAtTheThresholdIsReadWhole() async throws {
        await harness.start()
        await ask()
        let reply = String(repeating: "a", count: 120)
        harness.chatgpt.emit(.finished(text: reply))
        await harness.hear("ChatGPT says: \(reply)")
        XCTAssertTrue(harness.summarizer.model.inputs.isEmpty)
        XCTAssertEqual(harness.phase(.chatgpt), .idle)
    }

    /// Never cut: a longer reply goes whole to the summary model, and "read it all" reads it.
    func testALongerReplyIsSummarizedAndReadAllReadsItWhole() async throws {
        await harness.start()
        await ask()
        let reply = String(repeating: "Paris is the capital of France. ", count: 5)
            .trimmingCharacters(in: .whitespaces)
        harness.chatgpt.emit(.finished(text: reply))
        await harness.summarize(.success("Paris."))
        await harness.hear("ChatGPT says, in short: Paris.")
        XCTAssertEqual(harness.summarizer.model.inputs, [reply])

        harness.say("ChatGPT, read it all")
        await harness.decide(.readAll)
        await harness.hear("ChatGPT said: \(reply)")
    }

    func testAFailedTurnIsToldAndTheChatStaysUsable() async throws {
        await harness.start()
        await ask()
        harness.chatgpt.emit(.failed(reason: "ChatGPT gave no answer"))
        await harness.hear("ChatGPT stopped: ChatGPT gave no answer.")
        await harness.settle()
        XCTAssertEqual(harness.phase(.chatgpt), .idle)
        XCTAssertEqual(harness.fatal.reasons, [])
    }

    func testStatusSaysWhatTheChatIsDoing() async throws {
        await harness.start()
        harness.say("ChatGPT, what are you doing?")
        await harness.decide(.status)
        await harness.hear("ChatGPT isn't running.")
        await ask()
        harness.chatgpt.emit(.progress("Searching the web"))
        await harness.settle()
        harness.say("ChatGPT, what are you doing?")
        await harness.decide(.status)
        let turn = await harness.summarizeProgress(.success("ChatGPT is searching the web."))
        XCTAssertEqual(turn?.steps.map(\.line), ["Searching the web"])
        await harness.hear("ChatGPT is searching the web.")
        harness.chatgpt.emit(.finished(text: "Paris."))
        await harness.hear("ChatGPT says: Paris.")
        harness.say("ChatGPT, what are you doing?")
        await harness.decide(.status)
        await harness.hear("ChatGPT is idle.")
    }

    // MARK: - One chat failing

    /// The app quit: ChatGPT alone fails, Claude Code works on, and the next words open a new
    /// chat on a fresh delegate, never a resume.
    func testAnAppThatQuitsFailsThatChatAloneAndTheNextWordsOpenANewChat() async throws {
        await harness.start()
        await harness.launch(.claude)
        await ask()
        harness.chatgpt.emit(.exited(code: 0, stderrTail: []))
        await harness.hear("ChatGPT quit unexpectedly. Its unfinished task stopped, and nothing was resent. "
            + "Talk to ChatGPT to start it again.")
        XCTAssertTrue(harness.entries.contains(.lost(agent: .chatgpt, .turn)))
        XCTAssertEqual(harness.phase(.chatgpt), AgentPhase.none)
        XCTAssertEqual(harness.phase(.claude), .working)
        XCTAssertEqual(harness.fatal.reasons, [])
        await waitUntil("the old delegate to be stopped") { harness.chatgpts[0].stopped }

        harness.say("ChatGPT, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpts.count, 2)
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
        XCTAssertEqual(launched(.chatgpt), [Launched("what's the capital of France?"),
                                            Launched("what's the capital of France?")],
                       "never a resume")
    }

    /// The reply TapQ holds is the old chat's until a new chat starts.
    func testTheHeldReplyGoesWithItsChat() async throws {
        await harness.start()
        await answered()
        harness.chatgpt.emit(.exited(code: 0, stderrTail: []))
        await harness.hear("ChatGPT quit unexpectedly. Talk to ChatGPT to start it again.")
        harness.say("ChatGPT, read it all")
        await harness.decide(.readAll)
        await harness.hear("ChatGPT said: Paris.")

        await ask(.chatgpt, "and of Spain?")
        harness.say("ChatGPT, read it all")
        await harness.decide(.readAll)
        await harness.hear("There's no reply from ChatGPT to read.")
    }

    /// A restart tells what it cut off, resends nothing, and opens a new chat: a session id
    /// for a chat in `session.json` (a build of before) is not read.
    func testARestartOpensANewChatAndNeverResumes() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, seed: [
            .launchAsked(agent: .chatgpt, requestID: "launch-1", folder: "workspace", resume: false,
                         held: "what's the capital of France?"),
            .resolved(agent: .chatgpt, requestID: "launch-1", decision: .launch(yes: true)),
            .started(agent: .chatgpt, sessionID: "chat-1"),
            .sent(agent: .chatgpt, text: "what's the capital of France?"),
        ], sessionIDs: [.chatgpt: "chat-1"])
        await harness.start()
        let sentence = "TapQ restarted. ChatGPT's last answer is left in the app, unread, and nothing was resent."
        await harness.hear(sentence)
        XCTAssertEqual(harness.entries, [.lost(agent: .chatgpt, .turn), .spoke(id: SpeechID(raw: 1), text: sentence)])
        XCTAssertEqual(harness.chatgpt.sent, [])

        harness.say("ChatGPT, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.hear("Okay.")
        XCTAssertEqual(launched(.chatgpt), [Launched("carry on")], "never a resume")
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
    }

    /// A restart folds each start of a chat as a new chat, as the run did: the reply before it
    /// is not held, even when the delegate gave the same id.
    func testARestartHoldsNoReplyFromAChatBeforeTheLastStart() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, seed: [
            .started(agent: .chatgpt, sessionID: "chat"),
            .sent(agent: .chatgpt, text: "what's the capital of France?"),
            .finished(agent: .chatgpt, text: "Paris."),
            .spoke(id: SpeechID(raw: 1), text: "ChatGPT says: Paris."),
            .started(agent: .chatgpt, sessionID: "chat"),
        ])
        await harness.start()
        harness.say("ChatGPT, read it all")
        let input = await harness.decide { _ in .readAll }
        XCTAssertEqual(input?.context(.chatgpt)?.hasHeldReply, false)
        await harness.hear("There's no reply from ChatGPT to read.")
    }

    // MARK: - Conversations

    /// Neither listed nor switched, and the app's chats are never read or looked up.
    func testChatsAreNotListedOrSwitched() async throws {
        harness.chatCatalog.openNow = [OpenSession(id: "app", title: "Capitals", working: true)]
        await harness.start()
        harness.say("ChatGPT, what chats do you have?")
        await harness.decide(.listConversations)
        await harness.hear("TapQ can't list ChatGPT's chats yet.")
        harness.say("ChatGPT, more")
        await harness.decide(.moreConversations)
        await harness.hear("TapQ can't list ChatGPT's chats yet.")
        let item = harness.say("ChatGPT, go back to chat 2")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("TapQ can't list ChatGPT's chats yet.")

        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .noSuchConversation)))
        XCTAssertEqual(harness.phase(.chatgpt), AgentPhase.none)
        XCTAssertNil(harness.agentReport(.chatgpt)?.conversations)
        XCTAssertTrue(harness.chatCatalog.model.inputs.isEmpty)
        XCTAssertEqual(harness.chatCatalog.looks, 0)
    }

    /// A chat is never looked up as open elsewhere: not by a status, not before a start.
    func testAChatIsNeverLookedUpElsewhere() async throws {
        harness.chatCatalog.openNow = [OpenSession(id: "app", title: "Capitals", working: true)]
        await harness.start()
        harness.say("ChatGPT, what are you doing?")
        await harness.decide(.status)
        await harness.hear("ChatGPT isn't running.")
        await answered()
        harness.say("ChatGPT, new chat")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("ChatGPT is in a new chat.")
        harness.chatgpt.emit(.exited(code: 0, stderrTail: []))
        await harness.hear("ChatGPT quit unexpectedly. Talk to ChatGPT to start it again.")
        harness.say("ChatGPT, what are you doing?")
        await harness.decide(.status)
        await harness.hear("ChatGPT isn't running.")
        XCTAssertEqual(harness.chatCatalog.looks, 0)
    }

    /// A new chat starts at once (2026-10-24): the running chat's delegate is stopped and a
    /// fresh one opens a new chat, with nothing read first. With no words, nothing is sent.
    func testANewChatStartsFreshAtOnce() async throws {
        await harness.start()
        await answered()
        harness.say("ChatGPT, new chat")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("ChatGPT is in a new chat.")
        XCTAssertEqual(launched(.chatgpt), [Launched("what's the capital of France?"), Launched("")])
        XCTAssertEqual(harness.chatgpts.map(\.shownReads), [1, 0], "an explicit new chat looks at nothing first")
        XCTAssertTrue(harness.chatgpts[0].stopped, "the old chat's delegate is gone first")
        XCTAssertEqual(harness.chatgpts.count, 2)
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
        XCTAssertEqual(harness.chatgpt.sent, [])
        XCTAssertEqual(harness.phase(.chatgpt), .idle)

        harness.say("ChatGPT, read it all")
        await harness.decide(.readAll)
        await harness.hear("There's no reply from ChatGPT to read.")
        harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpt.sent, ["and of Spain?"])
    }

    func testANewChatWithWordsSendsThem() async throws {
        await harness.start()
        harness.say("ChatGPT, new chat: what's the capital of Spain?")
        await harness.decide(.newConversation(text: "what's the capital of Spain?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of Spain?"])
        XCTAssertEqual(harness.phase(.chatgpt), .working)
    }

    /// A chat that is answering is not moved to a new one: the user stops it first.
    func testANewChatWhileItAnswersIsRefused() async throws {
        await harness.start()
        await ask()
        let item = harness.say("ChatGPT, new chat")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("ChatGPT is working. To switch conversations, first say: ChatGPT, stop.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .busy)))
        XCTAssertEqual(harness.chatgpts.count, 1)
    }

    // MARK: - Routing

    /// Claude Code and Codex each wait on a heard request, with the chats on the roster.
    private func twoHeardRequests() async {
        await harness.launch(.claude)
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        await harness.launch(.codex, task: "write the tests")
        harness.codex.emit(.permission(.bash("c1", "swift test")))
        await harness.hear("Codex wants to run swift test. Allow it?")
    }

    /// A yes the model cannot place is asked about by the names of the agents whose requests
    /// the user heard.
    func testAYesTheModelCannotPlaceNamesTheAgentsWithHeardRequests() async throws {
        await harness.start()
        await twoHeardRequests()
        let item = harness.say("yes")
        let input = await harness.decideWithoutAgent(.approve(requestID: "", always: false))

        XCTAssertEqual(input?.agents.map { $0.pending?.heard }, [true, true, nil, nil])
        await harness.speaking("For Claude Code or Codex? Say the name with your answer.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .agentUnclear)))
        XCTAssertEqual(harness.claude.permissions, [])
        XCTAssertEqual(harness.codex.permissions, [])

        harness.output.play(at: harness.now(), verbatim: true)
        harness.say("Yes, Codex.")
        await harness.decide(for: .codex) { .approve(requestID: $0.context(.codex)?.pending?.requestID ?? "",
                                                     always: false) }
        await harness.hear("Allowed for Codex.")
        XCTAssertEqual(harness.codex.permissions, [.init(id: "c1", decision: .allow(always: false))])
        XCTAssertEqual(harness.claude.permissions, [])
    }

    /// The state rule (2026-10-13): with two requests heard, a no the model placed by the state
    /// rather than by a name the user said is asked about, never given; said with the name, it is.
    func testANoPlacedByTheStateWithTwoHeardRequestsIsAskedAbout() async throws {
        await harness.start()
        await twoHeardRequests()
        let item = harness.say("No.")
        await harness.decide(for: .claude, basis: .state) { input in
            .deny(requestID: input.agents.first { $0.agent == .claude }?.pending?.requestID ?? "", feedback: nil)
        }

        await harness.speaking("For Claude Code or Codex? Say the name with your answer.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .agentUnclear)))
        XCTAssertEqual(harness.claude.permissions, [])
        XCTAssertEqual(harness.codex.permissions, [])

        harness.output.play(at: harness.now(), verbatim: true)
        harness.say("No, Claude.")
        await harness.decide(for: .claude, basis: .name) { input in
            .deny(requestID: input.agents.first { $0.agent == .claude }?.pending?.requestID ?? "", feedback: nil)
        }
        await harness.hear("Denied for Claude Code.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .deny(feedback: nil))])
        XCTAssertEqual(harness.codex.permissions, [])
    }

    /// A chat's answer read after a request, ending in an offer: a bare yes placed by the state
    /// could be for either, and is asked about, never given to the request (review 2026-10-13).
    func testAYesAfterAChatsOfferReadAfterARequestIsAskedAbout() async throws {
        await harness.start()
        await ask()
        await harness.launch(.claude)
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        harness.chatgpt.emit(.finished(text: "Paris. Want a shorter version?"))
        await harness.hear("ChatGPT says: Paris. Want a shorter version?")
        let item = harness.say("Yes.")
        await harness.decide(for: .claude, basis: .state) { input in
            .approve(requestID: input.agents.first { $0.agent == .claude }?.pending?.requestID ?? "", always: false)
        }

        await harness.speaking("For Claude Code or ChatGPT? Say the name with your answer.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .agentUnclear)))
        XCTAssertTrue(harness.entries.contains(.decided(itemID: item, agent: nil,
                                                        intent: .approve(requestID: "p1", always: false))))
        XCTAssertEqual(harness.claude.permissions, [])
    }

    /// With two requests heard, words that fit one request alone ("no, use pnpm" for an npm
    /// command) go to it without a name (rule 2).
    func testAConsentWhoseWordsFitOneHeardRequestIsActedOn() async throws {
        await harness.start()
        await twoHeardRequests()
        harness.say("No, use pnpm instead.")
        await harness.decide(for: .claude, basis: .fit) { input in
            .deny(requestID: input.agents.first { $0.agent == .claude }?.pending?.requestID ?? "",
                  feedback: "use pnpm instead")
        }
        await harness.hear("Denied, and I told Claude Code why.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .deny(feedback: "use pnpm instead"))])
    }

    /// With one request heard, a bare yes needs no name: it can only be for that request, with
    /// a chat at work beside it.
    func testAYesPlacedByTheStateWithOneHeardRequestIsActedOn() async throws {
        await harness.start()
        await ask()
        await harness.launch(.claude)
        harness.claude.emit(.permission(.bash("p1", "npm install")))
        await harness.hear("Claude Code wants to run npm install. Allow it?")
        harness.say("Yes.")
        await harness.decide(for: .claude, basis: .state) { input in
            .approve(requestID: input.agents.first { $0.agent == .claude }?.pending?.requestID ?? "", always: false)
        }
        await harness.hear("Allowed for Claude Code.")
        XCTAssertEqual(harness.claude.permissions, [.init(id: "p1", decision: .allow(always: false))])
    }

    /// A chat agent is off unless `--desktop-chat` names it: it is not turned on, not missing.
    func testAChatThatIsNotTurnedOnIsSaidSo() async throws {
        harness = try KernelHarness()
        await harness.start()
        let item = harness.say("ChatGPT, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("ChatGPT isn't turned on in TapQ.")
        XCTAssertEqual(Array(harness.entries.prefix(3)), [
            .heard(itemID: item, agent: nil, text: "ChatGPT, what's the capital of France?"),
            .decided(itemID: item, agent: .chatgpt, intent: .instruct(text: "what's the capital of France?")),
            .refused(itemID: item, reason: .notInstalled),
        ])
        harness.say("Claude chat, hello")
        await harness.decide(.instruct(text: "hello"))
        await harness.hear("Claude chat isn't turned on in TapQ.")
        XCTAssertEqual(harness.chatgpt.starts, [])
        XCTAssertEqual(harness.claudeChat.starts, [])
    }
}
