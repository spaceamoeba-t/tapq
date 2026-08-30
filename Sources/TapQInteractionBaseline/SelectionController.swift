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
    /// Which voice this composition speaks with. Same seam, same default, and the same
    /// reason as `InteractionController.speechPath`.
    public var speechPath: SpokenPace.Path = SpokenPace.defaultPath
    private var entryMarginOverride: TimeInterval?
    /// Minimum remaining budget required to begin speaking.
    ///
    /// Derived from this controller's own worst prompt and the path's pace — see
    /// `InteractionController.entryMargin`, which does the same arithmetic against its
    /// presenter. A selection's floor is the larger of the two: it reads a question, a
    /// position, an option label, and the controls, where an approval reads one summary.
    public var entryMargin: TimeInterval {
        get {
            entryMarginOverride ?? SpokenPace.viableSeconds(
                utteranceCharacters: Self.maximumPromptCharacters,
                on: speechPath
            )
        }
        set { entryMarginOverride = newValue }
    }
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
    /// Answers `.status`/`.whatChanged` while a selection is open. Absent — the default —
    /// means the questions are answered with the honest "nothing recorded" sentence rather
    /// than mistaken for navigation.
    private let recallResponder: RecallResponding?
    /// The dictation flow, on exactly the terms the approval window has it: a wearer being
    /// asked to choose between options may still want to say something to the agent, and
    /// nothing about dictating changes which option is under the cursor.
    private let dictation: InstructionDictation
    /// Whether a nod can still confirm a read-back. Absent — every composition before
    /// `--voice-trust environment` — answers yes and keeps the wording unchanged.
    private let gestureConfirmation: GestureConfirmationQuerying?

    /// `controlsHint` is consulted on the session's first prompt and on every explicit
    /// repeat, and must answer for the window it is called in. The default teaches the
    /// full motion controls, which is the composition every host had before the provider
    /// existed.
    public init(speech: SpeechPresenting, arbiter: SelectionArbitrating,
                timeout: TimeInterval = 240,
                controlsHint: @escaping @MainActor () -> String = {
                    SelectionController.controlsHint
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                recallResponder: RecallResponding? = nil,
                instructionCapability: InstructionCapabilityChecking? = nil,
                wearerAttribution: WearerAttributionQuerying? = nil,
                instructionEnqueue: InstructionDictating? = nil,
                instructionAddressResolver: InstructionAddressResolving? = nil,
                voiceTrust: VoiceTrust = .wearer,
                gestureConfirmation: GestureConfirmationQuerying? = nil,
                intentSource: VoiceIntentSource = .transcriptGrammar) {
        self.speech = speech
        self.arbiter = arbiter
        self.timeout = timeout
        self.controlsHint = controlsHint
        let diagnostics = TapQDiagnosticEmitter(category: "Selection", sink: diagnosticSink)
        self.diagnostics = diagnostics
        self.recallResponder = recallResponder
        self.gestureConfirmation = gestureConfirmation
        self.dictation = InstructionDictation(capability: instructionCapability,
                                              attribution: wearerAttribution,
                                              enqueue: instructionEnqueue,
                                              diagnostics: diagnostics,
                                              resolveAddress: instructionAddressResolver,
                                              trust: voiceTrust,
                                              gestureConfirmation: gestureConfirmation,
                                              intentSource: intentSource)
    }

    /// The free-form read-back's confirmation cue, narrowed to speech where no gesture can
    /// arrive. Same rule and same reason as the dictation read-back: a sentence that asks
    /// for a nod the wearer cannot make is worse than one that asks for a word they can say.
    private var freeformConfirmCue: String {
        (gestureConfirmation?() ?? true)
            ? "Nod or say yes to send, shake or say no to discard."
            : "Say yes to send, or no to discard."
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
        // Expired (or nearly so) while queued: there isn't enough budget left to speak the
        // prompt and still leave the user time to answer, so no window is opened. Refused
        // out loud unless the deadline has actually passed — the split, and the reason for
        // it, is `InteractionController.resolve`'s.
        let remainingAtEntry = deadline.seconds(after: now())
        guard remainingAtEntry > entryMargin else {
            diagnostics.record("resolve.insufficient_budget", fields: [
                "id": request.id,
                "remaining": secondsField(remainingAtEntry),
                "floor": secondsField(entryMargin),
            ])
            return remainingAtEntry > 0 ? deferToScreen() : .noSelection
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
                // A sentence with no listen left to carry it is still said — the dictation
                // flow's discard notice is the case that matters, and a discard the wearer
                // cannot hear is indistinguishable from a queued instruction.
                if let utterance {
                    speech.speak(utterance, priority: .approval, onFinish: nil)
                }
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
                // And it is the longest thing this flow ever says, into whatever the
                // navigation so far has left — hence the re-check.
                guard let text = respeakable(
                    promptText(request, cursor: cursor, includeControls: true),
                    deadline: deadline, kind: "repeat"
                ) else {
                    outcome = "timeout"
                    return deferToScreen()
                }
                utterance = text
            case .freeform(let text):
                // Read-back confirmation: the wearer spoke a free-text answer.
                // Speak it back, then wait for nod (confirm) or shake (discard).
                let condensedText = SpokenText.condensed(text, maxWords: 12, maxCharacters: 96)
                utterance = "You said: '\(SpokenText.sentence(condensedText))' \(freeformConfirmCue)"
                diagnostics.record("freeform.readback",
                                   fields: ["length": "\(text.count)"])
                // The read-back is spoken with the microphone held closed for its drain, so
                // this listen covers the utterance's own playback and then leaves the wearer
                // a real answering window — the same rule the dictation read-back follows,
                // and for the same hardware reason (2026-08-30). Sizing it to the residue
                // alone would time out a confirmation the wearer never got to give.
                let confirmRemaining = deadline.seconds(after: now())
                guard confirmRemaining > 0 else {
                    outcome = "timeout"
                    return deferToScreen()
                }
                let confirmWindow = SpokenPace.listenSeconds(asking: utterance,
                                                             remaining: confirmRemaining)
                let confirmation = await BargeIn.listen(
                    speech: speech, text: utterance, priority: .approval
                ) {
                    await arbiter.listen(timeout: min(timeout, confirmWindow))
                }
                utterance = nil
                switch confirmation {
                case .allow, .select:
                    outcome = "resolved_freeform"
                    diagnostics.record("freeform.confirmed",
                                       fields: ["length": "\(text.count)"])
                    return SelectionResult(choices: [], freeText: text)
                case .deny:
                    // Discard and re-listen for a new answer. Putting the question again is
                    // a full re-speak like `repeat` is, and gets the same check: a discarded
                    // answer followed by a question the wearer cannot hear the end of is two
                    // lost turns rather than one.
                    diagnostics.record("freeform.discarded")
                    guard let text = respeakable(
                        promptText(request, cursor: cursor, includeControls: false),
                        deadline: deadline, kind: "freeform_reprompt"
                    ) else {
                        outcome = "timeout"
                        return deferToScreen()
                    }
                    utterance = text
                    continue
                case .none:
                    outcome = "timeout"
                    diagnostics.record("selection.timeout")
                    return deferToScreen()
                default:
                    // Any other intent (navigation, etc.) during read-back confirmation
                    // is treated as a discard — re-listen, under the same check.
                    diagnostics.record("freeform.discarded",
                                       fields: ["reason": "unexpected_intent"])
                    guard let text = respeakable(
                        promptText(request, cursor: cursor, includeControls: false),
                        deadline: deadline, kind: "freeform_reprompt"
                    ) else {
                        outcome = "timeout"
                        return deferToScreen()
                    }
                    utterance = text
                    continue
                }
            // Informational, and deliberately not in the bail-out group below: a wearer
            // asking what is going on has not chosen an option and has not declined to
            // choose one. Speak the answer, keep the cursor, keep the window — the
            // question is still on the table.
            case .status:
                utterance = recallText(for: .status)
            case .whatChanged:
                utterance = recallText(for: .whatChanged)
            // Also informational, in the only sense that matters here: the cursor does not
            // move, no option is chosen, and the question is still open when the flow
            // returns. The "yes" that confirms a read-back is consumed inside the flow and
            // never reaches the `.select, .allow` branch above.
            case .beginInstruction(let text):
                utterance = await dictate(text, for: request, deadline: deadline)
            case .none:
                outcome = "timeout"
                diagnostics.record("selection.timeout")
                return deferToScreen()
            case .deny, .deferToPrompt, .details:
                return .noSelection
            }
        }
    }

    /// Runs the dictation flow against this selection, returning what to say on the next
    /// listen.
    ///
    /// The deadline is the selection's own and is read, never written: dictating cannot buy
    /// the wearer more time to choose, and a flow that outlives the budget lands in the
    /// same timeout the loop already has.
    ///
    /// The read-back turn is the one place a listen may outlast the residue, and it buys the
    /// wearer nothing but the chance to answer: TapQ holds the microphone closed while it
    /// speaks, so a confirmation window shorter than its own question is one the wearer
    /// cannot give (`TurnBudget.afterSpeaking`). The selection itself is still decided by
    /// the loop's clock.
    private func dictate(
        _ capturedText: String?,
        for request: SelectionRequest,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        await dictation.run(capturedText: capturedText,
                            agentDisplayName: request.agent.displayName) { utterance, budget in
            let remaining = deadline.seconds(after: now())
            guard remaining > 0 else { return nil }
            let window: TimeInterval
            switch budget {
            case .remainingWindow:
                window = min(timeout, remaining)
            case .afterSpeaking(let answering):
                window = min(timeout, SpokenPace.listenSeconds(asking: utterance,
                                                               remaining: remaining,
                                                               answering: answering))
            }
            return await BargeIn.listen(speech: speech, text: utterance, priority: .approval) {
                await arbiter.listen(timeout: window)
            }
        }
    }

    /// The text, if there is still room to ask it and hear the answer; `nil` when the caller
    /// must refuse instead. `InteractionController.respeakable`'s twin — see `canRespeak`.
    private func respeakable(_ text: String,
                             deadline: ContinuousClock.Instant,
                             kind: String) -> String? {
        canRespeak(text, before: deadline, now: now(), on: speechPath,
                   kind: kind, diagnostics: diagnostics) ? text : nil
    }

    /// The spoken answer to a recall question, or the sentence that says there is nothing
    /// recorded. Speaking it is the whole effect: the selection is not advanced, not
    /// confirmed, and not abandoned.
    private func recallText(for intent: InputIntent) -> String {
        let answer = SpokenRecall.answer(recallResponder, for: intent)
        diagnostics.record("recall.spoken", fields: [
            "intent": "\(intent)",
            "recorded": answer == SpokenRecall.nothingRecorded ? "false" : "true",
        ])
        return answer
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

    /// The arithmetic of `promptText` at every cap at once, so the viability floor can be
    /// derived rather than guessed — the counterpart to
    /// `DefaultApprovalRequestPresenter.maximumPromptCharacters`, which documents the shape
    /// of this sum in more detail:
    ///
    ///     introduction           122   120 cap + terminator + separating space
    ///     question                97   96 cap + terminator
    ///     " "                      1
    ///     "N of M:"               12   an allowance; the shipped flows offer a handful
    ///     " "                      1
    ///     label                   49   48 cap + terminator
    ///     " " + controls          48   an allowance; the two shipped hints are 30 and 37
    ///     ────────────────────────────
    ///                            330
    ///
    /// The last two are allowances rather than caps because `controlsHint` is an injected
    /// closure and the option count is the caller's. Both are measured exactly on the
    /// per-utterance re-check, which is what the entry floor's promise is checked against.
    ///
    /// `nonisolated` for `CommandWindowController.windowSeconds`'s reason: the viability
    /// floor is derived off the main actor, at the command line, before any controller
    /// exists.
    public nonisolated static let maximumPromptCharacters = 122 + 97 + 1 + 12 + 1 + 49 + 48

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
