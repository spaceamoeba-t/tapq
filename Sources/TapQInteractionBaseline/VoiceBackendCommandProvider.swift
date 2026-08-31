import Foundation
import TapQContracts

/// Whether a backend session spans a single window or a whole conversation.
///
/// `.perWindow` — the M1 default: every `start()`/`stop()` cycle opens and closes the
/// backend session. Existing behavior, byte-identical.
///
/// `.conversation(idleClose:)` — the session is opened on the first `start()` and
/// outlives individual windows. Turns are per-window; the session is per-conversation.
/// After a window closes, an idle timer starts; if no new `start()` arrives before the
/// timer expires and no window is open, the session is closed. A subsequent `start()` after
/// idle-close reopens from scratch.
public enum SessionPolicy: Sendable, Equatable {
    case perWindow
    case conversation(idleClose: TimeInterval)
}

/// Presents any `VoiceBackend` as the `VoiceCommandProviding` the arbiter already consumes,
/// so swapping the speech pipe underneath TapQ never reaches the interaction layer.
///
/// The window shape is the one `VoiceListener` established and every composition above
/// depends on: one `start` opens a session and exactly one user turn, the first matched
/// transcript resolves the window and tears it down, and `stop` closes everything. Turns
/// are opened only inside `start`, which is what keeps the microphone from being live
/// between windows no matter which backend is plugged in.
///
/// In conversation mode (`SessionPolicy.conversation`), `start` opens a new turn on the
/// existing session rather than opening a new session each time. The session stays open
/// across windows so WebSocket reconnect churn is eliminated. The backend session is closed
/// either by `shutdown()` or by the idle timer when no window is open.
///
/// A window that comes due while the backend is mid-sentence waits for the sentence rather
/// than cutting it off: the turn is deferred until `responseCompleted`. Two things still
/// stop a response the instant they happen, because both mean the sentence has lost its
/// audience — the wearer talking over it (`cancelActiveResponse`), and the window that
/// response belonged to being resolved *by the wearer* (the suppression paths in
/// `endWindowKeepSession` and the first `.audio`). A clock coming round is neither, and
/// under `--voice-session` it is the loop's heartbeat: `stopUnresolved` is how a window that
/// nobody answered ends without touching what TapQ is still saying.
///
/// Every degraded path fails open in the same direction as the rest of the voice channel:
/// a session that cannot be opened, or one that dies mid-window, delivers nothing and
/// stays quiet. The window still resolves by gesture, tap, or timeout — a voice backend
/// must never be able to make a window hang.
@MainActor public final class VoiceBackendCommandProvider: VoiceCommandProviding {
    /// The keyword grammar, injected rather than defaulted.
    ///
    /// `VoiceCommandMatcher` lives in `TapQDetectionBaseline`, and this module deliberately
    /// depends on nothing but `TapQContracts`; composition passes `VoiceCommandMatcher.match`.
    public typealias TranscriptMatching = @MainActor (String) -> VoiceCommand?

    private let backend: any VoiceBackend
    /// The grammar, or `nil` where there is none.
    ///
    /// `nil` is not "no rules configured yet" — it is the shape of a composition that
    /// resolves intent by tool calling, and the realtime host passes no matcher at all. That
    /// is the point: on that path there is no object a later edit could reach for to "just
    /// check the transcript as well", because the composition never built one.
    private let match: TranscriptMatching?
    private let diagnostics: TapQDiagnosticEmitter
    private let sessionPolicy: SessionPolicy
    private let supportsBargeIn: Bool
    private let monotonicNow: @MainActor () -> TimeInterval
    private let responseAudio: (any VoiceResponseAudioPlaying)?
    private let freeformEnabled: Bool
    /// Where this provider takes the wearer's intent from. See `VoiceIntentSource`.
    private let intentSource: VoiceIntentSource
    private let idleSleep: @MainActor (TimeInterval) async -> Void
    /// Answers a wearer's question about an agent's work, or `nil` where there is no
    /// transcript to answer from.
    ///
    /// Its presence is the whole gate on `ask_about_work`: with it, the tool is declared to
    /// every session this provider opens; without it, the tool does not exist on the wire
    /// and a call for it is a protocol failure like any other undeclared name. That is why
    /// it is an initializer parameter and not a settable property — the declaration goes out
    /// on the first frame of the first session, so "is there a transcript?" has to be
    /// answered before this object exists rather than after.
    private let answerWorkQuestion: (@MainActor (String, String?) async -> WorkQuestionOutcome)?
    /// TapQ's deliberation loop, or `nil` where none is composed.
    ///
    /// The seam of `docs/TAPQ_AGENT_PLAN.md` Pillar C, and it gates `start_task` on exactly
    /// the terms `answerWorkQuestion` gates `ask_about_work`: with a loop the tool is declared
    /// to every session this provider opens, and without one it does not exist on the wire.
    /// An initializer parameter rather than a settable property for the same reason as well —
    /// the declaration rides the first frame of the first session, so the question has to be
    /// answered before this object exists.
    ///
    /// It is the protocol rather than a closure, unlike its neighbor, because the contract is
    /// the protocol: `WearerTaskStarting` is what the other half of M2 implements and what
    /// pins "one task at a time, the caller speaks what comes back". Nothing about a loop is
    /// visible here beyond that one method — this provider hands over a sentence the wearer
    /// said and gets back a sentence to say, and every later thing the loop speaks arrives on
    /// the same scripted channel through composition, not through this reference.
    private let startWearerTask: (any WearerTaskStarting)?
    /// Reports whether TapQ's own wearer turn signal is live. `nil` — the default, and every
    /// composition that predates the degrade path — means "assume it is", which keeps turn
    /// arbitration on TapQ's side exactly as it has always been.
    private let isWearerTurnSignalLive: (@MainActor () -> Bool)?

    private var handler: (@MainActor (VoiceCommand) -> Void)?
    private var sessionOpen = false
    private var turnActive = false

    /// In `.perWindow` mode this serves as both session and window identity. In
    /// `.conversation` mode only `sessionGeneration` guards backend events; this counter
    /// is bumped on each window cycle but is not used in the event handler.
    private var windowGeneration: UInt64 = 0
    /// Guards backend events in `.conversation` mode. Bumped only when the session is
    /// opened or torn down, so events from the live session are never dropped between
    /// windows.
    private var sessionGeneration: UInt64 = 0

    // -- Conversation mode state --
    /// Generation counter for the idle-close task.
    private var idleGeneration: UInt64 = 0
    /// True when `shutdown()` has been called. Prevents further opens.
    private var isShutDown = false
    /// When true, the next `responseCompleted` event should begin a deferred user turn.
    private var pendingUserTurn = false
    /// True after an idle-close: the next `openWindow` fires `onConversationReopened`.
    private var sessionIdleClosed = false
    /// Whether a freeform command has been delivered in the current turn.
    /// Prevents multiple freeform deliveries per turn (one-shot per turn).
    private var freeformDeliveredThisTurn = false
    /// True once `endWindowKeepSession` has run for the window that is open now.
    ///
    /// A window resolved by a tool call is ended twice — `deliver` closes it before handing
    /// the command over, and the interaction layer's `stop()` follows a moment later — and
    /// before 2026-08-28 both ran the whole ending, including arming suppression against a
    /// response the first call had already accounted for. Reset by `start()` and by teardown,
    /// so a second *window* is never mistaken for a second ending of the first.
    private var windowEndRan = false

    /// True while the window is paused by `pauseListening()` (activity-driven mic close).
    /// Audio routing continues so response playback is not interrupted; transcripts and
    /// command delivery are suspended. Cleared by the next `start()`.
    private var windowPaused = false

    // -- Scripted speech (voice-output isolation) --

    /// Sentences TapQ wrote that are waiting for a legal moment on the backend, oldest
    /// first. See `speakScripted(_:)` for why they queue rather than fall back.
    private var scriptedQueue: [String] = []

    /// True while a `backend.open` is in flight, from either door — a window opening or a
    /// sentence with nowhere to be spoken. One open at a time: two concurrent handshakes
    /// would race to install event callbacks on the same session identity.
    private var sessionOpening = false

    // -- Model-resolved intent (`.modelToolCalls` only) --

    /// The sentences TapQ has spoken since the last window closed, oldest first.
    ///
    /// This is the grounding, and it is grounding TapQ already gave away: every one of these
    /// was sent to the backend to be read out loud a moment ago, so restating them as context
    /// tells the model nothing it was not already told, and tells the *wearer* nothing they
    /// did not already hear. That equivalence is what makes the redaction rule hold by
    /// construction rather than by review — a request's tool input, its working directory, and
    /// its permission mode are not spoken, so they cannot arrive here.
    ///
    /// Cleared when a window ends rather than when one starts, because the prompt a window is
    /// about to be answered on is spoken *before* `start()` — `BargeIn` speaks and opens the
    /// window in the same main-actor turn. Clearing on start would throw away the one sentence
    /// the model most needs.
    private var spokenSinceWindowEnded: [String] = []

    /// How many of those sentences the model is given. The grounding is meant to say what the
    /// wearer is answering *now*; a longer history is a longer prompt in which an older
    /// question can be mistaken for the open one.
    static let maxGroundedSentences = 4

    /// The last grounding sent, so an unchanged one is not re-sent. A `session.update` per
    /// turn is cheap; one per turn that changes nothing is noise in the frame log.
    private var lastGroundingSent: String?

    /// TapQ's own durable memory of this conversation, as a block to join the per-turn
    /// grounding, or `nil` when there is nothing to state.
    ///
    /// A closure returning a rendered string rather than a store, because the store lives
    /// in the context layer and this one deliberately does not depend on it — and because
    /// what a provider is allowed to know about the wearer's history is "a paragraph
    /// somebody else composed", not a reader it could query for more.
    ///
    /// `nil` — the Apple path, and every composition without a cloud backend — grounds
    /// exactly what it grounded before: there is no memory to read and no line to omit.
    /// Pillar A of docs/TAPQ_AGENT_PLAN.md, milestone M1.
    public var wearerMemoryGrounding: (@MainActor () -> String?)?

    /// Fired with each sentence TapQ has just handed the backend to read aloud, so a host
    /// can keep a durable record of what the wearer heard.
    ///
    /// It sits inside `noteSpoken`, which already exists for the grounding and already
    /// returns early on the grammar path — so this observer is structurally unreachable
    /// off a model-backed session rather than disabled on one. What it reports is the
    /// backend's own copy: the same string, at the same moment, that the wearer hears.
    public var onSpokenToWearer: (@MainActor (String) -> Void)?

    /// The agents this run can currently address, for `queue_instruction`'s optional name.
    ///
    /// A closure because which sessions are live is the runtime's business and changes inside
    /// a run. `nil` — every composition with no roster — grounds the model with no names,
    /// which makes an addressed instruction resolve or be refused downstream exactly as a
    /// mis-heard name always has.
    public var liveAgentNames: (@MainActor () -> [String])?

    /// How many scripted sentences may wait at once.
    ///
    /// The queue exists to absorb the ordinary half-duplex wait — one response in flight,
    /// the next sentence right behind it — not to buffer a backend that has stopped
    /// speaking. A queue deeper than this means sentences are arriving faster than the
    /// specified backend can say them, which is a pipe that is not carrying TapQ's voice;
    /// the oldest is dropped and reported as the pipeline failure it is.
    static let maxQueuedScriptedUtterances = 8

    /// Fired when a scripted sentence can never be spoken by this backend: the session
    /// could not be opened, the session died with sentences still waiting, or the queue
    /// overflowed.
    ///
    /// It exists because the answer to "the backend cannot say this" is **not** to say it
    /// in TapQ's own voice. A run that asked for one backend and got two voices has been
    /// silently given a different product, so an undeliverable sentence is a voice-pipeline
    /// failure: composition wires this to `VoiceBrokenState.noteBackendFailed`, which
    /// breaks hands-free voice for the run, loudly and once.
    ///
    /// `nil` — the Apple path, and every test that composes no latch — means an
    /// undeliverable sentence is recorded and dropped, which is what a host with no failure
    /// boundary can honestly do about it.
    public var onScriptedSpeechUndeliverable: (@MainActor (String) -> Void)?

    /// Fired when the tool path — the only path to the wearer's intent on a model-backed
    /// session — has broken: an undeclared tool, arguments that cannot be read, a call on a
    /// session that declared none.
    ///
    /// It is a sibling of `onScriptedSpeechUndeliverable` and composition wires it to the
    /// same latch, for the mirror-image reason. That one fires when TapQ cannot be heard;
    /// this one fires when the wearer cannot be understood. Neither has a fallback: the
    /// fallback for speech would be a second voice, and the fallback for intent would be
    /// matching words against a grammar — which is the behavior the realtime path exists to
    /// no longer have.
    public var onIntentPipelineFailed: (@MainActor (String) -> Void)?

    /// Fired when the cloud call behind `ask_about_work` failed — an HTTP error, a timeout,
    /// a refusal, a response that did not decode.
    ///
    /// A third sibling of the two hooks above, wired by composition to the same latch, and
    /// separate from them for the same reason narration's is: the failure originates in a
    /// side call rather than in this provider's own traffic, and an operator reading the log
    /// needs to know which of the three broke. The posture is identical — the model family
    /// and endpoint are narration's, so the answer is narration's answer: break, and do not
    /// assemble a half-answer locally out of the slices TapQ selected.
    ///
    /// A transcript that cannot be *read* never reaches here. That is not a broken pipe, and
    /// the wearer is told about it out loud instead.
    public var onWorkAnswerFailed: (@MainActor (String) -> Void)?

    /// Observer fired after match evaluation for every final transcript in the current turn.
    /// The callback receives the transcript text and whether it matched a command.
    /// Needed by WP8 (free-form answers); inert until assigned.
    public var onTranscriptFinal: ((@MainActor (String, _ matched: Bool) -> Void))?

    /// Observer fired when the session reopens after an idle-close — the one moment a
    /// conversation-mode provider starts a *new* conversation on the same run.
    ///
    /// Fired before `backend.open`, so anything a host resets here is in force for the
    /// session that is about to exist rather than the one that just ended. No shipping
    /// composition assigns it today: it existed to re-probe a cross-backend fallback, and
    /// under the break policy there is no fallback and a dead backend is never re-probed.
    /// Kept because "a new conversation began" is a fact about this provider, not about
    /// that composition, and the accompanying `session.reopened_after_idle` diagnostic is
    /// how an operator reads conversation boundaries out of the log.
    public var onConversationReopened: (@MainActor () -> Void)?

    public init(backend: any VoiceBackend,
                match: TranscriptMatching? = nil,
                intentSource: VoiceIntentSource = .transcriptGrammar,
                sessionPolicy: SessionPolicy = .perWindow,
                supportsBargeIn: Bool = false,
                responseAudio: (any VoiceResponseAudioPlaying)? = nil,
                freeformEnabled: Bool = false,
                isWearerTurnSignalLive: (@MainActor () -> Bool)? = nil,
                answerWorkQuestion: (
                    @MainActor (String, String?) async -> WorkQuestionOutcome
                )? = nil,
                startWearerTask: (any WearerTaskStarting)? = nil,
                monotonicNow: @escaping @MainActor () -> TimeInterval = {
                    ProcessInfo.processInfo.systemUptime
                },
                idleSleep: @escaping @MainActor (TimeInterval) async -> Void = {
                    try? await Task.sleep(for: .seconds($0))
                },
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.backend = backend
        self.match = match
        self.intentSource = intentSource
        self.sessionPolicy = sessionPolicy
        self.supportsBargeIn = supportsBargeIn
        self.responseAudio = responseAudio
        self.freeformEnabled = freeformEnabled
        self.isWearerTurnSignalLive = isWearerTurnSignalLive
        self.answerWorkQuestion = answerWorkQuestion
        self.startWearerTask = startWearerTask
        self.monotonicNow = monotonicNow
        self.idleSleep = idleSleep
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceBackend", sink: diagnosticSink)
        // Declared once, here, before any session exists — so the tool set rides the very
        // first frame of every session this provider ever opens, including the ones a
        // reconnect establishes. Declaring per window would leave a gap between a session
        // coming up and its tools landing, and a window that opened inside that gap would
        // hear the wearer and have nothing to do about it.
        if intentSource == .modelToolCalls {
            backend.declareTools(VoiceIntentTools.declarations(
                // Six tools where this run can read an agent's session, five where it
                // cannot. Decided here, once, for the same reason the set is declared here:
                // a session that came up before the answer is known would either be missing
                // the tool or offering one nothing can carry out.
                includingAskAboutWork: answerWorkQuestion != nil,
                // And a seventh where a deliberation loop exists to hand a goal to. Its own
                // gate, read at the same instant and for the same reason: a run with no loop
                // has no seventh tool to disable, and the reflex six are untouched by whether
                // it is there.
                includingStartTask: startWearerTask != nil
            ))
        }
    }

    var isWindowOpenForTesting: Bool { handler != nil }
    var isSessionOpenForTesting: Bool { sessionOpen }

    // MARK: - VoiceCommandProviding

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        guard handler == nil else {
            diagnostics.record("start.skipped", fields: ["reason": "already_running"])
            return
        }
        guard !isShutDown else {
            diagnostics.record("start.skipped", fields: ["reason": "shutdown"])
            return
        }
        windowGeneration &+= 1
        handler = onCommand
        // A window that is opening has not been ended yet, whatever the last one did.
        windowEndRan = false
        // Cancel any pending idle-close: a window is opening.
        idleGeneration &+= 1
        // Decided here, before any turn exists, because a window is the unit the answer can
        // change on: AirPods connect and disconnect mid-run, and the turn that is about to
        // open has to be ended by whichever of the two endpointers is actually working now.
        applyTurnDetectionMode()

        switch sessionPolicy {
        case .perWindow:
            beginSessionOpen(forWindow: windowGeneration)
        case .conversation:
            let resuming = windowPaused
            windowPaused = false
            if sessionOpen {
                // Session already open: begin a new turn, but a response may still be in
                // flight from the prior window's commit. Calling beginUserTurn while the
                // adapter is in .responding would cause a protocol violation → session death.
                //
                // _responseInFlight is confirmed by audio; _responsePendingFromTurn is set
                // when the provider's own endUserTurn/endActiveTurn fires, bridging the gap
                // between the commit and the first audio delta (the session-death race).
                if _responseInFlight || _responsePendingFromTurn {
                    // A window opening is not a reason to stop a sentence. This branch used
                    // to cancel whenever barge-in was available, and what that bought on
                    // hardware (2026-08-27, `--voice-session`) was a spoken summary chopped
                    // mid-word: the loop's next eight-second listening window came due while
                    // the backend was still reading, and the window cut it off. Nobody had
                    // spoken, nobody had asked for anything new — the only event was a timer.
                    //
                    // So the wait is the default and it is bounded by the response itself:
                    // the peer owes a `response.done` for everything it starts, including
                    // one it was told to abandon, so `responseCompleted` always arrives and
                    // starts the turn (`turn.started_after_deferred`). No timer of our own —
                    // the window's own deadline is the backstop if a peer ever welches.
                    //
                    // The two cancels that mean something are elsewhere and are unchanged:
                    // `cancelActiveResponse` (the coordinator heard the wearer start talking)
                    // and the suppression paths in `endWindowKeepSession`/`.audio` (the
                    // window this response belonged to is already resolved). Both still
                    // cancel the instant they fire, and both go through the adapter's
                    // tombstone path, so the response's tail is drained rather than mistaken
                    // for a completion nobody asked for.
                    pendingUserTurn = true
                    diagnostics.record(resuming ? "turn.deferred_resume_response_in_flight"
                                                : "turn.deferred_response_in_flight")
                    return
                }
                if turnActive {
                    // The turn was preserved across an activity-driven pause (response
                    // playback started while the turn was still open). No new
                    // beginUserTurn needed.
                    freeformDeliveredThisTurn = false
                    diagnostics.record("window.resumed")
                    return
                }
                // Speech before microphone. A sentence waiting here is almost always this
                // window's own prompt: `BargeIn` speaks and opens the window in the same
                // main-actor turn, and the speech had nowhere to go — a response was still
                // draining, or the turn that just ended was still holding the pipe. Opening
                // the turn first would leave that prompt stuck behind the window it belongs
                // to and let the microphone open in silence.
                if !scriptedQueue.isEmpty {
                    flushScriptedSpeech()
                    if isResponsePending {
                        pendingUserTurn = true
                        diagnostics.record("turn.deferred_scripted_speech")
                        return
                    }
                }
                groundNextTurn()
                backend.beginUserTurn()
                turnActive = true
                freeformDeliveredThisTurn = false
                suppressionMark = nil
                diagnostics.record("window.started")
            } else if sessionOpening {
                // A session is already being established — by a scripted sentence that had
                // nowhere to be spoken, or by a window whose `stop()` raced the handshake.
                // That open finishes the job: it sees this handler and begins the turn (or
                // defers it behind whatever it just spoke). A second `backend.open` here
                // would race the first for the same session identity.
                diagnostics.record("window.awaiting_session")
            } else {
                beginSessionOpen(forWindow: windowGeneration)
            }
        }
    }

    public func stop() {
        switch sessionPolicy {
        case .perWindow:
            teardown()
        case .conversation:
            // Pass suppressResponse: true so an endpoint-created response (from a prior
            // endActiveTurn) is cancelled or armed for suppression rather than left to be
            // dropped between windows and cancelled/deferred at the next start(). When no
            // response is pending, the suppress logic is a no-op.
            endWindowKeepSession(suppressResponse: true, ending: .wearerResolved)
        }
    }

    /// The window ended with nothing in it: no command, no gesture, no tap — the clock.
    ///
    /// Everything `stop()` does except abandon what TapQ is saying. See
    /// `VoiceCommandProviding.stopUnresolved` for the hardware defect this exists for, and
    /// `endWindowKeepSession` for the rule it feeds.
    ///
    /// Per-window mode is deliberately identical to `stop()`: there the session dies with
    /// the window, so there is no sentence for a later window to inherit and a teardown that
    /// left the player running would leave audio behind a closed pipe.
    public func stopUnresolved() {
        switch sessionPolicy {
        case .perWindow:
            teardown()
        case .conversation:
            // No suppression, categorically. Arming a mark or cancelling here would be the
            // same silencing by a different door: a mark armed on a timeout fires on the
            // first audio of the answer the wearer is waiting for.
            endWindowKeepSession(suppressResponse: false, ending: .timedOut)
        }
    }

    /// Suspends command delivery without tearing down backend state.
    ///
    /// In `.perWindow` mode this is identical to `stop()`. In `.conversation` mode, the
    /// handler is cleared (transcripts are dropped) but the session, the in-flight response,
    /// and response audio playback are left untouched. This is the correct behavior when the
    /// activity signal rises because backend audio *started playing*: tearing down playback
    /// would silence the response that was just enqueued.
    ///
    /// When the pause is caused by TTS rather than backend playback (TTS starts while a turn
    /// is open), the turn is ended to uphold the invariant "a turn never spans a TTS-busy
    /// interval". The distinction is made by checking `responseAudio?.isPlaying`: if playback
    /// is active, the activity rise came from playback; otherwise it came from TTS.
    public func pauseListening() {
        switch sessionPolicy {
        case .perWindow:
            stop()
        case .conversation:
            guard handler != nil else { return }
            windowPaused = true
            handler = nil
            // End the turn only when the pause is NOT caused by response playback.
            // Backend audio starting: the turn was already committed (or is about to be
            // via the coordinator), and flushing the response would silence the answer.
            // TTS starting (e.g. notification): the turn must not span the TTS interval.
            if turnActive, !(responseAudio?.isPlaying ?? false) {
                turnActive = false
                _responsePendingFromTurn = backend.endUserTurn(expectingResponse: false)
                if _responsePendingFromTurn { noteResponseStarted(.wearerTurn) }
            }
            diagnostics.record("listening.paused")
        }
    }

    /// Tears down the entire session. For host teardown at serve exit.
    /// Idempotent.
    public func shutdown() {
        isShutDown = true
        idleGeneration &+= 1
        // Dropped rather than reported: the run is ending, and a sentence that outlived the
        // runtime asking for it is not a broken pipe.
        dropScriptedSpeech(reason: "shutdown")
        teardown()
    }

    // MARK: - Turn detection mode

    /// Which endpointer is in force, or `nil` before the question has been asked of this
    /// session. Reset to `nil` whenever the session goes away, so a fresh backend is always
    /// told explicitly rather than assumed to have inherited the last one's mode.
    private var nativeTurnDetectionOn: Bool?

    /// Chooses, for the window that is about to open, whether TapQ ends the wearer's turn or
    /// the backend's own end-of-speech detection does.
    ///
    /// The rule is one line — TapQ keeps turns while it has a wearer turn signal, and hands
    /// them over when it does not — and it is worth being explicit about why it is asked
    /// per window rather than settled once at startup. AirPods connect and disconnect while
    /// a run is going. A run that resolved the question at composition time would either
    /// leave a wearer with no AirPods talking into a buffer nobody commits until the window
    /// times out (the bug this exists to fix), or leave a wearer who has just put their
    /// AirPods in with a remote endpoint deciding where their sentences end for the rest of
    /// the day (the privacy cost this exists to keep narrow). Asking every time costs a
    /// boolean read and one frame on the sessions where the answer actually changed.
    ///
    /// Fail direction: an unknown answer counts as "signal live", so the fallback is TapQ
    /// keeping turn arbitration. That is the conservative direction — the failure it
    /// produces is a window that resolves late, not one that resolves without authorization.
    private func applyTurnDetectionMode() {
        guard backend.capabilities.supportsNativeTurnDetection else {
            // Nothing to decide: the Apple stack's recognizer finalizes transcripts from its
            // own silence heuristic, so a window there never depended on a commit. Recorded
            // once per session so the log says which of the two shapes this run is in.
            if nativeTurnDetectionOn == nil {
                nativeTurnDetectionOn = false
                diagnostics.record("turn_detection.manual", fields: ["reason": "unsupported"])
            }
            return
        }
        let native = !(isWearerTurnSignalLive?() ?? true)
        guard nativeTurnDetectionOn != native else { return }
        nativeTurnDetectionOn = native
        backend.setNativeTurnDetection(native)
        diagnostics.record(native ? "turn_detection.native" : "turn_detection.manual",
                           fields: ["reason": native ? "no_wearer_turn_signal"
                                                     : "wearer_turn_signal_live"])
    }

    /// Re-asks the question outside a window open.
    ///
    /// One caller: the host's motion-loss handler. Without it, a run started with
    /// `--imu-turn-control` and no AirPods would spend its *first* window in manual mode —
    /// the flag says AirPods are expected, and the detector only discovers the availability
    /// lie a bounded moment into that window. That is the one window a wearer with no
    /// AirPods most needs to work. The switch lands on the live session, so the turn already
    /// open is endpointed by the backend from that moment on.
    public func refreshTurnDetectionMode() {
        applyTurnDetectionMode()
    }

    // MARK: - Grounding

    /// Tells the backend what this turn is about, immediately before the microphone opens.
    ///
    /// Per turn rather than per session, because the thing the model has to get right changes
    /// per turn: which request is on the table, which list was just read, whether anything is
    /// listening at all. Per turn rather than per response, because the only moment the answer
    /// can matter is a turn in which the wearer is about to speak — a response TapQ asked for
    /// carries its own instructions, and grounding it twice would put the window's context
    /// inside a verbatim read-back.
    ///
    /// Inert on the grammar path: there is no model to ground, and a `session.update` against
    /// an Apple recognizer would be a frame with nowhere to go.
    private func groundNextTurn() {
        guard intentSource == .modelToolCalls else { return }
        let grounding = currentGrounding()
        guard grounding != lastGroundingSent else { return }
        lastGroundingSent = grounding
        backend.updateInstructions(grounding)
        diagnostics.record("tool.grounding_updated",
                           fields: ["length": "\(grounding.count)",
                                    "sentences": "\(spokenSinceWindowEnded.count)"])
    }

    /// The window brief, in the model's own reading order.
    ///
    /// Three facts and nothing else, each of them something TapQ already said out loud or
    /// something TapQ chose to state about its own state. There is no request object here, no
    /// session identifier, and no agent-supplied field — see `spokenSinceWindowEnded` for why
    /// that is structural rather than a habit.
    private func currentGrounding() -> String {
        var lines: [String] = []
        lines.append(handler != nil
            ? "A TapQ window is open: the wearer may be answering what TapQ just said."
            : "No TapQ window is open. Nothing can be approved, denied, or selected right now.")
        let recent = spokenSinceWindowEnded.suffix(Self.maxGroundedSentences)
        if recent.isEmpty {
            lines.append("TapQ has not said anything to the wearer since the last window.")
        } else {
            lines.append("What TapQ has just said to the wearer, in order:")
            for (offset, sentence) in recent.enumerated() {
                lines.append("  \(offset + 1). \(sentence)")
            }
        }
        let names = liveAgentNames?() ?? []
        if names.isEmpty {
            lines.append("No agent names are known; do not fill in queue_instruction's agent.")
        } else {
            lines.append("Agents the wearer may address by name: \(names.joined(separator: ", ")).")
        }
        // Last, and only when there is something to say. It goes after the window brief
        // rather than before it because the brief is what the wearer is answering *now*:
        // a model that read a fortnight of history first would have the open question at
        // the bottom of its prompt. Everything in the block was said or heard on this
        // voice channel, so the redaction rule holds here for the same reason it holds
        // for `spokenSinceWindowEnded`.
        if let memory = wearerMemoryGrounding?(), !memory.isEmpty {
            lines.append(memory)
        }
        return lines.joined(separator: "\n")
    }

    /// Records a sentence the wearer is about to hear, for the next turn's grounding.
    private func noteSpoken(_ text: String) {
        guard intentSource == .modelToolCalls else { return }
        onSpokenToWearer?(text)
        spokenSinceWindowEnded.append(text)
        // Bounded here as well as at read time: a window that spoke a hundred sentences
        // without opening a turn would otherwise grow this forever.
        let cap = Self.maxGroundedSentences * 2
        if spokenSinceWindowEnded.count > cap {
            spokenSinceWindowEnded.removeFirst(spokenSinceWindowEnded.count - cap)
        }
    }

    // MARK: - Turn coordination hooks (for WP7)

    /// Whether a user turn is currently active — read hook for `WearerTurnCoordinator`.
    public var isUserTurnActiveForCoordination: Bool { turnActive }

    /// Whether a response is in flight — read hook for `WearerTurnCoordinator`.
    public var isResponseInFlight: Bool { _responseInFlight }
    private var _responseInFlight = false

    /// True while a response exists on the backend that has not yet produced audio.
    ///
    /// Two sources, both ground truth rather than a proxy like `supportsBargeIn` or
    /// turn-active state: the value `endUserTurn(expectingResponse:)` reports (no turn end
    /// asks for a response today — see `endActiveTurn` — so this stays `false` unless a
    /// backend answers a commit on its own), and a `speakViaBackend` the backend accepted.
    ///
    /// In the gap between the commit+response.create and the first `.audio` delta,
    /// `start()` must not call `beginUserTurn()` — the adapter would reject it with
    /// `responseAlreadyInFlight`, killing the session.
    ///
    /// Cleared when `.audio` promotes it to `_responseInFlight`, when `.responseCompleted`
    /// settles the response, on session teardown, on idle-close, and on a fresh `openWindow`.
    private var _responsePendingFromTurn = false

    /// Whose words the response TapQ is currently tracking carries.
    ///
    /// The distinction the suppression mechanism turned out to need. A response that answers
    /// the wearer belongs to the window the wearer was answering in, and when that window is
    /// resolved the answer has lost its audience. A response carrying a sentence *TapQ wrote*
    /// belongs to nothing of the sort: it is TapQ's own voice, it is usually the sentence
    /// explaining what just happened to the window, and there is no second voice to say it
    /// with. See `endWindowKeepSession` for what that buys.
    enum ResponseOrigin: String {
        /// Nothing is being tracked.
        case none
        /// The model answering the wearer: a commit that asked for a response, or the model
        /// turn `askModelForCommittedSegment` asks for over a segment the backend committed.
        case wearerTurn
        /// A sentence TapQ wrote, sent verbatim on the scripted channel.
        case scripted
        /// `speakViaBackend` — the model saying something TapQ asked it to say in its own
        /// words. Not TapQ's voice, so not covered by the scripted invariant.
        case grounded
    }

    /// A response the resolution of a window means to abandon, bound to the response it was
    /// aimed at.
    ///
    /// The binding is the whole point, and it is what the mark did not have on 2026-08-28.
    /// An anonymous mark means "cancel whatever arrives next", and what arrived next on
    /// hardware was TapQ's own spoken refusal: a tool call resolved the window, the mark was
    /// armed against the function-call response that carried it, and the refusal TapQ queued
    /// a moment later inherited a cancellation aimed at something else. The wearer heard
    /// nothing and the log showed no cancel to explain it.
    private struct SuppressionMark {
        /// The provider's own identity for the response this mark was aimed at. Authoritative:
        /// it exists for every response TapQ asked for, named or not.
        let epoch: UInt64
        /// The peer's id for that response, when it had named it by the time the mark was
        /// armed. A cross-check and a log label, never the only binding — a peer that names
        /// nothing must not disable the mechanism.
        let wireID: String?
    }

    /// Armed when a window resolves while a response of the wearer's is pending or in flight.
    /// The response was created by a prior `endActiveTurn` (coordinator endpoint) or by the
    /// model turn a backend commit asks for, and cannot be cancelled immediately because
    /// `turnActive` is already false and/or no `.audio` has arrived yet. On the first `.audio`
    /// *of that response*, the provider cancels it instead of enqueueing. Dropped, unfired,
    /// when the response it named settles first, and never armed against TapQ's own voice.
    private var suppressionMark: SuppressionMark?

    /// Whether a mark is outstanding. The one thing the rest of the file asks about it.
    private var _responseSuppressed: Bool { suppressionMark != nil }

    /// The provider's identity for the response currently being tracked. Bumped once per
    /// response TapQ asks for, so no two responses in a session ever share one.
    private var responseEpoch: UInt64 = 0

    /// See `ResponseOrigin`. `.none` between responses.
    private var responseOrigin: ResponseOrigin = .none

    /// Records that TapQ has just asked for a response, and whose words it will carry.
    ///
    /// Called from every path that creates one, which is the same list `_responsePendingFromTurn`
    /// already had: a commit that asked for a reply, the model turn over a backend-committed
    /// segment, a grounded answer, and a scripted sentence.
    private func noteResponseStarted(_ origin: ResponseOrigin) {
        responseEpoch &+= 1
        responseOrigin = origin
    }

    /// Records that the response being tracked is over, however it ended.
    private func noteResponseSettled() {
        responseOrigin = .none
        // The permission a timed-out window granted belonged to that response and dies with
        // it. Left standing, it would admit the *next* response's audio into a run with no
        // window open — which is the one thing `audio.dropped_no_window` is there to catch.
        responseOutlivesWindow = false
    }

    /// Whether `mark` still names the response whose audio has just arrived.
    ///
    /// Three ways it may not, and each of them is a response that must be left alone: the
    /// mark was aimed at an earlier response (the hardware defect), the response now speaking
    /// is TapQ's own (belt and braces — such a mark is never armed), or the peer has named
    /// this response and it is not the one the mark recorded.
    private func suppressionApplies(_ mark: SuppressionMark) -> Bool {
        guard mark.epoch == responseEpoch else { return false }
        guard responseOrigin != .scripted else { return false }
        if let armed = mark.wireID, let current = backend.activeResponseIdentity,
           armed != current {
            return false
        }
        return true
    }

    /// The peer's id for the response in flight, as a log field.
    private var currentResponseLabel: String {
        backend.activeResponseIdentity ?? "unnamed"
    }

    /// True while the audio the player is holding is a sentence TapQ wrote.
    ///
    /// Outlives the response, and has to. A realtime peer delivers a sentence's audio far
    /// faster than the sentence takes to say: `response.done` for TapQ's refusal arrives
    /// while every sample of it is still sitting in the player. A window ending a beat later
    /// then flushed a sentence that had been fully received, fully queued, and not yet
    /// heard — no cancel, no diagnostic, the response complete on the wire, and silence in
    /// the wearer's ear. That is the shape of the 2026-08-28 report.
    ///
    /// Cleared when another response's audio takes the player over, when the wearer talks
    /// over it (`cancelActiveResponse`), and by teardown. Not cleared when the sentence
    /// simply finishes playing: a flush of a drained player is a no-op, so there is nothing
    /// to be gained by racing the last buffer to find out.
    private var playbackHoldsScriptedSpeech = false

    /// True while a response that TapQ decided to let finish is still arriving after the
    /// window it belonged to timed out.
    ///
    /// The flush is only half of what a window ending does to a sentence. The other half is
    /// the window guard on `.audio`: with no handler, no pause, and nothing scripted, every
    /// remaining chunk of a still-streaming response is dropped as `audio.dropped_no_window`.
    /// Letting playback survive a rotation and then discarding the frames that would have
    /// filled it would be the same defect with a quieter log — the answer would stop at
    /// whatever was already buffered.
    ///
    /// So this is the flush decision, remembered for as long as the response it was made
    /// about lasts. Cleared by `noteResponseSettled()`, which every path that ends a
    /// response already calls: the terminal frame, barge-in, teardown, idle-close, session
    /// failure, a fresh session.
    private var responseOutlivesWindow = false

    /// Whether the player is holding audio right now — sounding or queued.
    ///
    /// Named because the parenthesisation matters: `responseAudio?.isPlaying ?? false || x`
    /// binds as `responseAudio?.isPlaying ?? (false || x)`, which is not the question.
    private var playbackIsSounding: Bool { responseAudio?.isPlaying ?? false }

    /// Commits the current user turn without tearing down the window.
    ///
    /// Transcripts for the committed audio still route to the armed handler, so a match
    /// arriving after the commit resolves the window normally (the OpenAI flow: transcript
    /// only exists post-commit).
    ///
    /// Whether committing the wearer's turn should ask the backend to respond.
    ///
    /// On the grammar path, no: an endpointed turn the grammar did not match used to hand the
    /// whole utterance to the backend and let it answer, which is the one path where TapQ
    /// speaks a sentence nothing in TapQ wrote.
    ///
    /// On the tool path, yes, and it is not the same request. A response is how the model
    /// gets to *act* — a tool call is an item inside one, so a commit that asked for nothing
    /// would leave every sentence the wearer spoke unread and every window resolvable only by
    /// gesture, tap, or timeout. The old objection does not transfer: what comes back is
    /// either a tool call, silence, or one clarifying question, and the standing instructions
    /// say so in as many words. TapQ's own sentences still go out verbatim on the scripted
    /// channel, so nothing here can paraphrase a prompt or a read-back.
    private var commitExpectsResponse: Bool {
        intentSource == .modelToolCalls
    }

    /// Calling with no active turn is a recorded no-op — never a protocol violation surfaced
    /// to the window.
    public func endActiveTurn() {
        guard turnActive else {
            diagnostics.record("endActiveTurn.skipped", fields: ["reason": "no_active_turn"])
            return
        }
        turnActive = false
        _responsePendingFromTurn = backend.endUserTurn(expectingResponse: commitExpectsResponse)
        if _responsePendingFromTurn { noteResponseStarted(.wearerTurn) }
        diagnostics.record("turn.committed_by_coordinator",
                           fields: ["response": "\(commitExpectsResponse)"])
    }

    /// Speaks `text` in the backend's own voice instead of TapQ's synthesizer, when — and
    /// only when — the session is in a state where asking for a response is legal.
    ///
    /// The caller is `BackendPreferredSpeech`, which routes notification-priority
    /// utterances here and speaks them through the local engine on `false`. So this method
    /// is a *probe*: it reports whether the utterance was taken, and every unhappy answer
    /// is `false` rather than an error. A speech path that can throw is a speech path that
    /// can lose an utterance.
    ///
    /// Legality mirrors `VoiceTurnStateMachine.requestResponse`, which the adapters enforce
    /// by killing the session on a violation: legal from `.open` and `.committed` only. The
    /// provider's own state is the same state one level up — no session (`.idle`), an open
    /// user turn (`.userTurn`), or a response already pending, in flight, or armed for
    /// suppression (`.responding`) all decline.
    ///
    /// A taken utterance is tracked as a pending response for the same reason a committed
    /// turn's is: between `requestResponse` and the first `.audio`, a `start()` that called
    /// `beginUserTurn()` would be rejected with `responseAlreadyInFlight` and take the
    /// session down with it.
    ///
    /// - Returns: `true` when the backend was asked to speak `text`.
    @discardableResult
    public func speakViaBackend(_ text: String) -> Bool {
        let reason: String?
        if !sessionOpen {
            reason = "no_session"
        } else if turnActive {
            reason = "user_turn_open"
        } else if _responseInFlight || _responsePendingFromTurn || _responseSuppressed {
            reason = "response_in_flight"
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reason = "empty_text"
        } else {
            reason = nil
        }
        if let reason {
            diagnostics.record("speakViaBackend.skipped", fields: ["reason": reason])
            return false
        }
        backend.requestResponse(text: text)
        _responsePendingFromTurn = true
        noteResponseStarted(.grounded)
        diagnostics.record("speech.routed_to_backend", fields: ["length": "\(text.count)"])
        return true
    }

    // MARK: - Scripted speech

    /// Whether the backend is holding a response of any kind — created, playing, or armed
    /// for suppression. The one condition every "may TapQ start speaking now" question
    /// shares.
    private var isResponsePending: Bool {
        _responseInFlight || _responsePendingFromTurn || _responseSuppressed
    }

    /// Why a sentence cannot go out this instant, or `nil` when one can.
    ///
    /// The same legality `speakViaBackend` probes, named rather than returned as a bare
    /// `false`, because a scripted sentence does not fall back on a `false` — it waits.
    private var scriptedSpeechBlocker: String? {
        if !sessionOpen { return "no_session" }
        if turnActive { return "user_turn_open" }
        if isResponsePending { return "response_in_flight" }
        return nil
    }

    /// Speaks one sentence TapQ wrote in the specified backend's own voice, waiting for a
    /// legal moment rather than falling back to a second voice.
    ///
    /// This is the whole of the voice-output isolation decision expressed as one method.
    /// `speakViaBackend` above is a *probe*: it reports `false` and its caller says the
    /// sentence some other way. That is the right shape for a grounded answer, which is
    /// optional. It is the wrong shape for everything else TapQ says, because "some other
    /// way" is the local synthesizer, and a run that asked for `--voice-backend
    /// openai-realtime` and heard two alternating voices — one of which leaked into the
    /// open microphone and was transcribed as the wearer — was not given the backend it
    /// asked for.
    ///
    /// So there are only three answers here and none of them is "TapQ will say it itself":
    ///
    /// * `.spoken` — handed to the backend now.
    /// * `.queued` — the pipe is busy (a response is draining, a user turn is open, no
    ///   session exists yet). The sentence keeps its place in line and goes out at the next
    ///   legal moment; when there is no session, one is opened for it.
    /// * `.dropped` — nothing to say, or the run is ending. Neither is a failure.
    ///
    /// The fourth outcome — the sentence can never be spoken — is not a return value,
    /// because it is usually discovered long after the caller has moved on (an `open` that
    /// fails a handshake later, a session that dies mid-queue). It arrives at
    /// `onScriptedSpeechUndeliverable` instead, and composition turns it into the run's
    /// voice break.
    @discardableResult
    public func speakScripted(_ text: String) -> BackendSpeechDelivery {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            diagnostics.record("scripted_speech.skipped", fields: ["reason": "empty_text"])
            return .dropped("empty_text")
        }
        guard !isShutDown else {
            diagnostics.record("scripted_speech.skipped", fields: ["reason": "shutdown"])
            return .dropped("shutdown")
        }
        if let blocker = scriptedSpeechBlocker {
            enqueueScripted(text)
            diagnostics.record("speech.queued_for_backend",
                               fields: ["reason": blocker, "depth": "\(scriptedQueue.count)"])
            if blocker == "no_session" { openSessionForSpeech() }
            return .queued
        }
        // Order is part of the contract: a read-back that overtook the prompt it answers
        // would be worse than either of them arriving late.
        guard scriptedQueue.isEmpty else {
            enqueueScripted(text)
            flushScriptedSpeech()
            return .queued
        }
        sendScripted(text)
        return .spoken
    }

    /// Forgets every waiting sentence without calling it a failure. Teardown paths only.
    public func dropScriptedSpeech(reason: String) {
        guard !scriptedQueue.isEmpty else { return }
        diagnostics.record("scripted_speech.dropped",
                           fields: ["reason": reason, "count": "\(scriptedQueue.count)"])
        scriptedQueue.removeAll()
    }

    /// Hands the oldest waiting sentence to the backend, if one may go out now.
    ///
    /// Exactly one, always: TapQ runs half-duplex and the backend carries one response at a
    /// time, so the sentence behind it waits for `responseCompleted` — which is where this
    /// is called again.
    private func flushScriptedSpeech() {
        guard !scriptedQueue.isEmpty, scriptedSpeechBlocker == nil else { return }
        sendScripted(scriptedQueue.removeFirst())
    }

    private func sendScripted(_ text: String) {
        backend.requestScriptedSpeech(text: text)
        // Recorded at the moment it goes out rather than when it was written, so the model's
        // grounding lists what the wearer is actually hearing, in the order they hear it.
        noteSpoken(text)
        // Tracked exactly as a committed turn's response is, and for the same reason: until
        // the first `.audio`, a `beginUserTurn()` would be rejected as
        // `responseAlreadyInFlight` and take the session down with it.
        _responsePendingFromTurn = true
        // Marked as TapQ's own voice, which is what makes it unsuppressable. See
        // `ResponseOrigin` and `endWindowKeepSession`.
        noteResponseStarted(.scripted)
        diagnostics.record("speech.routed_to_backend", fields: ["length": "\(text.count)"])
    }

    private func enqueueScripted(_ text: String) {
        scriptedQueue.append(text)
        while scriptedQueue.count > Self.maxQueuedScriptedUtterances {
            let dropped = scriptedQueue.removeFirst()
            reportUndeliverable("queue_overflow", count: 1,
                                fields: ["length": "\(dropped.count)"])
        }
    }

    /// Abandons everything waiting and reports the pipe as broken.
    private func failScriptedSpeech(reason: String) {
        guard !scriptedQueue.isEmpty else { return }
        let count = scriptedQueue.count
        scriptedQueue.removeAll()
        reportUndeliverable(reason, count: count, fields: [:])
    }

    private func reportUndeliverable(_ reason: String, count: Int,
                                     fields: [String: String]) {
        var all = fields
        all["reason"] = reason
        all["count"] = "\(count)"
        // Error, not warning: this is a sentence the wearer was supposed to hear and did
        // not, on a channel that has no second voice to say it with.
        diagnostics.record("scripted_speech.undeliverable", level: .error, fields: all)
        onScriptedSpeechUndeliverable?(reason)
    }

    /// Opens a session because something has to be said and there is nowhere to say it.
    ///
    /// Only in conversation mode. A per-window session belongs to a window, and opening one
    /// outside a window would leave a session nothing ever closes; there, a waiting
    /// sentence goes out when the next window's session opens.
    private func openSessionForSpeech() {
        guard case .conversation = sessionPolicy else { return }
        guard !isShutDown, !sessionOpen, !sessionOpening else { return }
        diagnostics.record("speech_session.opening")
        beginSessionOpen(forWindow: nil)
    }

    /// Claims the right to open a session, then opens it.
    ///
    /// The claim is synchronous and the open is not, and that gap is the whole reason this
    /// exists. `BargeIn` speaks and opens a window in one main-actor turn: the sentence
    /// starts an open, the window arrives before that task has run a single line, and a
    /// `sessionOpening` set inside the task would still read `false`. Two handshakes would
    /// then race for one session identity — and the second one's `beginUserTurn` would open
    /// a microphone over the sentence the first was still reading, which is the exact defect
    /// this whole path exists to remove.
    private func beginSessionOpen(forWindow generation: UInt64?) {
        sessionOpening = true
        Task { @MainActor [weak self] in
            await self?.openSession(forWindow: generation)
        }
    }

    /// Cancels the active backend response (barge-in). Only fires when a response is in
    /// flight and the inner pipe supports barge-in (via the `supportsBargeIn` hint).
    ///
    /// This is the cancel that a window opening is not: the wearer has started talking over
    /// the backend, so the sentence is cut off now rather than waited out. It is unaffected
    /// by the deferral in `start()` — and it also *ends* one. A window whose turn is waiting
    /// for this response has just had its reason to wait removed, so the turn opens here
    /// instead of a `responseCompleted` later, which is the difference between catching the
    /// wearer's first word and catching their second.
    public func cancelActiveResponse() {
        guard _responseInFlight, supportsBargeIn else {
            diagnostics.record("cancelActiveResponse.skipped",
                               fields: ["reason": _responseInFlight ? "barge_in_unsupported" : "no_response"])
            return
        }
        backend.cancelResponse()
        _responseInFlight = false
        _responsePendingFromTurn = false
        // Deliberately origin-blind, and the one cancel path that is. Barge-in is the wearer
        // talking over whatever is speaking; when that is TapQ's own sentence, stopping it is
        // exactly what they asked for. The scripted invariant is about a *window resolving*
        // silencing TapQ, not about the wearer interrupting it.
        let cancelledLabel = currentResponseLabel
        suppressionMark = nil
        noteResponseSettled()
        playbackHoldsScriptedSpeech = false
        responseAudio?.stopAndFlush()
        diagnostics.record("response.cancelled_by_coordinator",
                           fields: ["response_id": cancelledLabel])
        // The cancelled response still owes a terminal frame, and the adapter still forwards
        // it as `responseCompleted`. That event finds `pendingUserTurn` already spent and
        // begins nothing, which is what keeps a turn from being opened twice.
        guard pendingUserTurn, handler != nil else { return }
        pendingUserTurn = false
        groundNextTurn()
        backend.beginUserTurn()
        turnActive = true
        freeformDeliveredThisTurn = false
        diagnostics.record("turn.started_after_barge_in")
    }

    // MARK: - Window lifecycle

    /// Establishes the backend session, for a window or for a sentence.
    ///
    /// - Parameter generation: the window generation this open belongs to, or `nil` when
    ///   nothing is listening and the session is being opened only so a scripted sentence
    ///   has somewhere to be spoken. The window case is byte-for-byte the behavior it has
    ///   always had, including closing a session whose window was torn down mid-handshake.
    private func openSession(forWindow generation: UInt64?) async {
        // `sessionOpening` was claimed synchronously by `beginSessionOpen`; this method only
        // ever clears it.
        // Fired BEFORE backend.open: a host resetting per-conversation state here must
        // have it in force for the session about to be established, not for the one that
        // idle-closed.
        if sessionIdleClosed {
            sessionIdleClosed = false
            onConversationReopened?()
            diagnostics.record("session.reopened_after_idle")
        }

        sessionGeneration &+= 1
        let sessGen = sessionGeneration
        do {
            try await backend.open { [weak self] event in
                self?.handleEvent(event, sessionGeneration: sessGen)
            }
        } catch {
            sessionOpening = false
            // Nothing will ever carry these: the pipe the operator specified could not be
            // opened, and there is no second voice to say them in.
            failScriptedSpeech(reason: "session_open_failed")
            guard let generation else {
                diagnostics.record("speech_session.open_failed", level: .warning,
                                   fields: ["error": Self.describe(error)])
                return
            }
            guard windowGeneration == generation else { return }
            diagnostics.record("window.open_failed", level: .warning,
                               fields: ["error": Self.describe(error)])
            teardown(expectedWindowGeneration: generation)
            return
        }
        sessionOpening = false
        // Teardown or an idle-close landed during the handshake: this session belongs to
        // nobody. Bumped by both, so one check covers both.
        guard sessionGeneration == sessGen else {
            backend.close()
            retryScriptedSessionIfNeeded()
            return
        }
        if let generation, windowGeneration != generation {
            // `stop()` landed while the handshake was still in flight.
            //
            // In conversation mode a *newer* window may already be waiting on this open —
            // `start()` sees a handshake in flight and lets it finish rather than racing a
            // second one — so a live handler means this session has an owner after all and
            // is adopted. With nobody waiting, the session is ours and nobody else will ever
            // close it. Per-window keeps the old behavior exactly: there, the next `start()`
            // opened a session of its own, and closing this one is what stops the two from
            // existing at once.
            let adopted: Bool
            if case .conversation = sessionPolicy { adopted = handler != nil } else { adopted = false }
            guard adopted else {
                backend.close()
                sessionGeneration &+= 1
                retryScriptedSessionIfNeeded()
                return
            }
            diagnostics.record("session.adopted_by_newer_window")
        }
        sessionOpen = true
        // A fresh session has no in-flight response and no deferred turn. Clear
        // any stale state carried from a prior conversation that idle-closed while
        // a response was still tracked (e.g. audio arrived between windows, then
        // the session timed out before responseCompleted).
        _responseInFlight = false
        _responsePendingFromTurn = false
        suppressionMark = nil
        noteResponseSettled()
        pendingUserTurn = false
        freeformDeliveredThisTurn = false
        windowEndRan = false
        // Before the turn, always. On a run where the backend owns every sentence, the
        // first thing a fresh session is asked to do is usually to read the prompt for the
        // window that opened it — and a microphone opened ahead of that prompt is a
        // microphone listening to TapQ's own voice.
        flushScriptedSpeech()
        guard handler != nil else {
            // Nobody is listening: this session exists to carry a sentence. The idle timer
            // owns it from here, exactly as it owns the gap between two windows.
            startIdleTimer()
            return
        }
        if isResponsePending {
            pendingUserTurn = true
            diagnostics.record("turn.deferred_scripted_speech")
            return
        }
        groundNextTurn()
        backend.beginUserTurn()
        turnActive = true
        diagnostics.record("window.started")
    }

    /// Re-opens a session for sentences that outlived the open they were waiting on.
    ///
    /// The races this covers are narrow — a window torn down mid-handshake, an idle-close
    /// landing on the same frame — and both leave a queue with nowhere to drain. Dropping
    /// the sentences would be a lost utterance; failing the run would be a break caused by
    /// a timing coincidence. Asking again is neither.
    private func retryScriptedSessionIfNeeded() {
        guard !scriptedQueue.isEmpty else { return }
        diagnostics.record("speech_session.reopening", fields: ["depth": "\(scriptedQueue.count)"])
        openSessionForSpeech()
    }

    /// Route backend events. In per-window mode, events are valid only for the session
    /// generation matching the open. In conversation mode, the same session generation
    /// spans many windows; events between windows (handler == nil) are simply ignored.
    private func handleEvent(_ event: VoiceBackendEvent, sessionGeneration sessGen: UInt64) {
        guard sessionGeneration == sessGen else { return }
        switch event {
        case .transcriptPartial(let transcript):
            guard handler != nil else { return }
            consume(transcript, isFinal: false)
        case .transcriptFinal(let transcript):
            guard handler != nil else { return }
            consume(transcript, isFinal: true)
        case .toolCall(let call):
            // Deliberately *not* guarded on `handler != nil`. Every other event here is
            // something to do with a window and is ignored when there is none; a tool call is
            // a question the model is parked on, and dropping it silently would leave the
            // voice channel waiting on an answer that never comes. It is answered either way
            // — with a refusal when nothing is listening.
            handle(call)
        case .audio(let chunk):
            // A suppressed response: cancel on first audio instead of enqueueing. This
            // handles the real OpenAI ordering where a match resolves after endActiveTurn
            // created a response but before any audio arrived.
            //
            // Spent either way — a mark survives exactly one response. What it may not do is
            // survive *past* one: a mark aimed at a response that has already settled is
            // dropped here rather than applied to whatever is speaking now.
            if let mark = suppressionMark {
                suppressionMark = nil
                if suppressionApplies(mark) {
                    _responsePendingFromTurn = false
                    if supportsBargeIn {
                        backend.cancelResponse()
                    }
                    diagnostics.record("response.suppressed_on_first_audio",
                                       fields: ["response_id": currentResponseLabel,
                                                "armed_for": mark.wireID ?? "unnamed",
                                                "cancelled": "\(supportsBargeIn)"])
                    // Do not track as in-flight (we just cancelled it) and do not enqueue.
                    return
                }
                diagnostics.record("response.suppression_skipped_settled",
                                   fields: ["armed_for": mark.wireID ?? "unnamed",
                                            "arrived": currentResponseLabel,
                                            "origin": responseOrigin.rawValue])
            }
            // Track response-in-flight at session scope, before the window guard. Between
            // windows (handler == nil) the response is still in flight at the adapter level;
            // the next start() must know this to avoid a protocol violation.
            _responseInFlight = true
            // Audio confirms the response exists; the pending-from-turn report is promoted.
            _responsePendingFromTurn = false
            // Allow audio routing when paused: a pause-for-playback must not interrupt the
            // response that caused the pause. Without the windowPaused check, the first
            // enqueue raises isPlaying → CombinedSpeechActivity → SpeechGatedVoice.stop →
            // provider.pauseListening (handler = nil), and every subsequent chunk would be
            // silently dropped.
            //
            // TapQ's own sentences are exempt from the window guard entirely. A scripted
            // sentence is spoken *because* a window closed — a refusal, a read-back, the
            // notice that explains what just happened — and `openSessionForSpeech` exists to
            // open a session for one when no window is anywhere near. Gating that audio on a
            // window is how a run says something out loud into a discarded buffer.
            //
            // And so is an answer whose window rotated out from under it: under
            // `--voice-session` the eight-second clock lands in the middle of a sentence
            // routinely, and `responseOutlivesWindow` is the record of the decision the
            // rotation already made about this exact response.
            guard handler != nil || windowPaused || responseOrigin == .scripted
                    || responseOutlivesWindow else {
                diagnostics.record("audio.dropped_no_window")
                return
            }
            // An .audio event is proof a response is in flight — gate on the event stream
            // rather than on composed capabilities, which a wrapper is free to narrow.
            if let responseAudio {
                playbackHoldsScriptedSpeech = responseOrigin == .scripted
                responseAudio.enqueue(chunk)
            } else {
                diagnostics.record("audio.ignored")
            }
        case .userAudioCommittedByBackend:
            // The degraded endpoint firing: the backend's VAD heard the wearer stop and
            // committed the audio, so a transcript is on its way and the window can resolve
            // through the ordinary match path instead of waiting out its timeout.
            //
            // On the grammar path nothing else is done here, and that is deliberate. The turn
            // is *not* closed — the wearer may still be talking, the microphone is still
            // theirs, and a second sentence is committed the same way. No response was created
            // (the mode is sent with `create_response: false`), so none of the response
            // tracking moves. And the window is not resolved: only a matched transcript, a
            // gesture, a tap, or the timeout may do that, which is the half of turn
            // arbitration that never left TapQ's side. What the event buys is the transcript;
            // what it must never buy is a decision.
            //
            // On the tool path the transcript is not what the event buys, because nothing
            // reads transcripts there — see `askModelForCommittedSegment`.
            diagnostics.record("turn.committed_by_backend")
            askModelForCommittedSegment()
        case .responseCompleted:
            _responseInFlight = false
            _responsePendingFromTurn = false
            // A mark whose response ended before any audio arrived has nothing left to
            // suppress. Reported rather than dropped in silence: an armed mark that never
            // fired is exactly the state that used to leak onto the next response.
            if let mark = suppressionMark {
                suppressionMark = nil
                diagnostics.record("response.suppression_retired",
                                   fields: ["armed_for": mark.wireID ?? "unnamed",
                                            "by": "response_completed"])
            }
            noteResponseSettled()
            responseAudio?.finishStream()
            // The pipe is free, so the next sentence goes out before the microphone does.
            // A window waiting on the response that just ended keeps waiting — its turn is
            // opened by whichever `responseCompleted` finds nothing left to say — which is
            // what keeps two TapQ sentences from being separated by a listening window
            // nobody asked for.
            if !scriptedQueue.isEmpty {
                flushScriptedSpeech()
                if isResponsePending {
                    if pendingUserTurn { diagnostics.record("turn.deferred_scripted_speech") }
                    return
                }
            }
            // A deferred turn was waiting for this response to complete.
            if pendingUserTurn, handler != nil {
                pendingUserTurn = false
                groundNextTurn()
                backend.beginUserTurn()
                turnActive = true
                freeformDeliveredThisTurn = false
                diagnostics.record("turn.started_after_deferred")
            } else {
                pendingUserTurn = false
            }
        case .sessionFailed(let failure):
            diagnostics.record("session.failed", level: .warning,
                               fields: ["detail": failure.localizedDescription])
            // Sentences still waiting are sentences this run will never say. Reported
            // rather than dropped, even though the failure below is already on its way to
            // the same latch: the two are different facts, and "the wearer was not told X"
            // is the one an operator reading the log needs by name.
            failScriptedSpeech(reason: "session_failed")
            // The session is gone: ending its turn would be a call into a dead backend.
            turnActive = false
            _responseInFlight = false
            _responsePendingFromTurn = false
            suppressionMark = nil
            noteResponseSettled()
            pendingUserTurn = false
            teardown()
        }
    }

    /// Asks the model to act on a segment its own VAD just committed.
    ///
    /// This exists because the two halves of the degrade fit together badly and something has
    /// to reconcile them. Without a wearer turn signal, TapQ hands end-of-speech detection to
    /// the backend, whose VAD commits the audio and — by the carve-out's own terms — creates
    /// no response. On the grammar path that was enough: the commit produced a transcript and
    /// the transcript was the intent. On the tool path a transcript is a log line, and a tool
    /// call is an item inside a response, so a session in this mode would hear every word the
    /// wearer said and act on none of them. That is precisely the wearer this decision was
    /// ratified for — no AirPods, voice as the only channel.
    ///
    /// So TapQ ends its own turn (the buffer is already gone; the adapter sends no second
    /// commit over an empty one) and asks for the response the carve-out would not let the
    /// service start. The turn is reopened when that response completes, so a wearer who is
    /// still talking gets their microphone back for the next sentence, bounded as ever by the
    /// window's own deadline.
    ///
    /// Nothing here resolves anything. The window still ends only by a tool call, a gesture, a
    /// tap, or the timeout — and the tool call still goes through every refusal in
    /// `VoiceIntentTools`.
    private func askModelForCommittedSegment() {
        guard intentSource == .modelToolCalls else { return }
        guard handler != nil, turnActive else { return }
        guard !isResponsePending else {
            // A response is already running — a scripted sentence, or the model still working
            // on the previous segment. Asking for a second one is a protocol violation, and
            // the segment is not lost: it is in the conversation, and the model reads it with
            // the next turn.
            diagnostics.record("turn.model_turn_skipped",
                               fields: ["reason": "response_in_flight"])
            return
        }
        turnActive = false
        backend.endUserTurn(expectingResponse: false)
        if backend.requestModelTurn() {
            _responsePendingFromTurn = true
            noteResponseStarted(.wearerTurn)
            // Reopened by the `responseCompleted` this response owes, exactly as a deferred
            // window turn is.
            pendingUserTurn = true
            diagnostics.record("turn.model_turn_requested")
            return
        }
        // Nothing was created, so nothing will complete, so nothing would ever reopen the
        // turn. Reopening now is what keeps a window from going deaf on a backend that
        // declined — the same fail direction as everywhere else on this path: the microphone
        // stays available and the window ends on its own terms.
        diagnostics.record("turn.model_turn_declined", level: .warning)
        groundNextTurn()
        backend.beginUserTurn()
        turnActive = true
        freeformDeliveredThisTurn = false
    }

    /// Executes one tool call, answers the model, and resolves the window if it was an
    /// action.
    ///
    /// The order is deliberate and is the only ordering that leaves nothing parked: the
    /// result goes back *before* the window is resolved, because resolving it cancels the
    /// response the call arrived in, and a peer that had its response cancelled with a call
    /// still open would be waiting on TapQ for the rest of the session.
    private func handle(_ call: VoiceToolCall) {
        guard intentSource == .modelToolCalls else {
            // A backend calling tools on a composition that declared none. Nothing here can
            // be executed safely — TapQ does not know what it was asked for — and a channel
            // inventing actions is the loudest kind of broken.
            return failIntentPipeline(
                "the backend called a tool on a session with no tools declared")
        }
        let resolution = VoiceIntentTools.resolve(
            call,
            windowOpen: handler != nil,
            askAboutWorkDeclared: answerWorkQuestion != nil,
            startTaskDeclared: startWearerTask != nil
        )
        switch resolution {
        case .malformed(let detail):
            // Answered first so the peer is not left parked on a call whose session is about
            // to end, then reported as the pipeline failure it is. No degradation to reading
            // the transcript: a tool protocol TapQ cannot parse says nothing about whether
            // the words were understood, and guessing from them is the thing this path
            // exists to have removed.
            backend.sendToolResult(callID: call.callID,
                                   output: "That tool call could not be carried out.")
            failIntentPipeline(detail)
        case .refused(let output, let speak):
            backend.sendToolResult(callID: call.callID, output: output)
            diagnostics.record(handler == nil ? "tool.refused_no_window" : "tool.refused",
                               fields: ["name": call.name])
            // Both, always. The model learns from the tool result; the wearer learns from
            // the sentence, and only from the sentence — `sendToolResult` starts no
            // response, so nothing the model might have said about this ever reaches them.
            // It rides the scripted channel, which the suppression fix made unsuppressable,
            // because a refusal spoken a beat after a window resolved is exactly the shape
            // that used to be eaten.
            speakScripted(speak)
        case .command(let command, let output):
            backend.sendToolResult(callID: call.callID, output: output)
            diagnostics.record("tool.executed",
                               fields: ["name": call.name, "command": "\(command)"])
            deliver(command)
        case .answerWorkQuestion(let question, let agent):
            guard let answerWorkQuestion else {
                // Unreachable: `resolve` produces this case only when the tool was declared,
                // and it is declared only when this closure exists. Answered and reported
                // rather than trapped, because a crash in a voice provider is the one
                // failure mode with no diagnostic at all.
                backend.sendToolResult(callID: call.callID,
                                       output: "That tool call could not be carried out.")
                return failIntentPipeline("ask_about_work with no answerer composed")
            }
            // Named for the tool rather than for the lookup: the answerer records the
            // `ask.requested`/`ask.answered` pair with the slice counts and the latency, and
            // one question producing two identically named lines in two categories is a log
            // an operator has to disambiguate rather than read.
            diagnostics.record("tool.ask_requested",
                               fields: ["length": "\(question.count)",
                                        "agent_named": "\(agent != nil)"])
            // The one tool whose result waits. Reading the transcript and asking the answer
            // model takes seconds, and the peer holds the call for those seconds — which is
            // the honest ordering, because the result says what TapQ *did*, and until the
            // answer exists TapQ has not done it. It is bounded by the answerer's own
            // timeout, the same bound narration runs under.
            //
            // No window is resolved, before or after: a question leaves whatever the wearer
            // was asked exactly where it was.
            Task { @MainActor [weak self] in
                let outcome = await answerWorkQuestion(question, agent)
                self?.deliverWorkAnswer(outcome, callID: call.callID)
            }
        case .startTask(let goal):
            guard let startWearerTask else {
                // Unreachable on the same terms as its neighbor above: `resolve` produces
                // this case only when the tool was declared, and it is declared only when
                // this seam exists. Answered and reported rather than trapped — a crash in a
                // voice provider is the one failure mode that leaves no diagnostic at all.
                backend.sendToolResult(callID: call.callID,
                                       output: "That tool call could not be carried out.")
                return failIntentPipeline("start_task with no deliberation loop composed")
            }
            // Length only, never the goal itself. The goal is the wearer's own sentence, and
            // the log this provider writes has never held one.
            diagnostics.record("tool.start_task_requested",
                               fields: ["length": "\(goal.count)"])
            // Fast by contract: the loop takes the goal or says it is busy, and either way
            // hands back one sentence. Everything it does afterwards it does off this turn
            // and speaks on the same scripted channel through composition, so nothing here
            // waits for a task to finish. It is still a `Task`, because the seam is `async`
            // and a provider that blocked the main actor on a loop's first step would stall
            // the window it was called from.
            //
            // No window is resolved, before or after — see `deliverTaskStart`.
            Task { @MainActor [weak self] in
                let start = await startWearerTask.startTask(goal: goal)
                self?.deliverTaskStart(start, callID: call.callID)
            }
        }
    }

    /// Speaks the loop's acknowledgment, whichever of the two it is.
    ///
    /// Both cases speak, and that is the whole of this method: `accepted` and `busy` are the
    /// same event from the wearer's side — they said something and TapQ has to answer — and
    /// the contract in `WearerTask.swift` is that the caller speaks the sentence it is given,
    /// verbatim. There is no third case and no failure branch: a loop that cannot take a task
    /// says so in the sentence, so nothing here can turn a busy loop into a broken run.
    ///
    /// Verbatim on the scripted channel, like every other TapQ sentence, and for the reason
    /// `sendToolResult` makes unavoidable: no response follows a tool result, so a sentence
    /// that lived only in the output would be one the wearer never hears.
    private func deliverTaskStart(_ start: WearerTaskStart, callID: String) {
        // The result first, then the sentence — the same order every other tool uses, so the
        // peer is never parked while TapQ is talking.
        switch start {
        case .accepted(let spoken):
            backend.sendToolResult(
                callID: callID,
                output: "TapQ has taken the task and told the wearer out loud. It is working "
                    + "on it now and will speak again when it has something to say. Say "
                    + "nothing further about it."
            )
            diagnostics.record("task.accepted", fields: ["length": "\(spoken.count)"])
            speakScripted(spoken)
        case .busy(let spoken):
            backend.sendToolResult(
                callID: callID,
                output: "TapQ is already working on a task, so this goal was not started and "
                    + "was not queued. The wearer has been told out loud. Say nothing "
                    + "further about it."
            )
            diagnostics.record("task.busy", fields: ["length": "\(spoken.count)"])
            speakScripted(spoken)
        }
    }

    /// Speaks the answer, or says why there isn't one, or breaks the run.
    ///
    /// The three-way split is the failure posture from `docs/TRANSCRIPT_CONTEXT_PLAN.md`,
    /// and the middle case is the one worth stating: a transcript that cannot be read is
    /// *not* a voice break. The pipe is intact, the wearer can still be spoken to, and
    /// ending their session over a file that rotated would be the disproportionate answer.
    /// So TapQ says out loud that it cannot see the session's history and carries on.
    private func deliverWorkAnswer(_ outcome: WorkQuestionOutcome, callID: String) {
        switch outcome {
        case .answered(let text):
            // The result first, then the sentence — the same order every other tool uses, so
            // the peer is never parked while TapQ is talking.
            backend.sendToolResult(
                callID: callID,
                output: "TapQ read the session history and has spoken the answer to the "
                    + "wearer. Say nothing further about it."
            )
            diagnostics.record("ask.spoken", fields: ["length": "\(text.count)"])
            // Verbatim on the scripted channel, like every other TapQ sentence: the answer
            // model already wrote speech, and a second model rewriting it would be a
            // paraphrase of the wearer's own transcript read back to them.
            speakScripted(text)
        case .unavailable(let notice):
            backend.sendToolResult(
                callID: callID,
                output: "TapQ cannot see that session's history, and has told the wearer so "
                    + "out loud. Nothing was looked up."
            )
            diagnostics.record("ask.unavailable", level: .error)
            speakScripted(notice)
        case .failed(let reason):
            backend.sendToolResult(callID: callID,
                                   output: "That question could not be answered.")
            // Deliberately silent here: the latch this reaches speaks its own notice, and a
            // sentence from TapQ saying "I couldn't answer" would be a degraded answer on a
            // path whose whole posture is that there is no such thing.
            diagnostics.record("ask.failed", level: .error, fields: ["reason": reason])
            onWorkAnswerFailed?(reason)
        }
    }

    /// Hands a resolved command to the open window on the terms a matched transcript has
    /// always been handed to it: the window is closed first, then the callback fires.
    private func deliver(_ command: VoiceCommand) {
        let callback = handler
        switch sessionPolicy {
        case .perWindow:
            teardown()
        case .conversation:
            endWindowKeepSession(suppressResponse: true)
        }
        callback?(command)
    }

    /// Reports that intent can no longer be resolved on this channel.
    ///
    /// Wired by composition to the same latch a dead socket and an unspeakable sentence
    /// reach: with the tool path broken there is no second way to understand the wearer, and
    /// a run that went on listening would be a microphone that hears everything and does
    /// nothing. `nil` — every composition with no failure boundary — records it and carries
    /// on quietly, which is all a host with no latch can honestly do.
    private func failIntentPipeline(_ detail: String) {
        diagnostics.record("tool.protocol_failed", level: .error, fields: ["detail": detail])
        onIntentPipelineFailed?(detail)
    }

    private func consume(_ transcript: String, isFinal: Bool) {
        // The whole of the "no keyword matching on the model path" rule, in one guard.
        //
        // Under `.modelToolCalls` a transcript is a log line. It is not compared against
        // anything, no command is derived from it, and the free-form delivery below — which
        // is itself a transcript→intent path, just one with no grammar in it — does not run.
        // What the wearer meant arrives separately, as a tool call, from a model that read the
        // same audio with the window's context in front of it.
        //
        // `onTranscriptFinal` still fires, reporting `matched: false`, because its consumers
        // are observers rather than deciders: what they are being told is "these words were
        // heard and nothing was done about them", which is exactly true here.
        guard intentSource == .transcriptGrammar else {
            guard isFinal else { return }
            diagnostics.record("transcript.observed",
                               fields: ["reason": "intent_from_tool_calls",
                                        "length": "\(transcript.count)"])
            onTranscriptFinal?(transcript, false)
            return
        }
        let command = match?(transcript)
        if let command {
            diagnostics.record("command.matched", fields: ["command": "\(command)"])
            let callback = handler

            switch sessionPolicy {
            case .perWindow:
                teardown()
            case .conversation:
                endWindowKeepSession(suppressResponse: true)
            }

            if isFinal {
                onTranscriptFinal?(transcript, true)
            }
            callback?(command)
        } else {
            if isFinal {
                // The wearer said something the grammar does not know. Logged so a "voice
                // does nothing" report stays diagnosable from the log file alone.
                diagnostics.record("transcript.rejected",
                                   fields: ["reason": "unmatched",
                                            "length": "\(transcript.count)"])
                onTranscriptFinal?(transcript, false)

                // When free-form is enabled, deliver an unmatched final transcript as a
                // .freeform command exactly once per turn. Empty/whitespace-only transcripts
                // are never delivered: nothing useful can be read back or sent.
                if freeformEnabled, !freeformDeliveredThisTurn {
                    let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        freeformDeliveredThisTurn = true
                        diagnostics.record("freeform.delivered",
                                           fields: ["length": "\(trimmed.count)"])
                        handler?(.freeform(trimmed))
                    }
                }
            }
        }
    }

    // MARK: - Teardown

    /// Full teardown: ends the turn, closes the session, clears the window.
    private func teardown(expectedWindowGeneration: UInt64? = nil) {
        if let expectedWindowGeneration, expectedWindowGeneration != windowGeneration { return }
        windowGeneration &+= 1
        sessionGeneration &+= 1
        handler = nil
        spokenSinceWindowEnded.removeAll()
        _responseInFlight = false
        _responsePendingFromTurn = false
        suppressionMark = nil
        noteResponseSettled()
        pendingUserTurn = false
        windowPaused = false
        windowEndRan = false
        // The mode belonged to the session that is going away. The next one is told
        // explicitly rather than assumed to have inherited it.
        nativeTurnDetectionOn = nil
        // A full teardown flushes whatever is queued, TapQ's own sentence included: the
        // session it was going to be spoken on is being closed, so there is nothing left to
        // speak it with. That is a different fact from a window ending.
        playbackHoldsScriptedSpeech = false
        responseAudio?.stopAndFlush()
        if turnActive {
            turnActive = false
            backend.endUserTurn(expectingResponse: false)
        }
        if sessionOpen {
            sessionOpen = false
            backend.close()
        }
    }

    /// How a window ended — which is what decides whether TapQ's voice survives it.
    enum WindowEnding {
        /// The wearer ended it: a matched transcript, a tool call, a nod, a tap, or the
        /// interaction layer's `stop()` after acting on one of those.
        case wearerResolved
        /// Nothing ended it. The arbiter's own timer ran out with every channel silent.
        case timedOut
    }

    /// End the current window but keep the conversation session alive.
    /// Used in `.conversation` mode when `stop()` is called or a match resolves.
    ///
    /// When `suppressResponse` is true, any response already pending or in flight from a
    /// prior `endActiveTurn` is suppressed: if audio has arrived (`_responseInFlight`), the
    /// response is cancelled immediately; if it is still pending (`_responsePendingFromTurn`),
    /// a suppression mark is armed so the first `.audio` *of that response* cancels it
    /// instead of enqueueing. The turn-ending `endUserTurn` itself always passes
    /// `expectingResponse: false`, so no *new* response is created.
    ///
    /// ## Three rules this method has learned the hard way
    ///
    /// **It runs once per window** (2026-08-28). Two paths resolve a window whose intent came
    /// from a tool call — `deliver`, which closes the window before handing the command over,
    /// and the `stop()` the interaction layer makes when it acts on that command — and both
    /// used to arm. The second arm is not a second suppression; it is the same one written
    /// twice over a state machine that has already moved on. So the second call is a recorded
    /// no-op.
    ///
    /// **It never suppresses TapQ's own voice** (2026-08-28). A scripted response carries a
    /// sentence TapQ wrote, on a channel with no second voice behind it, and it is very often
    /// *the sentence about this window closing*: the refusal, the read-back, the notice.
    /// Cancelling it because a window ended is cancelling the explanation for the window
    /// ending. So a scripted response is exempt from both suppression branches below and from
    /// the playback flush — categorically, not as a special case of some other condition.
    ///
    /// **A window timing out is not an audience leaving** (2026-08-29). The rule above was
    /// written about the *scripted* channel, and it was too narrow by exactly one case: the
    /// model answering a question the wearer asked out loud. That answer is `.wearerTurn`,
    /// not scripted — it is the only way TapQ answers a free-form question at all — and under
    /// `--voice-session` the eight-second window rotates every eight seconds forever. Twice on
    /// hardware, an answer that began late in a window was chopped mid-sentence by the flush
    /// below, with the response already *settled* on the wire and seconds of it still sitting
    /// in the player, so no amount of gating on `_responseInFlight` would have saved it.
    ///
    /// So the ending itself is the discriminator. `.timedOut` neither flushes the player nor
    /// suppresses anything: the clock took nobody away, the wearer is still there, and the
    /// next window's microphone is held shut by `SpeechGatedVoice` for exactly as long as the
    /// player is still sounding. `.wearerResolved` keeps every behavior it has ever had —
    /// barge-in, the suppression mark, the flush — because there the audience really did move
    /// on to something else.
    private func endWindowKeepSession(suppressResponse: Bool = false,
                                      ending: WindowEnding = .wearerResolved) {
        guard !windowEndRan else {
            // The other resolve path already did all of this. Debug rather than warning:
            // two paths reaching one ending is the ordinary shape of a tool-call resolution,
            // not an anomaly — what was wrong was both of them acting on it.
            diagnostics.record("window.end_skipped_already_ended", level: .debug,
                               fields: ["suppress": "\(suppressResponse)",
                                        "ending": "\(ending)"])
            return
        }
        windowEndRan = true
        windowGeneration &+= 1
        handler = nil
        pendingUserTurn = false
        windowPaused = false
        switch ending {
        case .timedOut:
            // Nothing was taken away, so nothing is abandoned. Recorded only when there was
            // something to lose, so a rotation over a silent player stays out of the log.
            if playbackIsSounding || isResponsePending {
                responseOutlivesWindow = true
                diagnostics.record("playback.survives_rotation", level: .debug,
                                   fields: ["origin": responseOrigin.rawValue,
                                            "playing": "\(playbackIsSounding)",
                                            "pending": "\(isResponsePending)"])
            }
        case .wearerResolved:
            // A permission an earlier rotation granted does not survive a window the wearer
            // actually resolved: this ending is the one that means "moved on".
            responseOutlivesWindow = false
            // TapQ's own sentence keeps playing. Anything else has lost its audience.
            if playbackHoldsScriptedSpeech || responseOrigin == .scripted {
                diagnostics.record("playback.flush_skipped_scripted", level: .debug)
            } else {
                responseAudio?.stopAndFlush()
            }
        }
        // The window this grounding described is over, and whatever is spoken next belongs to
        // the next one: a model told about a question that has already been answered would
        // answer it again. That was the whole rule until 2026-08-30, when it turned out to
        // have a hole the size of a read-back.
        //
        // A sentence is not over when its window is. TapQ's audio routinely outlives the
        // rotation that ended the window it was spoken in — the flush above deliberately
        // spares a scripted sentence, and a timed-out rotation spares everything — and the
        // wearer is still listening to it while the next window's grounding is being written.
        // Wiping there told the model "TapQ has not said anything" about audio the wearer
        // could hear at that moment, which is how a wearer's answer to a still-playing
        // question arrives at a model that does not know the question was asked.
        //
        // So the wipe waits for the audio, not for the window. Read after the switch above,
        // so a flush that just emptied the player is already accounted for — the condition is
        // "is any of TapQ's voice still to be heard", not "was it a moment ago".
        if playbackIsSounding || isResponsePending {
            diagnostics.record("grounding.kept_undrained", level: .debug,
                               fields: ["sentences": "\(spokenSinceWindowEnded.count)",
                                        "ending": "\(ending)"])
        } else {
            spokenSinceWindowEnded.removeAll()
        }
        if turnActive {
            turnActive = false
            // TapQ does not want a spoken reply for match-resolved or stop-ended windows.
            // expectingResponse: false → commit only (for transcription), no response.create.
            // The return value is the ground truth: false means no response was created.
            _responsePendingFromTurn = backend.endUserTurn(expectingResponse: false)
            if _responsePendingFromTurn { noteResponseStarted(.wearerTurn) }
        }
        // Suppress a response that is already pending or in flight from a prior
        // endActiveTurn (coordinator endpoint). This is the real OpenAI ordering:
        // endActiveTurn → commit+response.create → transcript arrives → match resolves.
        if suppressResponse {
            if responseOrigin == .scripted {
                diagnostics.record("response.suppression_skipped_scripted",
                                   fields: ["response_id": currentResponseLabel])
            } else if _responseInFlight, supportsBargeIn {
                // Audio has confirmed the response — cancel immediately.
                backend.cancelResponse()
                _responseInFlight = false
                _responsePendingFromTurn = false
                noteResponseSettled()
                playbackHoldsScriptedSpeech = false
                responseAudio?.stopAndFlush()
                diagnostics.record("response.suppressed_match_resolved",
                                   fields: ["response_id": currentResponseLabel])
            } else if _responsePendingFromTurn {
                // The backend reported it created a response, but no audio has arrived
                // yet. Arm the mark against *that* response — by the provider's own epoch,
                // and by the peer's id where it has already named it — so the audio that
                // finally arrives is either the one this window meant to abandon or
                // untouched.
                suppressionMark = SuppressionMark(epoch: responseEpoch,
                                                  wireID: backend.activeResponseIdentity)
                diagnostics.record("response.suppression_armed",
                                   fields: ["response_id": currentResponseLabel,
                                            "origin": responseOrigin.rawValue])
            } else {
                // Nothing is pending: the response this window's turn produced has already
                // settled, or it never asked for one. Recorded because an arm that does not
                // happen is the interesting half of this fix.
                diagnostics.record("response.suppression_skipped_settled",
                                   fields: ["reason": "nothing_pending"])
            }
        }
        // The window that was holding the pipe has let go of it. Anything TapQ still has to
        // say — the answer this window's last turn produced, a notice that arrived while
        // the wearer was talking — goes out now rather than at the next window.
        flushScriptedSpeech()
        // Session and session generation stay: the backend is still alive.
        if sessionOpen {
            startIdleTimer()
        }
    }

    // MARK: - Idle timer (conversation mode)

    private func startIdleTimer() {
        guard case .conversation(let idleClose) = sessionPolicy else { return }
        idleGeneration &+= 1
        let generation = idleGeneration
        let sleep = idleSleep
        Task { @MainActor [weak self] in
            await sleep(idleClose)
            self?.fireIdleClose(generation: generation)
        }
    }

    private func fireIdleClose(generation: UInt64) {
        guard idleGeneration == generation else { return }
        // Only close if no window is currently open.
        guard handler == nil else { return }
        guard sessionOpen else { return }
        // A sentence still waiting is a reason to keep the session: closing here would
        // strand it, and re-opening for it costs a whole handshake. One more idle window is
        // the cheaper wait, and the only way to reach this is a response the peer has held
        // open for the entire idle period — which the session outliving it does not worsen.
        guard scriptedQueue.isEmpty else {
            diagnostics.record("session.idle_close_deferred",
                               fields: ["depth": "\(scriptedQueue.count)"])
            flushScriptedSpeech()
            startIdleTimer()
            return
        }
        diagnostics.record("session.idle_closed")
        sessionOpen = false
        sessionIdleClosed = true
        // Clear session-scoped tracking: the session is ending, so any in-flight
        // response from the prior conversation is gone and a deferred turn waiting
        // on responseCompleted would never fire.
        _responseInFlight = false
        _responsePendingFromTurn = false
        suppressionMark = nil
        noteResponseSettled()
        pendingUserTurn = false
        nativeTurnDetectionOn = nil
        sessionGeneration &+= 1
        backend.close()
    }

    private static func describe(_ error: any Error) -> String {
        (error as? VoiceBackendFailure)?.localizedDescription ?? String(describing: error)
    }
}
