import Foundation
import TapQContracts

@MainActor public protocol SelectionArbitrating: AnyObject {
    /// See `InputArbitrating.listen(timeout:)` — same window/voice-guard contract.
    func listen(timeout: TimeInterval) async -> InputIntent?
}

/// Drives a speak-navigate-confirm cycle for multi-option selection.
///
/// The controller speaks the question and first option, then loops on user input:
/// - `.next` / `.previous` — navigate and speak the new option
/// - `.select` / `.allow` — confirm current selection (double-nod or double-tap)
/// - `.selectByNumber(n)` — jump directly to option n (1-indexed)
/// - `.deny` / `.deferToPrompt` / `nil` — return `.noSelection`
@MainActor public final class SelectionController {
    private let speech: SpeechPresenting
    private let arbiter: SelectionArbitrating
    private let diagnostics: TapQDiagnosticEmitter
    public var timeout: TimeInterval
    /// Minimum remaining budget required to begin speaking (see InteractionBudget.minViableRemaining).
    public var entryMargin: TimeInterval = InteractionBudget.minViableRemaining
    /// Clock seam: all deadline math reads time through this, so tests can advance a
    /// virtual clock instead of racing real sub-second deadlines against CI preemption.
    var now: () -> ContinuousClock.Instant = { .now }
    /// The controls are taught once per runtime session. The controller outlives every
    /// individual request, so this survives across questions by design.
    private var hasAnnouncedControls = false
    /// Which controls to teach, asked for at the moment a hint is spoken rather than at
    /// composition time: the channels available to a window are a per-window fact, and a
    /// device that appears mid-session must change what the next prompt teaches.
    private let controlsHint: @MainActor () -> String

    /// `controlsHint` is consulted on the session's first prompt and on every explicit
    /// repeat, and must answer for the window it is called in. The default teaches the
    /// full motion controls, which is the composition every host had before the provider
    /// existed.
    public init(speech: SpeechPresenting, arbiter: SelectionArbitrating,
                timeout: TimeInterval = 240,
                controlsHint: @escaping @MainActor () -> String = {
                    SelectionController.controlsHint
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.speech = speech
        self.arbiter = arbiter
        self.timeout = timeout
        self.controlsHint = controlsHint
        self.diagnostics = TapQDiagnosticEmitter(category: "Selection", sink: diagnosticSink)
    }

    public func resolve(_ request: SelectionRequest, deadline: ContinuousClock.Instant? = nil) async -> SelectionResult {
        let deadline = deadline ?? now() + .seconds(InteractionBudget.total)
        diagnostics.record("resolve.started",
                           fields: ["options": "\(request.options.count)"])
        var outcome = "deferred"
        defer { diagnostics.record("resolve.finished", fields: ["outcome": outcome]) }
        diagnostics.record("selection.presented",
                           fields: ["options": "\(request.options.count)"])
        guard !request.options.isEmpty else {
            diagnostics.record("selection.empty", level: .warning)
            return .noSelection
        }
        // Expired (or nearly so) while queued: the shim may have already failed open, and
        // there isn't enough budget left to speak the prompt and still leave the user time
        // to answer — stay silent.
        guard deadline.seconds(after: now()) > entryMargin else {
            diagnostics.record("resolve.insufficient_budget", fields: ["id": request.id])
            return .noSelection
        }
        var cursor = 0
        // Spoken concurrently with the next listen window (barge-in), so input while
        // the option is still being announced is not lost.
        //
        // The controls ride along only on the session's first selection. Marking them
        // announced here rather than after the utterance completes is deliberate: a user
        // who barges in before the hint finishes already knows the controls, and
        // re-arming would put the hint back on the next question.
        //
        // The request's spoken preamble rides the same first utterance, ahead of the
        // question. It is context about *this* question, so unlike the controls it is
        // tracked per resolve rather than per session — and like them it is said once:
        // a user navigating between options is choosing, not still being introduced, and
        // an explicit repeat is a request for the question, not for the preamble again.
        var utterance: String? = promptText(request, cursor: cursor,
                                            includeControls: !hasAnnouncedControls,
                                            includeIntroduction: true)
        hasAnnouncedControls = true
        while true {
            let remaining = deadline.seconds(after: now())
            guard remaining > 0 else {
                outcome = "timeout"
                return deferToScreen()
            }
            let intent = await BargeIn.listen(speech: speech, text: utterance, priority: .approval) {
                await arbiter.listen(timeout: min(timeout, remaining))
            }
            utterance = nil
            diagnostics.record("selection.navigated",
                               fields: ["intent": intent.map { "\($0)" } ?? "none",
                                        "cursor": "\(cursor)"])
            switch intent {
            case .next, .previous:
                // A navigation command moves immediately. Confirmation is a double-nod,
                // double-tap, "select", or a number.
                cursor = intent == .next
                    ? (cursor + 1) % request.options.count
                    : (cursor - 1 + request.options.count) % request.options.count
                utterance = optionText(request, cursor: cursor)
            case .select, .allow:
                outcome = "resolved"
                diagnostics.record("selection.resolved", fields: ["cursor": "\(cursor)"])
                return selection(at: cursor, request: request)
            case .selectByNumber(let n):
                let index = n - 1
                guard index >= 0, index < request.options.count else {
                    utterance = "Option \(n) is not available. There are \(request.options.count) options."
                    continue
                }
                outcome = "resolved"
                diagnostics.record("selection.resolved", fields: ["cursor": "\(index)"])
                return selection(at: index, request: request)
            case .repeatRequest:
                // An explicit repeat is the one moment the user has signalled they are
                // lost, so the controls come back even after the session's first prompt.
                utterance = promptText(request, cursor: cursor, includeControls: true)
            case .freeform(let text):
                // Read-back confirmation: the wearer spoke a free-text answer.
                // Speak it back, then wait for nod (confirm) or shake (discard).
                let condensedText = SpokenText.condensed(text, maxWords: 12, maxCharacters: 96)
                utterance = "You said: '\(SpokenText.sentence(condensedText))' Nod or say yes to send, shake or say no to discard."
                diagnostics.record("freeform.readback",
                                   fields: ["length": "\(text.count)"])
                let confirmRemaining = deadline.seconds(after: now())
                guard confirmRemaining > 0 else {
                    outcome = "timeout"
                    return deferToScreen()
                }
                let confirmation = await BargeIn.listen(
                    speech: speech, text: utterance, priority: .approval
                ) {
                    await arbiter.listen(timeout: min(timeout, confirmRemaining))
                }
                utterance = nil
                switch confirmation {
                case .allow, .select:
                    outcome = "resolved_freeform"
                    diagnostics.record("freeform.confirmed",
                                       fields: ["length": "\(text.count)"])
                    return SelectionResult(choices: [], freeText: text)
                case .deny:
                    // Discard and re-listen for a new answer.
                    diagnostics.record("freeform.discarded")
                    utterance = promptText(request, cursor: cursor,
                                           includeControls: false)
                    continue
                case .none:
                    outcome = "timeout"
                    diagnostics.record("selection.timeout")
                    return deferToScreen()
                default:
                    // Any other intent (navigation, etc.) during read-back confirmation
                    // is treated as a discard — re-listen.
                    diagnostics.record("freeform.discarded",
                                       fields: ["reason": "unexpected_intent"])
                    utterance = promptText(request, cursor: cursor,
                                           includeControls: false)
                    continue
                }
            case .none:
                outcome = "timeout"
                diagnostics.record("selection.timeout")
                return deferToScreen()
            case .deny, .deferToPrompt, .details:
                return .noSelection
            }
        }
    }

    /// Budget or listen window ran out: announce, then fall back to the on-screen prompt
    /// (`.noSelection` carries `timedOut: true`, which the broker maps to fail-open).
    private func deferToScreen() -> SelectionResult {
        speech.speak("Deferring to the screen.", priority: .notification, onFinish: nil)
        return .noSelection
    }

    private func selection(at index: Int, request: SelectionRequest) -> SelectionResult {
        SelectionResult(choices: [.init(index: index, label: request.options[index].label)])
    }

    /// How to navigate and confirm. The controls never change between selections, so
    /// repeating them on every question is 37 characters the user must sit through before
    /// reaching the option they are actually choosing between.
    public static let controlsHint = "Volume, then nod twice or double-tap."

    /// The same teaching for a session with no motion device: every word is in
    /// `VoiceCommandMatcher`'s grammar, so the hint only names controls that will work.
    /// Teaching volume and nods to a user whose earbuds are in a case is worse than
    /// teaching nothing — it is the runtime telling them to do something that cannot
    /// resolve the question.
    public static let voiceOnlyControlsHint = "Say next, previous, or select."

    private func promptText(
        _ request: SelectionRequest,
        cursor: Int,
        includeControls: Bool,
        includeIntroduction: Bool = false
    ) -> String {
        let option = request.options[cursor]
        let question = SpokenText.condensed(
            request.question,
            maxWords: 12,
            maxCharacters: 96
        )
        let label = SpokenText.condensed(
            option.label,
            maxWords: 6,
            maxCharacters: 48
        )
        let introduction = includeIntroduction
            ? Self.introduction(request.spokenPreamble)
            : ""
        let prompt = "\(introduction)\(SpokenText.sentence(question)) \(cursor + 1) of \(request.options.count): \(SpokenText.sentence(label))"
        return includeControls ? "\(prompt) \(controlsHint())" : prompt
    }

    /// A bounded, sentence-terminated lead-in, or "" when the request carries none.
    ///
    /// The bound is the controller's: `spokenPreamble` is a plain `String?` on a public
    /// contract, and an introduction the wearer has to sit through before hearing the
    /// first option defeats the point of speaking one.
    private static func introduction(_ text: String?) -> String {
        let condensed = SpokenText.condensed(
            text ?? "",
            maxWords: 24,
            maxCharacters: 120
        )
        return condensed.isEmpty ? "" : "\(SpokenText.sentence(condensed)) "
    }

    private func optionText(_ request: SelectionRequest, cursor: Int) -> String {
        let option = request.options[cursor]
        let label = SpokenText.condensed(
            option.label,
            maxWords: 6,
            maxCharacters: 48
        )
        return "\(cursor + 1): \(SpokenText.sentence(label))"
    }
}
