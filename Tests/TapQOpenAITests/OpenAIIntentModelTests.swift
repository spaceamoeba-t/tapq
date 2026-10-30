import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import TapQContracts
import TapQKernel
import TapQOpenAI

final class OpenAIIntentModelTests: XCTestCase {
    /// The intent prompt, byte for byte.
    static let systemPrompt = """
        You turn one spoken message into exactly one action for TapQ, a voice relay between a user
        and four agents: two coding agents, Claude Code (claude) and Codex (codex), and the user's
        own chats, Claude chat (claude-chat, in the Claude app) and ChatGPT (chatgpt). You never
        answer, explain, or do work yourself, even when the message is a question you could answer.

        Input JSON: message (what the user said, whole; from speech recognition, so words and names
        may be misheard: "Claud", "Clod" or "cloud code" can be Claude, "Kodex" or "codecs" can be
        Codex), agents (each with agent; phase: notInstalled|none|awaitingYes|idle|working; pending:
        the request it waits on, with the exact prompt TapQ read and heard: true once the user heard
        all of it, or null; hasHeldReply; lastSaid: the last thing TapQ read for it other than a
        request, such as its reply, or null; conversations: its conversations TapQ read out to the
        user, each with number, title, age and current: true for the one it is in, or []; and
        moreConversations: how many more it has that TapQ did not read), spokenToLast (the agent
        the user's last message was for, or null), heardFromLast (the agent whose words TapQ read
        to the user last, or null).

        Names: a bare "Claude", or a mishearing of it, is Claude Code. "Claude chat" (or "cloud
        chat"), "the Claude app" and "Claude desktop" are claude-chat. "ChatGPT", "chat GPT", "GPT"
        and mishearings such as "chat GBT" are chatgpt. "Chat" or "chats" alone names no agent: it
        is also a word for an agent's conversations ("my chats with Claude" are Claude Code's).

        agent: who the message is for. Decide in this order:
        1. An agent the user speaks to or gives the action to: named at the start or the end
           ("Claude, …", "…, Codex", "yes Claude"), or named as the one to act or asked about ("ask
           Claude to …", "what is Codex doing?"; "Codex, tell Claude to stop" is for Claude). An
           agent the user only talks about does not count ("Claude said the tests pass, Codex
           check them" is for Codex; "Claude's change broke it, fix it" names no one to act).
        2. Otherwise, a yes, no or answer goes to a request the user heard (pending.heard). With
           one heard request, that agent. With two or more, the agent whose request the words fit
           ("option two" fits a question, "use pnpm" fits an npm command, "go ahead and push" fits a
           push); when the words fit two or more of them, as a bare "yes", "no", "sure" or "do it"
           does, agent is null and TapQ asks which. spokenToLast and heardFromLast never choose
           between heard requests: a yes, no or answer is never given to an agent because it was
           spoken to, heard from or read last.
        3. Otherwise, a reply to what an agent said (a question in its lastSaid, its result) or to
           the conversations TapQ read for it is for that agent ("sure, do that" after ChatGPT
           asked "Want a shorter version?" is for ChatGPT, whoever was spoken to last); when
           either could be meant, heardFromLast.
        4. Otherwise, spokenToLast, else claude.
        by: why agent is that agent. "name" when the message names it (rule 1). "fit" when it is a
        yes, no or answer whose words fit that agent's heard request and no other (rule 2).
        "state" for anything else: the only heard request, a reply (rule 3), rule 4, or agent null.

        Actions, for that agent (pending is its pending):
        - approve: the user says yes to pending (a switch or a permission). always=true if they also
          ask not to be asked again, even when pending.canAlwaysAllow is false: TapQ tells them
          when it cannot.
        - deny: the user refuses pending: their words say no to it ("no", "don't", "not now",
          "cancel"). Only a refusal is a no: a task, a question or a follow-up for the agent is
          instruct, even while pending waits. Put any reason or alternative they give in feedback,
          in their words. A yes with a change or condition on what the agent does ("yes but use
          pnpm") is deny with that feedback. Asking not to be asked again is not such a condition.
        - answer: pending is a question. answers holds one array per question, in order: the exact
          option labels chosen, or the user's own words when no option fits.
        - interrupt: the user wants the agent to stop what it is doing now.
        - read_all: the user wants the whole last reply read out.
        - status: the user asks what the agent is doing or whether it is waiting on them.
        - list_conversations: the user asks which conversations (sessions, chats, threads) the
          agent has.
        - more_conversations: the user asks for more of the conversations TapQ read ("more", "what
          else", "the older ones").
        - switch_conversation: the user wants the agent to go to one of the conversations TapQ read
          for it ("the second one", "go back to the README one", "continue conversation 3"):
          conversation is its number. text is what the user wants done there, as instruct takes
          it, or null. When the conversation they want is not among those TapQ read, or none was
          read, choose list_conversations instead.
        - new_conversation: the user wants the agent to start over in a new, empty conversation or
          chat. text is what the user wants done in it, as instruct takes it, or null.
        - instruct: anything else for the agent: a task, a question, a follow-up, or a reply to the
          agent's last message. text is the message verbatim minus filler words and minus the words
          that only say who it is for (its name, "ask Claude", "tell Codex to"; "ChatGPT, what is
          the capital of Portugal?" is "what is the capital of Portugal?"); never shorten or reword
          it otherwise, and never answer it.
        - unclear: the message is empty, cut off, or you cannot tell what is meant.

        conversation is null for every other action. If the agent's pending is null, approve, deny
        and answer are impossible; a bare yes or no is instruct. A chat (claude-chat, chatgpt) never
        asks a permission or a question: its pending can only be a switch to another of its chats,
        so approve and deny answer that, and answer is impossible. When a choice would approve,
        deny or answer and you are unsure, choose unclear.
        """

    /// The intent schema, strict. The agents are the Mac roster (`AgentID.mac`), in order, and null.
    static let schema = """
        {"type":"object","additionalProperties":false,
         "required":["agent","by","action","text","always","feedback","answers","conversation"],
         "properties":{
          "agent":{"type":["string","null"],"enum":["claude","codex","claude-chat","chatgpt",null]},
          "by":{"type":"string","enum":["name","fit","state"]},
          "action":{"type":"string","enum":["instruct","interrupt","approve","deny","answer","read_all","status","unclear","list_conversations","more_conversations","switch_conversation","new_conversation"]},
          "text":{"type":["string","null"]},
          "always":{"type":"boolean"},
          "feedback":{"type":["string","null"]},
          "answers":{"type":["array","null"],"items":{"type":"array","items":{"type":"string"}}},
          "conversation":{"type":["integer","null"]}}}
        """

    private let permission = PendingSummary(
        kind: .permission, requestID: "perm-1",
        prompt: "Claude Code wants to run npm install. Allow?", canAlwaysAllow: false, heard: true)
    private let alwaysablePermission = PendingSummary(
        kind: .permission, requestID: "perm-2",
        prompt: "Claude Code wants to run npm test. Allow?", canAlwaysAllow: true, heard: true)
    private let launch = PendingSummary(
        kind: .launch, requestID: "launch-1",
        prompt: "Start Claude Code in tapq?", canAlwaysAllow: false, heard: true)
    private let databaseQuestion = PendingSummary(
        kind: .question, requestID: "q-1", prompt: "Codex asks: which database? Postgres, SQLite or DuckDB?",
        questions: [Question(key: "db", header: "Database", text: "Which database?",
                             options: [QuestionOption(label: "Postgres"), QuestionOption(label: "SQLite"),
                                       QuestionOption(label: "DuckDB")],
                             multiSelect: false, allowsFreeText: true)],
        canAlwaysAllow: false, heard: true)
    private let checksQuestion = PendingSummary(
        kind: .question, requestID: "q-2", prompt: "Claude Code asks: which checks? lint, test or build?",
        questions: [Question(key: "Which checks?", header: nil, text: "Which checks?",
                             options: [QuestionOption(label: "lint"), QuestionOption(label: "test"),
                                       QuestionOption(label: "build")],
                             multiSelect: true, allowsFreeText: true)],
        canAlwaysAllow: false, heard: true)

    // MARK: - Request

    /// `by` is the model's word on why it chose the agent (2026-10-13); the
    /// kernel's state rule reads it. No agent is placed by the state.
    func testTheBasisComesFromTheModelAndNoAgentIsTheState() async throws {
        let unnamed = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: Self.output("approve", by: "state"))),
                                        model: "gpt-5.6-luna", diagnostics: RecordingSink())
        let decision = try await unnamed.decide(input("yes", .working, permission))
        XCTAssertEqual(decision.agent, .claude)
        XCTAssertEqual(decision.basis, .state)
        XCTAssertTrue(decision.intent.isConsent)

        let named = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: Self.output("approve"))),
                                      model: "gpt-5.6-luna", diagnostics: RecordingSink())
        let namedDecision = try await named.decide(input("Claude, yes", .working, permission))
        XCTAssertEqual(namedDecision.basis, .name)

        let none = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: Self.output("approve", agent: nil))),
                                     model: "gpt-5.6-luna", diagnostics: RecordingSink())
        let noneDecision = try await none.decide(input("yes", .working, permission))
        XCTAssertNil(noneDecision.agent)
        XCTAssertEqual(noneDecision.basis, .state)
    }

    func testRequestIsPinned() async throws {
        let http = FakeHTTP(outputText: Self.output("status"))
        let model = OpenAIIntentModel(client: makeClient(http), model: "gpt-5.6-luna",
                                      diagnostics: RecordingSink())

        _ = try await model.decide(input("Claude, what are you doing?", .working))

        XCTAssertEqual(http.requests.first?.url?.absoluteString,
                       "https://api.openai.invalid/v1/responses")
        var body = try http.sentBody
        XCTAssertEqual(body.removeValue(forKey: "instructions")?.stringValue, Self.systemPrompt)
        let input = try XCTUnwrap(body.removeValue(forKey: "input")?.stringValue)
        XCTAssertEqual(try json(input), try json("""
            {"message":"Claude, what are you doing?",
             "agents":[{"agent":"claude","phase":"working","pending":null,"hasHeldReply":false,"lastSaid":null,
                        "conversations":[],"moreConversations":0},
                       {"agent":"codex","phase":"idle","pending":null,"hasHeldReply":false,"lastSaid":null,
                        "conversations":[],"moreConversations":0},
                       {"agent":"claude-chat","phase":"idle","pending":null,"hasHeldReply":false,"lastSaid":null,
                        "conversations":[],"moreConversations":0},
                       {"agent":"chatgpt","phase":"idle","pending":null,"hasHeldReply":false,"lastSaid":null,
                        "conversations":[],"moreConversations":0}],
             "spokenToLast":null,"heardFromLast":null}
            """))
        XCTAssertEqual(.object(body), try json("""
            {"model":"gpt-5.6-luna","store":false,"reasoning":{"effort":"none"},
             "text":{"verbosity":"low","format":{"type":"json_schema","name":"tapq_intent","strict":true,
                                                 "schema":\(Self.schema)}},
             "max_output_tokens":2048,"prompt_cache_key":"tapq-intent-v7"}
            """))
    }

    func testInputCarriesThePendingHeadWhole() async throws {
        let http = FakeHTTP(outputText: Self.output("answer", answers: [["SQLite"]]))
        let model = OpenAIIntentModel(client: makeClient(http), model: "m", diagnostics: RecordingSink())

        _ = try await model.decide(IntentInput(
            message: "option two",
            agents: [AgentContext(agent: .claude, phase: .idle, pending: nil, hasHeldReply: false,
                                  conversations: [ConversationChoice(number: 1, title: "fix the README", age: "today",
                                                                     current: true)],
                                  moreConversations: 3),
                     AgentContext(agent: .codex, phase: .working, pending: databaseQuestion, hasHeldReply: true,
                                  lastSaid: "Codex says: I need a database.")],
            spokenToLast: .claude, heardFromLast: .codex))

        let input = try XCTUnwrap(try http.sentBody["input"]?.stringValue)
        XCTAssertEqual(try json(input), try json("""
            {"message":"option two","spokenToLast":"claude","heardFromLast":"codex",
             "agents":[{"agent":"claude","phase":"idle","pending":null,"hasHeldReply":false,"lastSaid":null,
                        "conversations":[{"number":1,"title":"fix the README","age":"today","current":true}],
                        "moreConversations":3},
                       {"agent":"codex","phase":"working","hasHeldReply":true,"lastSaid":"Codex says: I need a database.",
                        "conversations":[],"moreConversations":0,
             "pending":{"kind":"question","requestID":"q-1",
                        "prompt":"Codex asks: which database? Postgres, SQLite or DuckDB?",
                        "canAlwaysAllow":false,"heard":true,
                        "questions":[{"key":"db","header":"Database","text":"Which database?",
                                      "options":[{"label":"Postgres"},{"label":"SQLite"},{"label":"DuckDB"}],
                                      "multiSelect":false,"allowsFreeText":true}]}}]}
            """))
    }

    func testModelComesFromTheEnvironmentWithOneDefault() async {
        XCTAssertEqual(OpenAIIntentModel.resolvedModel(environment: [:]), "gpt-5.6-luna")
        XCTAssertEqual(OpenAIIntentModel.resolvedModel(environment: ["TAPQ_INTENT_MODEL": "  "]),
                       "gpt-5.6-luna")
        XCTAssertEqual(OpenAIIntentModel.resolvedModel(environment: ["TAPQ_INTENT_MODEL": "gpt-6-luna"]),
                       "gpt-6-luna")
        XCTAssertEqual(OpenAIIntentModel.resolvedModel(environment: ["TAPQ_SUMMARY_MODEL": "other"]),
                       "gpt-5.6-luna")
    }

    // MARK: - The §5 worked examples

    func testWorkedExamplesDecode() async throws {
        let examples: [(number: Int, input: IntentInput, output: String, expected: Intent)] = [
            (1, input("run the tests", .idle), Self.output("instruct", text: "run the tests"),
             .instruct(text: "run the tests")),
            (2, input("yes", .working, permission), Self.output("approve"),
             .approve(requestID: "perm-1", always: false)),
            (3, input("yes but use pnpm", .working, permission), Self.output("deny", feedback: "use pnpm"),
             .deny(requestID: "perm-1", feedback: "use pnpm")),
            (4, input("stop", .working), Self.output("interrupt"), .interrupt),
            (5, input("also update the README", .working),
             Self.output("instruct", text: "also update the README"),
             .instruct(text: "also update the README")),
            (6, input("also update the README", .working, permission),
             Self.output("instruct", text: "also update the README"),
             .instruct(text: "also update the README")),
            (7, input("read it all", .idle, held: true), Self.output("read_all"), .readAll),
            (8, input("option two", .working, databaseQuestion, agent: .codex),
             Self.output("answer", agent: "codex", answers: [["SQLite"]]),
             .answer(requestID: "q-1", answers: [["SQLite"]])),
            (9, input("yes", .idle, held: true), Self.output("instruct", text: "yes"), .instruct(text: "yes")),
            (10, input("yes, and don't ask me again for that", .working, alwaysablePermission),
             Self.output("approve", always: true), .approve(requestID: "perm-2", always: true)),
            (11, input("no", .awaitingYes, launch), Self.output("deny"),
             .deny(requestID: "launch-1", feedback: nil)),
            (12, input("what are you doing?", .working), Self.output("status"), .status),
            (13, input("um", .idle), Self.output("unclear"), .unclear),
            (14, input("the first and the third", .working, checksQuestion),
             Self.output("answer", answers: [["lint", "build"]]),
             .answer(requestID: "q-2", answers: [["lint", "build"]])),
            (15, input("no, wait, yes", .working, permission), Self.output("unclear"), .unclear),
            (16, input("approve it and then push", .working, permission), Self.output("approve"),
             .approve(requestID: "perm-1", always: false)),
            // Live 2026-10-12, Codex: with no offer, this was decided as a deny.
            (17, input("yes, and don't ask me again for that", .working, permission, agent: .codex),
             Self.output("approve", agent: "codex", always: true), .approve(requestID: "perm-1", always: true)),
        ]
        XCTAssertEqual(examples.map(\.number), Array(1...17))
        for example in examples {
            let sink = RecordingSink()
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: example.output)),
                                          model: "m", diagnostics: sink)
            let decision = try await model.decide(example.input)
            let agent = try json(example.output)["agent"]?.stringValue.flatMap(AgentID.init(rawValue:))
            XCTAssertEqual(decision, IntentDecision(agent: agent, intent: example.expected),
                           "example \(example.number)")
            XCTAssertEqual(sink.events, [], "example \(example.number)")
        }
    }

    // MARK: - Semantically incomplete → unclear

    func testIncompleteOutputIsUnclearAndLoggedWithoutUserWords() async throws {
        let cases: [(input: IntentInput, output: String, action: String)] = [
            (input("run the tests", .idle), Self.output("instruct", text: ""), "instruct"),
            (input("run the tests", .idle), Self.output("instruct", text: " \n"), "instruct"),
            (input("run the tests", .idle), Self.output("instruct"), "instruct"),
            (input("option two", .working, databaseQuestion), Self.output("answer"), "answer"),
            (input("option two", .working, databaseQuestion), Self.output("answer", answers: []), "answer"),
            (input("yes", .idle), Self.output("approve"), "approve"),
            (input("no, use pnpm", .idle), Self.output("deny", feedback: "use pnpm"), "deny"),
            (input("SQLite", .idle), Self.output("answer", answers: [["SQLite"]]), "answer"),
        ]
        for (index, testCase) in cases.enumerated() {
            let sink = RecordingSink()
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: testCase.output)),
                                          model: "m", diagnostics: sink)

            let decision = try await model.decide(testCase.input)

            XCTAssertEqual(decision, IntentDecision(agent: .claude, intent: .unclear), "case \(index)")
            XCTAssertEqual(sink.events, [TapQDiagnosticEvent(
                category: "intent", name: "intent.incomplete", level: .warning,
                fields: ["agent": "claude", "action": testCase.action])], "case \(index)")
        }
    }

    /// "Always" is the user's words, offered or not: the kernel decides what is granted.
    func testAlwaysIsPassedOnAndBlankFeedbackIsNone() async throws {
        let unofferedAlways = OpenAIIntentModel(
            client: makeClient(FakeHTTP(outputText: Self.output("approve", always: true))),
            model: "m", diagnostics: RecordingSink())
        let approved = try await unofferedAlways.decide(input("yes, always", .working, permission))
        XCTAssertEqual(approved.intent, .approve(requestID: "perm-1", always: true))

        let blankFeedback = OpenAIIntentModel(
            client: makeClient(FakeHTTP(outputText: Self.output("deny", feedback: "  "))),
            model: "m", diagnostics: RecordingSink())
        let denied = try await blankFeedback.decide(input("no", .working, permission))
        XCTAssertEqual(denied.intent, .deny(requestID: "perm-1", feedback: nil))
    }

    // MARK: - Routing (§4.2, 2026-10-12)

    /// The model names the agent; the request id is that agent's head's (§4.2).
    func testTheChosenAgentsHeadIsAnswered() async throws {
        let codex = AgentContext(agent: .codex, phase: .working, pending: databaseQuestion, hasHeldReply: false)
        let claude = AgentContext(agent: .claude, phase: .working, pending: permission, hasHeldReply: true)
        let answering = OpenAIIntentModel(
            client: makeClient(FakeHTTP(outputText: Self.output("approve", agent: "claude"))),
            model: "m", diagnostics: RecordingSink())
        let approved = try await answering.decide(IntentInput(message: "approve Claude's request",
                                                              agents: [claude, codex], spokenToLast: .codex))
        XCTAssertEqual(approved, IntentDecision(agent: .claude, intent: .approve(requestID: "perm-1", always: false)))
    }

    /// The routing examples of §5: the output is the model's, the mapping is pinned.
    func testRoutingExamplesDecode() async throws {
        let idleCodex = AgentContext(agent: .codex, phase: .idle, pending: nil, hasHeldReply: false)
        let idleClaude = AgentContext(agent: .claude, phase: .idle, pending: nil, hasHeldReply: false)
        let askingCodex = AgentContext(agent: .codex, phase: .working, pending: alwaysablePermission, hasHeldReply: false)
        let askingClaude = AgentContext(agent: .claude, phase: .working, pending: permission, hasHeldReply: false)
        let examples: [(number: Int, input: IntentInput, output: String, expected: IntentDecision)] = [
            (18, IntentInput(message: "What is Claude doing right now?", agents: [idleClaude, idleCodex],
                             spokenToLast: .codex),
             Self.output("status", agent: "claude"), IntentDecision(agent: .claude, intent: .status)),
            (19, IntentInput(message: "Ask Claude how many unit tests there are", agents: [idleClaude, idleCodex],
                             spokenToLast: .codex),
             Self.output("instruct", agent: "claude", text: "how many unit tests there are"),
             IntentDecision(agent: .claude, intent: .instruct(text: "how many unit tests there are"))),
            (20, IntentInput(message: "Claude said the tests pass, Codex check them", agents: [idleClaude, idleCodex],
                             spokenToLast: .claude),
             Self.output("instruct", agent: "codex", text: "Claude said the tests pass, check them"),
             IntentDecision(agent: .codex, intent: .instruct(text: "Claude said the tests pass, check them"))),
            (21, IntentInput(message: "Yes, Claude.", agents: [askingClaude, askingCodex], spokenToLast: .codex),
             Self.output("approve", agent: "claude"),
             IntentDecision(agent: .claude, intent: .approve(requestID: "perm-1", always: false))),
            // Both requests heard and the words fit both: no agent, and TapQ asks which.
            (22, IntentInput(message: "Yes.", agents: [askingClaude, askingCodex], spokenToLast: .codex),
             Self.output("approve", agent: nil, by: "state"),
             IntentDecision(agent: nil, intent: .approve(requestID: "", always: false), basis: .state)),
        ]
        for example in examples {
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: example.output)),
                                          model: "m", diagnostics: RecordingSink())
            let decision = try await model.decide(example.input)
            XCTAssertEqual(decision, example.expected, "example \(example.number)")
        }
    }

    // MARK: - Chat agents (2026-10-13)

    /// The chats' names decode, and their one request is a switch to another chat (2026-10-24): a
    /// yes or no answers it.
    func testChatAgentsDecode() async throws {
        let newChat = PendingSummary(kind: .launch, requestID: "launch-2", prompt: "Switch ChatGPT to chat 2: plan a trip?",
                                     canAlwaysAllow: false, heard: true)
        let examples: [(input: IntentInput, output: String, expected: IntentDecision)] = [
            (input("ChatGPT, what is the capital of Portugal?", .idle, agent: .chatgpt),
             Self.output("instruct", agent: "chatgpt", text: "what is the capital of Portugal?"),
             IntentDecision(agent: .chatgpt, intent: .instruct(text: "what is the capital of Portugal?"))),
            (input("Yes.", .awaitingYes, newChat, agent: .chatgpt), Self.output("approve", agent: "chatgpt"),
             IntentDecision(agent: .chatgpt, intent: .approve(requestID: "launch-2", always: false))),
            (input("No.", .idle, newChat, agent: .chatgpt), Self.output("deny", agent: "chatgpt"),
             IntentDecision(agent: .chatgpt, intent: .deny(requestID: "launch-2", feedback: nil))),
            (input("Stop.", .working, agent: .chatgpt), Self.output("interrupt", agent: "chatgpt"),
             IntentDecision(agent: .chatgpt, intent: .interrupt)),
            (input("Claude chat, start a new chat.", .idle, agent: .claudeChat),
             Self.output("new_conversation", agent: "claude-chat"),
             IntentDecision(agent: .claudeChat, intent: .newConversation(text: nil))),
            (input("Ask the Claude app what a monad is.", .idle, agent: .claudeChat),
             Self.output("instruct", agent: "claude-chat", text: "what a monad is"),
             IntentDecision(agent: .claudeChat, intent: .instruct(text: "what a monad is"))),
        ]
        for (index, example) in examples.enumerated() {
            let sink = RecordingSink()
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: example.output)),
                                          model: "m", diagnostics: sink)
            let decision = try await model.decide(example.input)
            XCTAssertEqual(decision, example.expected, "example \(index)")
            XCTAssertEqual(sink.events, [], "example \(index)")
        }
    }

    // MARK: - Conversations (2026-10-12)

    /// The conversation examples of §5: the number is the one TapQ read, and any words go with it.
    func testConversationExamplesDecode() async throws {
        let listed = AgentContext(agent: .claude, phase: .idle, pending: nil, hasHeldReply: false,
                                  conversations: [ConversationChoice(number: 1, title: "run the tests", age: "today",
                                                                     current: true),
                                                  ConversationChoice(number: 2, title: "fix the README",
                                                                     age: "yesterday", current: false)],
                                  moreConversations: 4)
        let idleCodex = AgentContext(agent: .codex, phase: .idle, pending: nil, hasHeldReply: false)
        let examples: [(number: Int, message: String, output: String, expected: Intent)] = [
            (23, "Claude, what conversations do you have?", Self.output("list_conversations"), .listConversations),
            (24, "More.", Self.output("more_conversations"), .moreConversations),
            (25, "Go back to the README one and add tests for it.",
             Self.output("switch_conversation", text: "add tests for it", conversation: 2),
             .switchConversation(number: 2, text: "add tests for it")),
            (26, "Claude, switch to the second one.", Self.output("switch_conversation", text: " ", conversation: 2),
             .switchConversation(number: 2, text: nil)),
            (27, "Claude, start over in a new conversation and run the tests.",
             Self.output("new_conversation", text: "run the tests"), .newConversation(text: "run the tests")),
            (28, "Claude, new conversation.", Self.output("new_conversation"), .newConversation(text: nil)),
        ]
        for example in examples {
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: example.output)),
                                          model: "m", diagnostics: RecordingSink())
            let decision = try await model.decide(IntentInput(message: example.message, agents: [listed, idleCodex],
                                                              spokenToLast: .claude, heardFromLast: .claude))
            XCTAssertEqual(decision, IntentDecision(agent: .claude, intent: example.expected), "example \(example.number)")
        }

        // A switch with no number names no conversation: unclear, as any incomplete action.
        let sink = RecordingSink()
        let numberless = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: Self.output("switch_conversation"))),
                                           model: "m", diagnostics: sink)
        let decision = try await numberless.decide(IntentInput(message: "switch", agents: [listed, idleCodex]))
        XCTAssertEqual(decision, IntentDecision(agent: .claude, intent: .unclear))
        XCTAssertEqual(sink.events.map(\.name), ["intent.incomplete"])
    }

    // MARK: - Contract

    func testOutputOutsideTheSchemaIsContract() async {
        let outputs = [
            "not json",
            #"{"action":"launch","text":null,"always":false,"feedback":null,"answers":null}"#,
            #"{"action":"interrupt","text":null,"feedback":null,"answers":null}"#,
            #"{"action":"answer","text":null,"always":false,"feedback":null,"answers":["SQLite"]}"#,
            #"{"action":"status","text":null,"always":false,"feedback":null,"answers":null}"#,
            #"{"agent":"cursor","action":"status","text":null,"always":false,"feedback":null,"answers":null}"#,
            // 2026-10-12: `conversation` is required like every other key.
            #"{"agent":"claude","action":"status","text":null,"always":false,"feedback":null,"answers":null}"#,
            #"{"agent":"claude","action":"switch_conversation","text":null,"always":false,"feedback":null,"answers":null,"conversation":"two"}"#,
        ]
        for output in outputs {
            let model = OpenAIIntentModel(client: makeClient(FakeHTTP(outputText: output)), model: "m",
                                          diagnostics: RecordingSink())
            let error = await thrownError { () async throws(TextModelError) in
                try await model.decide(self.input("stop", .working))
            }
            XCTAssertEqual(error, .contract("intent output misses the schema"), output)
        }
    }

    func testClientFailuresPassThrough() async {
        for (http, expected) in [(FakeHTTP(throwing: URLError(.timedOut)), TextModelError.callBound("transport")),
                                 (FakeHTTP(status: 503, body: Data()), .callBound("http 503")),
                                 (FakeHTTP(status: 401, body: Data()), .contract("http 401"))] {
            let model = OpenAIIntentModel(client: makeClient(http), model: "m", diagnostics: RecordingSink())
            let error = await thrownError { () async throws(TextModelError) in
                try await model.decide(self.input("stop", .working))
            }
            XCTAssertEqual(error, expected)
        }
    }

    // MARK: - Helpers

    /// Every agent, as the kernel sends them: `agent` in `phase` with `pending`, the others idle.
    private func input(_ message: String, _ phase: AgentPhase, _ pending: PendingSummary? = nil,
                       held: Bool = false, agent: AgentID = .claude) -> IntentInput {
        IntentInput(message: message, agents: AgentID.mac.map { id in
            id == agent ? AgentContext(agent: id, phase: phase, pending: pending, hasHeldReply: held)
                : AgentContext(agent: id, phase: .idle, pending: nil, hasHeldReply: false)
        })
    }

    /// The model's JSON for one action, every key present as the strict schema requires.
    static func output(_ action: String, agent: String? = "claude", by: String = "name", text: String? = nil,
                       always: Bool = false, feedback: String? = nil, answers: [[String]]? = nil,
                       conversation: Int? = nil) -> String {
        let value: JSONValue = .object([
            "agent": agent.map(JSONValue.string) ?? .null,
            "by": .string(by),
            "action": .string(action),
            "text": text.map(JSONValue.string) ?? .null,
            "always": .bool(always),
            "feedback": feedback.map(JSONValue.string) ?? .null,
            "answers": answers.map { .array($0.map { .array($0.map(JSONValue.string)) }) } ?? .null,
            "conversation": conversation.map { .number(Double($0)) } ?? .null,
        ])
        return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }
}
