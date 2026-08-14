import Foundation
import TapQContracts

/// Who is waiting for the wearer's attention, right now.
///
/// `InteractionGate` serializes windows as a chain of tasks and keeps no record of what is
/// queued behind the one it is running, so "who's waiting?" had nothing to read. This is
/// that record: one entry per request that has entered the gate and not yet left it,
/// wrapped around the gate's call sites by whoever composes them.
///
/// Speech-safe by construction, the same way `SessionContextStore`'s events are: an entry
/// holds an agent identity and the session ID it arrived under, and there is no field on it
/// that a tool input, a working directory, or a permission mode could ride into an
/// utterance. The session ID is a lookup key and never speech — what the wearer hears is a
/// display name and a count.
@MainActor public final class SessionWaitRegistry {
    /// A claim on one waiting slot, handed out by `begin` and surrendered to `end`.
    ///
    /// A token rather than the session ID because the same session can legitimately be
    /// waiting twice (Claude Code fires parallel tool calls in one response, and the gate
    /// queues them), and ending "the wait for session s" would then close the wrong one.
    public struct Token: Sendable, Hashable {
        fileprivate let value: UInt64
    }

    /// One waiting request, in the only two terms that may be spoken about it.
    public struct Waiter: Sendable, Equatable {
        /// Opaque. Present so a caller can ask about *this* session; never spoken.
        public let sessionID: String
        public let agent: AgentIdentity

        public init(sessionID: String, agent: AgentIdentity) {
            self.sessionID = sessionID
            self.agent = agent
        }
    }

    private var order: [Token] = []
    private var entries: [Token: Waiter] = [:]
    private var nextValue: UInt64 = 0

    public init() {}

    /// Registers a request as waiting and returns the token that ends the wait.
    ///
    /// The caller is expected to `defer { end(token:) }` around the gated body, so a body
    /// that throws or is cancelled still leaves the registry empty. Nothing here expires on
    /// its own: an entry that is never ended is a leaked wait, which is why the pairing
    /// belongs in a `defer` and not at the bottom of a happy path.
    public func begin(sessionID: String, agent: AgentIdentity) -> Token {
        nextValue += 1
        let token = Token(value: nextValue)
        entries[token] = Waiter(sessionID: sessionID, agent: agent)
        order.append(token)
        return token
    }

    /// Releases a slot. Idempotent, and silent about tokens it does not know: `defer`-based
    /// pairing means `end` can be reached twice on unwind paths, and a registry that
    /// trapped there would turn a bookkeeping detail into a crashed runtime.
    public func end(token: Token) {
        guard entries.removeValue(forKey: token) != nil else { return }
        order.removeAll { $0 == token }
    }

    /// Everything waiting, oldest first — the order the gate will reach them in.
    public var waiting: [Waiter] {
        order.compactMap { entries[$0] }
    }

    /// How many requests are waiting, including the one being answered.
    public var waitingCount: Int { order.count }

    /// How many *other* requests are waiting — the count a status line reports after
    /// naming the request in hand ("2 more waiting").
    public func waitingCount(excluding token: Token) -> Int {
        entries[token] == nil ? order.count : order.count - 1
    }

    /// The display names of the agents waiting, oldest first, each named once however many
    /// of its sessions are queued. A wearer hearing "Claude Code, Claude Code, Codex" learns
    /// nothing the count did not already tell them.
    public var waitingAgentNames: [String] {
        var seen = Set<String>()
        return waiting.compactMap { seen.insert($0.agent.displayName).inserted ? $0.agent.displayName : nil }
    }

    /// The agent behind a session, for a caller composing a line about that session
    /// specifically. `nil` once the session's last wait has ended.
    public func agentDisplayName(forSession sessionID: String) -> String? {
        waiting.first { $0.sessionID == sessionID }?.agent.displayName
    }
}
