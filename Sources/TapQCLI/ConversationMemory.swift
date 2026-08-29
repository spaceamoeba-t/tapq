import Foundation
import TapQContextBaseline
import TapQContracts
import TapQInteractionBaseline

/// What the runtime remembers about the sessions it is serving, and everything it says
/// out loud from that memory.
///
/// Three pieces that only make sense together live here: the bounded per-session event
/// ring (`SessionContextStore`), the record of who is queued at the interaction gate
/// (`SessionWaitRegistry`), and the request that is being asked about right now. Recall
/// needs all three — "what changed" reads the ring for *this* session, "who's waiting"
/// reads the registry, and both need to know which session the wearer is inside — so
/// composing them anywhere else would mean three objects wired into four call sites each.
///
/// It is a reference type because the runtime's gate call sites are closures over locals,
/// not methods on the service: a captured `var` store would be copied into each closure
/// and every recording would be written to a different memory.
///
/// Everything it can say is speech-safe by construction. The store's events have nowhere
/// to put a `toolInput`, a `cwd`, or a `permissionMode`; the registry holds an agent
/// identity and an opaque session key; the roster holds the same two and a pair of
/// timestamps; and the open-window text is the summary and detail TapQ already speaks. No
/// composition here needs a redaction pass because no unsafe field ever reaches it.
@MainActor public final class ConversationMemory {
    /// A claim on one open window, surrendered to ``endWindow(_:)``.
    ///
    /// It wraps the registry's token rather than the session ID because one session can
    /// legitimately have two requests queued at once (parallel tool calls in a single
    /// agent response), and closing "the window for session s" would then close the
    /// wrong one.
    public struct WindowToken: Sendable, Hashable {
        fileprivate let registryToken: SessionWaitRegistry.Token
    }

    /// The request a window is open for, in the terms recall may speak about it.
    ///
    /// The whole `AgentIdentity` and not just its display name: dictation asks whether
    /// *this* agent can be instructed at all, and that is a question about the adapter
    /// behind the identifier, not about the name TapQ says out loud.
    private struct OpenWindow {
        let sessionID: String
        let agent: AgentIdentity
        let summary: String
        let detail: String

        var agentDisplayName: String { agent.displayName }
    }

    /// Who is queued at the gate. Exposed so a composition that wants the counts for
    /// something other than speech — a diagnostic line, a future fleet view — reads the
    /// same registry recall reads, rather than a second one that could disagree.
    public let waitRegistry = SessionWaitRegistry()

    /// Instructions dictated into these sessions and not yet delivered, or `nil` when the
    /// run was started without `--voice-instructions`.
    ///
    /// Held here because everything that touches an instruction already has to know which
    /// session is being spoken into, and that is what this object tracks. `nil` is the
    /// inert composition and it is inert all the way down: the dictation closure below is
    /// absent, so the flow returns before it says anything; the status line has no count to
    /// add; and the coordinator this run builds has no mailbox to drain.
    public let instructions: InstructionMailbox?

    /// Approvals the delegation filter answered without asking, this run.
    ///
    /// A plain count and not a list: the list is `AutoAnswerLog`, which is on disk, is
    /// greppable, and says which tool and which threshold. What the wearer can be told out
    /// loud in one breath is the number, and the number is what makes them go and read the
    /// file. Zero without `--auto-answer routine`, which is what keeps the status sentence
    /// byte-identical to Rung C's.
    public private(set) var autoAnsweredCount = 0

    /// The last request TapQ opened a window for, kept after that window closes.
    ///
    /// It exists for the one window nobody was asked to open: an attention window (RD3)
    /// happens *between* requests, so `dictationTarget` — which reads the open window — has
    /// nothing to answer with, and a wearer saying "tell it to run the tests too" would be
    /// refused for having no addressee. The agent whose request TapQ handled most recently
    /// is the only agent they can mean; there is no second candidate to disambiguate
    /// against, and guessing between candidates is exactly what this does not do.
    private var lastTarget: (sessionID: String, agent: AgentIdentity)?

    /// Which session answers to which agent's name, so a dictation can be addressed to an
    /// agent other than the one in front of the wearer.
    ///
    /// It is filled from the traffic this object already watches — see ``noteAgentSeen``
    /// — rather than from a subscription of its own, because a roster that could fall
    /// behind conversation memory would be a roster that disagreed with what recall says
    /// out loud. Read only through ``instructionAddressResolver``; nothing else in the
    /// runtime needs to know who is live.
    private var roster = AgentRoster()

    /// The clock, kept as well as handed to the store: the roster's liveness window is
    /// answered in wall time, and tests that drive a virtual clock must be able to age an
    /// entry out without waiting half an hour.
    private let clock: @Sendable () -> Date

    private var store: SessionContextStore
    private var windows: [WindowToken: OpenWindow] = [:]
    /// Open windows in the order they entered the gate. The gate is FIFO, so the first
    /// element is the request currently being asked about — which is the session recall
    /// answers for.
    private var openOrder: [WindowToken] = []

    /// - Parameters:
    ///   - clock: timestamp source for recorded events, injected by tests.
    ///   - instructions: the run's instruction queue, or `nil` without
    ///     `--voice-instructions` — which is the default, and byte-for-byte the Rung B
    ///     composition.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        instructions: InstructionMailbox? = nil
    ) {
        self.store = SessionContextStore(clock: clock)
        self.clock = clock
        self.instructions = instructions
    }

    /// The one place the roster learns that a session is alive.
    ///
    /// Both callers are traffic this object already had to observe — a window opening
    /// (every approval, selection, and stop question) and a notification arriving (the one
    /// kind of message that never opens a window). Between them they cover every way an
    /// agent can reach TapQ, which is what makes "TapQ has heard from this session" and
    /// "this session is in the roster" the same statement.
    private func noteAgentSeen(sessionID: String, agent: AgentIdentity) {
        roster.note(sessionID: sessionID, agent: agent, at: clock())
    }

    // MARK: - Window lifecycle

    /// Registers a request as waiting for the wearer and remembers what it is about.
    ///
    /// Called *before* the interaction gate, not inside it: a request queued behind three
    /// others is waiting for the wearer in every sense the question "who's waiting?"
    /// means, and a registry that only counted the one being spoken would always answer
    /// "one".
    ///
    /// The caller pairs this with `defer { endWindow(token) }` so a cancelled or throwing
    /// body still leaves the registry empty.
    public func beginWindow(
        sessionID: String,
        agent: AgentIdentity,
        summary: String,
        detail: String = ""
    ) -> WindowToken {
        let token = WindowToken(
            registryToken: waitRegistry.begin(sessionID: sessionID, agent: agent)
        )
        windows[token] = OpenWindow(
            sessionID: sessionID,
            agent: agent,
            summary: summary,
            detail: detail
        )
        openOrder.append(token)
        lastTarget = (sessionID, agent)
        noteAgentSeen(sessionID: sessionID, agent: agent)
        return token
    }

    /// Releases a window. Idempotent, for the same reason `SessionWaitRegistry.end` is:
    /// `defer`-based pairing can be reached twice on an unwind path.
    public func endWindow(_ token: WindowToken) {
        waitRegistry.end(token: token.registryToken)
        guard windows.removeValue(forKey: token) != nil else { return }
        openOrder.removeAll { $0 == token }
    }

    /// Convenience for the gate call sites: open a window, run `body`, close the window
    /// whatever `body` does.
    public func withWindow<T>(
        sessionID: String,
        agent: AgentIdentity,
        summary: String,
        detail: String = "",
        _ body: @MainActor () async -> T
    ) async -> T {
        let token = beginWindow(
            sessionID: sessionID, agent: agent, summary: summary, detail: detail
        )
        defer { endWindow(token) }
        return await body()
    }

    // MARK: - Recording

    /// Records a resolved approval — a broker tool call or a yes/no stop question alike,
    /// which are the same request type by the time they reach here.
    public func record(approval: ApprovalRequest, decision: Decision) {
        store.record(approval: approval, decision: decision)
    }

    /// Notes that the delegation filter answered one approval without asking.
    ///
    /// Separate from ``record(approval:decision:)`` and called alongside it, not instead of
    /// it: an auto-allow is a resolved approval like any other and belongs in the session's
    /// event ring, where "what changed?" will read it back as "Claude Code approved run the
    /// tests." This adds the one fact the ring has no field for — that nobody was asked.
    public func noteAutoAnswer() {
        autoAnsweredCount += 1
    }

    /// Records a resolved selection window.
    public func record(selection: SelectionRequest, result: SelectionResult) {
        store.record(selection: selection, result: result)
    }

    /// Records a selection that answered a question found in the agent's final reply.
    ///
    /// Split from ``record(selection:result:)`` only for the free-text case: an answer the
    /// wearer spoke into a stop question is a different thing to recall than a label they
    /// picked from a menu, and `stopAnswer` is the kind that says so. A chosen label is
    /// recorded as the selection it is.
    public func recordStopSelection(_ request: SelectionRequest, result: SelectionResult) {
        guard result.choices.isEmpty, let freeText = result.freeText, !freeText.isEmpty else {
            store.record(selection: request, result: result)
            return
        }
        store.recordStopAnswer(
            session: request.sessionID,
            agent: request.agent,
            question: request.question,
            answer: freeText
        )
    }

    /// Records a spoken notification. Called only where one is actually announced: under
    /// `--no-announcements` TapQ says nothing, and recalling "the agent reported X" for
    /// something the wearer never heard would be inventing a conversation.
    public func record(notification: AgentNotification) {
        store.record(notification: notification)
        // The only agent message that never opens a window. Without this a session that
        // has done nothing but announce things would be unaddressable by name, which the
        // wearer would experience as TapQ not knowing about an agent it had just spoken
        // about out loud.
        noteAgentSeen(sessionID: notification.sessionID, agent: notification.agent)
    }

    // MARK: - Recall

    /// The answer to a spoken recall question, or `nil` when no window is open — which the
    /// controllers turn into "Nothing recorded yet." Recall is only reachable from inside
    /// a window, so `nil` here is a composition error, not a wearer-visible state.
    public func recallAnswer(for intent: InputIntent) -> String? {
        guard let token = openOrder.first, let window = windows[token] else { return nil }
        switch intent {
        case .whatChanged:
            return SessionRecall.whatChanged(
                store.recent(session: window.sessionID, limit: SessionRecall.recalledEventLimit)
            )
        case .status:
            return SessionRecall.status(
                agentDisplayName: window.agentDisplayName,
                summary: window.summary,
                othersWaiting: waitRegistry.waitingCount(excluding: token.registryToken),
                // This session's undelivered dictations, not the fleet's: the wearer is
                // being told about the conversation they are standing in, and an
                // instruction queued for a different agent is not something they can act
                // on from here. Zero without a mailbox, which restores Rung B's sentence.
                instructionsQueued: instructions?.pendingCount(session: window.sessionID) ?? 0,
                autoAnswered: autoAnsweredCount
            )
        default:
            // Every other intent is a decision or a navigation, and this seam exists
            // precisely so recall can never answer one.
            return nil
        }
    }

    /// The recall closure the controllers take. A closure, so a controller holds something
    /// that can only hand back a sentence.
    ///
    /// It captures the memory strongly. There is no cycle to break — memory knows nothing
    /// about the controllers — and a weak capture would make recall answer "nothing
    /// recorded" for the rest of the run if the composition that built it ever stopped
    /// holding it, which is a silent failure rather than a loud one.
    public var recallResponder: RecallResponding {
        { [self] intent in recallAnswer(for: intent) }
    }

    // MARK: - Grounded question answering

    /// The instruction that answers `question` from this session's memory, or `nil` when
    /// there is no open window or nothing legible was asked.
    public func groundedAnswer(for question: String) -> String? {
        guard let token = openOrder.first, let window = windows[token] else { return nil }
        return SessionRecall.groundedAnswer(
            question: question,
            digest: SessionRecall.digest(
                events: store.recent(
                    session: window.sessionID, limit: SessionRecall.digestEventLimit
                ),
                currentSummary: window.summary,
                currentDetail: window.detail
            )
        )
    }

    /// The free-form closure the approval controller takes, routed to `speak`.
    ///
    /// `speak` is `VoiceBackendCommandProvider.speakViaBackend`, which reports whether the
    /// realtime session was in a state to take the text. Its `false` — no session, a turn
    /// already open, a response in flight — is this responder's `false`, and the window
    /// then behaves exactly as it did before Rung B: the question goes unanswered and the
    /// wearer is still being asked what they were asked.
    ///
    /// - Parameter speak: routes TapQ-authored instructions to the realtime backend.
    public func freeformResponder(
        speak: @escaping @MainActor (String) -> Bool
    ) -> FreeformQuestionResponding {
        { [self] question in
            guard let grounded = groundedAnswer(for: question) else { return false }
            return speak(grounded)
        }
    }

    // MARK: - Instructions (Rung C)

    /// The session and agent a dictated instruction would be addressed to: the window the
    /// wearer is standing in, which is the same one recall answers about.
    ///
    /// There is no other candidate. The microphone is live only inside a response window,
    /// so a dictation always happens inside one, and "the agent that just asked me
    /// something" is the only agent a wearer can mean when they say "tell it to…".
    private var dictationTarget: (sessionID: String, agent: AgentIdentity)? {
        guard let token = openOrder.first, let window = windows[token] else { return nil }
        return (window.sessionID, window.agent)
    }

    /// Whether the agent whose window is open can receive an instruction at all (RC6).
    ///
    /// Answers `false` with no open window, which is the same fail-closed default the rest
    /// of this path takes: a dictation with nowhere to be addressed is refused out loud
    /// rather than queued against a guess.
    public var instructionCapability: InstructionCapabilityChecking {
        { [self] in
            guard let target = dictationTarget else { return false }
            return AgentCapabilities.of(target.agent).instructions
        }
    }

    /// The closure the controllers enqueue a confirmed instruction through, or `nil` when
    /// this run has no mailbox — which is what makes the dictation grammar inert without
    /// `--voice-instructions`.
    ///
    /// It takes text and returns nothing, so the whole reach of the dictation path is
    /// "put a sentence in a queue". It cannot allow, deny, choose, or defer, and there is
    /// no return value a controller could mistake for one.
    public var instructionEnqueue: InstructionDictating? {
        guard let instructions else { return nil }
        return { [self] text in
            // A window that closed between the capability check and the wearer's
            // confirmation. Reported rather than swallowed: the dictation flow says "Queued
            // for ⟨agent⟩" only if this says it was.
            guard let target = dictationTarget else { return .notQueued }
            return Self.outcome(of: instructions.enqueue(text, session: target.sessionID))
        }
    }

    /// Translates the mailbox's own result into the one fact the dictation flow may know.
    ///
    /// Deliberately lossy: the flow learns whether the sentence is waiting and whether it
    /// cost the oldest one, and never sees the `QueuedInstruction` itself. The wearer's
    /// words are already in the read-back, and a controller holding the queued value would
    /// be a controller that could read the mailbox back.
    private static func outcome(of result: InstructionEnqueueResult) -> InstructionQueueOutcome {
        switch result {
        case .rejectedEmpty: return .notQueued
        case .queued: return .queued
        case .queuedDroppingOldest: return .queuedDroppingOldest
        }
    }

    // MARK: - Addressed instructions

    /// Resolves a spoken agent name to the session a dictation should be routed to, or
    /// `nil` when nothing live answers to it.
    ///
    /// `nil` for the whole closure — not just for a name — without a mailbox, for the same
    /// reason ``instructionEnqueue`` is: a run with nowhere to put an instruction has
    /// nothing to route, and an absent resolver is what makes the dictation flow skip the
    /// address grammar entirely rather than parse a sentence it cannot act on.
    ///
    /// One resolver serves every window. Which sessions are live is a fact about the
    /// fleet, not about the window the wearer is standing in, so an in-prompt dictation, an
    /// attention window, and a held voice-session boundary all resolve "Codex" to the same
    /// session — and a second one of them makes the name ambiguous in all three.
    ///
    /// The addressee it hands back can reach exactly one thing: this mailbox, at that
    /// session. It carries no session identifier the controllers could speak and no
    /// capability of its own beyond queueing a sentence.
    public var instructionAddressResolver: InstructionAddressResolving? {
        guard let instructions else { return nil }
        return { [self] name in
            switch roster.resolve(name: name, now: clock()) {
            case .none:
                return nil
            case let .ambiguous(agentDisplayName):
                return .ambiguous(agentDisplayName: agentDisplayName)
            case let .resolved(entry):
                return .resolved(
                    InstructionAddressee(
                        agentDisplayName: entry.agent.displayName,
                        // The same per-adapter table the in-window check reads. Routing is
                        // a different way to reach an agent, never a different rule about
                        // which agents can be reached.
                        acceptsInstructions: AgentCapabilities.of(entry.agent).instructions,
                        enqueue: { text in
                            Self.outcome(
                                of: instructions.enqueue(text, session: entry.sessionID)
                            )
                        }
                    )
                )
            }
        }
    }

    /// The display names a wearer could address right now, sorted for a stable reading.
    ///
    /// Its one consumer is the grounding a model-backed backend is given, so that
    /// `queue_instruction`'s optional agent argument is filled from names that exist rather
    /// than invented from the sentence. Display names only — the same three fields
    /// `InstructionAddressee` is allowed to carry, minus the two this does not need. No
    /// session identifiers, because a name is what the wearer says and an identifier is
    /// something they must never hear.
    ///
    /// Empty without `--voice-instructions`: with no mailbox there is nothing to address, and
    /// a model told about agents it cannot reach would offer a routing that always refuses.
    public var liveAgentDisplayNames: [String] {
        guard instructions != nil else { return [] }
        return roster.liveEntries(at: clock()).map(\.agent.displayName)
    }

    /// Whether `agentID` currently has more than one live session, which is what makes its
    /// name unusable for routing. For tests and diagnostics.
    public func isAgentAmbiguous(_ agentID: String) -> Bool {
        roster.isAmbiguous(agentID: agentID, at: clock())
    }

    /// The session that answers to `agentID` right now, or `nil` when none does. For tests
    /// and diagnostics; routing goes through ``instructionAddressResolver``.
    public func rosterEntry(agentID: String) -> AgentRoster.Entry? {
        roster.entry(agentID: agentID, at: clock())
    }

    // MARK: - Instructions from a wearer-initiated window (Rung D)

    /// Where a dictation would go when the wearer opened the window themselves: the request
    /// in hand if there is one, and otherwise the last request TapQ handled.
    ///
    /// The fallback is only ever reached from an attention window, because every other
    /// window is opened *by* a request and therefore has one open. Still `nil` before the
    /// first request of a run, which is the honest answer — TapQ has not met an agent yet.
    private var standingTarget: (sessionID: String, agent: AgentIdentity)? {
        dictationTarget ?? lastTarget
    }

    /// The agent an attention window would address, for the sentences the dictation flow
    /// speaks ("Queued for Claude Code."). `nil` before any request has been served.
    public var standingAgentDisplayName: String? {
        standingTarget?.agent.displayName
    }

    /// Recall for a wearer-initiated window (RD3), where there is no open request to answer
    /// about.
    ///
    /// Separate from ``recallResponder`` rather than a fallback inside it, because the two
    /// answer different questions and mixing them would let an in-prompt "status" quietly
    /// describe a request that had already been resolved. Here the honest lead is that
    /// nothing is waiting; "what changed?" still reads the last-served session's ring,
    /// which is exactly the history the wearer means.
    public var standingRecallResponder: RecallResponding {
        { [self] intent in
            switch intent {
            case .whatChanged:
                guard let target = standingTarget else { return nil }
                return SessionRecall.whatChanged(
                    store.recent(
                        session: target.sessionID, limit: SessionRecall.recalledEventLimit
                    )
                )
            case .status:
                return SessionRecall.standingStatus(
                    instructionsQueued: standingTarget.flatMap { target in
                        instructions?.pendingCount(session: target.sessionID)
                    } ?? 0,
                    autoAnswered: autoAnsweredCount
                )
            default:
                // Same seam, same reason: every other intent is a decision or a
                // navigation, and recall can never answer one.
                return nil
            }
        }
    }

    /// ``instructionCapability`` for a wearer-initiated window. Same fail-closed answer —
    /// no target, no dictation — and the same per-adapter table: an attention window at a
    /// Cursor session is refused by name exactly as an in-prompt dictation is.
    public var standingInstructionCapability: InstructionCapabilityChecking {
        { [self] in
            guard let target = standingTarget else { return false }
            return AgentCapabilities.of(target.agent).instructions
        }
    }

    /// ``instructionEnqueue`` for a wearer-initiated window, or `nil` without a mailbox.
    public var standingInstructionEnqueue: InstructionDictating? {
        guard let instructions else { return nil }
        return { [self] text in
            guard let target = standingTarget else { return .notQueued }
            return Self.outcome(of: instructions.enqueue(text, session: target.sessionID))
        }
    }

    /// Records an instruction at the moment the coordinator hands it to the agent, so
    /// "what changed?" can say the agent was told to do it.
    public func recordInstruction(session: String, agent: AgentIdentity, text: String) {
        store.recordInstruction(session: session, agent: agent, text: text)
    }

    /// The recording closure the stop-question coordinator takes. Same shape and same
    /// reason as ``recallResponder``: the coordinator holds something that can only note a
    /// delivery, never read the session's memory back.
    public var instructionRecorder: StopQuestionCoordinator.RecordInstruction {
        { [self] session, agent, text in
            recordInstruction(session: session, agent: agent, text: text)
        }
    }

    // MARK: - Inspection

    /// The events recorded for a session, oldest first. For tests and diagnostics.
    public func events(session: String) -> [SessionContextEvent] {
        store.events(session: session)
    }
}
