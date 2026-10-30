import Foundation
import TapQContracts
import TapQKernel

/// A first instruction to an agent that is off, and the conversations it may carry on → the one
/// it does, or none for a new one (maintainer, 2026-10-24: "infer which conversation to proceed
/// with or start a new conversation"). The words are the user's; the titles are the agent's own,
/// or the title the user's chat app shows.
public struct OpenAIConversationPicker: ConversationPicker {
    public static let environmentKey = "TAPQ_PICKER_MODEL"

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

    /// Strict.
    static let schema = try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"object","additionalProperties":false,"required":["conversation","name"],
         "properties":{"conversation":{"type":["integer","null"]},"name":{"type":"string"}}}
        """.utf8))

    private let client: OpenAIClient
    private let model: String

    public init(client: OpenAIClient, model: String) {
        self.client = client
        self.model = model
    }

    /// `TAPQ_PICKER_MODEL` when set and non-blank, else `gpt-5.6-luna`.
    public static func resolvedModel(environment: [String: String]) -> String {
        resolvedTextModel(environmentKey, in: environment)
    }

    /// A number that is not a candidate's is a contract failure: the words would go into a
    /// conversation the user was never offered.
    public func pick(_ instruction: String, among candidates: [ConversationCandidate],
                     agent: AgentID) async throws(TextModelError) -> ConversationPick {
        let request = ResponsesRequest(model: model, instructions: Self.instructions,
                                       input: Input(agent: agent.displayName, message: instruction,
                                                    conversations: candidates).json,
                                       text: .init(format: .init(name: "tapq_pick", schema: Self.schema)),
                                       maxOutputTokens: 1024, promptCacheKey: "tapq-pick-v1")
        let text = try await client.respond(request.encoded())
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw .contract("pick output misses the schema")
        }
        if let number = output.conversation, !candidates.contains(where: { $0.number == number }) {
            throw .contract("picked \(number), not one of the \(candidates.count) conversations")
        }
        return ConversationPick(number: output.conversation,
                                name: output.conversation == nil ? "" : output.name)
    }

    private struct Input: Encodable {
        let agent: String
        let message: String
        let conversations: [ConversationCandidate]

        /// Strings cannot fail to encode.
        var json: String { String(decoding: try! KernelJSON.encoder().encode(self), as: UTF8.self) }
    }

    private struct Output: Decodable {
        let conversation: Int?
        let name: String

        private enum CodingKeys: String, CodingKey { case conversation, name }

        /// `conversation` must be there, null for a new one: a missing key is no choice.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            conversation = try container.decode(Int?.self, forKey: .conversation)
            name = try container.decode(String.self, forKey: .name)
        }
    }
}
