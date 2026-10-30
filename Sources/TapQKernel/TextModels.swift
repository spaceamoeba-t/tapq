import Foundation

public enum AgentPhase: String, Sendable, Codable { case notInstalled, none, awaitingYes, idle, working }

public struct PendingSummary: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case launch, permission, question }
    public let kind: Kind
    public let requestID: String
    /// Exactly the sentence TapQ spoke.
    public let prompt: String
    /// Empty unless `.question`.
    public let questions: [Question]
    public let canAlwaysAllow: Bool
    /// The user has heard the prompt read in full (gate condition b), so a yes can answer it.
    public let heard: Bool

    public init(kind: Kind, requestID: String, prompt: String, questions: [Question] = [],
                canAlwaysAllow: Bool, heard: Bool = false) {
        self.kind = kind
        self.requestID = requestID
        self.prompt = prompt
        self.questions = questions
        self.canAlwaysAllow = canAlwaysAllow
        self.heard = heard
    }
}

/// A conversation TapQ read out for an agent, as the intent model sees it (2026-10-12). The
/// user picks one by its number; one that was not read cannot be picked.
public struct ConversationChoice: Sendable, Equatable, Codable {
    /// As read: 1 is the newest, and "more" numbers on.
    public let number: Int
    /// The name TapQ read for it.
    public let title: String
    /// As read: "today", "yesterday", "on Monday", "on October 3".
    public let age: String
    /// The conversation the agent is in, and resumes.
    public let current: Bool

    public init(number: Int, title: String, age: String, current: Bool) {
        self.number = number
        self.title = title
        self.age = age
        self.current = current
    }
}

/// One agent as the intent model sees it.
public struct AgentContext: Sendable, Equatable, Codable {
    public let agent: AgentID
    public let phase: AgentPhase
    /// The head of that agent's FIFO only.
    public let pending: PendingSummary?
    public let hasHeldReply: Bool
    /// The last sentence TapQ read for this agent other than a request: its reply as spoken
    /// ("Codex says, in short: … Shall I commit?"), its failure. A bare "yes" can answer it.
    public let lastSaid: String?
    /// Its conversations TapQ has read out, by number; empty until the user asks for them.
    public let conversations: [ConversationChoice]
    /// How many more it has that TapQ has not read.
    public let moreConversations: Int

    public init(agent: AgentID, phase: AgentPhase, pending: PendingSummary?, hasHeldReply: Bool,
                lastSaid: String? = nil, conversations: [ConversationChoice] = [], moreConversations: Int = 0) {
        self.agent = agent
        self.phase = phase
        self.pending = pending
        self.hasHeldReply = hasHeldReply
        self.lastSaid = lastSaid
        self.conversations = conversations
        self.moreConversations = moreConversations
    }
}

/// Everything the intent model routes and decides one utterance with (§4.2, routing by the
/// model since 2026-10-12): the sentence whole, every agent, and who the user last spoke to and
/// heard from. No rule picks the agent first.
public struct IntentInput: Sendable, Equatable, Codable {
    /// The utterance as heard, name and all.
    public let message: String
    /// Every agent, in `AgentID` order, installed or not.
    public let agents: [AgentContext]
    /// The agent the user's last utterance was for.
    public let spokenToLast: AgentID?
    /// The agent whose words TapQ last read: a request of its, or its reply.
    public let heardFromLast: AgentID?

    public init(message: String, agents: [AgentContext], spokenToLast: AgentID? = nil,
                heardFromLast: AgentID? = nil) {
        self.message = message
        self.agents = agents
        self.spokenToLast = spokenToLast
        self.heardFromLast = heardFromLast
    }

    public func context(_ agent: AgentID) -> AgentContext? { agents.first { $0.agent == agent } }
}

/// One utterance's action, and the agent it is for. nil: the model could not tell which agent
/// a yes, no or answer is for, and TapQ asks.
public struct IntentDecision: Sendable, Equatable {
    /// Why the model chose the agent (§4.2, 2026-10-13).
    public enum Basis: String, Sendable, Equatable, Codable {
        /// The user's words name it (rule 1).
        case name
        /// A yes, no or answer whose words fit only that agent's heard request (rule 2).
        case fit
        /// Anything else: the one heard request, a reply to what it said, who was spoken to.
        case state
    }

    public let agent: AgentID?
    public let intent: Intent
    /// A yes, no or answer placed by `state` is acted on only when one request was heard: with
    /// two or more, which one is the user's to say (the kernel asks).
    public let basis: Basis

    public init(agent: AgentID?, intent: Intent, basis: Basis = .name) {
        self.agent = agent
        self.intent = intent
        self.basis = basis
    }
}

public enum Intent: Sendable, Equatable, Codable {
    case instruct(text: String)
    case interrupt
    case approve(requestID: String, always: Bool)
    case deny(requestID: String, feedback: String?)
    case answer(requestID: String, answers: [[String]])
    case readAll
    case status
    case unclear
    /// The agent's conversations in this folder, newest first, five at a time (2026-10-12).
    case listConversations
    /// The next five of the list already read.
    case moreConversations
    /// Into the conversation read as `number`, after a yes; `text` is then sent to it.
    case switchConversation(number: Int, text: String?)
    /// Into a new, empty conversation, at once (maintainer, 2026-10-24: no yes); `text` is then
    /// sent to it.
    case newConversation(text: String?)
}

public enum TextModelError: Error, Sendable, Equatable {
    /// Timeout, network error, HTTP 408/429/5xx, an incomplete response, a refusal: spoken.
    case callBound(String)
    /// Other HTTP 4xx, JSON that misses the schema: fatal.
    case contract(String)
}

public protocol IntentModel: Sendable {
    func decide(_ input: IntentInput) async throws(TextModelError) -> IntentDecision
}

public protocol ReplySummarizer: Sendable {
    func summarize(_ reply: String, agent: AgentID) async throws(TextModelError) -> String
}

/// Up to five conversations' titles, as each agent stored them (a first message can run to 200
/// characters) → short names the user can hear and say back (2026-10-12). The same count, in
/// order; on a call-bound failure the kernel reads the titles as they are.
public protocol ConversationTitler: Sendable {
    func names(_ titles: [String], agent: AgentID) async throws(TextModelError) -> [String]
}

/// One conversation a first instruction may carry on, as the picker sees it (2026-10-24).
public struct ConversationCandidate: Sendable, Equatable, Codable {
    /// 1 is the newest.
    public let number: Int
    /// As the agent stored it (a name the user gave, its own summary, the first thing the user
    /// said in it), or the title the user's chat app shows for its chat.
    public let title: String
    /// "today", "yesterday", "on Monday"; empty for the chat an app shows, whose age TapQ
    /// cannot see.
    public let age: String
    /// The conversation TapQ was last in for this agent, or the chat its app shows now.
    public let last: Bool

    public init(number: Int, title: String, age: String, last: Bool) {
        self.number = number
        self.title = title
        self.age = age
        self.last = last
    }
}

/// Where a first instruction goes: a candidate's `number`, or nil for a new conversation.
/// `name`: what the chosen one is about, in a few plain spoken words, so the user hears where
/// the words went; "" for a new one.
public struct ConversationPick: Sendable, Equatable {
    public let number: Int?
    public let name: String

    public init(number: Int?, name: String) {
        self.number = number
        self.name = name
    }
}

/// An instruction to an agent that is off, and the conversations it may carry on → the one it
/// does, or none for a new one (maintainer, 2026-10-24: "infer which conversation to proceed
/// with or start a new conversation"). A number that is not a candidate's is a contract
/// failure: the words would go where the user never was. On a call-bound failure the kernel
/// carries on the last one, else starts a new one, and says so.
public protocol ConversationPicker: Sendable {
    func pick(_ instruction: String, among candidates: [ConversationCandidate],
              agent: AgentID) async throws(TextModelError) -> ConversationPick
}

/// An agent's turn so far, as TapQ saw it: what the user asked, what the agent said along the
/// way and the tools it used, each with whether it is still running. Kept in memory for status
/// only, never journaled; the oldest are dropped past `TurnSoFar.kept`, and each entry is cut
/// at `TurnSoFar.entryLimit` characters.
public struct TurnSoFar: Sendable, Equatable {
    /// Entries kept per list; `steps` counts all of them.
    public static let kept = 30
    public static let entryLimit = 600

    /// Where a step is, as the agents' own screens show it: Claude Code's spinner and then its
    /// result, Codex's "Running" and then "Ran", Pi's pending tool calls (2026-10-15).
    public enum State: String, Sendable, Equatable, Codable {
        /// Started and not ended: what the agent is doing now.
        case running
        /// It asked the user's permission, not yet answered: it has not run.
        case waiting
        case done
        case failed
        /// Turned down before it ran.
        case declined
        /// Ended on purpose before it finished.
        case stopped

        init(_ outcome: StepOutcome) {
            switch outcome {
            case .done: self = .done
            case .failed: self = .failed
            case .declined: self = .declined
            case .stopped: self = .stopped
            }
        }
    }

    public struct Step: Sendable, Equatable {
        /// As the status channel shows it ("Bash: Run the unit tests").
        public let line: String
        /// Nil when the agent gave the step no id, so nothing can tell when it ends.
        public internal(set) var state: State?
        let id: String?

        public init(_ line: String, state: State? = .running, id: String? = nil) {
            self.line = line
            self.state = state
            self.id = id
        }
    }

    /// The user's words sent to the agent this turn: the instruction, then any steers.
    public private(set) var asked: [String] = []
    /// The agent's own words along the way (Claude Code's prose between tool calls, Codex's
    /// messages), oldest first.
    public private(set) var said: [String] = []
    /// Its tools, oldest first.
    public private(set) var steps: [Step] = []
    /// Every step this turn, including those dropped.
    public private(set) var stepCount = 0

    public init(asked: [String] = [], said: [String] = [], steps: [Step] = []) {
        for text in asked { ask(text) }
        for text in said { say(text) }
        for step in steps {
            stepCount += 1
            Self.add(step, to: &self.steps)
        }
    }

    public mutating func ask(_ text: String) { Self.add(text, to: &asked) }
    public mutating func say(_ text: String) { Self.add(text, to: &said) }

    /// A step started: running until `end` names its `id`. Without an id its state is unknown.
    public mutating func step(_ line: String, id: String? = nil) {
        stepCount += 1
        Self.add(Step(line, state: id == nil ? nil : .running, id: id), to: &steps)
    }

    /// The step with this id ended. One no longer kept, or never started, is left alone; so is
    /// one already ended (an agent reports a step's end once).
    public mutating func end(_ id: String, _ outcome: StepOutcome) {
        guard let index = steps.lastIndex(where: { $0.id == id }),
              [.running, .waiting].contains(steps[index].state) else { return }
        steps[index].state = State(outcome)
    }

    /// The step asked the user's permission: it waits, as Claude Code's and Codex's screens
    /// show a prompt instead of a running tool.
    public mutating func wait(_ id: String) { change(id, from: .running, to: .waiting) }

    /// The user allowed it: it runs. A denied one waits until the agent ends it as declined.
    public mutating func resume(_ id: String) { change(id, from: .waiting, to: .running) }

    private mutating func change(_ id: String, from: State, to: State) {
        guard let index = steps.lastIndex(where: { $0.id == id }), steps[index].state == from else { return }
        steps[index].state = to
    }

    /// Whether the agent has shown anything of its work yet.
    public var hasWork: Bool { !said.isEmpty || !steps.isEmpty }

    private static func add(_ text: String, to list: inout [String]) {
        guard let entry = entry(text) else { return }
        list.append(entry)
        if list.count > kept { list.removeFirst(list.count - kept) }
    }

    private static func add(_ step: Step, to list: inout [Step]) {
        guard let line = entry(step.line) else { return }
        list.append(Step(line, state: step.state, id: step.id))
        if list.count > kept { list.removeFirst(list.count - kept) }
    }

    private static func entry(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > entryLimit ? String(trimmed.prefix(entryLimit)) + "…" : trimmed
    }
}

/// An agent's turn so far → where it is in the whole task, in words the user can hear: what it
/// is doing now, what is done and what is left (maintainer, 2026-10-15). Status reads this
/// instead of the agent's last tool line, which read raw shell commands aloud.
public protocol ProgressSummarizer: Sendable {
    /// One or two spoken sentences that start with the agent's name.
    func summarize(_ turn: TurnSoFar, agent: AgentID) async throws(TextModelError) -> String
}

/// A shell command an agent asks to run → what it does, in words the user can hear. The user
/// approves the description, not the command (maintainer ruling 2026-10-12).
public protocol CommandDescriber: Sendable {
    /// A verb phrase that completes "<agent> wants to …". `workspacePaths`: every path that
    /// names the agent's folder, as the user picked it and where links on the way lead
    /// (`KernelConfiguration.workspacePaths`): a command can name it either way.
    func describe(_ command: String, agent: AgentID, workspacePaths: [String]) async throws(TextModelError) -> String
}
