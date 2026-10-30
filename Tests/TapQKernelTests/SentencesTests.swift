import Foundation
import XCTest
@testable import TapQKernel

final class SentencesTests: XCTestCase {
    private let question = Question(key: "db", header: nil, text: "Which database?",
                                    options: [QuestionOption(label: "Postgres"),
                                              QuestionOption(label: "SQLite"),
                                              QuestionOption(label: "DuckDB")],
                                    multiSelect: false, allowsFreeText: true)

    /// A first instruction starts the agent at once, and the user hears where it went
    /// (maintainer, 2026-10-24).
    func testStartSentences() {
        XCTAssertEqual(Sentences.continuing(.claude, name: "the login bug fix.", last: false),
                       "Okay, Claude Code continues the login bug fix.")
        XCTAssertEqual(Sentences.continuing(.codex, name: nil, last: true), "Okay, Codex continues its last conversation.")
        XCTAssertEqual(Sentences.continuing(.codex, name: nil, last: false),
                       "Okay, Codex continues an earlier conversation.")
        XCTAssertEqual(Sentences.startingNew(.claude), "Okay, Claude Code starts a new conversation.")
        XCTAssertEqual(Sentences.startingNew(.claude, lastOpenElsewhere: true),
                       "Okay, Claude Code starts a new conversation. Its last one is open elsewhere.")
        XCTAssertEqual(Sentences.pickFailed(.codex, continued: true),
                       "I couldn't tell which conversation you meant, so Codex continues its last one.")
        XCTAssertEqual(Sentences.pickFailed(.claude, continued: false),
                       "I couldn't tell which conversation you meant, so Claude Code starts a new one.")
        XCTAssertEqual(Sentences.unreadConversations(.codex),
                       "I couldn't read Codex's conversations, so it starts a new one.")
    }

    func testPrompts() {
        XCTAssertEqual(Sentences.permission(.claude, .bash("p", "rm -rf ./build && npm run build",
                                                           reason: "deletes files")),
                       "Claude Code wants to run rm -rf ./build && npm run build. It says: deletes files. Allow it?")
        XCTAssertEqual(Sentences.permission(.codex, .bash("p", "curl --head https://example.com",
                                                          reason: "May I rerun curl outside the sandbox?")),
                       "Codex wants to run curl --head https://example.com. It says: May I rerun curl outside "
                        + "the sandbox? Allow it?")
        XCTAssertEqual(Sentences.permission(.codex, PermissionRequest(
            id: "p", tool: "fileChange", inputJSON: "{}", paths: ["a.swift", "b.swift"])),
                       "Codex wants to edit a.swift and b.swift. Allow it?")
        XCTAssertEqual(Sentences.permission(.claude, PermissionRequest(
            id: "p", tool: "WebFetch", inputJSON: #"{"prompt":"read","url":"https://example.com/a"}"#)),
                       "Claude Code wants to fetch https://example.com/a. Allow it?")
        XCTAssertEqual(Sentences.permission(.claude, PermissionRequest(
            id: "p", tool: "mcp__gmail__send_message", inputJSON: "{}", title: "Send an email")),
                       "Claude Code wants to use mcp__gmail__send_message: Send an email. Allow it?")
        XCTAssertEqual(Sentences.permission(.claude, PermissionRequest(
            id: "p", tool: "mcp__gmail__send_message",
            inputJSON: #"{"to":"bob@example.com","cc":["x"],"meta":{"a":"b, c"},"body":"Hi \"Bob\""}"#)),
                       #"Claude Code wants to use mcp__gmail__send_message: to bob@example.com, cc x, meta {"a":"b, c"}, body Hi "Bob". Allow it?"#)
        XCTAssertEqual(Sentences.question(.codex, QuestionRequest(id: "q", questions: [question])),
                       "Codex asks: Which database? Options: Postgres, SQLite, or DuckDB.")
        let multi = Question(key: "k", header: nil, text: "Which checks?",
                             options: [QuestionOption(label: "lint"), QuestionOption(label: "test")],
                             multiSelect: true, allowsFreeText: true)
        XCTAssertEqual(Sentences.question(.claude, QuestionRequest(id: "q", questions: [multi, question])),
                       "Claude Code has 2 questions. One: Which checks? Pick any of: lint or test. "
                           + "Two: Which database? Options: Postgres, SQLite, or DuckDB.")
    }

    func testAcksAndResults() {
        XCTAssertEqual(Sentences.reask, "I'll ask again.")
        XCTAssertEqual(Sentences.missed, "Sorry, I missed that. Please say it again.")
        XCTAssertEqual(Sentences.okay, "Okay.")
        XCTAssertEqual(Sentences.steered, "Okay, I'll add that.")
        // Consent acks name the agent, so a yes taken for the wrong one is heard (2026-10-12).
        XCTAssertEqual(Sentences.answered(.codex), "Codex has your answer.")
        XCTAssertEqual(Sentences.allowed(.claude, always: false), "Allowed for Claude Code.")
        XCTAssertEqual(Sentences.allowed(.claude, always: true),
                       "Allowed for Claude Code, and it won't ask again for that.")
        XCTAssertEqual(Sentences.allowed(.codex, always: false, askedAlways: true),
                       "Allowed for Codex, but it will still ask next time.")
        XCTAssertEqual(Sentences.denied(.claude, feedback: false), "Denied for Claude Code.")
        XCTAssertEqual(Sentences.whichAgent([.claude, .codex]),
                       "For Claude Code or Codex? Say the name with your answer.")
        XCTAssertEqual(Sentences.denied(.claude, feedback: true), "Denied, and I told Claude Code why.")
        XCTAssertEqual(Sentences.notInstalled(.codex), "Codex isn't installed on this Mac.")
        XCTAssertEqual(Sentences.notInstalled(.codex, notOnPlan: true), "Codex isn't turned on in TapQ.")
        XCTAssertEqual(Sentences.notInstalled(.chatgpt, appMissing: true, notOnPlan: true),
                       "ChatGPT isn't turned on in TapQ.", "--agents is what the user can change first")
        XCTAssertEqual(Sentences.unclear(.claude), "I didn't catch what Claude Code should do. Say it again.")
        XCTAssertEqual(Sentences.stayingOff(.claude), "Okay, Claude Code stays off.")
        XCTAssertEqual(Sentences.stopping(.claude), "Stopping Claude Code.")
        XCTAssertEqual(Sentences.notWorking(.claude), "Claude Code isn't working on anything.")
        XCTAssertEqual(Sentences.unreadable(.codex), "I couldn't read Codex's request reliably, so I said no.")
        XCTAssertEqual(Sentences.readAll(.claude, held: "All of it."), "Claude Code said: All of it.")
        XCTAssertEqual(Sentences.readAll(.claude, held: nil), "There's no reply from Claude Code to read.")
        XCTAssertEqual(Sentences.withdrew(.claude), "Claude Code withdrew that request.")
        XCTAssertEqual(Sentences.finished(.claude, "Tests pass."), "Claude Code says: Tests pass.")
        XCTAssertEqual(Sentences.finished(.claude, " "), "Claude Code is done.")
        XCTAssertEqual(Sentences.summary(.claude, "Tests pass."), "Claude Code says, in short: Tests pass.")
        XCTAssertEqual(Sentences.summaryFailed(.codex),
                       "Codex is done, but I couldn't summarize the reply. Say: Codex, read it all.")
        XCTAssertEqual(Sentences.stopped(.claude), "Claude Code stopped.")
        XCTAssertEqual(Sentences.failed(.claude, reason: "Usage limit reached"),
                       "Claude Code stopped: Usage limit reached.")
        XCTAssertEqual(Sentences.failed(.codex, reason: "You've hit your usage limit. "),
                       "Codex stopped: You've hit your usage limit.")
        XCTAssertEqual(Sentences.failed(.claude, reason: "Is the key revoked?"),
                       "Claude Code stopped: Is the key revoked?")
        XCTAssertEqual(Sentences.nothingWaiting, "Nothing is waiting on you.")
        XCTAssertEqual(Sentences.resumed(.claude, openRequests: 0, unheardReply: false),
                       "TapQ restarted. Claude Code's unfinished task stopped, and nothing was resent.")
        XCTAssertEqual(Sentences.resumed(.claude, openRequests: 2, unheardReply: false),
                       "TapQ restarted. Claude Code's unfinished task and 2 open requests stopped, "
                           + "and nothing was resent.")
        XCTAssertEqual(Sentences.resumed(.codex, openRequests: 1, unheardReply: true),
                       "TapQ restarted. Codex's unfinished task and 1 open request stopped, "
                           + "and nothing was resent. Codex has a reply; say: Codex, read it all.")
        XCTAssertEqual(Sentences.resumed(.claude, openRequests: nil, unheardReply: true),
                       "Claude Code has a reply; say: Claude Code, read it all.")
        XCTAssertNil(Sentences.resumed(.claude, openRequests: nil, unheardReply: false))
        XCTAssertEqual(Sentences.resumed(.codex, openRequests: 0, unheardReply: false, taskDelivered: true),
                       "TapQ restarted. Codex's unfinished task stopped, and nothing was resent, "
                           + "but Codex may take the task up again when it resumes.")
        XCTAssertEqual(Sentences.resumed(.claude, openRequests: 0, unheardReply: false, taskDelivered: true),
                       "TapQ restarted. Claude Code's unfinished task stopped, and nothing was resent.",
                       "Claude Code did not take a lost task up again (0 of 3)")
    }

    /// V2 P1-2: with a title, every input field is still spoken, so a yes never sends to a
    /// recipient the user did not hear.
    func testConsentSpeaksTheTitleAndEveryField() {
        XCTAssertEqual(Sentences.permission(.claude, PermissionRequest(
            id: "p", tool: "mcp__gmail__send_message",
            inputJSON: #"{"to":["bob@example.com","eve@example.com"],"subject":"Lunch","body":"Noon?"}"#,
            title: "Send message")),
                       "Claude Code wants to use mcp__gmail__send_message: Send message, "
                           + "to bob@example.com and eve@example.com, subject Lunch, body Noon?. Allow it?")
        XCTAssertEqual(Sentences.permission(.codex, PermissionRequest(
            id: "p", tool: "mcp__drive__share",
            inputJSON: #"{ "file": "plan.pdf", "notify": false, "days": 7, "who": [{"email":"x@y.z"}], "tags": [], "note": null }"#,
            title: "Share a file")),
                       #"Codex wants to use mcp__drive__share: Share a file, file plan.pdf, notify false, days 7, "#
                           + #"who [{"email":"x@y.z"}], tags [], note null. Allow it?"#)
    }

    /// The progress summarizer's words, with the name first and what the agent waits on.
    func testProgress() {
        var state = AgentState(phase: .working)
        XCTAssertEqual(Sentences.progress(.claude, "Claude Code is running the tests.", state),
                       "Claude Code is running the tests.")
        XCTAssertEqual(Sentences.progress(.codex, "It is editing the README", state),
                       "Codex: It is editing the README.")
        state.pending = [PendingRequest(id: "p", kind: .permission(.bash("p", "ls")),
                                        prompt: "Claude Code wants to list the folder. Allow it?")]
        XCTAssertEqual(Sentences.progress(.claude, "Claude Code is checking the folder", state),
                       "Claude Code is checking the folder. It's waiting on you: Claude Code wants to list the folder. Allow it?")
        state.pending[0].describing = true
        XCTAssertEqual(Sentences.progress(.claude, "Claude Code is checking the folder.", state),
                       "Claude Code is checking the folder.")
        XCTAssertNil(Sentences.progress(.claude, "```\n```", state), "words that read as nothing")
        XCTAssertNil(Sentences.progress(.claude, " \n ", state))
    }

    func testStatus() {
        var state = AgentState(phase: .none)
        XCTAssertEqual(Sentences.status(.claude, state), "Claude Code isn't running.")
        state.phase = .idle
        XCTAssertEqual(Sentences.status(.claude, state), "Claude Code is idle.")
        state.phase = .working
        XCTAssertEqual(Sentences.status(.claude, state), "Claude Code is working.")
        state.progress = "Bash: swift test"
        state.pending = [PendingRequest(id: "p", kind: .permission(.bash("p", "ls")),
                                        prompt: "Claude Code wants to run ls. Allow it?")]
        XCTAssertEqual(Sentences.status(.claude, state),
                       "Claude Code is working. It's waiting on you: Claude Code wants to run ls. Allow it?",
                       "never the tool line, which read shell commands aloud (2026-10-15)")
        state.turn = TurnSoFar(said: ["Running `rm -rf build` now."])
        XCTAssertEqual(Sentences.status(.claude, state),
                       "Claude Code is working. It's waiting on you: Claude Code wants to run ls. Allow it?",
                       "nor the agent's own words, which can hold a command")
        state.pending[0].describing = true
        XCTAssertEqual(Sentences.status(.claude, state), "Claude Code is working.",
                       "a command's prompt is not read before its description")
        state.pending[0].describing = false
        XCTAssertEqual(Sentences.progressFailed(.claude, state),
                       "Claude Code is working, but I couldn't summarize where it is. "
                           + "It's waiting on you: Claude Code wants to run ls. Allow it?",
                       "a failed status summary is told, out loud (2026-10-16)")

        // A switch asked of an agent that runs leaves it running until the yes (2026-10-12).
        var switching = AgentState(phase: .awaitingYes)
        switching.pending = [PendingRequest(id: "l", kind: .launch(Launch(folder: "tapq", target: .new, held: "",
                                                                          running: true)),
                                            prompt: "Start a new Claude Code conversation in tapq?")]
        XCTAssertEqual(Sentences.status(.claude, switching),
                       "Claude Code is idle. It's waiting on you: Start a new Claude Code conversation in tapq?")
        switching.pending = [PendingRequest(id: "l", kind: .launch(Launch(folder: "tapq", held: "lint")),
                                            prompt: "Resume Claude Code in tapq?")]
        XCTAssertEqual(Sentences.status(.claude, switching),
                       "Claude Code isn't running. It's waiting on you: Resume Claude Code in tapq?")
    }

    // MARK: - Conversations (2026-10-12)

    func testConversationPromptsAndAcks() {
        XCTAssertEqual(Sentences.switchConversation(.codex, number: 2, title: "fix the README."),
                       "Switch Codex to conversation 2: fix the README?")
        XCTAssertEqual(Sentences.staying(.codex), "Okay, Codex stays in its conversation.")
        XCTAssertEqual(Sentences.switched(.codex, number: 3), "Codex is in conversation 3 now.")
        XCTAssertEqual(Sentences.switched(.claude, number: nil), "Claude Code is in a new conversation.")
        XCTAssertEqual(Sentences.alreadyIn(.claude, number: 1), "Claude Code is already in conversation 1.")
        XCTAssertEqual(Sentences.busy(.codex), "Codex is working. To switch conversations, first say: Codex, stop.")
        XCTAssertEqual(Sentences.noSuchConversation(.claude, number: 7, listed: true),
                       "I didn't read a conversation 7 for Claude Code.")
        XCTAssertEqual(Sentences.noSuchConversation(.claude, number: 7, listed: false),
                       "Ask for Claude Code's conversations first, then choose one by its number.")
        XCTAssertEqual(Sentences.noConversations(.codex, folder: "tally"), "Codex has no conversations in tally yet.")
        XCTAssertEqual(Sentences.allConversationsRead(.codex), "That's all of Codex's conversations.")
        XCTAssertEqual(Sentences.listFailed(.codex, reason: "it took too long"),
                       "I couldn't list Codex's conversations: it took too long.")
        XCTAssertEqual(Sentences.switchWithdrawn(.claude),
                       "Claude Code started working, so it stays in its conversation.")
        XCTAssertEqual(Sentences.agentFailed(.claude, .startFailed("No conversation found"), openRequests: nil,
                                             taskDelivered: false, resumed: true),
                       "Claude Code couldn't start: No conversation found. "
                           + "If that conversation is gone, say: Claude Code, new conversation.")
    }

    // MARK: - Desktop chat agents (2026-10-13)

    /// Other parts of TapQ match these, word for word.
    func testChatAgentSentences() {
        XCTAssertEqual(Sentences.continuing(.chatgpt, name: "Portugal Capital Question", last: true),
                       "Okay, ChatGPT continues Portugal Capital Question.")
        XCTAssertEqual(Sentences.startingNew(.claudeChat), "Okay, Claude chat starts a new chat.")
        XCTAssertEqual(Sentences.switched(.claudeChat, number: nil), "Claude chat is in a new chat.")
        XCTAssertEqual(Sentences.switched(.chatgpt, number: nil), "ChatGPT is in a new chat.")
        XCTAssertEqual(Sentences.staying(.chatgpt), "Okay, ChatGPT stays in its chat.")
        XCTAssertEqual(Sentences.stillAnswering(.chatgpt),
                       "ChatGPT is still answering. Say it again when it's done, or say: ChatGPT, stop.")
        XCTAssertEqual(Sentences.stillAnswering(.claudeChat),
                       "Claude chat is still answering. Say it again when it's done, or say: Claude chat, stop.")
        XCTAssertEqual(Sentences.cannotListChats(.chatgpt), "TapQ can't list ChatGPT's chats yet.")
        XCTAssertEqual(Sentences.cannotListChats(.claudeChat), "TapQ can't list Claude chat's chats yet.")
        XCTAssertEqual(Sentences.notInstalled(.chatgpt), "ChatGPT isn't turned on in TapQ.")
        XCTAssertEqual(Sentences.notInstalled(.claudeChat), "Claude chat isn't turned on in TapQ.")
        // Turned on, and its app is not on this Mac (review 2026-10-13).
        XCTAssertEqual(Sentences.notInstalled(.claudeChat, appMissing: true), "The Claude app isn't installed on this Mac.")
        XCTAssertEqual(Sentences.notInstalled(.chatgpt, appMissing: true), "The ChatGPT app isn't installed on this Mac.")
        // A chat's app goes on answering: its answer is left, never said to be stopped.
        XCTAssertEqual(Sentences.resumed(.chatgpt, openRequests: 0, unheardReply: false),
                       "TapQ restarted. ChatGPT's last answer is left in the app, unread, and nothing was resent.")
        XCTAssertEqual(Sentences.agentFailed(.chatgpt, .lostTrack, openRequests: 0, taskDelivered: true),
                       "TapQ lost track of ChatGPT, so it let go of the app. Its last answer is left in the app, "
                           + "unread, and nothing was resent. Talk to ChatGPT to start it again.")
        XCTAssertEqual(Sentences.notInstalled(.claude), "Claude Code isn't installed on this Mac.")
        XCTAssertEqual(Sentences.stayingOff(.chatgpt), "Okay, ChatGPT stays off.")
    }

    /// Over the API the chat is TapQ's own, kept in the folder: started, continued, listed and
    /// switched, each as a chat (2026-10-13).
    func testAPIChatSentences() {
        XCTAssertEqual(Sentences.continuing(.chatgpt, name: nil, last: true), "Okay, ChatGPT continues its last chat.")
        XCTAssertEqual(Sentences.pickFailed(.claudeChat, continued: false),
                       "I couldn't tell which chat you meant, so Claude chat starts a new one.")
        XCTAssertEqual(Sentences.switchConversation(.chatgpt, number: 2, title: "plan a trip."),
                       "Switch ChatGPT to chat 2: plan a trip?")
        XCTAssertEqual(Sentences.switched(.chatgpt, number: 2), "ChatGPT is in chat 2 now.")
        XCTAssertEqual(Sentences.alreadyIn(.claudeChat, number: 1), "Claude chat is already in chat 1.")
        XCTAssertEqual(Sentences.noConversations(.chatgpt, folder: "tally"), "ChatGPT has no chats in tally yet.")
        XCTAssertEqual(Sentences.allConversationsRead(.chatgpt), "That's all of ChatGPT's chats.")
        XCTAssertEqual(Sentences.listFailed(.chatgpt, reason: "unreadable"), "I couldn't list ChatGPT's chats: unreadable.")
        XCTAssertEqual(Sentences.noSuchConversation(.chatgpt, number: 3, listed: true), "I didn't read a chat 3 for ChatGPT.")
        XCTAssertEqual(Sentences.conversations(.chatgpt, folder: "tally",
                                               read: [ConversationChoice(number: 1, title: "capitals", age: "today",
                                                                         current: true)],
                                               total: 1, left: 0),
                       "ChatGPT has 1 chat in tally. 1, today, the current one: capitals.")
        XCTAssertEqual(Sentences.notInstalled(.claudeChat, keyMissing: true), "Claude chat needs an Anthropic API key in TapQ.")
        XCTAssertEqual(Sentences.notInstalled(.chatgpt, keyMissing: true), "ChatGPT needs an OpenAI API key in TapQ.")
        XCTAssertEqual(Sentences.resumed(.chatgpt, openRequests: 0, unheardReply: false, chats: .api),
                       "TapQ restarted. ChatGPT's unfinished answer stopped, and nothing was resent.")
        XCTAssertEqual(Sentences.agentFailed(.chatgpt, .startFailed("that chat is gone"), openRequests: nil,
                                             taskDelivered: false, resumed: true, chats: .api),
                       "ChatGPT couldn't start: that chat is gone. If that chat is gone, say: ChatGPT, new conversation.")
        XCTAssertEqual(Sentences.agentFailed(.chatgpt, .lostTrack, openRequests: 0, taskDelivered: true, chats: .api),
                       "TapQ lost track of ChatGPT, so it stopped it. Its unfinished answer stopped, and nothing was "
                           + "resent. Talk to ChatGPT to start it again.")
    }

    /// The question names the agents a yes could be for, however many there are.
    func testWhichAgentNamesTheCandidates() {
        XCTAssertEqual(Sentences.whichAgent([.claude, .chatgpt]),
                       "For Claude Code or ChatGPT? Say the name with your answer.")
        XCTAssertEqual(Sentences.whichAgent([.claude, .codex, .claudeChat]),
                       "For Claude Code, Codex, or Claude chat? Say the name with your answer.")
        XCTAssertEqual(Sentences.whichAgent(AgentID.mac),
                       "For Claude Code, Codex, Claude chat, or ChatGPT? Say the name with your answer.")
    }

    func testAListReadingSaysOnlyWhatWasAskedFor() {
        let first = [ConversationChoice(number: 1, title: "build milestone one", age: "today", current: true),
                     ConversationChoice(number: 2, title: "fix the README?", age: "yesterday", current: false)]
        XCTAssertEqual(Sentences.conversations(.claude, folder: "tally", read: first, total: 2, left: 0),
                       "Claude Code has 2 conversations in tally. "
                           + "1, today, the current one: build milestone one. 2, yesterday: fix the README?")
        XCTAssertEqual(Sentences.conversations(.claude, folder: "tally", read: Array(first.prefix(1)), total: 1, left: 0),
                       "Claude Code has 1 conversation in tally. 1, today, the current one: build milestone one.")
        XCTAssertEqual(Sentences.conversations(.claude, folder: "tally", read: first, total: 8, left: 6),
                       "Claude Code has 8 conversations in tally. "
                           + "1, today, the current one: build milestone one. 2, yesterday: fix the README? "
                           + "There are 6 more.")
        let more = [ConversationChoice(number: 6, title: "lint", age: "on Monday", current: false)]
        XCTAssertEqual(Sentences.conversations(.codex, folder: "tally", read: more, total: 7, left: 1),
                       "6, on Monday: lint. There is 1 more.")
        XCTAssertEqual(Sentences.conversations(.codex, folder: "tally", read: more, total: 6, left: 0),
                       "6, on Monday: lint. That's all.")
    }

    /// Open elsewhere (2026-10-12): another process has the conversation, so "isn't running" is
    /// said with where the agent is, and a resume is refused with the way out.
    func testWhatIsOpenElsewhereIsSaid() {
        let app = OpenSession(id: "a", title: "Music medley study.", working: true)
        let terminal = OpenSession(id: "t", title: "**fix** the README", working: false)
        XCTAssertEqual(Sentences.status(.claude, AgentState(phase: .none), openElsewhere: [app]),
                       "Claude Code isn't running in TapQ, but one of its conversations is open elsewhere: "
                           + "Music medley study, working.")
        XCTAssertEqual(Sentences.status(.claude, AgentState(phase: .none), openElsewhere: [app, terminal]),
                       "Claude Code isn't running in TapQ, but 2 of its conversations are open elsewhere: "
                           + "Music medley study, working; fix the README, idle.")
        var asked = AgentState(phase: .awaitingYes)
        asked.pending = [PendingRequest(id: "l", kind: .launch(Launch(folder: "tapq", held: "lint")),
                                        prompt: "Start Claude Code in tapq?")]
        XCTAssertEqual(Sentences.status(.claude, asked, openElsewhere: [terminal]),
                       "Claude Code isn't running in TapQ, but one of its conversations is open elsewhere: "
                           + "fix the README, idle. It's waiting on you: Start Claude Code in tapq?")
        XCTAssertEqual(Sentences.status(.claude, AgentState(phase: .idle), openElsewhere: [app]), "Claude Code is idle.",
                       "a running agent's status is its own")

        let read = [ConversationChoice(number: 1, title: "run the tests", age: "today", current: true),
                    ConversationChoice(number: 2, title: "Music medley study", age: "today", current: false)]
        XCTAssertEqual(Sentences.conversations(.claude, folder: "tally", read: read, total: 2, left: 0, open: [2]),
                       "Claude Code has 2 conversations in tally. "
                           + "1, today, the current one: run the tests. 2, today, open elsewhere: Music medley study.")

        XCTAssertEqual(Sentences.openElsewhere(.claude, number: 2),
                       "I can't continue conversation 2 while it's open elsewhere. "
                           + "Close it there and ask again, or say: Claude Code, new conversation.")
    }

    func testAgesAreSaidAsAPersonSaysThem() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 09:00 on Monday 2026-10-12 in Los Angeles.
        let now = Date(timeIntervalSince1970: 1_791_820_800)
        func ago(_ hours: Double) -> String { Sentences.age(of: now.addingTimeInterval(-hours * 3600), now: now,
                                                            calendar: calendar) }
        XCTAssertEqual(ago(8), "today", "just after midnight")
        XCTAssertEqual(ago(10), "yesterday", "late the evening before")
        XCTAssertEqual(ago(-1), "today", "a clock slightly ahead")
        XCTAssertEqual(ago(3 * 24), "on Friday")
        XCTAssertEqual(ago(6 * 24), "on Tuesday")
        XCTAssertEqual(ago(7 * 24), "on October 5")
        XCTAssertEqual(ago(400 * 24), "on September 7, 2025")
    }
}
