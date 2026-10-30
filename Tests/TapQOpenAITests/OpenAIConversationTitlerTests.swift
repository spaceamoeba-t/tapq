import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import TapQContracts
import TapQKernel
import TapQOpenAI

final class OpenAIConversationTitlerTests: XCTestCase {
    /// The titler's prompt, byte for byte.
    static let instructions = """
        You name a coding agent's conversations for a list that TapQ reads aloud. The user picks one
        by its number, and TapQ then asks "Switch to conversation 2: <name>?".

        Input JSON: agent (its name) and titles: each conversation's title as the agent stored it,
        newest first. A title is a name the user gave, the agent's own summary, or the first thing
        the user said in that conversation, cut at 200 characters.

        Output names: exactly one per title, in the same order. Each says what that conversation is
        about in at most eight plain spoken words, from its title only: keep the title's own words
        where they fit, name files and programs by their plain names, and leave out paths, symbols,
        markup and code. A short title that already reads well stays as it is. When two titles are
        about the same thing, make their names tell them apart. Never merge, drop or reorder
        titles, and never add anything a title does not say.
        """

    static let schema = """
        {"type":"object","additionalProperties":false,"required":["names"],
         "properties":{"names":{"type":"array","items":{"type":"string"}}}}
        """

    func testRequestIsPinned() async throws {
        let http = FakeHTTP(outputText: #"{"names":["Milestone one from the spec","README fixes"]}"#)
        let titler = OpenAIConversationTitler(client: makeClient(http), model: "gpt-5.6-luna")

        let names = try await titler.names(["read the spec file and build milestone one.", "fix the README"],
                                           agent: .claude)

        XCTAssertEqual(names, ["Milestone one from the spec", "README fixes"])
        XCTAssertEqual(http.requests.first?.url?.absoluteString, "https://api.openai.invalid/v1/responses")
        var body = try http.sentBody
        XCTAssertEqual(body.removeValue(forKey: "instructions")?.stringValue, Self.instructions)
        let input = try XCTUnwrap(body.removeValue(forKey: "input")?.stringValue)
        XCTAssertEqual(try json(input), try json("""
            {"agent":"Claude Code","titles":["read the spec file and build milestone one.","fix the README"]}
            """))
        XCTAssertEqual(.object(body), try json("""
            {"model":"gpt-5.6-luna","store":false,"reasoning":{"effort":"none"},
             "text":{"verbosity":"low","format":{"type":"json_schema","name":"tapq_titles","strict":true,
                                                 "schema":\(Self.schema)}},
             "max_output_tokens":512,"prompt_cache_key":"tapq-titles-v1"}
            """))
    }

    /// Names that do not match the titles one for one would be read against the wrong
    /// conversations.
    func testAnyOtherCountOrShapeIsContract() async {
        let cases: [(output: String, expected: TextModelError)] = [
            (#"{"names":["one"]}"#, .contract("1 names for 2 titles")),
            (#"{"names":["one","two","three"]}"#, .contract("3 names for 2 titles")),
            (#"{"titles":["one","two"]}"#, .contract("titles output misses the schema")),
            ("one, two", .contract("titles output misses the schema")),
        ]
        for testCase in cases {
            let titler = OpenAIConversationTitler(client: makeClient(FakeHTTP(outputText: testCase.output)), model: "m")
            let error = await thrownError { () async throws(TextModelError) in
                try await titler.names(["a", "b"], agent: .codex)
            }
            XCTAssertEqual(error, testCase.expected, testCase.output)
        }
    }

    func testClientFailuresPassThrough() async {
        for (http, expected) in [(FakeHTTP(throwing: URLError(.timedOut)), TextModelError.callBound("transport")),
                                 (FakeHTTP(status: 503, body: Data()), .callBound("http 503")),
                                 (FakeHTTP(status: 401, body: Data()), .contract("http 401"))] {
            let titler = OpenAIConversationTitler(client: makeClient(http), model: "m")
            let error = await thrownError { () async throws(TextModelError) in
                try await titler.names(["a"], agent: .claude)
            }
            XCTAssertEqual(error, expected)
        }
    }

    func testModelComesFromTheEnvironmentWithOneDefault() async {
        XCTAssertEqual(OpenAIConversationTitler.resolvedModel(environment: [:]), "gpt-5.6-luna")
        XCTAssertEqual(OpenAIConversationTitler.resolvedModel(environment: ["TAPQ_TITLER_MODEL": "gpt-6-luna"]),
                       "gpt-6-luna")
    }
}
