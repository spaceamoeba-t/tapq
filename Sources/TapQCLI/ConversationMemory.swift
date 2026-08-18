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
    private struct OpenWindow {
        let sessionID: String
        let agentDisplayName: String
        let summary: String
        let detail: String
    }

    /// Who is queued at the gate. Exposed so a composition that wants the counts for
    /// something other than speech — a diagnostic line, a future fleet view — reads the
    /// same registry recall reads, rather than a second one that could disagree.
    public let waitRegistry = SessionWaitRegistry()

    private var store: SessionContextStore
    private var windows: [WindowToken: OpenWindow] = [:]
    /// Open windows in the order they entered the gate. The gate is FIFO, so the first
    /// element is the request currently being asked about — which is the session recall
    /// answers for.
    private var openOrder: [WindowToken] = []

    /// - Parameter clock: timestamp source for recorded events, injected by tests.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = SessionContextStore(clock: clock)
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
            agentDisplayName: agent.displayName,
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
                othersWaiting: waitRegistry.waitingCount(excluding: token.registryToken)
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
            guard let instructions = groundedAnswer(for: question) else { return false }
            return speak(instructions)
        }
    }

    // MARK: - Inspection

    /// The events recorded for a session, oldest first. For tests and diagnostics.
    public func events(session: String) -> [SessionContextEvent] {
        store.events(session: session)
    }
}
