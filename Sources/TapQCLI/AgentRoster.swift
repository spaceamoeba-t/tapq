import Foundation
import TapQContracts

/// Which session answers to which agent's name, for the length of time TapQ can honestly
/// claim to know.
///
/// This is the roster in its first form, and its whole content is one simplifying
/// assumption: **at most one live session per adapter**. That assumption is what lets a
/// wearer say "tell Codex to run the tests" and mean something exact — there is one Codex,
/// so naming the adapter names the session. The type's real job is not the happy path but
/// the moment the assumption breaks: a second Codex session makes the name ambiguous, and
/// an ambiguous name resolves to nothing at all rather than to the newer session.
///
/// It is a `Sendable` value type with `mutating` methods, owned by the `@MainActor`
/// ``ConversationMemory`` — the same shape as ``TapQContextBaseline/SessionContextStore``
/// and ``TapQContextBaseline/InstructionQueue``, and for the same reason: no lock, no
/// actor, and no second copy that could disagree about who is live.
///
/// Everything it holds is speech-safe by construction, like every other store on this
/// path. There is nowhere to put a `toolInput`, a `cwd`, or a `permissionMode` — an entry
/// is an opaque session key, an agent identity TapQ already says out loud, and two
/// timestamps.
///
/// It is bounded by time rather than by count. A count bound would evict a session the
/// wearer is actively working in as soon as a fleet grew past it; ``liveness`` evicts the
/// sessions that have stopped talking, which is the same set the wearer has stopped
/// thinking about.
public struct AgentRoster: Sendable {
    /// How long an agent stays addressable by name after TapQ last heard from it.
    ///
    /// Thirty minutes is chosen against the failure it prevents rather than against any
    /// notion of a session's real lifetime, which TapQ cannot observe: nothing on the wire
    /// says a session ended, so an entry can only ever expire on silence. Too short and a
    /// wearer who steps away from a long build cannot address it on their return; too long
    /// and a name keeps resolving to a terminal that was closed an hour ago — the one
    /// outcome that is worse than a refusal, because the sentence is queued and nothing
    /// ever delivers it.
    public static let liveness: TimeInterval = 30 * 60

    /// One agent's live session, in the terms a dictation may be routed by.
    public struct Entry: Sendable, Equatable {
        /// The opaque session key an instruction is queued against.
        public let sessionID: String
        /// The agent behind it. The whole identity and not just the display name, because
        /// routing has to ask ``TapQContracts/AgentCapabilities`` whether this adapter has
        /// a turn boundary at all — a question about the adapter, not about the name.
        public let agent: AgentIdentity
        /// When TapQ last saw traffic from this session, from the roster's caller's clock.
        public let lastSeen: Date
    }

    /// What a spoken name resolved to. `nil` from ``resolve(name:now:)`` is the third
    /// answer — nothing live answers to it.
    public enum Resolution: Sendable, Equatable {
        /// Exactly one live session answers to the name.
        case resolved(Entry)
        /// The adapter has more than one live session, so its name picks out none of them.
        case ambiguous(agentDisplayName: String)
    }

    /// The most recently seen session per agent.
    private var live: [String: Entry] = [:]
    /// The session each agent had *before* the one in `live`, kept only so ambiguity can
    /// be detected and, just as importantly, un-detected.
    ///
    /// One slot and not a list. The question this map answers is "is there a second live
    /// session for this agent?", which a third session cannot make any truer — and a list
    /// would invite a future reader to treat it as a session inventory, which is the
    /// FleetRoster this type is deliberately not yet.
    private var displaced: [String: Entry] = [:]

    public init() {}

    // MARK: - Writing

    /// Notes that TapQ just saw traffic from `sessionID`, belonging to `agent`.
    ///
    /// Called from wherever conversation memory already observes an agent — a window
    /// opening, a notification arriving — rather than from a hook of its own. A roster
    /// that had to be told separately would be a roster that could silently fall behind
    /// the memory it is supposed to describe.
    public mutating func note(sessionID: String, agent: AgentIdentity, at now: Date) {
        let entry = Entry(sessionID: sessionID, agent: agent, lastSeen: now)
        guard let current = live[agent.id] else {
            live[agent.id] = entry
            return
        }
        guard current.sessionID != sessionID else {
            live[agent.id] = entry
            return
        }
        // A different session for an agent that already has one. If the one on record has
        // gone quiet past the liveness window it is not a rival, it is history: the new
        // session takes the slot outright and the agent is unambiguous again.
        if Self.isExpired(current, at: now) {
            displaced.removeValue(forKey: agent.id)
        } else {
            displaced[agent.id] = current
        }
        live[agent.id] = entry
    }

    // MARK: - Reading

    /// The session that answers to `name`, the fact that two do, or `nil` for a name
    /// nothing live answers to.
    ///
    /// Matching is on the display name or its first word, case-insensitively and on
    /// letters and digits only — "codex", "Codex.", and "CODEX" are one name, and "claude"
    /// reaches "Claude Code". It is deliberately not fuzzy: a near-miss that routed a
    /// sentence into the wrong agent's session is the failure this whole path is shaped to
    /// avoid, and a near-miss that refuses costs the wearer one repeat.
    ///
    /// Two adapters answering to the same spoken name resolve to ``Resolution/ambiguous``
    /// for the same reason two sessions of one adapter do. Nothing shipped collides, but
    /// the fail-closed answer must not depend on that staying true.
    public func resolve(name: String, now: Date) -> Resolution? {
        let spoken = Self.normalized(name)
        guard !spoken.isEmpty else { return nil }
        let matches = live.values
            .filter { !Self.isExpired($0, at: now) && Self.matches(spoken, $0.agent) }
            .sorted { $0.agent.id < $1.agent.id }
        guard let match = matches.first else { return nil }
        guard matches.count == 1 else {
            return .ambiguous(agentDisplayName: match.agent.displayName)
        }
        guard !isAmbiguous(agentID: match.agent.id, at: now) else {
            return .ambiguous(agentDisplayName: match.agent.displayName)
        }
        return .resolved(match)
    }

    /// The agent's live session, or `nil` when it has none or has gone quiet. For tests
    /// and diagnostics; routing goes through ``resolve(name:now:)``.
    public func entry(agentID: String, at now: Date) -> Entry? {
        guard let entry = live[agentID], !Self.isExpired(entry, at: now) else { return nil }
        return entry
    }

    /// Whether a second session has been seen for this agent recently enough that its name
    /// picks out neither. Reads the clock rather than a stored flag, so an agent becomes
    /// unambiguous again the moment the rival session ages out — no sweep, no timer, and
    /// no state that can be left behind by one.
    public func isAmbiguous(agentID: String, at now: Date) -> Bool {
        guard let other = displaced[agentID] else { return false }
        return !Self.isExpired(other, at: now)
    }

    /// Every agent with a live session, sorted by identifier. For diagnostics.
    public func liveEntries(at now: Date) -> [Entry] {
        live.values
            .filter { !Self.isExpired($0, at: now) }
            .sorted { $0.agent.id < $1.agent.id }
    }

    // MARK: - Internals

    private static func isExpired(_ entry: Entry, at now: Date) -> Bool {
        now.timeIntervalSince(entry.lastSeen) > liveness
    }

    /// Whether a spoken name picks out this agent: its whole display name, or the first
    /// word of it.
    private static func matches(_ spoken: String, _ agent: AgentIdentity) -> Bool {
        let display = agent.displayName
        if normalized(display) == spoken { return true }
        guard let first = display.split(whereSeparator: \.isWhitespace).first else {
            return false
        }
        return normalized(first) == spoken
    }

    /// Lowercased letters and digits only, so punctuation a recognizer added cannot hide a
    /// match. The same normalization the dictation flow's address parser compares with.
    private static func normalized<S: StringProtocol>(_ text: S) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
