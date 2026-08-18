import Foundation
import TapQContracts

/// Whether TapQ keeps listening for the wearer between agent requests.
///
/// The name is the promise: attention, not activation. `imu` does not open a microphone
/// that was closed — it keeps the *motion* stream up so an attributed wearer-speech onset
/// can open a short command window, and that window can only answer questions. There is
/// deliberately no case that means "and it can also approve things".
public enum AttentionMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// Detection stops with the window that opened it, as it always has. The default.
    case off
    /// The motion subscription is held open for the run, and an attributed wearer-speech
    /// onset between windows opens a `CommandWindowController`.
    case imu
}

/// What a command window did. Deliberately three counters and nothing else.
///
/// This type is the structural half of "an attention window can never resolve an agent
/// request". `InteractionController.resolve` returns a `Decision` and
/// `SelectionController.resolve` returns a `SelectionResult`; both are values a broker can
/// act on. There is no inhabitant of this struct that a broker could act on — no case, no
/// payload, no optional that could carry an allow. A future edit that tried to let an
/// attention window approve something would have to change this type first, in a diff that
/// says so out loud.
public struct CommandWindowOutcome: Sendable, Equatable {
    /// Informational answers spoken (`.status`, `.whatChanged`, `.repeatRequest`).
    public let answers: Int
    /// Request-scoped intents turned away with `CommandWindowController.nothingWaiting`.
    public let ignored: Int
    /// Dictation flows entered. Whether one reached the agent's inbox is the flow's own
    /// business and is spoken out loud; the window only records that it happened.
    public let dictations: Int

    public init(answers: Int = 0, ignored: Int = 0, dictations: Int = 0) {
        self.answers = answers
        self.ignored = ignored
        self.dictations = dictations
    }

    /// Whether the window did anything at all beyond opening and closing.
    public var isEmpty: Bool { answers == 0 && ignored == 0 && dictations == 0 }
}

/// A short, wearer-initiated window opened between agent requests: the wearer said
/// something while nothing was waiting, and TapQ answers.
///
/// The composition is the whole design — a `listen` primitive, the interaction gate, and
/// the Rung B/C responders — assembled with two hard limits the approval window does not
/// have:
///
/// 1. **It cannot resolve anything.** `run()` returns `CommandWindowOutcome`, and the
///    intents that resolve requests (`.allow`, `.deny`, `.select`, …) are answered with
///    one sentence saying there is nothing to answer. "Nothing waiting" is not an accident
///    of timing here: the window runs inside the same `InteractionGate` the agent windows
///    run in, so a request being answered means this window has not started yet.
/// 2. **It is short.** A fixed `windowSeconds` deadline, not an `InteractionBudget`
///    number. Those numbers are sized for a request whose asker is blocked on the answer
///    with a hook holding a socket open; nothing is blocked on this window, and a wearer
///    who opened it by accident should get their silence back quickly.
///
/// Everything it can say comes from injected closures, so the controller stays ignorant of
/// where memory lives and where instructions go — the discipline the approval and
/// selection windows already keep.
@MainActor public final class CommandWindowController {
    /// The fixed window length. Not derived from `InteractionBudget`: see the note above.
    ///
    /// The three constants below are `nonisolated` so a host composing off the main actor
    /// — and this type's own default argument — can read them.
    public nonisolated static let windowSeconds: TimeInterval = 8

    /// Spoken when the wearer says something that would answer a request, and there is no
    /// request. It names the situation rather than the intent — a wearer who nodded at a
    /// passing thought does not need to be told which gesture was read.
    public nonisolated static let nothingWaiting = "Nothing is waiting."

    /// The default opener. Short on purpose: the whole window is eight seconds, and the
    /// wearer is mid-sentence.
    public nonisolated static let defaultCue = "Yes?"

    /// How many turns one window will take. The deadline is the real bound; this is the
    /// backstop for what the deadline cannot see — a recognizer picking up a nearby
    /// conversation and feeding intent after intent inside the same eight seconds.
    static let maxTurns = 6

    private let speech: SpeechPresenting
    private let arbiter: InputArbitrating
    private let gate: InteractionGate
    private let cue: String
    /// Who a dictated instruction would go to, for the flow's spoken lines. A plain string
    /// because outside a request there is no `AgentIdentity` in hand — this window was
    /// opened by the wearer, not by an agent.
    private let agentDisplayName: String
    private let recallResponder: RecallResponding?
    private let dictation: InstructionDictation
    private let diagnostics: TapQDiagnosticEmitter
    /// Clock seam, as on the other controllers: deadline math reads time through this so
    /// tests can drive a virtual clock instead of racing a real eight seconds.
    var now: () -> ContinuousClock.Instant = { .now }

    /// - Parameters:
    ///   - gate: the same gate the approval and selection windows use. A private one would
    ///     let an attention window talk over a request being answered.
    ///   - cue: the opener, spoken concurrently with the first listen (barge-in), so a
    ///     wearer who is already talking is not cut off.
    ///   - recallResponder: answers `.status`/`.whatChanged`/`.repeatRequest`. Absent
    ///     means the questions are still heard and answered with the honest answer that
    ///     nothing is recorded.
    ///   - instructionEnqueue: absent — the default — makes dictation inert: the intent is
    ///     heard, nothing is spoken, and the window goes on listening.
    public init(speech: SpeechPresenting,
                arbiter: InputArbitrating,
                gate: InteractionGate,
                cue: String = CommandWindowController.defaultCue,
                agentDisplayName: String = "the agent",
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                recallResponder: RecallResponding? = nil,
                instructionCapability: InstructionCapabilityChecking? = nil,
                wearerAttribution: WearerAttributionQuerying? = nil,
                instructionEnqueue: InstructionDictating? = nil) {
        self.speech = speech
        self.arbiter = arbiter
        self.gate = gate
        self.cue = cue
        self.agentDisplayName = agentDisplayName
        let diagnostics = TapQDiagnosticEmitter(category: "CommandWindow", sink: diagnosticSink)
        self.diagnostics = diagnostics
        self.recallResponder = recallResponder
        self.dictation = InstructionDictation(capability: instructionCapability,
                                              attribution: wearerAttribution,
                                              enqueue: instructionEnqueue,
                                              diagnostics: diagnostics)
    }

    /// Opens the window and runs it to its deadline. Serialized against every other window
    /// by the shared gate.
    public func run() async -> CommandWindowOutcome {
        await gate.run { await self.loop() }
    }

    private func loop() async -> CommandWindowOutcome {
        let deadline = now() + .seconds(Self.windowSeconds)
        diagnostics.record("window.opened", fields: ["seconds": "\(Self.windowSeconds)"])
        var answers = 0
        var ignored = 0
        var dictations = 0
        /// What to say on the next listen. Cleared the moment it is handed over, so a
        /// sentence is never spoken twice and never left over after it has been.
        var pending: String? = cue
        /// The last thing this window said, so `.repeatRequest` has something to repeat.
        var lastSpoken: String?
        var turns = 0
        while turns < Self.maxTurns, deadline.seconds(after: now()) > 0 {
            turns += 1
            let utterance = pending
            pending = nil
            if let utterance { lastSpoken = utterance }
            guard let intent = await listen(speaking: utterance, until: deadline) else { break }
            diagnostics.record("input.received", fields: ["intent": "\(intent)"])
            switch intent {
            case .status, .whatChanged:
                answers += 1
                pending = recallText(for: intent)
            case .repeatRequest:
                answers += 1
                // No request is on the table, so "repeat" can only mean the last thing
                // said in here. When the window has said nothing but its cue, the recall
                // responder gets the question — it is the only party that knows whether
                // anything happened before the window opened.
                pending = lastSpoken == cue ? recallText(for: intent) : lastSpoken
            case .beginInstruction(let text):
                dictations += 1
                pending = await dictate(text, until: deadline)
            case .allow, .deny, .select, .selectByNumber, .deferToPrompt, .details,
                 .next, .previous:
                // Every intent whose meaning is "about the request" — and there is no
                // request. Said once per occurrence, and the window keeps listening: a
                // wearer who opened it to ask something may have reached for the wrong
                // word first.
                ignored += 1
                diagnostics.record("intent.ignored", fields: ["intent": "\(intent)"])
                pending = Self.nothingWaiting
            case .freeform:
                // Free text with nothing to answer it. Ignored in silence, exactly as the
                // approval window ignores it when no responder is composed: a wearer whose
                // recognizer overheard a sentence should not hear TapQ react to it.
                diagnostics.record("intent.unhandled")
            }
        }
        // The window ran out with something still to say (a last answer, or a turn that
        // never got its listen). Said now, because the listen that would have carried it
        // is not going to happen.
        if let pending { speech.speak(pending, priority: .notification, onFinish: nil) }
        diagnostics.record("window.closed", fields: [
            "answers": "\(answers)", "ignored": "\(ignored)", "dictations": "\(dictations)",
        ])
        return CommandWindowOutcome(answers: answers, ignored: ignored, dictations: dictations)
    }

    /// One turn: speak (barge-in) and listen for whatever is left of the window.
    ///
    /// `.notification` priority, not `.approval`: nothing said in here is a question the
    /// wearer must answer, and an attention window must never preempt speech that is.
    private func listen(speaking text: String?,
                        until deadline: ContinuousClock.Instant) async -> InputIntent? {
        let remaining = deadline.seconds(after: now())
        guard remaining > 0 else { return nil }
        return await BargeIn.listen(speech: speech, text: text, priority: .notification) {
            await self.arbiter.listen(timeout: min(Self.windowSeconds, remaining))
        }
    }

    /// The RC3 dictation flow, on the terms the approval and selection windows have it.
    /// The deadline is this window's own and is read, never written: dictating cannot buy
    /// the wearer a longer attention window.
    private func dictate(_ capturedText: String?,
                         until deadline: ContinuousClock.Instant) async -> String? {
        await dictation.run(capturedText: capturedText,
                            agentDisplayName: agentDisplayName) { utterance in
            await self.listen(speaking: utterance, until: deadline)
        }
    }

    private func recallText(for intent: InputIntent) -> String {
        let answer = SpokenRecall.answer(recallResponder, for: intent)
        diagnostics.record("recall.spoken", fields: [
            "intent": "\(intent)",
            "recorded": answer == SpokenRecall.nothingRecorded ? "false" : "true",
        ])
        return answer
    }
}
