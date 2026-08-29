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

/// Which of TapQ's two wearer-initiated windows this is.
///
/// The difference is what an *unmatched* sentence means. In an attention window (Rung D)
/// it means nothing — the wearer's recognizer overheard something and TapQ stays quiet. In
/// a voice-session window the wearer is standing at a turn boundary that is being held open
/// for them, so an unmatched sentence is the instruction they came to give, and the two
/// end-phrases are the only way out of the loop that does not involve queueing one.
public enum CommandWindowKind: Sendable, Equatable {
    /// The Rung D window: opened by an attributed speech onset between requests. Unmatched
    /// speech is ignored in silence.
    case attention
    /// The Rung H window: opened while a shim waits at a turn boundary. Unmatched speech
    /// enters the dictation flow with no prefix, and "end voice session" closes the loop.
    case voiceSession
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
    /// The wearer said they were done listening ("end voice session", "stop listening").
    ///
    /// It does not weaken the guarantee above. The only thing a caller may do with it is
    /// stop re-opening windows and let a held turn boundary go — which resolves nothing,
    /// approves nothing, and is exactly what the agent's Stop event would have done on its
    /// own had TapQ never held it. Always `false` for a `.attention` window.
    public let endedByWearer: Bool

    public init(
        answers: Int = 0,
        ignored: Int = 0,
        dictations: Int = 0,
        endedByWearer: Bool = false
    ) {
        self.answers = answers
        self.ignored = ignored
        self.dictations = dictations
        self.endedByWearer = endedByWearer
    }

    /// Whether the window did anything at all beyond opening and closing.
    public var isEmpty: Bool {
        answers == 0 && ignored == 0 && dictations == 0 && !endedByWearer
    }
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

    /// The opener a voice session uses at a held turn boundary. It says what TapQ is doing
    /// rather than asking a question, because nothing was asked: the agent finished, and
    /// the microphone is open for whatever comes next.
    public nonisolated static let voiceSessionCue = "Listening."

    /// Spoken as the loop lets the boundary go.
    public nonisolated static let voiceSessionEnded = "Voice session ended."

    /// Whether a *spoken* input may end the voice session.
    ///
    /// True on the Apple path, where it is the shipped behavior and the only way out of the
    /// loop that does not involve queueing an instruction. False wherever a model resolves
    /// intent (`--voice-backend openai-realtime`), and the reason is on the record: on
    /// 2026-08-28 a fragment of ordinary dictation matched the word "no", arrived as `.deny`,
    /// and ended a live session mid-test. Negation words occur constantly in speech, and a
    /// session that dies whenever one appears is unusable.
    ///
    /// It gates *voice* and nothing else. A nod, a shake, or a tap ends the session whatever
    /// this says — which is why the loop below reads the resolving channel rather than the
    /// intent alone. What is left when it is false: the session budget expiring, a gesture or
    /// a tap, and shutting the runtime down. See `docs/REALTIME_INTENT_PLAN.md`.
    private let voiceMayEndSession: Bool

    /// The sentences that close a voice session, matched on the wearer's own words because
    /// none of them is in the command grammar: "stop" and "no" arrive as `.deny`, which the
    /// window already treats as an ending, and everything here is what a wearer says when
    /// they mean it in more words than that.
    ///
    /// Reachable only while `voiceMayEndSession` is true — i.e. on the Apple path. A model
    /// path has no phrase list at all, because it has no transcript→intent step to hang one
    /// on.
    ///
    /// Compared on letters only and case-insensitively, the way `VoiceCommandMatcher`
    /// compares its runs, so punctuation a recognizer adds cannot hide a match.
    nonisolated static let endPhrases = [
        "end voice session", "end the voice session", "end session",
        "stop listening", "stop the voice session", "exit voice session",
    ]

    /// Whether `text` is one of the phrases that ends a voice session.
    nonisolated static func endsVoiceSession(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter }.joined(separator: " ")
        return endPhrases.contains(words)
    }

    /// How many turns one window will take. The deadline is the real bound; this is the
    /// backstop for what the deadline cannot see — a recognizer picking up a nearby
    /// conversation and feeding intent after intent inside the same eight seconds.
    static let maxTurns = 6

    private let speech: SpeechPresenting
    private let arbiter: InputArbitrating
    private let gate: InteractionGate
    /// The opener, or `nil` for a window that should just listen. A voice session speaks
    /// its cue once at the boundary and re-opens silently: eight-second windows that each
    /// announced themselves would talk over the wearer every time they paused to think.
    private let cue: String?
    /// Which window this is. `.attention` is the default and the shipped behavior.
    private let kind: CommandWindowKind
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
                cue: String? = CommandWindowController.defaultCue,
                agentDisplayName: String = "the agent",
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                recallResponder: RecallResponding? = nil,
                instructionCapability: InstructionCapabilityChecking? = nil,
                wearerAttribution: WearerAttributionQuerying? = nil,
                instructionEnqueue: InstructionDictating? = nil,
                instructionAddressResolver: InstructionAddressResolving? = nil,
                kind: CommandWindowKind = .attention,
                voiceTrust: VoiceTrust = .wearer,
                voiceMayEndSession: Bool = true,
                gestureConfirmation: GestureConfirmationQuerying? = nil) {
        self.voiceMayEndSession = voiceMayEndSession
        self.speech = speech
        self.arbiter = arbiter
        self.gate = gate
        self.cue = cue
        self.kind = kind
        self.agentDisplayName = agentDisplayName
        let diagnostics = TapQDiagnosticEmitter(category: "CommandWindow", sink: diagnosticSink)
        self.diagnostics = diagnostics
        self.recallResponder = recallResponder
        self.dictation = InstructionDictation(capability: instructionCapability,
                                              attribution: wearerAttribution,
                                              enqueue: instructionEnqueue,
                                              diagnostics: diagnostics,
                                              resolveAddress: instructionAddressResolver,
                                              trust: voiceTrust,
                                              gestureConfirmation: gestureConfirmation)
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
        var endedByWearer = false
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
            guard let resolved = await listen(speaking: utterance, until: deadline) else { break }
            let intent = resolved.intent
            diagnostics.record("input.received", fields: [
                "intent": "\(intent)", "channel": resolved.channel.rawValue,
            ])
            /// Whether *this* input is allowed to end the voice session. Voice is the only
            /// channel the policy narrows, so an arbiter that cannot say where an input came
            /// from is treated as not-voice — the same fail direction `ResolvedInput`
            /// documents, and safe here because ending a held boundary resolves nothing and
            /// approves nothing.
            let mayEnd = voiceMayEndSession || resolved.channel != .voice
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
            case .deny where kind == .voiceSession && mayEnd:
                // A shake, a tap, or — on the Apple path only — "stop"/"no"/"cancel". At a
                // held boundary the only thing there is to decline is the holding, so this is
                // how a wearer ends the session in one gesture or one word. In an attention
                // window it stays what it has always been: an intent about a request that does
                // not exist.
                endedByWearer = true
                diagnostics.record("voice_session.ended",
                                   fields: ["by": "deny", "channel": resolved.channel.rawValue])
            case .allow, .deny, .select, .selectByNumber, .deferToPrompt, .details,
                 .next, .previous:
                // Every intent whose meaning is "about the request" — and there is no
                // request. Said once per occurrence, and the window keeps listening: a
                // wearer who opened it to ask something may have reached for the wrong
                // word first.
                ignored += 1
                diagnostics.record("intent.ignored", fields: ["intent": "\(intent)"])
                pending = Self.nothingWaiting
            case .freeform(let text) where kind == .voiceSession:
                // The phrase check is the Apple path's, and only its. It is a transcript
                // being matched against a fixed list of sentences, which is precisely what a
                // model-resolved session does not do — and there is no tool that ends a
                // session, so on that path this branch is dictation and nothing else.
                if voiceMayEndSession, Self.endsVoiceSession(text) {
                    endedByWearer = true
                    diagnostics.record("voice_session.ended", fields: ["by": "phrase"])
                    break
                }
                // The whole point of the mode: at a boundary being held open for them, a
                // wearer's sentence *is* the instruction, so it enters the same
                // read-back-and-confirm flow "tell it to …" enters — no prefix, and no
                // shorter path to the agent's inbox than the one dictation has always had.
                dictations += 1
                pending = await dictate(text, until: deadline)
            case .freeform:
                // Free text with nothing to answer it. Ignored in silence, exactly as the
                // approval window ignores it when no responder is composed: a wearer whose
                // recognizer overheard a sentence should not hear TapQ react to it.
                diagnostics.record("intent.unhandled")
            }
            if endedByWearer {
                // Said now rather than left pending: the loop is over, so there is no next
                // listen to carry it, and a wearer who ended the session should hear that
                // it ended.
                speech.speak(Self.voiceSessionEnded, priority: .notification, onFinish: nil)
                pending = nil
                break
            }
        }
        // The window ran out with something still to say (a last answer, or a turn that
        // never got its listen). Said now, because the listen that would have carried it
        // is not going to happen.
        if let pending { speech.speak(pending, priority: .notification, onFinish: nil) }
        diagnostics.record("window.closed", fields: [
            "answers": "\(answers)", "ignored": "\(ignored)", "dictations": "\(dictations)",
        ])
        return CommandWindowOutcome(answers: answers, ignored: ignored,
                                    dictations: dictations, endedByWearer: endedByWearer)
    }

    /// One turn: speak (barge-in) and listen for whatever is left of the window.
    ///
    /// `.notification` priority, not `.approval`: nothing said in here is a question the
    /// wearer must answer, and an attention window must never preempt speech that is.
    /// `listenForInput` rather than `listen`, because the loop has to know which channel
    /// resolved it: ending a voice session is a decision voice is no longer allowed to make
    /// on every path, and an intent with no provenance cannot be held to that. Arbiters that
    /// report nothing get the protocol's `.unspecified` default and behave as they always
    /// have.
    private func listen(speaking text: String?,
                        until deadline: ContinuousClock.Instant) async -> ResolvedInput? {
        let remaining = deadline.seconds(after: now())
        guard remaining > 0 else { return nil }
        return await BargeIn.listen(speech: speech, text: text, priority: .notification) {
            await self.arbiter.listenForInput(timeout: min(Self.windowSeconds, remaining))
        }
    }

    /// The RC3 dictation flow, on the terms the approval and selection windows have it.
    /// The deadline is this window's own and is read, never written: dictating cannot buy
    /// the wearer a longer attention window.
    private func dictate(_ capturedText: String?,
                         until deadline: ContinuousClock.Instant) async -> String? {
        await dictation.run(capturedText: capturedText,
                            agentDisplayName: agentDisplayName) { utterance in
            // The dictation flow decides on the intent alone: a read-back is confirmed by a
            // nod, a tap, or a spoken yes, and all three are the same answer to the same
            // question. Provenance matters to the loop above, which is deciding whether the
            // *session* may end, and to nothing in here.
            await self.listen(speaking: utterance, until: deadline)?.intent
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
