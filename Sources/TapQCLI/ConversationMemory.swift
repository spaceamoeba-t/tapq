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
/// identity and an opaque session key; and the open-window text is the summary and detail
/// TapQ already speaks. No composition here needs a redaction pass because no unsafe
/// field ever reaches it.
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
        self.instructions = instructions
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
                instructionsQueued: instructions?.pendingCount(session: window.sessionID) ?? 0
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
            guard let target = dictationTarget else { return }
            instructions.enqueue(text, session: target.sessionID)
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
