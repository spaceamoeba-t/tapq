import Foundation
import TapQContracts
import TapQKernel

/// Up to five conversations' titles → names TapQ reads in the list (maintainer, 2026-10-12).
/// The agents keep a title the user gave, their own summary, or the first message cut at 200
/// characters; five of those read whole take a minute, and a switch is asked with the name
/// under the verbatim gate, so a path or markup in it would not survive the reading.
public struct OpenAIConversationTitler: ConversationTitler {
    public static let environmentKey = "TAPQ_TITLER_MODEL"

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

    /// Strict.
    static let schema = try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"object","additionalProperties":false,"required":["names"],
         "properties":{"names":{"type":"array","items":{"type":"string"}}}}
        """.utf8))

    private let client: OpenAIClient
    private let model: String

    public init(client: OpenAIClient, model: String) {
        self.client = client
        self.model = model
    }

    /// `TAPQ_TITLER_MODEL` when set and non-blank, else `gpt-5.6-luna`.
    public static func resolvedModel(environment: [String: String]) -> String {
        resolvedTextModel(environmentKey, in: environment)
    }

    /// A count that is not the titles' is a contract failure: names read against the wrong
    /// conversations would switch to one the user did not choose.
    public func names(_ titles: [String], agent: AgentID) async throws(TextModelError) -> [String] {
        let request = ResponsesRequest(model: model, instructions: Self.instructions,
                                       input: Input(agent: agent.displayName, titles: titles).json,
                                       text: .init(format: .init(name: "tapq_titles", schema: Self.schema)),
                                       maxOutputTokens: 512, promptCacheKey: "tapq-titles-v1")
        let text = try await client.respond(request.encoded())
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw .contract("titles output misses the schema")
        }
        guard output.names.count == titles.count else {
            throw .contract("\(output.names.count) names for \(titles.count) titles")
        }
        return output.names
    }

    private struct Input: Encodable {
        let agent: String
        let titles: [String]

        /// Strings cannot fail to encode.
        var json: String { String(decoding: try! KernelJSON.encoder().encode(self), as: UTF8.self) }
    }

    private struct Output: Decodable {
        let names: [String]
    }
}
