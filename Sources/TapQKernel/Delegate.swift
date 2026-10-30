import Foundation

/// The agents TapQ relays to: two coding agents, and the user's chats in the Claude and
/// ChatGPT apps (2026-10-13). The raw value is the name on disk (`session.json`, the journal)
/// and on the status channel. Which of them a run has is its host's roster
/// (`KernelConfiguration.roster`), never every case.
public enum AgentID: String, Sendable, Codable, CaseIterable {
    case claude, codex
    case claudeChat = "claude-chat"
    case chatgpt

    /// The Mac's agents, in the order the status line and the intent model list them.
    public static let mac: [AgentID] = [.claude, .codex, .claudeChat, .chatgpt]
}

/// What an agent is, which decides what the kernel may ask of it.
public enum AgentKind: Sendable, Equatable {
    /// A CLI TapQ spawns in the workspace: it asks permissions and questions, takes words
    /// while it works, and keeps resumable conversations in the folder.
    case coding
    /// A chat with Claude or ChatGPT: one question, one answer.
    case chat
}

/// How a chat agent reaches Claude or ChatGPT, chosen per agent when TapQ starts (2026-10-13).
public enum ChatBackend: String, Sendable, Equatable, Codable {
    /// The conversation in the user's own app, on the user's account, through Accessibility
    /// (`--desktop-chat`). The app keeps the chats; TapQ lists none, and a run's first words
    /// carry on the chat the app shows or open a new one (2026-10-24).
    case app
    /// TapQ's own chat over the vendor's API, on an API key (`--api-chat`). TapQ keeps the
    /// chats in the folder, so they resume, list and switch as a coding agent's conversations
    /// do.
    case api
}

public extension AgentID {
    /// Spoken name, and the name the intent prompt uses. A bare "Claude" is Claude Code
    /// (maintainer, 2026-10-13); the chat is "Claude chat".
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .claudeChat: return "Claude chat"
        case .chatgpt: return "ChatGPT"
        }
    }

    var kind: AgentKind {
        switch self {
        case .claude, .codex: return .coding
        case .claudeChat, .chatgpt: return .chat
        }
    }

    /// Words said to it while it works reach the turn (Claude's merge, Codex's `turn/steer`).
    /// A chat's answer cannot be steered, in the app or over the API.
    var steers: Bool { kind != .chat }

    /// It keeps its conversations across TapQ runs, so a relaunch can resume one, and lists and
    /// switches the folder's conversations by voice: a coding agent, and a chat over the API
    /// (2026-10-13). A chat in the user's app keeps none: its app shows the chat.
    /// `chats` is how this run reaches a chat agent; the other kinds ignore it.
    func resumes(_ chats: ChatBackend) -> Bool { kind != .chat || chats == .api }
}

/// What the delegate offers so that a request is not asked again. Opaque to the kernel;
/// the delegate echoes it back in the reply.
public struct AlwaysAllowOffer: Sendable, Equatable, Codable {
    /// e.g. "allow Bash(npm test:*) in this project".
    public let description: String
    /// Claude: `permission_suggestions`; Codex: "acceptForSession", never an execpolicy amendment
    /// (it would write Codex's rules for every later session; ruling 2026-10-12).
    public let payloadJSON: String

    public init(description: String, payloadJSON: String) {
        self.description = description
        self.payloadJSON = payloadJSON
    }
}

public struct PermissionRequest: Sendable, Equatable, Codable {
    /// The delegate's own request id; unique per agent.
    public let id: String
    /// "Bash", "Edit", "mcp__gmail__send_message", "commandExecution", "fileChange".
    public let tool: String
    /// The FULL input, verbatim.
    public let inputJSON: String
    /// The shell command when there is one, in full.
    public let command: String?
    /// Files touched, when known.
    public let paths: [String]
    /// The delegate's own description (Claude `description`/`display_name`).
    public let title: String?
    /// Claude `decision_reason`; Codex `reason`.
    public let reason: String?
    public let alwaysAllow: AlwaysAllowOffer?
    /// The step it asks about, by the id `progress` gave it (Claude Code's `tool_use_id`,
    /// Codex's `itemId`): that step waits on the user (2026-10-15). For status only; never
    /// journaled.
    public let step: String?

    public init(id: String, tool: String, inputJSON: String, command: String? = nil,
                paths: [String] = [], title: String? = nil, reason: String? = nil,
                alwaysAllow: AlwaysAllowOffer? = nil, step: String? = nil) {
        self.id = id
        self.tool = tool
        self.inputJSON = inputJSON
        self.command = command
        self.paths = paths
        self.title = title
        self.reason = reason
        self.alwaysAllow = alwaysAllow
        self.step = step
    }

    private enum CodingKeys: String, CodingKey {
        case id, tool, inputJSON, command, paths, title, reason, alwaysAllow
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id),
                  tool: try container.decode(String.self, forKey: .tool),
                  inputJSON: try container.decode(String.self, forKey: .inputJSON),
                  command: try container.decodeIfPresent(String.self, forKey: .command),
                  paths: try container.decode([String].self, forKey: .paths),
                  title: try container.decodeIfPresent(String.self, forKey: .title),
                  reason: try container.decodeIfPresent(String.self, forKey: .reason),
                  alwaysAllow: try container.decodeIfPresent(AlwaysAllowOffer.self, forKey: .alwaysAllow))
    }
}

public struct QuestionOption: Sendable, Equatable, Codable {
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct Question: Sendable, Equatable, Codable {
    /// Claude: the question text; Codex: the question id.
    public let key: String
    public let header: String?
    public let text: String
    public let options: [QuestionOption]
    public let multiSelect: Bool
    /// Claude: always true; Codex: `isOther`.
    public let allowsFreeText: Bool

    public init(key: String, header: String?, text: String, options: [QuestionOption],
                multiSelect: Bool, allowsFreeText: Bool) {
        self.key = key
        self.header = header
        self.text = text
        self.options = options
        self.multiSelect = multiSelect
        self.allowsFreeText = allowsFreeText
    }
}

public struct QuestionRequest: Sendable, Equatable, Codable {
    public let id: String
    /// All of them, never only the first (01-8).
    public let questions: [Question]

    public init(id: String, questions: [Question]) {
        self.id = id
        self.questions = questions
    }
}

public enum PermissionDecision: Sendable, Equatable, Codable {
    case allow(always: Bool)
    case deny(feedback: String?)
}

/// How a step the agent started ended, in the agent's own terms: Claude Code's `tool_result`
/// (`is_error`, `tool_result_meta` `non_execution_kind`), Codex's `item/completed` status
/// (`completed`, `failed`, `declined`), the `tool_execution_end` and `isError` of Pi's loop
/// (2026-10-15).
public enum StepOutcome: String, Sendable, Equatable, Encodable {
    case done
    case failed
    /// It never ran: the user, or a rule, turned it down.
    case declined
    /// Ended on purpose before it finished: Claude Code's task `status` `stopped` (KillShell,
    /// TaskStop).
    case stopped
}

public enum DelegateEvent: Sendable, Equatable {
    /// A tool started. For `status` only; never spoken on its own. `step` is the agent's own
    /// id for it (Claude Code's `tool_use` id, Codex's item id), which `stepEnded` names.
    case progress(String, step: String? = nil)
    /// A step `progress` started has ended (2026-10-15). For `status` only: a step still
    /// running is what the agent is doing now, never something it has done.
    case stepEnded(step: String, StepOutcome)
    /// The agent's own words during its turn, before its reply (Claude Code's prose between
    /// tool calls, a Codex `agentMessage`); the reply's own words may come too, just before
    /// `finished`. For `status` only; never spoken on its own (2026-10-15).
    case said(String)
    case permission(PermissionRequest)
    case question(QuestionRequest)
    /// The delegate cancelled a request (Claude `control_cancel_request`, Codex
    /// `serverRequest/resolved` for a request TapQ did not answer). Also emitted by the
    /// delegate for every request still open when a turn ends, before that turn's terminal
    /// event. So no request outlives its turn.
    case withdrawn(requestID: String)
    /// The turn ended normally; `text` may be empty.
    case finished(text: String)
    /// The turn ended because TapQ interrupted it (any `aborted_*`).
    case stopped
    /// D6: a non-abort error result; the process is healthy.
    case failed(reason: String)
    /// A sentence for the user about something the delegate answered on its own (a declined
    /// MCP elicitation, a secret question). Spoken verbatim in the result band; no state changes.
    case notice(String)
    /// The process ended on its own: this agent failed, and TapQ runs on (ruling 2026-10-12).
    case exited(code: Int32, stderrTail: [String])
    /// A frame the loop must act on but cannot: the kernel stops this agent.
    case violation(String)
}

public enum DelegateSession: Sendable, Equatable {
    case fresh
    case resume(id: String)
}

/// ACP-shaped: start/load ≈ session/new|load, send ≈ session/prompt (or steer),
/// interrupt ≈ session/cancel, resolve* ≈ the reply to session/request_permission.
///
/// One object per process: after an agent fails, the kernel stops it and makes a fresh one
/// (`DelegateFactory`). Any throw fails that agent alone (ruling 2026-10-12).
@MainActor
public protocol Delegate: AnyObject {
    var agent: AgentID { get }
    /// One stream for the object's life; readable before `start`.
    var events: AsyncStream<DelegateEvent> { get }
    /// Spawns and handshakes. `persist` is called with the session id before any user
    /// message can reach the agent: before spawn for Claude (the id is ours), and after
    /// `thread/start` for Codex. A throw from `persist` aborts start. `stop` during `start`
    /// makes it throw (the kernel's start bound).
    func start(_ session: DelegateSession, persist: (String) throws -> Void) async throws
    /// A user message. Idle → new turn; working → steer (Claude: plain user line, which K0
    /// measured merges; Codex: `turn/steer`).
    func send(_ text: String) throws
    func interrupt() throws
    func resolve(permission id: String, _ decision: PermissionDecision) throws
    /// `answers[i]` answers `questions[i]`: option labels, or one free-text string.
    func resolve(question id: String, answers: [[String]]) throws
    /// D13 clean stop: close stdin, wait ≤ 5 s, SIGTERM the group, wait ≤ 2 s, SIGKILL.
    func stop() async
    /// A chat in the user's app: the title of the chat its app shows now, which a first
    /// instruction may carry on (2026-10-24), read before `start` and changing nothing. nil when
    /// the app shows none, and for every agent that keeps its own conversations.
    func shownConversation() async -> String?
}

public extension Delegate {
    func shownConversation() async -> String? { nil }
}
