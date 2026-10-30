import Foundation
import TapQContracts
import TapQKernel

/// One utterance → the agent it is for and exactly one `Intent` (routing by
/// the model since 2026-10-12). The model proposes; the kernel's gate decides. The model never
/// names a request id: the id of the chosen agent's pending head is attached here.
public struct OpenAIIntentModel: IntentModel {
    public static let environmentKey = "TAPQ_INTENT_MODEL"

    static let instructions = """
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

    /// The agents a host offers the model, and the prompt that names them.
    public enum Roster: Sendable, Equatable {
        /// The Mac's coding agents and chats: prompt v7 (2026-10-24: only a refusal is a no).
        case mac

        public var agents: [AgentID] { AgentID.mac }

        var instructions: String { OpenAIIntentModel.instructions }

        var schema: JSONValue { OpenAIIntentModel.schema }

        var cacheKey: String { "tapq-intent-v7" }
    }

    /// Strict: every key required, nullable where unused. The agent is one of the roster's, so
    /// an agent added there is one the model can name; null is "TapQ asks which".
    static let schema = schema(for: AgentID.mac)

    static func schema(for agents: [AgentID]) -> JSONValue {
        let names = agents.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
        return try! JSONDecoder().decode(JSONValue.self, from: Data("""
        {"type":"object","additionalProperties":false,
         "required":["agent","by","action","text","always","feedback","answers","conversation"],
         "properties":{
          "agent":{"type":["string","null"],"enum":[\(names),null]},
          "by":{"type":"string","enum":["name","fit","state"]},
          "action":{"type":"string","enum":["instruct","interrupt","approve","deny","answer","read_all","status","unclear","list_conversations","more_conversations","switch_conversation","new_conversation"]},
          "text":{"type":["string","null"]},
          "always":{"type":"boolean"},
          "feedback":{"type":["string","null"]},
          "answers":{"type":["array","null"],"items":{"type":"array","items":{"type":"string"}}},
          "conversation":{"type":["integer","null"]}}}
        """.utf8))
    }

    private let client: OpenAIClient
    private let model: String
    private let roster: Roster
    private let diagnostics: TapQDiagnosticEmitter

    public init(client: OpenAIClient, model: String, roster: Roster = .mac, diagnostics: any TapQDiagnosticSink) {
        self.client = client
        self.model = model
        self.roster = roster
        self.diagnostics = TapQDiagnosticEmitter(category: "intent", sink: diagnostics)
    }

    /// `TAPQ_INTENT_MODEL` when set and non-blank, else `gpt-5.6-luna`.
    public static func resolvedModel(environment: [String: String]) -> String {
        resolvedTextModel(environmentKey, in: environment)
    }

    /// The model routes and decides (§4.2): the request id is the chosen agent's head's. No
    /// agent means it could not tell which request a yes, no or answer is for.
    public func decide(_ input: IntentInput) async throws(TextModelError) -> IntentDecision {
        let request = ResponsesRequest(
            model: model, instructions: roster.instructions,
            input: ModelInput(input).json,
            text: .init(format: .init(name: "tapq_intent", schema: roster.schema)),
            maxOutputTokens: 2048, promptCacheKey: roster.cacheKey)
        let text = try await client.respond(request.encoded())
        guard let output = try? JSONDecoder().decode(Output.self, from: Data(text.utf8)) else {
            throw .contract("intent output misses the schema")
        }
        guard let agent = output.agent, let context = input.context(agent) else {
            return IntentDecision(agent: nil, intent: output.intent(pending: Self.unknownRequest) ?? .unclear,
                                  basis: .state)
        }
        if let intent = output.intent(pending: context.pending) {
            return IntentDecision(agent: agent, intent: intent, basis: output.by)
        }
        // Never the output's text: it is the user's words.
        diagnostics.record("intent.incomplete", level: .warning,
                           fields: ["agent": agent.rawValue, "action": output.action.rawValue])
        return IntentDecision(agent: agent, intent: .unclear, basis: output.by)
    }

    /// The request a yes, no or answer with no agent would have answered: none TapQ can name.
    private static let unknownRequest = PendingSummary(kind: .permission, requestID: "", prompt: "",
                                                       canAlwaysAllow: false)

    /// `IntentInput` with every null written out, as the instructions describe it.
    private struct ModelInput: Encodable {
        let input: IntentInput

        init(_ input: IntentInput) { self.input = input }

        /// Strings, enums and bools cannot fail to encode.
        var json: String { String(decoding: try! KernelJSON.encoder().encode(self), as: UTF8.self) }

        enum CodingKeys: String, CodingKey { case message, agents, spokenToLast, heardFromLast }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(input.message, forKey: .message)
            try container.encode(input.agents.map(Agent.init), forKey: .agents)
            try container.encode(input.spokenToLast, forKey: .spokenToLast)
            try container.encode(input.heardFromLast, forKey: .heardFromLast)
        }

        private struct Agent: Encodable {
            let context: AgentContext

            enum CodingKeys: String, CodingKey {
                case agent, phase, pending, hasHeldReply, lastSaid, conversations, moreConversations
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(context.agent, forKey: .agent)
                try container.encode(context.phase, forKey: .phase)
                try container.encode(context.pending, forKey: .pending)
                try container.encode(context.hasHeldReply, forKey: .hasHeldReply)
                try container.encode(context.lastSaid, forKey: .lastSaid)
                try container.encode(context.conversations, forKey: .conversations)
                try container.encode(context.moreConversations, forKey: .moreConversations)
            }
        }
    }

    private struct Output: Decodable {
        enum Action: String, Decodable {
            case instruct, interrupt, approve, deny, answer, status, unclear
            case readAll = "read_all"
            case listConversations = "list_conversations"
            case moreConversations = "more_conversations"
            case switchConversation = "switch_conversation"
            case newConversation = "new_conversation"
        }

        let agent: AgentID?
        let by: IntentDecision.Basis
        let action: Action
        let text: String?
        let always: Bool
        let feedback: String?
        let answers: [[String]]?
        let conversation: Int?

        private enum CodingKeys: String, CodingKey {
            case agent, by, action, text, always, feedback, answers, conversation
        }

        /// Strict, as the schema is: every key present, `null` where unused. A missing key is a
        /// schema miss, not a nil.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            agent = try container.decode(AgentID?.self, forKey: .agent)
            by = try container.decode(IntentDecision.Basis.self, forKey: .by)
            action = try container.decode(Action.self, forKey: .action)
            text = try container.decode(String?.self, forKey: .text)
            always = try container.decode(Bool.self, forKey: .always)
            feedback = try container.decode(String?.self, forKey: .feedback)
            answers = try container.decode([[String]]?.self, forKey: .answers)
            conversation = try container.decode(Int?.self, forKey: .conversation)
        }

        /// Nil when the JSON fits the schema but not the action (§5 "semantically incomplete").
        func intent(pending: PendingSummary?) -> Intent? {
            switch action {
            case .instruct:
                guard let text, !text.isBlank else { return nil }
                return .instruct(text: text)
            case .interrupt: return .interrupt
            case .approve:
                guard let pending else { return nil }
                // The user's words; whether "always" is granted is the kernel's call (§4.3).
                return .approve(requestID: pending.requestID, always: always)
            case .deny:
                guard let pending else { return nil }
                return .deny(requestID: pending.requestID, feedback: feedback?.isBlank == false ? feedback : nil)
            case .answer:
                guard let pending, let answers, !answers.isEmpty else { return nil }
                return .answer(requestID: pending.requestID, answers: answers)
            case .readAll: return .readAll
            case .status: return .status
            case .unclear: return .unclear
            case .listConversations: return .listConversations
            case .moreConversations: return .moreConversations
            case .switchConversation:
                guard let conversation else { return nil }
                return .switchConversation(number: conversation, text: text?.isBlank == false ? text : nil)
            case .newConversation:
                return .newConversation(text: text?.isBlank == false ? text : nil)
            }
        }
    }
}

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
