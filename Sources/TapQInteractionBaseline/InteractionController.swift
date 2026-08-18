import Foundation
import TapQContracts

/// Supplies host-facing wording while the controller owns only interaction state.
/// Product names, brand voice, and agent-specific copy belong in the embedding app.
public protocol ApprovalRequestPresenting: Sendable {
    func prompt(for request: ApprovalRequest) -> String
    func details(for request: ApprovalRequest) -> String
    func notification(for notification: AgentNotification) -> String
    func deferralNotice() -> String
    /// Spoken when a risk-escalated request needs the approve gesture a second time.
    func repeatConfirmationCue() -> String
    /// Spoken when a two-channel request still needs the spoken half.
    func voiceConfirmationCue() -> String
    /// Spoken when a two-channel request still needs the gesture half.
    func gestureConfirmationCue() -> String
}

/// Defaults for the confirmation cues, so a host that wrote a presenter before risk
/// escalation existed keeps compiling and still says something when a request arms.
///
/// The cues ride the approval channel — the same `speak` the prompt itself uses, at
/// `.approval` priority — not the agent-notification channel that `--no-announcements`
/// silences. A user who cannot hear that a second confirmation is required has no way to
/// give one, and the request would run out its window; suppressing the cue would make an
/// escalated request unanswerable rather than quiet.
///
/// A two-channel cue always names the half that is *missing*, so the user is told what to
/// do next rather than what a requirement is called.
public extension ApprovalRequestPresenting {
    func repeatConfirmationCue() -> String { "Risky action. Approve again to confirm." }
    /// "Yes" is already in the voice grammar (`VoiceCommandMatcher`), so this asks for a
    /// word the recognizer accepts rather than teaching a new one.
    func voiceConfirmationCue() -> String { "Risky action. Say yes to confirm." }
    /// Nod and tap are the two approve inputs that are not speech; either completes the
    /// gesture half.
    func gestureConfirmationCue() -> String { "Risky action. Nod or tap to confirm." }
}

/// Agent-neutral wording suitable for SDK examples and tests.
public struct DefaultApprovalRequestPresenter: ApprovalRequestPresenting {
    /// Whether a notification may say the summary the adapter sent with it.
    ///
    /// Off by default, which is what every host composed before spoken summaries existed
    /// and what `--speech-summarizer off` restores: the notification says only that the
    /// agent is waiting. There is no model on this path — the text is the adapter's own,
    /// condensed deterministically — but it is still *new spoken content*, and the off
    /// switch has to mean that nothing TapQ says has changed.
    private let speaksNotificationSummary: Bool

    public init(speaksNotificationSummary: Bool = false) {
        self.speaksNotificationSummary = speaksNotificationSummary
    }

    /// The preamble, when there is one, is one spoken sentence in front of the prompt:
    /// "<Name>: <preamble> <summary> Yes or no?". The prompt sentence itself is condensed
    /// exactly as it always was, so the words that name what is being authorized are
    /// unchanged whether or not context precedes them.
    public func prompt(for request: ApprovalRequest) -> String {
        let name = request.agent.displayName
        let summary = SpokenText.condensed(
            request.summary,
            maxWords: 6,
            maxCharacters: 64
        )
        let lead = Self.preamble(request.spokenPreamble)
        switch request.kind {
        case .toolApproval: return "\(name): \(lead)\(SpokenText.sentence(summary)) Approve?"
        case .question: return "\(name): \(lead)\(SpokenText.sentence(summary)) Yes or no?"
        }
    }

    public func details(for request: ApprovalRequest) -> String {
        request.detail.isEmpty ? "No further details." : request.detail
    }

    /// A notification says what the agent's state is, and — when the host allows it and
    /// the adapter sent one — what the agent said about it.
    ///
    /// Only the Claude adapter populates `summary` today, with the hook's own short
    /// message text. A kind that arrives with no summary is spoken exactly as before.
    public func notification(for notification: AgentNotification) -> String {
        let name = notification.agent.displayName
        let state: String
        switch notification.kind {
        case .waitingForInput: state = "\(name) is waiting"
        case .permissionWaiting: state = "\(name) needs approval"
        case .finished: state = "\(name) finished"
        }
        guard speaksNotificationSummary else { return "\(state)." }
        let summary = SpokenText.condensed(
            notification.summary ?? "",
            maxWords: 12,
            maxCharacters: 96
        )
        guard !summary.isEmpty else { return "\(state)." }
        return "\(state): \(SpokenText.sentence(summary))"
    }

    /// A spoken lead-in, bounded and sentence-terminated, or "" when there is none.
    ///
    /// The bound is the presenter's, not the caller's: `spokenPreamble` is a plain
    /// `String?` on a public contract, so a host can put an essay there, and an utterance
    /// the wearer cannot sit through is as unusable as no utterance at all.
    private static func preamble(_ text: String?) -> String {
        let condensed = SpokenText.condensed(
            text ?? "",
            maxWords: 24,
            maxCharacters: 120
        )
        return condensed.isEmpty ? "" : "\(SpokenText.sentence(condensed)) "
    }

    public func deferralNotice() -> String { "Deferring to the screen." }
}

/// Drives one approval to a `Decision`: speak the request, open an input window, and
/// resolve on the first nod/voice. `repeat`/`details` re-speak and listen again; a
/// timeout (or "skip") resolves to `.ask` so a missed answer never hangs or wrongly denies.
///
/// A caller may raise what approving costs by passing a `RequiredConfirmation`, which
/// holds the first allow back and waits for a second, qualifying one. It cannot lower
/// anything: deny, skip, and timeout behave identically at every requirement.
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

    /// `requiredConfirmation` is how much the user has to do to approve. `.standard` — the
    /// default, and what every call site written before risk escalation passes — is the
    /// behavior that was here before: the first allow resolves. Anything stronger holds
    /// the first allow back and waits for a qualifying second one.
    ///
    /// Escalation touches the allow path only. Deny resolves immediately in every state,
    /// a timeout still falls through to `.ask`, and no requirement can turn an unanswered
    /// request into an approved one.
    public func resolve(
        _ request: ApprovalRequest,
        deadline: ContinuousClock.Instant? = nil,
        requiredConfirmation: RequiredConfirmation = .standard
    ) async -> Decision {
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
        // Which halves of an escalated confirmation have arrived so far. `.standard`
        // never reads it, which is why its path below is unchanged.
        var progress = ConfirmationProgress()
        while true {
            let remaining = deadline.seconds(after: now())
            guard remaining > 0 else { return deferToScreen() }
            let input = await BargeIn.listen(speech: speech, text: utterance, priority: .approval) {
                await arbiter.listenForInput(timeout: min(timeout, remaining))
            }
            utterance = nil
            diagnostics.record("input.received",
                               fields: ["intent": input.map { "\($0.intent)" } ?? "none"])
            switch input?.intent {
            case .allow:
                let wasArmed = progress.armed
                switch allowOutcome(
                    under: requiredConfirmation,
                    channel: input?.channel ?? .unspecified,
                    progress: &progress
                ) {
                case .approve:
                    return .allow
                case .awaitConfirmation(let cue):
                    if !wasArmed {
                        diagnostics.record("confirmation.armed", fields: [
                            "id": request.id,
                            "requirement": requiredConfirmation.rawValue,
                        ])
                    }
                    utterance = cue
                }
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
            case .next, .previous, .select, .selectByNumber, .freeform:
                // Navigation and free-form intents are not meaningful in approval flow —
                // keep listening. A free-form answer to an approval is an authorization
                // surface change and is out of scope for this milestone.
                break
            }
        }
    }

    /// What an allow intent means under a confirmation requirement.
    private enum AllowOutcome {
        /// The requirement is satisfied.
        case approve
        /// Not yet. Keep listening, speaking `cue` first.
        case awaitConfirmation(cue: String)
    }

    /// Which halves of a confirmation the user has supplied so far.
    ///
    /// Tracked as *families* rather than a count, because that is what
    /// `gestureAndVoice` actually claims: speech and movement are independent enough
    /// that one source of error cannot produce both. Two spoken "yes"es are one source
    /// (a radio, a conversation, one misheard phrase repeated) and do not satisfy it.
    private struct ConfirmationProgress {
        /// An allow has been collected toward an escalated requirement.
        var armed = false
        /// A spoken allow has been collected.
        var voice = false
        /// A nod or a tap has been collected. `.unspecified` counts toward neither
        /// family: an input that cannot say where it came from cannot evidence
        /// independence, so a provenance-free arbiter arms but never completes.
        var gesture = false
    }

    /// Advances the confirmation state machine by one allow intent.
    ///
    /// The only way out is `approve`, and only a second qualifying allow produces it —
    /// so a requirement above `.standard` cannot be satisfied by the same single input
    /// that satisfies `.standard` today. Everything else keeps the window open, which
    /// ends in the ordinary timeout (`.ask`) if the user never confirms.
    private func allowOutcome(
        under requirement: RequiredConfirmation,
        channel: InputChannel,
        progress: inout ConfirmationProgress
    ) -> AllowOutcome {
        let wasArmed = progress.armed
        progress.armed = true
        switch channel {
        case .voice: progress.voice = true
        case .gesture, .tap: progress.gesture = true
        case .unspecified: break
        }

        switch requirement {
        case .standard:
            return .approve
        case .doubleGesture:
            // One approve *event* is already a paired double nod (or a tap, or a spoken
            // yes), so this asks for a second approve event of any kind: whichever way
            // the first one arrived, one movement can never confirm the command it just
            // raised. Which channel repeated is not this requirement's concern.
            if wasArmed { return .approve }
            return .awaitConfirmation(cue: presenter.repeatConfirmationCue())
        case .gestureAndVoice:
            // Both families, in either order. Cue the one still missing; when neither
            // has been evidenced (a provenance-free arbiter), ask for speech, which is
            // the half a stray movement cannot supply.
            if progress.voice, progress.gesture { return .approve }
            return .awaitConfirmation(
                cue: progress.voice
                    ? presenter.gestureConfirmationCue()
                    : presenter.voiceConfirmationCue()
            )
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
