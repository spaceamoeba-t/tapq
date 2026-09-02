import Foundation
import TapQContracts

/// Which session answers to which agent's name: the one that has TapQ's focus.
///
/// This is the roster in its second form (`docs/SESSION_FOCUS_PLAN.md`). The first form
/// rested on one assumption — at most one live session per adapter — and spent its whole
/// mechanism on the moment that assumption broke: a second Codex session made the name
/// *ambiguous*, and an ambiguous name resolved to nothing at all. That was honest and it was
/// a trap. A wearer who opened a second terminal, or asked TapQ to start a session, lost the
/// ability to address the agent by name until one of the two went quiet for half an hour.
///
/// Focus replaces ambiguity. **Exactly one session per agent has the focus**, and the name
/// resolves to it, always. **Newest wins**: a session TapQ has never heard from takes the
/// focus the moment it speaks, and the session that had it is *detached* — it stays on the
/// books so that its later traffic is recognized as a detached session's and moves nothing.
/// Detach is not an ending: the session's transcript, its terminal, and its process are all
/// exactly where they were. It has only lost the wearer's ear.
///
/// One exception, and it is the trap's other half. A detached session whose replacement has
/// gone quiet past ``liveness`` is the only session again — the terminal that replaced it
/// was closed, or the session TapQ started has ended (``endSession(sessionID:)``). There is
/// nothing left to be loyal to, so its next traffic takes the focus back rather than being
/// ignored until the wearer restarts TapQ.
///
/// It is a `Sendable` value type with `mutating` methods, owned by the `@MainActor`
/// ``ConversationMemory`` — the same shape as ``TapQContextBaseline/SessionContextStore``
/// and ``TapQContextBaseline/InstructionQueue``, and for the same reason: no lock, no
/// actor, and no second copy that could disagree about who has the focus.
///
/// Everything it holds is speech-safe by construction, like every other store on this
/// path. There is nowhere to put a `toolInput`, a `cwd`, or a `permissionMode` — an entry
/// is an opaque session key, an agent identity TapQ already says out loud, and a timestamp.
public struct AgentRoster: Sendable {
    /// How long a focused session stays addressable by name after TapQ last heard from it.
    ///
    /// Thirty minutes is chosen against the failure it prevents rather than against any
    /// notion of a session's real lifetime, which TapQ cannot observe: nothing on the wire
    /// says a keyboard session ended, so an entry can only ever expire on silence. Too short
    /// and a wearer who steps away from a long build cannot address it on their return; too
    /// long and a name keeps resolving to a terminal that was closed an hour ago — the one
    /// outcome that is worse than a refusal, because the sentence is queued and nothing
    /// ever delivers it.
    public static let liveness: TimeInterval = 30 * 60

    /// How many detached session keys are remembered.
    ///
    /// A bound on a list of opaque strings that grows by one per session the wearer moves
    /// on from. Thirty-two is a day of unusually restless work; past it the oldest key is
    /// forgotten, and a session that old speaking again would be treated as new — which is
    /// the same answer it would get after a restart.
    public static let detachedCapacity = 32

    /// One agent's focused session, in the terms a dictation may be routed by.
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
        /// Exactly one focused session answers to the name.
        case resolved(Entry)
        /// Two *adapters* answer to the same spoken name, so it picks out neither. Nothing
        /// shipped collides, but the fail-closed answer must not depend on that staying
        /// true. Two sessions of one adapter no longer reach this case: the focus decides.
        case ambiguous(agentDisplayName: String)
    }

    /// What noting traffic from a session did to the focus.
    public enum Arrival: Sendable, Equatable {
        /// The focused session, refreshed. Nothing moved.
        case focused
        /// The session took the focus: it is new to this roster, or it is a detached
        /// session speaking again after its replacement went quiet. `displacing` is the
        /// session that had the focus and is now detached, or `nil` when there was none —
        /// an agent's first session, or a focus that had already expired.
        case tookFocus(displacing: Entry?)
        /// A detached session. Nothing moved, and the caller answers it as detached.
        case detached
    }

    /// The focused session per agent, by agent identifier.
    private var live: [String: Entry] = [:]
    /// Sessions that had the focus and lost it, oldest first. Keys only: a detached
    /// session is recognized, not described.
    private var detached: [String] = []

    public init() {}

    // MARK: - Writing

    /// Notes that TapQ just saw traffic from `sessionID`, belonging to `agent`, and says
    /// what that did to the focus.
    ///
    /// Called from wherever conversation memory already observes an agent — a window
    /// opening, a notification arriving, and since session focus, the head of every broker
    /// handler — rather than from a hook of its own. A roster that had to be told
    /// separately would be a roster that could silently fall behind the memory it is
    /// supposed to describe.
    @discardableResult
    public mutating func note(sessionID: String, agent: AgentIdentity, at now: Date)
        -> Arrival
    {
        let entry = Entry(sessionID: sessionID, agent: agent, lastSeen: now)
        let current = live[agent.id]
        if let current, current.sessionID == sessionID {
            live[agent.id] = entry
            return .focused
        }
        if isDetached(sessionID: sessionID) {
            // The exception: nothing live is left for this agent, so the detached session
            // is the only one again and takes the focus back. Otherwise it stays detached.
            guard current == nil || Self.isExpired(current!, at: now) else { return .detached }
            forgetDetached(sessionID)
            live[agent.id] = entry
            return .tookFocus(displacing: nil)
        }
        // A session this roster has never heard from. Newest wins: it takes the focus, and
        // whatever had it is detached — unless that one had already gone quiet past the
        // liveness window, in which case it is history rather than a session to detach.
        live[agent.id] = entry
        guard let current, !Self.isExpired(current, at: now) else {
            return .tookFocus(displacing: nil)
        }
        rememberDetached(current.sessionID)
        return .tookFocus(displacing: current)
    }

    /// Gives `sessionID` the focus before it has spoken: TapQ started it and chose its key.
    ///
    /// The session that had the focus is detached, exactly as ``note(sessionID:agent:at:)``
    /// would detach it, and handed back so the caller can release what it was holding.
    /// `nil` when nothing live had the focus.
    @discardableResult
    public mutating func focus(sessionID: String, agent: AgentIdentity, at now: Date)
        -> Entry?
    {
        forgetDetached(sessionID)
        let current = live[agent.id]
        live[agent.id] = Entry(sessionID: sessionID, agent: agent, lastSeen: now)
        guard let current, current.sessionID != sessionID,
              !Self.isExpired(current, at: now)
        else { return nil }
        rememberDetached(current.sessionID)
        return current
    }

    /// Records that a session is detached without its having been displaced here: read
    /// back from the session book at startup, so a restart does not hand the focus to
    /// whichever session happens to speak first.
    public mutating func markDetached(sessionID: String) {
        guard !live.values.contains(where: { $0.sessionID == sessionID }) else { return }
        rememberDetached(sessionID)
    }

    /// Notes that a session is over — its process exited — so the focus it held is free
    /// for the next session to speak, rather than sitting on a dead key for half an hour.
    /// A detached session that ends is simply forgotten.
    public mutating func endSession(sessionID: String) {
        forgetDetached(sessionID)
        for (agentID, entry) in live where entry.sessionID == sessionID {
            live.removeValue(forKey: agentID)
        }
    }

    // MARK: - Reading

    /// The focused session that answers to `name`, the fact that two adapters do, or `nil`
    /// for a name nothing live answers to.
    ///
    /// Matching is on the display name or its first word, case-insensitively and on
    /// letters and digits only — "codex", "Codex.", and "CODEX" are one name, and "claude"
    /// reaches "Claude Code". It is deliberately not fuzzy: a near-miss that routed a
    /// sentence into the wrong agent's session is the failure this whole path is shaped to
    /// avoid, and a near-miss that refuses costs the wearer one repeat.
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
        return .resolved(match)
    }

    /// The agent's focused session, or `nil` when it has none or it has gone quiet.
    public func entry(agentID: String, at now: Date) -> Entry? {
        guard let entry = live[agentID], !Self.isExpired(entry, at: now) else { return nil }
        return entry
    }

    /// Whether `sessionID` had the focus and lost it. Read at the head of every broker
    /// handler: a detached session's hooks are answered at once and in silence.
    public func isDetached(sessionID: String) -> Bool {
        detached.contains { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
    }

    /// Every agent with a focused session, sorted by identifier. For diagnostics.
    public func liveEntries(at now: Date) -> [Entry] {
        live.values
            .filter { !Self.isExpired($0, at: now) }
            .sorted { $0.agent.id < $1.agent.id }
    }

    // MARK: - Internals

    private mutating func rememberDetached(_ sessionID: String) {
        forgetDetached(sessionID)
        detached.append(sessionID)
        if detached.count > Self.detachedCapacity {
            detached.removeFirst(detached.count - Self.detachedCapacity)
        }
    }

    private mutating func forgetDetached(_ sessionID: String) {
        detached.removeAll { $0.caseInsensitiveCompare(sessionID) == .orderedSame }
    }

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
