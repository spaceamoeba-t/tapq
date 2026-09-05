/// What TapQ can actually do with a given agent, as a fact about its adapter.
///
/// A static table rather than something advertised on the wire, and deliberately so: every
/// shim TapQ talks to is TapQ's own, shipped in this repository and versioned with it, so
/// the set of message types an agent can send and receive is already known here at compile
/// time. A per-connection advertisement would add a handshake to a protocol that has none
/// (one request line, one response line) in exchange for re-learning what this file
/// already states.
///
/// The four capabilities are the four things a wearer can experience, and each is `false`
/// for at least one shipped adapter — which is why the table exists rather than an
/// assumption that every agent can do everything:
///
/// - **approvals** — the agent asks before acting, and a nod can answer. Every adapter.
/// - **questions** — the agent's own questions reach TapQ as something answerable out
///   loud, whether a menu (`selection.request`) or a question in its final reply
///   (`stop.question`). Cursor and OpenCode have no such channel.
/// - **notifications** — the agent can say something that needs no answer.
/// - **instructions** — TapQ can hand the agent a sentence *it* did not ask for. This is
///   the narrowest of the four: it needs a turn boundary the adapter can intercept and
///   restart with new text, which only Claude Code's stop hook and Codex's stop event
///   provide.
///
/// Consumed in two places, for the same reason in both: to refuse honestly rather than
/// silently. The dictation flow reads it before inviting the wearer to speak, so a wearer
/// with no screen hears "Instructions aren't supported for ⟨agent⟩" instead of dictating
/// into nothing; `tapq instruct --agent` reads it before opening a socket, so the operator
/// sees the same fact as an error instead of an accepted submission that never arrives.
public struct AgentCapabilities: Sendable, Equatable {
    /// The agent asks TapQ before it acts.
    public let approvals: Bool
    /// The agent's own questions — menus and questions in a final reply — reach TapQ.
    public let questions: Bool
    /// The agent can announce something that needs no answer.
    public let notifications: Bool
    /// TapQ can deliver a dictated instruction into the agent's session.
    public let instructions: Bool

    public init(approvals: Bool, questions: Bool, notifications: Bool, instructions: Bool) {
        self.approvals = approvals
        self.questions = questions
        self.notifications = notifications
        self.instructions = instructions
    }

    /// Claude Code: approvals, `AskUserQuestion` menus, notifications, and a `Stop` hook
    /// whose block reason restarts the turn — which is what an instruction is delivered as.
    public static let claudeCode = AgentCapabilities(
        approvals: true, questions: true, notifications: true, instructions: true
    )

    /// Codex: the same four, delivered the same way — its Stop hook's block reason
    /// restarts the turn. Its stop event also carries `stop_hook_active`, which the shim
    /// records but no longer acts on (2026-09-04): loop safety is the runtime's.
    public static let codex = AgentCapabilities(
        approvals: true, questions: true, notifications: true, instructions: true
    )

    /// Cursor: approvals and notifications only. Its hook surface has no text-bearing
    /// channel at all — no menu, no final-reply question, nothing to carry an instruction.
    public static let cursor = AgentCapabilities(
        approvals: true, questions: false, notifications: true, instructions: false
    )

    /// OpenCode: approvals and notifications only. The plugin is strictly
    /// event → relay → reply, spawned per event, and OpenCode exposes no documented way to
    /// continue a turn that has already finished — so there is no boundary to deliver into.
    public static let openCode = AgentCapabilities(
        approvals: true, questions: false, notifications: true, instructions: false
    )

    /// A peer that predates agent identity on the wire. It can still ask for approvals and
    /// announce things — that is what it has always done — but nothing may be *sent* to an
    /// agent TapQ cannot name, which is the same fail-closed rule the instruction channel
    /// follows everywhere else.
    public static let unknown = AgentCapabilities(
        approvals: true, questions: false, notifications: true, instructions: false
    )

    /// The capabilities of `agent`, by identity.
    public static func of(_ agent: AgentIdentity) -> AgentCapabilities {
        of(agentID: agent.id)
    }

    /// The capabilities of the adapter with this identifier.
    ///
    /// An unrecognized identifier reads as ``unknown`` rather than as a permissive default:
    /// a third-party shim borrowing the wire is exactly the case where TapQ must not assume
    /// there is a turn boundary waiting to receive a sentence.
    public static func of(agentID: String) -> AgentCapabilities {
        switch agentID {
        case AgentIdentity.claudeCode.id: return .claudeCode
        case AgentIdentity.codex.id: return .codex
        case AgentIdentity.cursor.id: return .cursor
        case AgentIdentity.openCode.id: return .openCode
        default: return .unknown
        }
    }

    /// Every adapter TapQ ships, in documentation order. The capability matrix in
    /// `docs/INTEGRATIONS.md` is this list, and a test pins the two together.
    public static let shippedAgents: [AgentIdentity] = [
        .claudeCode, .codex, .cursor, .openCode,
    ]
}
