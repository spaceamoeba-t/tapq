import Foundation
import TapQContracts

/// One speech-safe thing that happened in a session: what the agent asked for, and
/// what the wearer's hands-free answer was.
///
/// The redaction contract on ``TapQContracts/ApprovalRequest`` — `toolInput`, `cwd`,
/// and `permissionMode` must never reach diagnostics or speech — is enforced here by
/// construction rather than by discipline: this type has nowhere to put them. Every
/// field is something TapQ already says out loud, so prose composed from these events
/// is speakable without a second redaction pass.
public struct SessionContextEvent: Sendable, Equatable {
    /// Which interaction produced the event. It changes only the recall phrasing.
    public enum Kind: String, Sendable, Equatable {
        /// A yes/no approval window.
        case approval
        /// A multi-option selection window.
        case selection
        /// A free-text answer to a question found in the agent's final reply.
        case stopAnswer
        /// A non-blocking spoken update; nothing was decided.
        case notification
        /// An instruction the wearer dictated, delivered to the agent at a turn
        /// boundary. Nothing was authorized: an instruction is work the agent is asked
        /// to do, and it still asks permission for every action inside it.
        case instruction
    }

    /// How the interaction ended, in the wearer's terms.
    ///
    /// There is deliberately no "still open" case: an event is recorded at the moment
    /// an interaction resolves, so every recorded event has an outcome to speak.
    public enum Outcome: Sendable, Equatable {
        /// The wearer approved the action.
        case allowed
        /// The wearer denied the action.
        case denied
        /// No hands-free answer — the agent's own on-screen prompt decides. This is
        /// also where a timed-out window lands.
        case deferred
        /// The labels the wearer chose, in the order the runtime reported them.
        case chose([String])
        /// A free-text spoken answer.
        case answered(String)
        /// Nothing was decided; TapQ only said something out loud.
        case noted
        /// The wearer's dictated instruction reached the agent.
        case instructed
    }

    /// Spoken budget for `summary`, `toolName`, and each choice label. Shared with
    /// ``SpokenSummary`` so recall speech obeys the same per-sentence budget as the
    /// summaries it recalls.
    public static let summaryCharacterLimit = SpokenSummary.sentenceCharacterLimit
    /// Spoken budget for `detail`, shared with ``SpokenSummary/detailCharacterLimit``.
    public static let detailCharacterLimit = SpokenSummary.detailCharacterLimit

    public let kind: Kind
    /// The agent's display name ("Claude Code"), never its opaque session identifier.
    public let agentDisplayName: String
    /// The short spoken phrase describing what was asked ("run npm test").
    public let summary: String
    /// The longer spoken context, when the interaction had one. May be empty.
    public let detail: String
    /// The tool name as the adapter rendered it ("Bash"). May be empty.
    public let toolName: String
    public let outcome: Outcome
    /// When the interaction resolved, from the recording store's clock.
    public let timestamp: Date

    /// Normalizes whitespace and truncates every text field to its cap.
    ///
    /// As with ``SpokenSummary``, the truncation lives in the only initializer: no
    /// caller can put an essay — or a newline that would confuse a digest — into a
    /// recalled event.
    public init(
        kind: Kind,
        agentDisplayName: String,
        summary: String,
        detail: String = "",
        toolName: String = "",
        outcome: Outcome,
        timestamp: Date
    ) {
        self.kind = kind
        self.agentDisplayName = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(agentDisplayName),
            limit: Self.summaryCharacterLimit
        )
        self.summary = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(summary),
            limit: Self.summaryCharacterLimit
        )
        self.detail = SpokenSummaryText.cappedDetail(detail)
        self.toolName = SpokenSummaryText.truncated(
            SpokenSummaryText.normalized(toolName),
            limit: Self.summaryCharacterLimit
        )
        self.outcome = Self.capped(outcome)
        self.timestamp = timestamp
    }

    private static func capped(_ outcome: Outcome) -> Outcome {
        switch outcome {
        case .allowed, .denied, .deferred, .noted, .instructed:
            return outcome
        case let .chose(labels):
            let cleaned = labels
                .map {
                    SpokenSummaryText.truncated(
                        SpokenSummaryText.normalized($0),
                        limit: summaryCharacterLimit
                    )
                }
                .filter { !$0.isEmpty }
            return cleaned.isEmpty ? .deferred : .chose(cleaned)
        case let .answered(text):
            let cleaned = SpokenSummaryText.truncated(
                SpokenSummaryText.normalized(text),
                limit: summaryCharacterLimit
            )
            return cleaned.isEmpty ? .deferred : .answered(cleaned)
        }
    }
}

/// A bounded, speech-safe memory of what each session asked and how it was answered.
///
/// The shape mirrors ``AnsweredQuestionStore``: a `Sendable` value type with `mutating`
/// methods, owned by the `@MainActor` runtime, so recall needs no lock and no actor of
/// its own. Two bounds keep a long-running fleet from growing this without limit —
/// ``eventCapacity`` events per session and ``sessionCapacity`` sessions — and both
/// evict first-in-first-out.
///
/// Session eviction is by *first appearance*, not by last use: a session that has been
/// tracked since startup is evicted before a session first seen a minute ago. That is
/// the ratified rule (RB1) and it keeps eviction independent of recording order, at the
/// cost of occasionally forgetting a still-busy long-lived session. Recall degrades to
/// "nothing recorded" when that happens, which is a safe answer.
public struct SessionContextStore: Sendable {
    /// Events retained per session before the oldest is dropped.
    public static let eventCapacity = 16
    /// Sessions retained before the first-seen session is dropped whole.
    public static let sessionCapacity = 8

    private var sessionOrder: [String] = []
    private var eventsBySession: [String: [SessionContextEvent]] = [:]
    /// Sessions whose agent launched background work since its last finished boundary.
    /// Membership only — nothing of the command is kept, per the redaction contract.
    private var backgroundWorkLaunched: Set<String> = []
    /// Sessions whose agent is mid-turn: something was asked or delivered since the last
    /// boundary that ended a turn. Membership only, like the set above.
    private var openTurns: Set<String> = []
    /// Sessions whose last finished boundary closed over background work still running —
    /// the flag above, consumed there and kept here until the boundary after it.
    private var workRunningPastBoundary: Set<String> = []
    private let clock: @Sendable () -> Date

    /// What a `finished` boundary closed over.
    ///
    /// An agent's turn and the work it started are not the same thing: a turn that launched
    /// a background command ends the moment the launch returns, minutes before the command
    /// does. Anything that waits for "finished" — a follow-up above all — needs to know
    /// which of the two it just heard, and this is the store's answer, settled from the
    /// approvals it recorded during the turn.
    public enum TurnEnding: Sendable, Equatable {
        /// The turn ended and nothing it started is known to be still running.
        case complete
        /// The turn ended with background work it launched still running. The next
        /// finished boundary of the same session is reported as ``complete`` unless
        /// another launch happens first.
        case leftWorkRunning
    }

    /// - Parameter clock: the timestamp source for recorded events. Tests inject a
    ///   fixed or stepping clock; the runtime takes the default wall clock.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    // MARK: - Recording

    /// Records an already-stamped event, evicting by both bounds.
    public mutating func record(_ event: SessionContextEvent, session: String) {
        // An approval, a selection, a stop answer, or an instruction is a turn in
        // progress; only a boundary notification closes one, and `record(notification:)`
        // settles that below before reaching here.
        if event.kind != .notification { openTurns.insert(session) }
        var list = eventsBySession[session] ?? []
        if list.isEmpty { sessionOrder.append(session) }
        list.append(event)
        if list.count > Self.eventCapacity {
            list.removeFirst(list.count - Self.eventCapacity)
        }
        eventsBySession[session] = list
        evictOldestSessions()
    }

    /// Records an event stamped with the store's clock.
    public mutating func record(
        session: String,
        kind: SessionContextEvent.Kind,
        agentDisplayName: String,
        summary: String,
        detail: String = "",
        toolName: String = "",
        outcome: SessionContextEvent.Outcome
    ) {
        record(
            SessionContextEvent(
                kind: kind,
                agentDisplayName: agentDisplayName,
                summary: summary,
                detail: detail,
                toolName: toolName,
                outcome: outcome,
                timestamp: clock()
            ),
            session: session
        )
    }

    /// Records a resolved approval window, copying only the request's speech-safe
    /// fields. This overload is the reason the runtime never has to remember which
    /// `ApprovalRequest` fields are unspeakable.
    public mutating func record(approval: ApprovalRequest, decision: Decision) {
        // A denied launch never ran; an approved or on-screen-deferred one may have. The
        // flag is settled — and forgotten — by the session's next finished boundary.
        if decision != .deny, approval.launchesBackgroundWork {
            backgroundWorkLaunched.insert(approval.sessionID)
        }
        record(
            session: approval.sessionID,
            kind: .approval,
            agentDisplayName: approval.agent.displayName,
            summary: approval.summary,
            detail: approval.detail,
            toolName: approval.toolName,
            outcome: Self.outcome(for: decision)
        )
    }

    /// Records a resolved selection window. A timed-out result and a result with no
    /// choices both land on ``SessionContextEvent/Outcome/deferred``; a free-text
    /// resolution is recorded as the spoken answer.
    public mutating func record(selection: SelectionRequest, result: SelectionResult) {
        record(
            session: selection.sessionID,
            kind: .selection,
            agentDisplayName: selection.agent.displayName,
            summary: selection.question,
            outcome: Self.outcome(for: result)
        )
    }

    /// Records a free-text answer to a question found in the agent's final reply.
    public mutating func recordStopAnswer(
        session: String,
        agent: AgentIdentity,
        question: String,
        detail: String = "",
        answer: String
    ) {
        record(
            session: session,
            kind: .stopAnswer,
            agentDisplayName: agent.displayName,
            summary: question,
            detail: detail,
            outcome: .answered(answer)
        )
    }

    /// Records an instruction at the moment it is handed to the agent.
    ///
    /// Recorded on delivery rather than on dictation, for the same reason every other
    /// event is recorded at resolution: until the agent's turn boundary comes around,
    /// a queued instruction is still something that might be dropped at capacity, and
    /// recall that said "you told it to run the tests" about a sentence the agent never
    /// received would be inventing a conversation.
    ///
    /// The text is the instruction itself, which is speech-safe by construction — it is
    /// what the wearer said and what TapQ read back to them before queueing it.
    public mutating func recordInstruction(
        session: String,
        agent: AgentIdentity,
        text: String
    ) {
        record(
            session: session,
            kind: .instruction,
            agentDisplayName: agent.displayName,
            summary: text,
            outcome: .instructed
        )
    }

    /// Records a spoken notification. Nothing was decided, so the outcome is `noted`
    /// and the summary falls back to a phrase for the notification's kind.
    ///
    /// - Returns: for a `finished` notification, what the turn closed over — settled here
    ///   because this is the one place every boundary passes through, so the flag a
    ///   background launch set is consumed exactly once whether or not anyone was waiting
    ///   on it. `nil` for every other kind.
    @discardableResult
    public mutating func record(notification: AgentNotification) -> TurnEnding? {
        var ending: TurnEnding?
        if notification.kind == .finished {
            let leftRunning = backgroundWorkLaunched.remove(notification.sessionID) != nil
            ending = leftRunning ? .leftWorkRunning : .complete
            if leftRunning {
                workRunningPastBoundary.insert(notification.sessionID)
            } else {
                workRunningPastBoundary.remove(notification.sessionID)
            }
        }
        switch notification.kind {
        case .finished, .waitingForInput:
            openTurns.remove(notification.sessionID)
        case .permissionWaiting:
            openTurns.insert(notification.sessionID)
        }
        let summary = notification.summary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = ending == .leftWorkRunning
            ? Self.finishedWithWorkRunningPhrase
            : Self.phrase(for: notification.kind)
        record(
            session: notification.sessionID,
            kind: .notification,
            agentDisplayName: notification.agent.displayName,
            summary: summary.isEmpty ? fallback : summary,
            outcome: .noted
        )
        return ending
    }

    // MARK: - Reading

    /// Every retained event for a session, oldest first. Empty for an unknown or
    /// evicted session.
    public func events(session: String) -> [SessionContextEvent] {
        eventsBySession[session] ?? []
    }

    /// At most `limit` events for a session, newest first — the order recall speaks
    /// them in.
    public func recent(session: String, limit: Int) -> [SessionContextEvent] {
        guard limit > 0 else { return [] }
        return Array(events(session: session).suffix(limit).reversed())
    }

    /// The tracked sessions in first-seen order.
    public var trackedSessions: [String] { sessionOrder }

    /// Whether the session's agent is in the middle of a turn, or left background work
    /// running at its last boundary — as far as the events TapQ saw can say.
    ///
    /// What "start a new session" asks before detaching the focused one
    /// (`docs/SESSION_FOCUS_PLAN.md` §1, rule 5): a session that is mid-task is one the
    /// wearer may not want to walk away from, so TapQ confirms first. A session TapQ has
    /// never heard from, or whose last event was a boundary, is idle here. The answer is
    /// only as good as the hooks: an agent whose turn ended without a Stop reaching the
    /// broker reads as mid-task until its next boundary, which errs toward one extra
    /// question rather than one silent detach.
    public func isMidTask(session: String) -> Bool {
        openTurns.contains(session) || backgroundWorkLaunched.contains(session)
            || workRunningPastBoundary.contains(session)
    }

    // MARK: - Internals

    private mutating func evictOldestSessions() {
        while sessionOrder.count > Self.sessionCapacity {
            let evicted = sessionOrder.removeFirst()
            eventsBySession.removeValue(forKey: evicted)
            backgroundWorkLaunched.remove(evicted)
            openTurns.remove(evicted)
            workRunningPastBoundary.remove(evicted)
        }
    }

    /// The recall phrase for a turn that ended with its background work still going —
    /// "Claude Code reported finished, with work still running in the background." — so
    /// "what changed?" does not read a turn end as the work being done.
    static let finishedWithWorkRunningPhrase =
        "finished, with work still running in the background"

    private static func outcome(for decision: Decision) -> SessionContextEvent.Outcome {
        switch decision {
        case .allow: return .allowed
        case .deny: return .denied
        case .ask: return .deferred
        }
    }

    private static func outcome(
        for result: SelectionResult
    ) -> SessionContextEvent.Outcome {
        if let freeText = result.freeText, !freeText.isEmpty, result.choices.isEmpty {
            return .answered(freeText)
        }
        guard !result.choices.isEmpty else { return .deferred }
        return .chose(result.choices.map(\.label))
    }

    private static func phrase(for kind: AgentNotification.Kind) -> String {
        switch kind {
        case .waitingForInput: return "waiting for input"
        case .permissionWaiting: return "waiting for permission"
        case .finished: return "finished"
        }
    }
}
