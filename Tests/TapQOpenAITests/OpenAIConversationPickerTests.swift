import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import TapQContracts
import TapQKernel
import TapQOpenAI

final class OpenAIConversationPickerTests: XCTestCase {
    /// The picker's prompt, byte for byte.
    static let instructions = """
        TapQ relays what a user says to an agent: a coding agent (Claude Code, Codex), a chat (Claude
        chat, ChatGPT) or TapQ's own agent. The agent is not running yet, and the user just said
        something to it. You choose where that goes: on in one of the agent's conversations, or
        into a new one. TapQ starts it there at once, without asking, and says where.

        Input JSON: agent (its name); message (what the user said to it, as heard, in any language);
        conversations: the ones it may carry on, newest first, each with number, title (a name the
        user gave it, the agent's own summary, the first thing the user said in it, or the title the
        user's chat app shows for the chat on its screen), age ("today", "on Monday"; "" when
        unknown) and last (true for the one the user was last in through TapQ, or the chat the app
        shows now).

        Output conversation: the number of the one the message carries on, or null for a new one.
        - A message on a title's subject, or a follow-up to it, carries that one on.
        - A message that refers to earlier work or talk ("continue", "go on", "as we discussed",
          "the listings from today", "that bug", "the test you wrote") carries on the one whose
          title it fits; when it fits none of them or several equally, the one marked last, else
          the newest.
        - A message that starts something no title is about, or asks for a new or fresh start, is
          null.
        Output name: when conversation is a number, what that conversation is about, as a short
        noun phrase that fits "Claude Code continues …" ("the login bug fix", "the Toronto listings
        comparison"), in at most eight plain spoken words from its title only, in the title's
        language, without paths, symbols, markup or code; otherwise "".
        """

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["conversation","name"],
         "properties":{"conversation":{"type":["integer","null"]},"name":{"type":"string"}}}
        """

    private let candidates = [
        ConversationCandidate(number: 1, title: "Downtown Toronto rentals", age: "", last: true),
        ConversationCandidate(number: 2, title: "fix the README", age: "yesterday", last: false),
    ]

    func testRequestIsPinned() async throws {
        let http = FakeHTTP(outputText: #"{"conversation":1,"name":"the Toronto rentals comparison"}"#)
        let picker = OpenAIConversationPicker(client: makeClient(http), model: "gpt-5.6-luna")

        let pick = try await picker.pick("继续帮我对比一下这三个房源", among: candidates, agent: .chatgpt)

        XCTAssertEqual(pick, ConversationPick(number: 1, name: "the Toronto rentals comparison"))
        XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://api.openai.invalid/v1/responses")
        var body = try http.sentBody
        XCTAssertEqual(body.removeValue(forKey: "instructions")?.stringValue, Self.instructions)
        let input = try XCTUnwrap(body.removeValue(forKey: "input")?.stringValue)
        XCTAssertEqual(try json(input), try json("""
            {"agent":"ChatGPT","message":"继续帮我对比一下这三个房源",
             "conversations":[{"number":1,"title":"Downtown Toronto rentals","age":"","last":true},
                              {"number":2,"title":"fix the README","age":"yesterday","last":false}]}
            """))
        XCTAssertEqual(.object(body), try json("""
            {"model":"gpt-5.6-luna","store":false,"reasoning":{"effort":"none"},
             "text":{"verbosity":"low","format":{"type":"json_schema","name":"tapq_pick","strict":true,
                                                 "schema":\(Self.schema)}},
             "max_output_tokens":1024,"prompt_cache_key":"tapq-pick-v1"}
            """))
    }

    /// A new conversation has no name to say, whatever the model wrote.
    func testANewConversationHasNoName() async throws {
        let http = FakeHTTP(outputText: #"{"conversation":null,"name":"a poem"}"#)
        let picker = OpenAIConversationPicker(client: makeClient(http), model: "m")
        let pick = try await picker.pick("write a poem about autumn", among: candidates, agent: .claudeChat)
        XCTAssertEqual(pick, ConversationPick(number: nil, name: ""))
    }

    /// A number no candidate has would send the words where the user never was.
    func testANumberNotOfferedOrAnotherShapeIsContract() async {
        let cases: [(output: String, expected: TextModelError)] = [
            (#"{"conversation":3,"name":"x"}"#, .contract("picked 3, not one of the 2 conversations")),
            (#"{"conversation":0,"name":"x"}"#, .contract("picked 0, not one of the 2 conversations")),
            (#"{"number":1,"name":"x"}"#, .contract("pick output misses the schema")),
            ("the first one", .contract("pick output misses the schema")),
        ]
        for testCase in cases {
            let picker = OpenAIConversationPicker(client: makeClient(FakeHTTP(outputText: testCase.output)), model: "m")
            let error = await thrownError { () async throws(TextModelError) in
                _ = try await picker.pick("go on", among: self.candidates, agent: .claude)
            }
            XCTAssertEqual(error, testCase.expected, testCase.output)
        }
    }

    func testClientFailuresPassThrough() async {
        for (http, expected) in [(FakeHTTP(throwing: URLError(.timedOut)), TextModelError.callBound("transport")),
                                 (FakeHTTP(status: 503, body: Data()), .callBound("http 503")),
                                 (FakeHTTP(status: 401, body: Data()), .contract("http 401"))] {
            let picker = OpenAIConversationPicker(client: makeClient(http), model: "m")
            let error = await thrownError { () async throws(TextModelError) in
                _ = try await picker.pick("go on", among: self.candidates, agent: .codex)
            }
            XCTAssertEqual(error, expected)
        }
    }

    func testModelComesFromTheEnvironmentWithOneDefault() async {
        XCTAssertEqual(OpenAIConversationPicker.resolvedModel(environment: [:]), "gpt-5.6-luna")
        XCTAssertEqual(OpenAIConversationPicker.resolvedModel(environment: ["TAPQ_PICKER_MODEL": "gpt-6-luna"]),
                       "gpt-6-luna")
    }
}
