import Foundation
import XCTest
@testable import TapQKernel

/// Claude chat and ChatGPT over the vendors' APIs (`--api-chat`, 2026-10-13):
/// the same two agents and names as in the apps, but the chats are TapQ's own, kept in the
/// folder. So, unlike a chat in the user's app, one resumes after a relaunch, and the folder's
/// chats are listed and switched as a coding agent's conversations are, and a first question
/// carries on the one the picker finds (2026-10-24). Like it, one cannot be steered while it
/// answers and never asks a permission.
@MainActor
final class KernelAPIChatTests: XCTestCase {
    private var harness: KernelHarness!

    private static let everyAgent = Set(AgentID.mac)
    private static let overTheAPI: [AgentID: ChatBackend] = [.claudeChat: .api, .chatgpt: .api]

    override func setUp() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, chatBackends: Self.overTheAPI)
    }

    override func tearDown() async throws {
        await harness.finish()
        harness = nil
    }

    /// Drives ChatGPT from none to answering `question` in a new chat, then to idle with `answer`.
    private func answered(_ question: String = "what's the capital of France?", _ answer: String = "Paris.") async {
        harness.say("ChatGPT, \(question)")
        await harness.decide(.instruct(text: question))
        await harness.offer(.chatgpt, .success([]))
        await harness.hear("Okay.")
        harness.chatgpt.emit(.finished(text: answer))
        await harness.hear("ChatGPT says: \(answer)")
    }

    // MARK: - Launch and resume

    /// Started at once (2026-10-24): with no chat to carry on, a new one, and nothing is asked.
    func testTheFirstQuestionStartsANewChatThatIsKept() async throws {
        await harness.start()
        harness.say("ChatGPT, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.offer(.chatgpt, .success([]))
        await harness.hear("Okay.")
        XCTAssertTrue(harness.entries.contains(.launching(agent: .chatgpt, target: .new,
                                                          held: "what's the capital of France?")),
                      "\(harness.entries)")
        XCTAssertFalse(harness.entries.contains { if case .launchAsked = $0 { true } else { false } }, "nothing is asked")
        XCTAssertEqual(harness.picker.model.inputs, [], "nothing to pick from")
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?"])
        XCTAssertEqual(try harness.sessions.sessionID(for: .chatgpt), "session-new", "the chat is kept to resume")
        XCTAssertTrue(harness.entries.contains(.started(agent: .chatgpt, sessionID: "session-new", chats: .api)))
        harness.chatgpt.emit(.finished(text: "Paris."))
        await harness.hear("ChatGPT says: Paris.")
        XCTAssertEqual(harness.phase(.chatgpt), .idle)
    }

    /// A follow-up goes into the same chat with no prompt, as a coding agent's next task does.
    func testAFollowUpGoesIntoTheSameChat() async throws {
        await harness.start()
        await answered()
        harness.say("ChatGPT, and of Spain?")
        await harness.decide(.instruct(text: "and of Spain?"))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.chatgpt.starts, [.fresh], "no new start")
        XCTAssertEqual(harness.chatgpt.sent, ["what's the capital of France?", "and of Spain?"])
        harness.chatgpt.emit(.finished(text: "Madrid."))
        await harness.hear("ChatGPT says: Madrid.")
    }

    /// An answer is not steered over the API either: the words are not sent, and are said again.
    func testWordsWhileItAnswersAreRefused() async throws {
        await harness.start()
        harness.say("ChatGPT, write a long story")
        await harness.decide(.instruct(text: "write a long story"))
        await harness.offer(.chatgpt, .success([]))
        await harness.hear("Okay.")
        let item = harness.say("ChatGPT, make it about a lighthouse")
        await harness.decide(.instruct(text: "make it about a lighthouse"))
        await harness.hear("ChatGPT is still answering. Say it again when it's done, or say: ChatGPT, stop.")
        XCTAssertTrue(harness.entries.contains(.refused(itemID: item, reason: .busy)))
        XCTAssertEqual(harness.chatgpt.sent, ["write a long story"])
    }

    /// After a relaunch the folder's chat the words carry on is resumed at once, and the user
    /// hears which (2026-10-24).
    func testARelaunchContinuesTheFoldersChat() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, sessionIDs: [.chatgpt: "chat-1", .claudeChat: "chat-2"],
                                    chatBackends: Self.overTheAPI)
        await harness.start()
        harness.say("ChatGPT, what did I ask you?")
        await harness.decide(.instruct(text: "what did I ask you?"))
        await harness.offer(.chatgpt, .success([.made("chat-1", "what's the capital of France?")]))
        let asked = await harness.pick(.success(ConversationPick(number: 1, name: "the capital of France")))
        XCTAssertEqual(asked, PickInput(instruction: "what did I ask you?",
                                        candidates: [ConversationCandidate(number: 1, title: "what's the capital of France?",
                                                                           age: "today", last: true)],
                                        agent: .chatgpt))
        await harness.hear("Okay, ChatGPT continues the capital of France.")
        XCTAssertEqual(harness.chatgpt.starts, [.resume(id: "chat-1")])
        XCTAssertEqual(harness.chatgpt.sent, ["what did I ask you?"])

        harness.say("Claude chat, and you?")
        await harness.decide(.instruct(text: "and you?"))
        await harness.offer(.claudeChat, .success([.made("chat-2", "say hello")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, Claude chat continues its last chat.")
        XCTAssertEqual(harness.claudeChat.starts, [.resume(id: "chat-2")])
        XCTAssertEqual(harness.claude.starts, [], "Claude chat is not Claude Code")
    }

    func testClaudeChatStartsANewClaudeChat() async throws {
        await harness.start()
        harness.say("Claude chat, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.offer(.claudeChat, .success([]))
        await harness.hear("Okay.")
        XCTAssertEqual(harness.claudeChat.starts, [.fresh])
        XCTAssertEqual(try harness.sessions.sessionID(for: .claudeChat), "session-new")
    }

    /// A chat whose file is gone fails its start, and the way out is said once.
    func testAChatThatIsGoneSaysHowToStartOver() async throws {
        struct Gone: Error, CustomStringConvertible { let description = "that chat is gone" }
        harness = try KernelHarness(installed: Self.everyAgent, sessionIDs: [.chatgpt: "chat-1"],
                                    chatBackends: Self.overTheAPI)
        harness.chatgpt.startError = Gone()
        await harness.start()
        harness.say("ChatGPT, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.chatgpt, .success([.made("chat-1", "plan a trip")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "the trip plan")))
        await harness.hear("ChatGPT couldn't start: that chat is gone. If that chat is gone, say: ChatGPT, new conversation.")
        XCTAssertEqual(harness.phase(.chatgpt), AgentPhase.none)
    }

    // MARK: - New, list and switch

    func testANewConversationStartsANewChat() async throws {
        await harness.start()
        await answered()
        harness.say("ChatGPT, new chat")
        await harness.decide(.newConversation(text: nil))
        await harness.hear("ChatGPT is in a new chat.")
        XCTAssertEqual(harness.chatgpts.count, 2, "the old chat's delegate is gone first")
        XCTAssertTrue(harness.chatgpts[0].stopped)
        XCTAssertEqual(harness.chatgpt.starts, [.fresh])

        harness.say("ChatGPT, read it all.")
        await harness.decide(.readAll)
        await harness.hear("There's no reply from ChatGPT to read.")
    }

    /// The folder's chats are read from TapQ's own store, newest first, and one read can be
    /// gone back to behind a yes: a switch is still asked (2026-10-24).
    func testTheFoldersChatsAreListedAndOneIsGoneBackTo() async throws {
        await harness.start()
        await answered()
        harness.say("ChatGPT, what chats do you have?")
        await harness.decide(.listConversations)
        await harness.list(.chatgpt, .success([.made("session-new", "what's the capital of France?"),
                                               .made("old-1", "plan a trip to Lisbon", daysAgo: 1)]))
        await harness.hear("ChatGPT has 2 chats in workspace. "
            + "1, today, the current one: what's the capital of France? 2, yesterday: plan a trip to Lisbon.")
        XCTAssertEqual(harness.chatCatalog.model.inputs, [KernelHarness.workspace, KernelHarness.workspace],
                       "read for the first question, and for the list")

        harness.say("ChatGPT, go back to the Lisbon one")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("Switch ChatGPT to chat 2: plan a trip to Lisbon?")
        harness.say("ChatGPT, yes")
        await harness.approve()
        await harness.hear("ChatGPT is in chat 2 now.")
        XCTAssertEqual(harness.chatgpt.starts, [.resume(id: "old-1")])
        XCTAssertEqual(try harness.sessions.sessionID(for: .chatgpt), "old-1")

        harness.say("ChatGPT, go to chat 2")
        await harness.decide(.switchConversation(number: 2, text: nil))
        await harness.hear("ChatGPT is already in chat 2.")

        harness.say("ChatGPT, more")
        await harness.decide(.moreConversations)
        await harness.hear("That's all of ChatGPT's chats.")
    }

    func testNoChatsAndAFailedListingAreSaid() async throws {
        await harness.start()
        harness.say("Claude chat, list my chats")
        await harness.decide(.listConversations)
        await harness.list(.claudeChat, .success([]))
        await harness.hear("Claude chat has no chats in workspace yet.")

        harness.say("ChatGPT, list my chats")
        await harness.decide(.listConversations)
        await harness.list(.chatgpt, .failure(.callBound("the chats folder is unreadable")))
        await harness.hear("I couldn't list ChatGPT's chats: the chats folder is unreadable.")

        harness.say("ChatGPT, chat 4")
        await harness.decide(.switchConversation(number: 4, text: nil))
        await harness.hear("Ask for ChatGPT's chats first, then choose one by its number.")
    }

    // MARK: - Missing key and restart

    /// Turned on over the API without its vendor's key: the user hears which key.
    func testAChatWithoutItsKeySaysWhichKey() async throws {
        harness = try KernelHarness(installed: [.claude, .codex, .chatgpt], chatBackends: Self.overTheAPI,
                                    missingKeys: [.claudeChat])
        await harness.start()
        harness.say("Claude chat, what's the capital of France?")
        await harness.decide(.instruct(text: "what's the capital of France?"))
        await harness.hear("Claude chat needs an Anthropic API key in TapQ.")
        XCTAssertEqual(harness.claudeChat.starts, [])
    }

    /// A restart mid-answer: the request died with the process; nothing is resent, and the
    /// folder's chat is offered again.
    func testARestartMidAnswerIsToldAndTheChatContinues() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, seed: [
            .launchAsked(agent: .chatgpt, requestID: "launch-1", folder: "workspace", resume: false,
                         held: "what's the capital of France?"),
            .resolved(agent: .chatgpt, requestID: "launch-1", decision: .launch(yes: true)),
            .started(agent: .chatgpt, sessionID: "chat-1"),
            .sent(agent: .chatgpt, text: "what's the capital of France?"),
        ], sessionIDs: [.chatgpt: "chat-1"], chatBackends: Self.overTheAPI)
        await harness.start()
        let sentence = "TapQ restarted. ChatGPT's unfinished answer stopped, and nothing was resent."
        await harness.hear(sentence)
        XCTAssertEqual(harness.entries, [.lost(agent: .chatgpt, .turn), .spoke(id: SpeechID(raw: 1), text: sentence)])

        harness.say("ChatGPT, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.chatgpt, .success([.made("chat-1", "what's the capital of France?")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, ChatGPT continues its last chat.")
        XCTAssertEqual(harness.chatgpt.starts, [.resume(id: "chat-1")])
    }

    /// A lost turn is told as it was sent, whatever this run's route: a turn sent in the app is
    /// left there, one sent over the API stopped with TapQ (review 2026-10-13).
    func testARestartTellsTheLostTurnAsItWasSent() async throws {
        let inTheApp: [JournalEntry] = [
            .started(agent: .chatgpt, sessionID: "app-chat", chats: .app),
            .sent(agent: .chatgpt, text: "what's the capital of France?"),
        ]
        harness = try KernelHarness(installed: Self.everyAgent, seed: inTheApp, chatBackends: Self.overTheAPI)
        await harness.start()
        await harness.hear("TapQ restarted. ChatGPT's last answer is left in the app, unread, and nothing was resent.")
        await harness.finish()

        let overTheAPI: [JournalEntry] = [
            .started(agent: .claudeChat, sessionID: "chat-1", chats: .api),
            .sent(agent: .claudeChat, text: "write a story"),
        ]
        harness = try KernelHarness(installed: Self.everyAgent, seed: overTheAPI)
        await harness.start()
        await harness.hear("TapQ restarted. Claude chat's unfinished answer stopped, and nothing was resent.")
    }

    /// A chat over the API proved its resume when it loaded the chat: a failure of its first turn
    /// after a relaunch is told with its own reason only, never "if that chat is gone".
    func testAFirstTurnFailureAfterAResumeIsItsReasonOnly() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, sessionIDs: [.chatgpt: "chat-1"],
                                    chatBackends: Self.overTheAPI)
        await harness.start()
        harness.say("ChatGPT, carry on")
        await harness.decide(.instruct(text: "carry on"))
        await harness.offer(.chatgpt, .success([.made("chat-1", "what's the capital of France?")]))
        await harness.pick(.success(ConversationPick(number: 1, name: "")))
        await harness.hear("Okay, ChatGPT continues its last chat.")
        harness.chatgpt.emit(.failed(reason: "OpenAI's API is overloaded right now"))
        await harness.hear("ChatGPT stopped: OpenAI's API is overloaded right now.")
    }

    /// The chat's last reply survives a relaunch in the same chat, so "read it all" still reads it.
    func testARelaunchKeepsTheLastReplyOfTheSameChat() async throws {
        harness = try KernelHarness(installed: Self.everyAgent, seed: [
            .started(agent: .chatgpt, sessionID: "chat-1"),
            .sent(agent: .chatgpt, text: "what's the capital of France?"),
            .finished(agent: .chatgpt, text: "Paris."),
            .spoke(id: SpeechID(raw: 1), text: "ChatGPT says: Paris."),
            .started(agent: .chatgpt, sessionID: "chat-1"),
        ], sessionIDs: [.chatgpt: "chat-1"], chatBackends: Self.overTheAPI)
        await harness.start()
        harness.say("ChatGPT, read it all")
        let input = await harness.decide { _ in .readAll }
        XCTAssertEqual(input?.context(.chatgpt)?.hasHeldReply, true)
        await harness.hear("ChatGPT said: Paris.")
    }

    /// Losing track of a chat over the API stops it, as a coding agent's process is stopped:
    /// there is no app to let go of.
    func testLosingTrackOfAnAPIChatStopsIt() async throws {
        await harness.start()
        harness.say("ChatGPT, write a long story")
        await harness.decide(.instruct(text: "write a long story"))
        await harness.offer(.chatgpt, .success([]))
        await harness.hear("Okay.")
        harness.chatgpt.finishEvents()
        await harness.hear("TapQ lost track of ChatGPT, so it stopped it. Its unfinished answer stopped, "
            + "and nothing was resent. Talk to ChatGPT to start it again.")
    }
}
