import Foundation
import TapQContracts

/// Supplies host-facing wording while the controller owns only interaction state.
/// Product names, brand voice, and agent-specific copy belong in the embedding app.
public protocol ApprovalRequestPresenting: Sendable {
    func prompt(for request: ApprovalRequest) -> String
    func details(for request: ApprovalRequest) -> String
    func notification(for notification: AgentNotification) -> String
    func deferralNotice() -> String
}

/// Agent-neutral wording suitable for SDK examples and tests.
public struct DefaultApprovalRequestPresenter: ApprovalRequestPresenting {
    public init() {}

    public func prompt(for request: ApprovalRequest) -> String {
        let name = request.agent.displayName
        let summary = SpokenText.condensed(
            request.summary,
            maxWords: 6,
            maxCharacters: 64
        )
        switch request.kind {
        case .toolApproval: return "\(name): \(SpokenText.sentence(summary)) Approve?"
        case .question: return "\(name): \(SpokenText.sentence(summary)) Yes or no?"
        }
    }

    public func details(for request: ApprovalRequest) -> String {
        request.detail.isEmpty ? "No further details." : request.detail
    }

    public func notification(for notification: AgentNotification) -> String {
        let name = notification.agent.displayName
        switch notification.kind {
        case .waitingForInput:
            return "\(name) is waiting."
        case .permissionWaiting:
            return "\(name) needs approval."
        case .finished:
            return "\(name) finished."
        }
    }

    public func deferralNotice() -> String { "Deferring to the screen." }
}

/// Drives one approval to a `Decision`: speak the request, open an input window, and
/// resolve on the first nod/voice. `repeat`/`details` re-speak and listen again; a
/// timeout (or "skip") resolves to `.ask` so a missed answer never hangs or wrongly denies.
@MainActor public final class InteractionController {
    private let speech: SpeechPresenting
    private let arbiter: InputArbitrating
    private let presenter: any ApprovalRequestPresenting
    private let diagnostics: TapQDiagnosticEmitter
    public var timeout: TimeInterval
    /// Minimum remaining budget required to begin speaking (see InteractionBudget.minViableRemaining).
    public var entryMargin: TimeInterval = InteractionBudget.minViableRemaining
    /// Clock seam: all deadline math reads time through this, so tests can advance a
    /// virtual clock instead of racing real sub-second deadlines against CI preemption.
    var now: () -> ContinuousClock.Instant = { .now }

    public init(speech: SpeechPresenting, arbiter: InputArbitrating,
                timeout: TimeInterval = 240,
                presenter: any ApprovalRequestPresenting = DefaultApprovalRequestPresenter(),
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.speech = speech
        self.arbiter = arbiter
        self.timeout = timeout
        self.presenter = presenter
        self.diagnostics = TapQDiagnosticEmitter(category: "Interaction", sink: diagnosticSink)
    }

    public func resolve(_ request: ApprovalRequest, deadline: ContinuousClock.Instant? = nil) async -> Decision {
        let deadline = deadline ?? now() + .seconds(InteractionBudget.total)
        diagnostics.record("resolve.started", fields: ["tool": request.toolName, "id": request.id])
        // Expired (or nearly so) while queued behind other requests: the shim may have
        // already failed open, and there isn't enough budget left to speak the prompt and
        // still leave the user time to answer — don't speak, don't open a window.
        guard deadline.seconds(after: now()) > entryMargin else {
            diagnostics.record("resolve.insufficient_budget", fields: ["id": request.id])
            return .ask
        }
        // Spoken concurrently with the next listen window (barge-in), so a nod during
        // the prompt is not lost. nil = keep listening without re-speaking.
        var utterance: String? = promptText(for: request)
        while true {
            let remaining = deadline.seconds(after: now())
            guard remaining > 0 else { return deferToScreen() }
            let intent = await BargeIn.listen(speech: speech, text: utterance, priority: .approval) {
                await arbiter.listen(timeout: min(timeout, remaining))
            }
            utterance = nil
            diagnostics.record("input.received",
                               fields: ["intent": intent.map { "\($0)" } ?? "none"])
            switch intent {
            case .allow:
                return .allow
            case .deny:
                return .deny
            case .deferToPrompt:
                return .ask
            case .none:
                return deferToScreen()
            case .repeatRequest:
                utterance = promptText(for: request)
            case .details:
                utterance = detailText(for: request)
            case .next, .previous, .select, .selectByNumber:
                // Navigation intents are not meaningful in approval flow — keep listening.
                break
            }
        }
    }

    /// The budget (or a silent listen window) ran out: tell the user where the question
    /// went, then let the hook resolve to the normal on-screen prompt.
    private func deferToScreen() -> Decision {
        speech.speak(presenter.deferralNotice(), priority: .notification, onFinish: nil)
        return .ask
    }

    public func announce(_ notification: AgentNotification) {
        speech.speak(notificationText(for: notification), priority: .notification, onFinish: nil)
    }

    func promptText(for request: ApprovalRequest) -> String {
        presenter.prompt(for: request)
    }

    func detailText(for request: ApprovalRequest) -> String {
        presenter.details(for: request)
    }

    func notificationText(for notification: AgentNotification) -> String {
        presenter.notification(for: notification)
    }
}
