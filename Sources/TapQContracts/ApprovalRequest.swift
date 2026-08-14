import Foundation

/// An agent action awaiting a hands-free allow/deny.
///
/// `summary` is a short spoken verb phrase ("run npm test"); `detail` is the fuller
/// text spoken only when the user asks for details. The agent-specific rendering of a
/// tool call into these strings lives in its adapter, keeping the runtime agnostic.
///
/// `toolInput`, `cwd`, `permissionMode`, and `approvalSource` carry the raw request
/// context a risk reasoner needs to judge the action, and each is nil-able for its own
/// reason. `approvalSource` is the discriminator: the broker rejects an approval that
/// lacks one, so a broker-originated request always has both it and `toolInput`, while a
/// request built anywhere else (a question detected in an agent's reply, say) has
/// neither. `cwd` and `permissionMode` may be nil even for broker traffic — the shims
/// send null when the agent's hook payload omits them.
///
/// This context is potentially sensitive — the full Bash command line and working
/// directory ride along — so it stays in process: it must not reach diagnostics, logs,
/// or spoken output. `description` and `debugDescription` are redacted accordingly.
public struct ApprovalRequest: Sendable, Equatable, Identifiable {
    /// What kind of yes/no the user is being asked for — it changes only the spoken
    /// phrasing, never the input mapping (nod/voice-yes → allow, shake/voice-no → deny).
    public enum Kind: String, Sendable, Equatable {
        /// A tool call awaiting permission: "The agent wants to …. Approve?"
        case toolApproval
        /// A yes/no question found in an agent's reply: "The agent asks: …. Yes or no?"
        case question
    }

    public let id: String
    public let sessionID: String
    public let agent: AgentIdentity
    public let toolName: String
    public let summary: String
    public let detail: String
    public let kind: Kind
    /// One spoken sentence of context, said before the prompt sentence.
    ///
    /// Presentation only, and in-process only: no wire message carries it, so a request
    /// that arrived from an agent adapter always has `nil` here. The stop-question path
    /// sets it from a spoken summary of the agent's final reply, and only when a
    /// summarizer is configured — `nil` restores the pre-summary prompt word for word.
    /// It never names what is being authorized; that stays the presenter's own wording
    /// around `summary`.
    public let spokenPreamble: String?
    /// The tool's arguments exactly as the agent sent them; for Bash this holds the
    /// full command text under `command`.
    public let toolInput: [String: JSONValue]?
    /// The agent's working directory when it asked.
    public let cwd: String?
    /// The agent's permission mode string, unnormalized (for example "default", "auto").
    public let permissionMode: String?
    /// Which agent hook event produced this approval.
    public let approvalSource: ApprovalSource?

    /// The context parameters default to nil so callers that only have presentation
    /// strings — and every call site written before the context existed — stay valid.
    public init(id: String, sessionID: String, agent: AgentIdentity = .unknown,
                toolName: String, summary: String, detail: String,
                kind: Kind = .toolApproval,
                spokenPreamble: String? = nil,
                toolInput: [String: JSONValue]? = nil,
                cwd: String? = nil,
                permissionMode: String? = nil,
                approvalSource: ApprovalSource? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.toolName = toolName
        self.summary = summary
        self.detail = detail
        self.kind = kind
        self.spokenPreamble = spokenPreamble
        self.toolInput = toolInput
        self.cwd = cwd
        self.permissionMode = permissionMode
        self.approvalSource = approvalSource
    }
}

/// Interpolating a request must never be a way to leak what it asks for. The synthesized
/// rendering would dump the Bash command line, the working directory, and the spoken
/// summary into whatever string it lands in — a diagnostic field, a log line — so both
/// renderings are pinned to identifying fields only.
extension ApprovalRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ApprovalRequest(id: \(id), agent: \(agent.id), tool: \(toolName), kind: \(kind.rawValue))"
    }

    public var debugDescription: String { description }
}
