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

/// Answers a spoken recall question (`.status`, `.whatChanged`) out of whatever the host
/// remembers, returning `nil` when it remembers nothing worth saying.
///
/// A closure rather than a store reference, for the reason `SelectionController.controlsHint`
/// is one: the controllers own interaction state and must stay ignorant of where memory
/// lives. It also keeps the recall path unable to reach anything but text — a responder can
/// return a sentence, and cannot return a decision.
///
/// The bound on the answer's length belongs to the responder. What is worth speaking depends
/// on how many events it is composing, and a controller-side cap could only truncate a
/// sentence its author had already fitted.
public typealias RecallResponding = @MainActor (InputIntent) -> String?

/// Offers a spoken question to whoever can answer it, returning whether it was taken.
///
/// `false` — and the absence of a responder — means the transcript is handled exactly as it
/// was before this seam existed: the window keeps listening and nothing is spoken.
public typealias FreeformQuestionResponding = @MainActor (String) -> Bool

/// What a recall question is answered with, in one place so the approval and selection
/// flows can never drift into saying different things about the same silence.
@MainActor enum SpokenRecall {
    /// Spoken when there is no responder, or the responder has nothing recorded. Silence
    /// would be indistinguishable from a missed question, and the wearer cannot see a
    /// screen to check.
    static let nothingRecorded = "Nothing recorded yet."

    static func answer(_ responder: RecallResponding?, for intent: InputIntent) -> String {
        guard let text = responder?(intent)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nothingRecorded }
        return text
    }
}

/// Whether a free-text transcript is a question, decided by the grammar and never by a
/// model: the wearer is inside an approval window, and a mis-read statement must cost at
/// most an unanswered sentence — so the test is one a reader can run in their head.
///
/// Two signals, both cheap: the transcript ends in a question mark, or it opens with an
/// interrogative. The second exists because recognizers routinely emit unpunctuated text,
/// which would make the first signal alone almost never fire on the realtime path.
enum FreeformQuestion {
    static func isQuestion(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        guard let first = trimmed.lowercased().split(whereSeparator: { !$0.isLetter }).first
        else { return false }
        return openers.contains(String(first))
    }

    /// Words that open a question. The wh-family plus the auxiliaries English inverts to
    /// ask one ("did you run the tests"), which is the shape an unpunctuated transcript
    /// arrives in. Apostrophes never reach this set: the split above keeps letters only,
    /// so "what's" is read as "what".
    static let openers: Set<String> = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "is", "are", "was", "were", "am", "do", "does", "did", "can", "could",
        "should", "would", "will", "has", "have", "had", "may", "might", "shall",
    ]
}

/// Whether the agent behind this window can be given a dictated instruction at all.
///
/// A closure for the reason `RecallResponding` is one: which agents have a text-bearing
/// turn boundary is a fact about adapters, and the controllers must stay ignorant of them.
/// A `false` answer is spoken out loud rather than swallowed — a wearer with no screen
/// cannot otherwise tell a refused dictation from an unheard one.
public typealias InstructionCapabilityChecking = @MainActor () -> Bool

/// Whether what the microphone just heard can be proved to be the wearer's own speech.
/// Backed by `WearerAttributionChecking` at composition time, and fail-closed by contract:
/// an absent closure answers no, because a runtime that cannot attribute speech has no
/// business accepting dictation.
public typealias WearerAttributionQuerying = @MainActor () -> Bool

/// Whether a nod or a tap could still confirm something in this window.
///
/// Read at the moment a read-back is composed, never at composition time: AirPods come and
/// go inside a run, and a sentence that tells the wearer to nod when nodding is impossible
/// is worse than one that tells them nothing. An absent closure — every composition that
/// predates `--voice-trust environment` — answers yes, which is what keeps the wearer-trust
/// read-backs byte-identical to the ones this repo has always spoken.
public typealias GestureConfirmationQuerying = @MainActor () -> Bool

/// What queueing an instruction did to the mailbox it went into.
///
/// Two cases, and the second is why this type exists at all. The mailbox holds four
/// instructions per session and drops the *oldest* to make room for a fifth (RC2), which
/// until 2026-08-28 happened in silence: a wearer who dictated five sentences heard "Queued"
/// five times and the agent received four. Losing one of the wearer's own sentences without
/// telling them is exactly the silence the audible-refusal decision removed, so the fact
/// comes back to the read-back and is spoken there.
///
/// Deliberately not an error and deliberately not a refusal — the newest sentence *was*
/// queued, which is the ratified rule. The wearer is told what it cost, not that it failed.
public enum InstructionQueueOutcome: Sendable, Equatable {
    /// The instruction is waiting and nothing was lost.
    case queued
    /// The instruction is waiting; the session's oldest waiting instruction was dropped to
    /// make room for it.
    case queuedDroppingOldest
    /// Nothing was queued: the sentence reached the mailbox and the mailbox had nowhere to
    /// put it — the window it was addressed to closed between the capability check and the
    /// wearer's confirmation, or the text was empty by the time it arrived.
    ///
    /// Found by the 2026-08-28 sweep, and the worst shape in the set: the read-back had
    /// already said "Queued for ⟨agent⟩" before this was known, so the wearer was not merely
    /// told nothing, they were told something untrue. Both are fixed by the same seam —
    /// the sentence is composed after the mailbox answers, not before.
    case notQueued
}

/// Hands a confirmed instruction to whoever queues it for the agent's next turn boundary.
///
/// Text in, and out comes one fact about the mailbox and nothing else: the dictation path
/// can reach the agent's inbox and learn what putting a sentence in it displaced. It still
/// cannot allow, deny, select, or defer, and the return type is the proof — an
/// ``InstructionQueueOutcome`` names nothing a controller could resolve a request with, and
/// both of its cases mean the sentence was accepted.
public typealias InstructionDictating = @MainActor (String) -> InstructionQueueOutcome

/// The RC3 dictation flow — capability, attribution, capture, read-back, confirm, queue —
/// in one place, so the approval window and the selection window can never drift into
/// dictating on different terms.
///
/// A value that runs *inside* the caller's loop rather than a controller of its own. The
/// window's deadline belongs to the caller and is never extended, paused, or restarted
/// here; when the flow ends the caller picks its own loop back up exactly where it left
/// off, with at most one sentence to say. Dictation is something that happens during a
/// window, not instead of one.
@MainActor struct InstructionDictation {
    /// One turn of the caller's window: speak `utterance` (barge-in, at the caller's own
    /// priority) and return the next intent, or `nil` when the window produced nothing.
    /// Supplying this is how each controller keeps ownership of its arbiter and its clock.
    typealias Turn = (String?) async -> InputIntent?

    let capability: InstructionCapabilityChecking?
    let attribution: WearerAttributionQuerying?
    let enqueue: InstructionDictating?
    let diagnostics: TapQDiagnosticEmitter
    /// Resolves a spoken agent name to somewhere else to send this sentence. `nil` — the
    /// default, and every composition written before addressing existed — means the flow
    /// never looks for an address, and every dictation goes to the window's own target.
    var resolveAddress: InstructionAddressResolving?
    /// Whose voice may instruct. `.wearer` — the default — keeps the fail-closed
    /// attribution check; `.environment` skips it and says so in the diagnostics.
    var trust: VoiceTrust = .wearer
    /// Whether the read-back may still ask for a nod. `nil` means yes, which is the
    /// wearer-trust composition and the wording every earlier build spoke.
    var gestureConfirmation: GestureConfirmationQuerying?

    /// Spoken when the wearer opened the flow without saying what to dictate.
    static let cue = "Go ahead."
    /// Spoken whenever a dictation ends without being queued, so the wearer never has to
    /// guess whether something was sent. Silence would be indistinguishable from success.
    static let discardedNotice = "Instruction discarded."
    /// The fail-closed refusal, spoken both for a voice that is not the wearer's and for a
    /// signal that cannot say whose it was. One sentence for both, because from the
    /// wearer's side they are the same situation and have the same remedy — say it again
    /// with the earbuds in and settled. Which of the two refused is in the diagnostic, and
    /// naming it out loud would only teach a bystander how to be believed.
    static let unattributedRefusal = "I can't confirm that was you — instruction discarded."

    /// Spoken when the mailbox took nothing after the wearer confirmed the read-back.
    ///
    /// Says it plainly rather than explaining: the cause is a window that closed underneath
    /// the confirmation, which is not a thing the wearer can perceive or act on, and the
    /// remedy is the same one every other lost dictation has.
    static let notQueuedNotice = "That wasn't queued after all — say it again."

    /// Spoken when this run has no instruction mailbox at all: `--voice-instructions` was
    /// not passed, so there is nowhere for a dictation to go.
    ///
    /// Until 2026-08-28 this was the flow's silent exit — it returned before saying
    /// anything, on the reasoning that a runtime without the flag should behave as though
    /// the phrase had never been learned. But the phrase *is* learned: on the model path
    /// `queue_instruction` is declared unconditionally, so a wearer on a run without the
    /// flag could dictate a whole sentence and hear nothing at all. Naming the configuration
    /// is right here — unlike a closed window, this is a standing property of the run, and a
    /// wearer who hears it once knows not to try again.
    static let noMailboxRefusal = "This run isn't set up to send instructions to agents."

    /// The refusal for an address nobody answers to: an agent TapQ has never served, or
    /// one whose session has gone quiet past the roster's liveness window.
    ///
    /// It names the name back rather than listing who *is* live, because the list is a
    /// sentence that grows with the fleet and the wearer's remedy is the same either way —
    /// say it again, or say it from that session's window. The name is bounded before it
    /// is spoken: it is the wearer's own speech, and a mis-segmented transcript could
    /// otherwise put a paragraph in it.
    static func unknownAgentRefusal(_ name: String) -> String {
        let spoken = SpokenText.condensed(name, maxWords: 4, maxCharacters: 40)
        return "I don't know an agent called \(spoken) — instruction discarded."
    }

    /// The refusal that says the one-session-per-adapter assumption broke.
    ///
    /// Fail closed and say why. TapQ knows two live sessions answer to this name and has
    /// no way to ask which was meant, so it refuses the routing and points at the one
    /// place where the addressee is unambiguous by construction — that session's own
    /// window, where a dictation needs no address at all.
    static func ambiguousAgentRefusal(_ agent: String) -> String {
        "More than one \(agent) session is active — say it from that session's window."
    }

    /// Runs the flow to completion, returning the sentence the caller should speak on its
    /// next listen — `nil` when there is nothing to say.
    ///
    /// Every exit is a resumption. There is no return value that ends a window, resolves a
    /// request, or chooses an option, which is the structural half of "dictation can never
    /// authorize": whatever the wearer says in here, the question they were asked is still
    /// on the table when it is over.
    func run(
        capturedText: String?,
        agentDisplayName agent: String,
        turn: Turn
    ) async -> String? {
        // Nowhere for an instruction to go. The wearer still asked for one, so they are told
        // so — see `noMailboxRefusal` for why this stopped being the flow's silent exit on
        // 2026-08-28. The window itself is unchanged: it goes on listening exactly as it did
        // before, with one sentence to say first.
        guard let enqueue else {
            diagnostics.record("instruction.no_mailbox", fields: ["agent": agent])
            return Self.noMailboxRefusal
        }
        guard capability?() ?? false else {
            diagnostics.record("instruction.unsupported_agent", fields: ["agent": agent])
            return "Instructions aren't supported for \(agent)."
        }
        // Checked before the wearer is invited to speak, so an unattributable voice is
        // turned away at the door rather than after dictating a sentence.
        guard isAttributed(stage: "begin") else { return Self.unattributedRefusal }

        var dictated = Self.speechSafe(capturedText)
        if dictated == nil {
            switch await turn(Self.cue) {
            case .freeform(let spoken):
                dictated = Self.speechSafe(spoken)
            case .none:
                // Silence is a discard like any other, and the window resumes — the caller's
                // own next listen is what decides whether the window is over.
                diagnostics.record("instruction.discarded", fields: ["reason": "silence"])
                return nil
            default:
                // A matched command is not free text. A wearer whose dictation collides
                // with the grammar ("run the tests again" is a repeat) hears that it was
                // dropped and can say it as "tell it to …" instead, which captures the
                // sentence whole and never reaches this branch.
                diagnostics.record("instruction.discarded", fields: ["reason": "not_dictation"])
                return Self.discardedNotice
            }
        }
        guard let instruction = dictated else {
            diagnostics.record("instruction.discarded", fields: ["reason": "empty"])
            return Self.discardedNotice
        }
        // The dictated sentence is a second utterance and earns its own check: the wearer
        // opening the flow does not make the next voice in the room theirs.
        guard isAttributed(stage: "text") else { return Self.unattributedRefusal }

        // Where this sentence is going, and under whose name it is read back. Both are the
        // window's own until an address says otherwise — which is what keeps an unaddressed
        // dictation byte-identical to the one this repo has always spoken.
        var target = agent
        var deliver = enqueue
        var text = instruction
        switch route(instruction) {
        case .unaddressed:
            break
        case let .routed(addressee, rest):
            target = addressee.agentDisplayName
            deliver = addressee.enqueue
            text = rest
        case let .refused(sentence):
            return sentence
        }

        // The read-back is bounded; what gets queued is not. Truncating the instruction to
        // fit the sentence would change what the agent is asked to do ("run the tests but
        // not the slow ones" → "run the tests but"), which is worse than a long utterance —
        // and `condensed` ends a shortened read-back in an ellipsis, so the wearer hears
        // that they are confirming a sentence longer than the one being spoken.
        //
        // What is read back is the routed text, under the routed name: an address that has
        // been stripped must not be spoken back as part of the sentence, and a wearer
        // confirming a routed dictation must hear which agent they are confirming it for.
        let readBack = SpokenText.condensed(text, maxWords: 24, maxCharacters: 160)
        switch await turn("Instruction: '\(SpokenText.sentence(readBack))' \(confirmCue)") {
        case .allow, .select:
            // Nod, tap, or "yes" — the same dual channel that confirms anything else, and
            // for the same reason: the read-back is the only moment the wearer hears what
            // the agent is about to be told.
            let outcome = deliver(text)
            diagnostics.record("instruction.queued",
                               fields: ["agent": target,
                                        "characters": "\(text.count)",
                                        "outcome": "\(outcome)"])
            switch outcome {
            case .queued:
                return "Queued for \(target)."
            case .queuedDroppingOldest:
                // Appended to the confirmation rather than replacing it, because two
                // separate things are true and the wearer needs both: this sentence is on
                // its way, and an earlier one no longer is. Which earlier one is not said —
                // it would be the wearer's own words read back at them minutes late, and the
                // remedy is the same either way.
                return "Queued for \(target). This replaced the oldest waiting instruction."
            case .notQueued:
                return Self.notQueuedNotice
            }
        case .none:
            diagnostics.record("instruction.discarded", fields: ["reason": "silence"])
            return nil
        default:
            diagnostics.record("instruction.discarded", fields: ["reason": "declined"])
            return Self.discardedNotice
        }
    }

    /// What an address on the dictated sentence did.
    private enum Routing {
        /// No address, or no resolver composed. The window's own target stands.
        case unaddressed
        /// The address named one live session; the instruction is what was left of it.
        case routed(InstructionAddressee, text: String)
        /// The address named no one, two someones, or an agent with no turn boundary.
        /// Nothing is queued and the sentence is what the wearer hears.
        case refused(String)
    }

    /// Reads a leading "tell ⟨agent⟩ to …" and decides where the sentence goes.
    ///
    /// Every non-resolution refuses rather than falling back to the window's own target.
    /// A wearer who named an agent meant that agent, and quietly delivering their sentence
    /// somewhere else is the one outcome that cannot be heard and corrected — they would
    /// hear "Queued for ⟨other agent⟩" only after confirming a read-back they had already
    /// approved for someone else.
    ///
    /// Diagnostics carry the resolved agent's name and never the wearer's words: an
    /// unresolved name is speech, and speech belongs in the read-back and the refusal, not
    /// in an operational log line.
    private func route(_ instruction: String) -> Routing {
        guard let resolveAddress, let address = InstructionAddress.parse(instruction) else {
            return .unaddressed
        }
        guard let resolution = resolveAddress(address.name) else {
            diagnostics.record("instruction.unknown_agent")
            return .refused(Self.unknownAgentRefusal(address.name))
        }
        switch resolution {
        case let .ambiguous(agentDisplayName):
            diagnostics.record("instruction.ambiguous_agent",
                               fields: ["agent": agentDisplayName])
            return .refused(Self.ambiguousAgentRefusal(agentDisplayName))
        case let .resolved(addressee):
            // The per-adapter table applies to the agent the sentence is *going* to, not
            // to the one that happened to open the window. Refused by name, in the same
            // words an in-window dictation at that agent would have heard.
            guard addressee.acceptsInstructions else {
                diagnostics.record("instruction.unsupported_agent",
                                   fields: ["agent": addressee.agentDisplayName])
                return .refused(
                    "Instructions aren't supported for \(addressee.agentDisplayName)."
                )
            }
            diagnostics.record("instruction.routed",
                               fields: ["agent": addressee.agentDisplayName])
            return .routed(addressee, text: address.rest)
        }
    }

    /// How the wearer is asked to confirm the read-back.
    ///
    /// The dual channel is the default and stays the default: nod, tap, or "yes". It
    /// narrows to speech alone only where the gesture half cannot arrive — no earbuds, so
    /// no nod and no tap — because a read-back that asks for a movement the wearer cannot
    /// make reads as a feature that is broken rather than one that is voice-only.
    private var confirmCue: String {
        (gestureConfirmation?() ?? true)
            ? "Nod or say yes to queue it."
            : "Say yes to queue it."
    }

    /// The fail-closed check, with the refusal diagnostic attached so both refusal points
    /// report the same event name and differ only in which stage they name.
    ///
    /// Under `.environment` there is nothing to check: the run has declared that the
    /// microphone is the user, so the check is skipped rather than answered. It is recorded
    /// at each stage the wearer-trust path would have checked, so a log can always say
    /// which of the two postures a queued instruction was accepted under — the bypass is
    /// never silent.
    private func isAttributed(stage: String) -> Bool {
        guard trust != .environment else {
            diagnostics.record("instruction.trusted_environment", fields: ["stage": stage])
            return true
        }
        guard attribution?() ?? false else {
            diagnostics.record("instruction.rejected_unattributed", fields: ["stage": stage])
            return false
        }
        return true
    }

    /// Collapses a dictated transcript to one line of ordinary text, or `nil` when nothing
    /// is left. Whitespace only: the words are the wearer's and are not otherwise edited,
    /// but a transcript carrying newlines would be read back — and queued — as something
    /// the wearer did not say in one breath.
    private static func speechSafe(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }
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
    /// Answers `.status`/`.whatChanged`. Absent — the default, and every composition
    /// written before recall existed — means the questions are still heard and still
    /// answered, with the honest answer that nothing is recorded.
    private let recallResponder: RecallResponding?
    /// Answers a spoken question inside the window. Absent means a free-text transcript
    /// is ignored exactly as it always was.
    private let freeformResponder: FreeformQuestionResponding?
    /// The dictation flow. Composed from the three injected closures; inert unless a host
    /// supplied somewhere for a confirmed instruction to go.
    private let dictation: InstructionDictation

    /// How many questions one window will answer.
    ///
    /// A budget rather than a rate limit because the failure it guards is a loop, not a
    /// cost: a wearer whose recognizer is picking up a nearby conversation could otherwise
    /// keep an approval window talking indefinitely. Three is enough to ask a question,
    /// hear the answer, and follow up once; the fourth question is silently dropped and
    /// the window is still waiting for the answer it opened for.
    static let groundedAnswerBudget = 3

    public init(speech: SpeechPresenting, arbiter: InputArbitrating,
                timeout: TimeInterval = 240,
                presenter: any ApprovalRequestPresenting = DefaultApprovalRequestPresenter(),
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                recallResponder: RecallResponding? = nil,
                freeformResponder: FreeformQuestionResponding? = nil,
                instructionCapability: InstructionCapabilityChecking? = nil,
                wearerAttribution: WearerAttributionQuerying? = nil,
                instructionEnqueue: InstructionDictating? = nil,
                instructionAddressResolver: InstructionAddressResolving? = nil,
                voiceTrust: VoiceTrust = .wearer,
                gestureConfirmation: GestureConfirmationQuerying? = nil) {
        self.speech = speech
        self.arbiter = arbiter
        self.timeout = timeout
        self.presenter = presenter
        let diagnostics = TapQDiagnosticEmitter(category: "Interaction", sink: diagnosticSink)
        self.diagnostics = diagnostics
        self.recallResponder = recallResponder
        self.freeformResponder = freeformResponder
        self.dictation = InstructionDictation(capability: instructionCapability,
                                              attribution: wearerAttribution,
                                              enqueue: instructionEnqueue,
                                              diagnostics: diagnostics,
                                              resolveAddress: instructionAddressResolver,
                                              trust: voiceTrust,
                                              gestureConfirmation: gestureConfirmation)
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
        // Questions answered inside this window. Per window, not per session: a budget
        // that outlived the request would silence the next one for reasons the wearer
        // has no way to hear.
        var answeredQuestions = 0
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
            case .status:
                utterance = recallText(for: .status)
            case .whatChanged:
                utterance = recallText(for: .whatChanged)
            case .beginInstruction(let text):
                // Dictation runs inside this window and hands it straight back. The request
                // in front of the wearer is untouched by everything that happens in there —
                // including the "yes" that confirms the read-back, which is consumed by the
                // flow and never reaches the allow path above.
                utterance = await dictate(text, for: request, deadline: deadline)
            case .freeform(let text):
                // A question asked inside the window is answered, if anyone can answer it,
                // and the window keeps listening either way. A free-form answer to an
                // approval remains out of scope: this path cannot resolve the request.
                offerQuestion(text, answered: &answeredQuestions)
            case .next, .previous, .select, .selectByNumber:
                // Navigation intents are not meaningful in approval flow — keep listening.
                break
            }
        }
    }

    /// The spoken answer to a recall question. Never `nil`: a question the wearer asked
    /// out loud gets a sentence back, even when the sentence is that there is nothing to
    /// report. The window is untouched — this is something said, not something decided.
    private func recallText(for intent: InputIntent) -> String {
        let answer = SpokenRecall.answer(recallResponder, for: intent)
        diagnostics.record("recall.spoken", fields: [
            "intent": "\(intent)",
            "recorded": answer == SpokenRecall.nothingRecorded ? "false" : "true",
        ])
        return answer
    }

    /// Runs the dictation flow against this window, returning what to say on the next
    /// listen.
    ///
    /// The deadline handed in is the window's own and is read, never written: each turn of
    /// the flow gets whatever is left of it, and a dictation that outlives the budget ends
    /// the same way an unanswered prompt does — the loop below sees no time remaining and
    /// defers to the screen.
    private func dictate(
        _ capturedText: String?,
        for request: ApprovalRequest,
        deadline: ContinuousClock.Instant
    ) async -> String? {
        await dictation.run(capturedText: capturedText,
                            agentDisplayName: request.agent.displayName) { utterance in
            let remaining = deadline.seconds(after: now())
            guard remaining > 0 else { return nil }
            return await BargeIn.listen(speech: speech, text: utterance, priority: .approval) {
                await arbiter.listenForInput(timeout: min(timeout, remaining))
            }?.intent
        }
    }

    /// Offers a free-text transcript to the question responder, spending one unit of the
    /// window's budget when it is taken.
    ///
    /// Every early return is today's behavior: no responder, not a question, or budget
    /// spent all leave the transcript ignored and the window listening. The responder
    /// speaks for itself when it accepts, which is why nothing is enqueued here.
    private func offerQuestion(_ text: String, answered: inout Int) {
        guard let freeformResponder, FreeformQuestion.isQuestion(text) else { return }
        guard answered < Self.groundedAnswerBudget else {
            diagnostics.record("qa.budget_exhausted",
                               fields: ["limit": "\(Self.groundedAnswerBudget)"])
            return
        }
        if freeformResponder(text) {
            answered += 1
            diagnostics.record("qa.answered", fields: ["answered": "\(answered)"])
        } else {
            diagnostics.record("qa.declined")
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
