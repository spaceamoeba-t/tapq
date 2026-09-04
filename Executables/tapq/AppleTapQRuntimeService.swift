#if canImport(TapQAppleAdapters)
import Foundation
import TapQAppleAdapters
import TapQBrokerRuntime
import TapQCLI
import TapQClaudeAdapter
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQInteractionBaseline
import TapQVoiceBackends
#if canImport(Darwin)
import Darwin
#endif

/// Decides when an attributed wearer-speech onset is allowed to open a command window, and
/// opens exactly one at a time.
///
/// Small and separate because it is the whole of "always-on" that is not already somebody
/// else's: the detector's hold keeps the samples flowing, `WearerSpeechSignalSource` decides
/// what counts as speech, `CommandWindowController` decides what a window may do, and this
/// decides *whether there should be one*. Three guards, each closing a different way for the
/// wearer to be interrupted by TapQ answering the wrong thing:
///
/// 1. **Onsets only.** The signal reports both edges; the end of a sentence is not a request
///    for attention.
/// 2. **One at a time.** The window is eight seconds of listening, and a wearer who pauses
///    mid-sentence must not stack a second window behind the first.
/// 3. **Nothing waiting.** If any request is queued at the gate, the wearer speaking is a
///    wearer answering it — the request window's own microphone is live and its grammar is
///    the one that should hear them. Opening an attention window here would serialize behind
///    that request and then answer a question nobody asked.
@MainActor private final class AttentionArming {
    private let waits: SessionWaitRegistry
    private let makeController: @MainActor () -> CommandWindowController
    private let diagnostics: TapQDiagnosticEmitter
    private var isRunning = false

    init(waits: SessionWaitRegistry,
         diagnosticSink: any TapQDiagnosticSink,
         makeController: @escaping @MainActor () -> CommandWindowController) {
        self.waits = waits
        self.makeController = makeController
        self.diagnostics = TapQDiagnosticEmitter(category: "Attention", sink: diagnosticSink)
    }

    /// Whether a command window is open right now. For diagnostics and tests.
    var isWindowOpen: Bool { isRunning }

    func wearerSpeakingChanged(_ speaking: Bool) {
        guard speaking else { return }
        guard !isRunning else {
            diagnostics.record("onset.ignored_window_open")
            return
        }
        guard waits.waitingCount == 0 else {
            // The wearer is talking to a prompt, not to TapQ.
            diagnostics.record("onset.ignored_request_waiting", fields: [
                "waiting": "\(waits.waitingCount)",
            ])
            return
        }
        isRunning = true
        diagnostics.record("window.arming")
        // Detached from the observer's turn: the signal is being broadcast from inside a
        // motion-sample callback, and an eight-second window must not run inside one.
        let controller = makeController()
        Task { @MainActor [weak self] in
            let outcome = await controller.run()
            self?.isRunning = false
            self?.diagnostics.record("window.finished", fields: [
                "answers": "\(outcome.answers)",
                "ignored": "\(outcome.ignored)",
                "dictations": "\(outcome.dictations)",
            ])
        }
    }
}

/// Keeps a listening window open for as long as a turn boundary is being held (RH1).
///
/// The counterpart to `AttentionArming`, and deliberately shaped like it: the registry
/// decides *whether* a boundary is held, `CommandWindowController` decides what a window
/// may do, and this decides that there should be one — and then another, until the hold
/// ends. Re-opening rather than one long window is what keeps the microphone rules intact:
/// every window is bounded (a minute here, against the attention window's eight seconds —
/// see `CommandWindowController.voiceSessionWindowSeconds`), with the same gate, the same
/// grammar, and the same half-duplex behavior.
///
/// One loop at a time, addressing the boundary that started it. Two agents can be held at
/// once — nothing prevents it — but TapQ has one microphone and one wearer, and a window
/// that dictated into whichever session asked most recently would be a way to send the
/// right sentence to the wrong agent. The second boundary waits out its own budget and the
/// session idles, which is the honest outcome rather than a guessed one.
@MainActor private final class VoiceSessionListening {
    private let waits: InstructionWaitRegistry
    private let makeController: @MainActor (
        _ sessionID: String,
        _ agent: AgentIdentity,
        _ cue: String?
    ) -> CommandWindowController
    private let diagnostics: TapQDiagnosticEmitter
    private var isRunning = false
    /// The session the running loop is addressing, so a re-poll of the boundary it is
    /// already listening to is silent while a *second* agent asking is still reported.
    private var listeningSession: String?
    /// The boundary the next window addresses. Read per rotation rather than fixed when
    /// the loop began, because the focus can move while the loop runs
    /// (`docs/SESSION_FOCUS_PLAN.md`): the session that started it is detached and its
    /// boundary released, the new session's boundary is held in the same breath, and
    /// `waits.isWaiting` never went false in between. Without this the loop would keep
    /// naming a session TapQ has stopped speaking for.
    private var target: (sessionID: String, agent: AgentIdentity)?
    /// Set when the session the loop is addressing was detached, so the next `begin` from
    /// another session retargets the loop instead of being reported as a second agent.
    private var targetDetached = false

    init(waits: InstructionWaitRegistry,
         diagnosticSink: any TapQDiagnosticSink,
         makeController: @escaping @MainActor (String, AgentIdentity, String?) -> CommandWindowController) {
        self.waits = waits
        self.makeController = makeController
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceSession", sink: diagnosticSink)
    }

    /// Whether a listening loop is running. For diagnostics and tests.
    var isListening: Bool { isRunning }

    /// Fired when the loop starts and when it ends. The wake-word gate's edge: a spotter
    /// must be off the microphone for as long as this loop is on it, and back on it within
    /// a second of the loop ending (`docs/WAKE_WORD_PLAN.md` §8, step 4).
    var onListeningChanged: (@MainActor () -> Void)?

    /// The wearer ended the voice session. Set by the composition to cancel a deliberation
    /// task that is still thinking: "end voice session" is about the mode the wearer is in,
    /// and a task that went on speaking after they stepped out of it would be TapQ talking
    /// to a room. `nil` on every path that composes no loop.
    var onEndedByWearer: (@MainActor () -> Void)?

    /// Starts listening for the boundary just held, if nothing is listening already.
    ///
    /// Called immediately before the caller suspends on the registry, so the loop's first
    /// turn always sees a registered waiter: both run on this actor, and the registration
    /// happens in the same actor turn as this call.
    /// Idempotent, and called on every poll of a held boundary rather than only the first:
    /// the loop must be running for as long as something is held, and asking again is the
    /// cheapest way to be sure of that. A poll for the session already being listened to is
    /// therefore not worth a line — only a *different* session asking is, because that is
    /// the second-agent case this loop deliberately does not serve.
    func begin(sessionID: String, agent: AgentIdentity) {
        guard !isRunning else {
            guard listeningSession != sessionID else { return }
            if targetDetached {
                // The focus moved: the session this loop was listening for is detached,
                // and this is the new one's boundary. The next window addresses it.
                target = (sessionID, agent)
                listeningSession = sessionID
                targetDetached = false
                diagnostics.record("listening.retargeted", fields: ["agent": agent.id])
            } else {
                diagnostics.record("listening.already_running", fields: [
                    "session": sessionID, "listening": listeningSession ?? "",
                ])
            }
            return
        }
        isRunning = true
        listeningSession = sessionID
        target = (sessionID, agent)
        targetDetached = false
        diagnostics.record("listening.began", fields: ["agent": agent.id])
        onListeningChanged?()
        Task { @MainActor [weak self] in
            await self?.loop()
        }
    }

    /// The session the loop is addressing lost the focus. Its boundary has been released
    /// by the caller; if another boundary is held the loop keeps running and the next
    /// `begin` retargets it, otherwise it ends on its own.
    func noteDetached(sessionID: String) {
        guard isRunning, listeningSession == sessionID else { return }
        targetDetached = true
    }

    private func loop() async {
        defer {
            isRunning = false
            listeningSession = nil
            target = nil
            targetDetached = false
            diagnostics.record("listening.ended")
            onListeningChanged?()
        }
        var windows = 0
        while waits.isWaiting, let (sessionID, agent) = target {
            // The cue is spoken once, at the boundary. A window that announced itself every
            // eight seconds would talk over a wearer who is still deciding what to say.
            let cue = windows == 0 ? CommandWindowController.voiceSessionCue : nil
            windows += 1
            let outcome = await makeController(sessionID, agent, cue).run()
            diagnostics.record("window.finished", fields: [
                "answers": "\(outcome.answers)",
                "dictations": "\(outcome.dictations)",
                "ended": "\(outcome.endedByWearer)",
            ])
            guard !outcome.endedByWearer else {
                // Everything, not just this session: "end voice session" is about the mode
                // the wearer is in, not about one agent they cannot see the names of.
                waits.releaseAll()
                onEndedByWearer?()
                return
            }
        }
    }
}

/// Where an `ask_about_work` question is answered from, once the pieces exist.
///
/// A one-field box, and it exists because of an ordering the composition cannot avoid. The
/// voice provider is built at the top of `serve`, and its `answerWorkQuestion` closure is an
/// init parameter; the deliberation loop is built two hundred lines later, because its
/// surfaces need the conversation memory, the durable store, and the interaction gate, none
/// of which exist yet up there. So the provider is handed a closure that asks *this* where
/// to go, and this learns the answer before any voice traffic can arrive — the provider
/// opens no session until a window arms, which is after `onReady`.
///
/// The direct answerer stays behind it rather than being discarded. It is M1's one-call
/// shape of the same question, it owns the three unavailability sentences the loop reuses,
/// and if a future edit ever leaves the loop unbuilt this composition answers questions
/// instead of failing them.
@MainActor private final class WorkQuestionRoute {
    private let direct: TranscriptQuestionAnswerer
    /// Set once, by the M2 hookup below.
    var loop: WearerTaskLoop?

    init(direct: TranscriptQuestionAnswerer) {
        self.direct = direct
    }

    func answer(question: String, agentDisplayName: String?) async -> WorkQuestionOutcome {
        guard let loop else {
            return await direct.answer(question: question, agentDisplayName: agentDisplayName)
        }
        return await loop.answerWorkQuestion(
            question: question, agentDisplayName: agentDisplayName
        )
    }
}

/// The `start_task` seam, boxed for construction order: the provider is built before the
/// loop's seven tool surfaces exist, so it holds this handle and the M2 hookup fills it —
/// the same shape ``WorkQuestionRoute`` is, for the same reason. On the arm that builds
/// the provider the loop is always built too (its reasoner is the narrator, and the
/// narrator is mandatory there), so a call through an unfilled handle means composition
/// itself broke — it answers audibly rather than pretending a task is running.
@MainActor private final class WearerTaskHandle: WearerTaskStarting {
    /// Set once, by the M2 hookup below.
    var loop: WearerTaskLoop?

    nonisolated func startTask(goal: String) async -> WearerTaskStart {
        guard let loop = await MainActor.run(body: { self.loop }) else {
            return .busy(spoken: "I can't take tasks right now.")
        }
        return await loop.startTask(goal: goal)
    }
}

/// The follow-up seam, boxed for the same construction-order reason as
/// ``WearerTaskHandle``: the provider declares `set_followup` and `cancel_followup` at
/// init, and the scheduler that answers them is built beside the loop, far below. On the
/// arm that builds the provider the scheduler is always built too, so an unfilled handle
/// means composition itself broke — it refuses audibly rather than pretending a promise
/// was kept.
@MainActor private final class WearerFollowupHandle: WearerFollowupScheduling {
    /// Set once, by the M3 hookup below.
    var scheduler: WearerFollowupScheduler?

    nonisolated func setFollowup(
        agent: String, instruction: String
    ) async -> WearerFollowupAcknowledgment {
        guard let scheduler = await MainActor.run(body: { self.scheduler }) else {
            return .refused(spoken: "I can't take follow-ups right now.")
        }
        return await scheduler.setFollowup(agent: agent, instruction: instruction)
    }

    nonisolated func cancelFollowup(
        agent: String
    ) async -> WearerFollowupAcknowledgment {
        guard let scheduler = await MainActor.run(body: { self.scheduler }) else {
            return .refused(spoken: "I can't take follow-ups right now.")
        }
        return await scheduler.cancelFollowup(agent: agent)
    }
}

/// The folder the launch in flight is using, shared between the three closures that have to
/// agree about it.
///
/// It exists because a folder TapQ *makes* can only be made once. Until the wake word there
/// was nothing stateful here: "where does the next session work" was a pure function of the
/// focused session and `--session-directory`, so the composition could ask it twice — once
/// for the session book, once inside the launcher — and get the same answer both times. A
/// workspace folder asked for twice is two folders, one of them empty and never used.
///
/// So the decision is made once, before the launch, and the launcher's own closures read it
/// back rather than deciding again. The hook check reads it for a second reason: TapQ writes
/// its hooks into the folder it makes, and a check that looked anywhere else would refuse a
/// session whose hooks it had just installed.
///
/// `@unchecked Sendable` over a lock because `hookStatus` is a `@Sendable` closure the
/// launcher may call from anywhere, while everything that writes here is main-actor work.
private final class ChosenSessionDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var path: String?

    var current: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return path
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            path = newValue
        }
    }
}

/// Headless macOS host composed from TapQ's broker, interaction, and hardware adapters.
/// The broker and interaction layers remain agent-neutral; installed adapters normalize
/// Claude Code, Codex, or future agent events before they reach this process.
@MainActor final class AppleTapQRuntimeService: TapQRuntimeServing {
    private var signalSources: [DispatchSourceSignal] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    /// The stage-2 reasoner built for this run, and the authority it was actually given.
    /// The approval closure reads both when it is composed: `.shadow` records what the
    /// reasoner said without changing the interaction, `.primary` also lets a decision
    /// raise the confirmation the request must collect, and `.off` — including every run
    /// where no reasoner could be built — never consults one at all.
    private(set) var reasoner: (any ContextReasoning)?
    private(set) var reasonerMode: ReasonerMode = .off
    /// Owns the between-windows attention loop for the life of the run, or nil when
    /// `--attention` was off. A property rather than a `serve` local because the only other
    /// reference to it is a weak capture inside a wearer-speech observer, and a local would
    /// be released at the first suspension — leaving the flag on and the feature dead.
    private var attentionArming: AttentionArming?
    /// Owns the voice session's listening loop for the life of the run, or nil without
    /// `--voice-session`. A property for the same ARC reason `attentionArming` is one: the
    /// only other reference to it is a weak capture inside the broker's wait handler, and a
    /// local would be released at the first suspension — leaving the flag on and every held
    /// boundary silent.
    private var voiceSessionListening: VoiceSessionListening?
    /// The wake word's three pieces, held for the run for the ARC reason `attentionArming`
    /// is: every other reference to them is a weak capture inside a callback somebody else
    /// owns — the spotter's, the wait registry's, the speech gate's — and a local would be
    /// released at the first suspension, leaving `--attention wake` on and deaf.
    private var wakeSpotter: (any WakeWordSpotting)?
    private var wakeArming: WakeWordArming?
    private var wakeGate: WakeWordGate?
    /// The registry every request prompt passes through, once `serve` has built conversation
    /// memory. A property for the reason the two above are: the predicates below are read
    /// from closures the notification policy holds for the life of the run, and the registry
    /// itself is a local in `serve`.
    private var requestWaits: SessionWaitRegistry?

    /// Whether a request prompt is open, or queued behind one.
    ///
    /// The third kind of command window, and the one the predicate below did not cover until
    /// 2026-09-01. An approval or a selection resolves inside `interactionGate.run`, on an
    /// `InputArbiter` listen of up to four minutes — with no attention window and no
    /// voice-session listening loop, because both of those deliberately stand down while a
    /// request is in play. So neither arm below was true, and a notice about another agent or
    /// a review sentence went straight into the prompt the wearer was answering: the speech
    /// gate tears the recognizer down for the utterance while the request's own budget keeps
    /// counting. That is the exact race the deferral exists to end, at the one window where
    /// the wearer is most clearly mid-answer. The maintainer's ruling: prompts count.
    ///
    /// `waitingCount` rather than a flag set around the resolve, because it is already this
    /// runtime's answer to "is a request in play" — `AttentionArming` declines to open on
    /// it, in its own guard 3, for this same reason in almost these words — and a second
    /// predicate is a second thing that can disagree with the first. It reads true from the
    /// moment a request enters `memory.withWindow`, which covers the queue wait as well as
    /// the listen: a wearer with three approvals stacked at the gate is being asked things
    /// for the whole of it.
    private var isRequestWindowOpen: Bool {
        (requestWaits?.waitingCount ?? 0) > 0
    }

    /// Whether the wearer is inside a command window right now — the attention window an
    /// onset opened, any of the windows a held turn boundary keeps re-opening, or a request
    /// prompt they are being asked to answer.
    ///
    /// The voice-session arm reads `isListening` rather than a per-window flag deliberately.
    /// That loop opens windows back to back for as long as the boundary is
    /// held, and the gaps between them are microseconds; a notice timed into one of those
    /// gaps would be spoken into the window that opened immediately after it.
    private var isCommandWindowOpen: Bool {
        attentionArming?.isWindowOpen == true
            || voiceSessionListening?.isListening == true
            || isRequestWindowOpen
    }

    /// The open window is the voice session's idle wait and nothing else: TapQ listening at
    /// a held boundary with no request in hand and no wearer-opened attention window.
    ///
    /// The request arm is stated rather than assumed. It is believed to be redundant — the
    /// runtime log shows `VoiceSession listening.ended` before `Interaction resolve.started`,
    /// so the listening loop is over before an approval's own listen begins — but "idle"
    /// is the one predicate that turns the deferral *off*, and a belief about ordering is
    /// not the thing to rest that on. Written out, a reordering costs a deferred sentence
    /// rather than a sentence spoken across a prompt.
    private var isIdleListening: Bool {
        voiceSessionListening?.isListening == true
            && attentionArming?.isWindowOpen != true
            && !isRequestWindowOpen
    }

    /// What a wake window says when it opens. Short, and unmistakably a reply to the wearer:
    /// the held-boundary cue ("Listening.") would be TapQ describing itself, which is a
    /// strange answer to somebody who has just said its name (`docs/WAKE_WORD_PLAN.md` §7,
    /// open decision 2).
    nonisolated static let wakeWindowCue = "Yes?"

    /// What a session started by voice with no goal is asked to do: nothing, briefly, so
    /// its first Stop comes at once and the held boundary there takes the wearer's real
    /// instruction. Recorded as the session's goal, because it is what the agent was told.
    nonisolated static let goallessSessionPrompt =
        "You were started hands-free through TapQ with no task yet. Reply with one short "
        + "sentence saying you are ready, and stop; the next instruction arrives by voice."

    func serve(
        configuration: TapQRuntimeConfiguration,
        reasonerLoader: TapQReasonerLoading?,
        onReady: @escaping @MainActor (TapQRuntimeEndpoint) -> Void
    ) async throws {
        let store = CalibrationStore(
            gestureProfileURL: configuration.gestureProfileURL,
            tapProfileURL: configuration.tapProfileURL,
            wearerSpeechProfileURL: CalibrationStore.defaultStore().wearerSpeechProfileURL
        )
        let gestureProfile = try loadGestureIfPresent(store)
        let tapProfile = try loadTapIfPresent(store)
        // Read before anything is built and thrown out of `serve` if it does not parse,
        // exactly as a malformed calibration profile is. A policy file exists only to
        // *narrow* what TapQ answers without asking, so the forgiving reading — fall back
        // to defaults — is the one that could widen it, and is not available here. Loaded
        // only under the flag: a run with the filter off leaves the file unread and
        // unmissed.
        let autoAnswerPolicy: AutoAnswerPolicy? = configuration.autoAnswerMode == .off
            ? nil
            : try AutoAnswerPolicyStore.defaultStore().load()

        let diagnostics = ConsoleDiagnosticSink()
        let classifierSelection = try QuestionClassifierFactory.select(
            provider: configuration.questionClassifier,
            anthropicAPIKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            openAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            diagnosticSink: diagnostics
        )
        diagnostics.record(.init(
            category: "Context",
            name: "classifier.selected",
            fields: [
                "mode": classifierSelection.backend.rawValue,
            ]
        ))
        // Same startup contract as the classifier: an explicitly requested provider that
        // cannot be built throws here and `serve` exits, rather than quietly running with
        // a different one. `off` yields no summarizer at all, and every consumer below is
        // composed from that nil — which is how "off means today's spoken behavior" is
        // enforced structurally instead of by a flag check at each speaking site.
        let summarizerSelection = try SpeechSummarizerFactory.select(
            provider: configuration.speechSummarizer,
            anthropicAPIKey: ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
            openAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
            diagnosticSink: diagnostics
        )
        diagnostics.record(.init(
            category: "Context",
            name: "summarizer.selected",
            fields: [
                "mode": summarizerSelection.backend.rawValue,
            ]
        ))
        let speech = SpeechEngine(diagnosticSink: diagnostics)
        // Pin the voice before anything can speak. Unset, AVFoundation would follow the
        // system language and read TapQ's English prompts with whatever voice that
        // implies — the counterpart to VoiceListener's en-US recognizer pin.
        speech.voiceSelection = configuration.speechVoice
        let gestures = HeadGestureDetector(
            config: gestureProfile?.config ?? HeadGestureConfig(),
            tapConfig: tapProfile?.config ?? TapConfig(),
            diagnosticSink: diagnostics
        )

        var encoderStatus: String?
        if let modelURL = configuration.encoderModelURL, configuration.encoderMode != .off {
            do {
                let scorer = try await CoreMLMotionScorer.load(modelURL: modelURL)
                gestures.configureEncoder(scorer: scorer, mode: configuration.encoderMode)
                encoderStatus = configuration.encoderMode.rawValue
            } catch {
                // A broken model must never take down hands-free serving; the
                // deterministic heuristics are the documented offline fallback.
                diagnostics.record(.init(
                    category: "GestureAdapter",
                    name: "encoder.load_failed",
                    level: .error,
                    fields: ["error": String(describing: error)]
                ))
                encoderStatus = "unavailable, heuristic fallback (\(error.localizedDescription))"
            }
        }

        var reasonerStatus: String?
        if configuration.reasonerProvider != .off, configuration.reasonerMode != .off {
            do {
                guard let reasonerLoader else {
                    throw TapQReasonerUnavailableError.unsupportedPlatform
                }
                reasoner = try await reasonerLoader(
                    configuration.reasonerConfig,
                    diagnostics
                )
                reasonerMode = configuration.reasonerMode
                reasonerStatus = "\(configuration.reasonerMode.rawValue)"
                    + " (\(configuration.reasonerProvider.rawValue))"
            } catch {
                // Deliberately unlike the question classifier, which aborts startup when
                // an explicitly requested provider is misconfigured. An unavailable
                // reasoner is an environment condition — wrong OS version, ineligible
                // device, assets still downloading — not a mistake in the command line,
                // and degrading is safe because the reasoner is escalation-only: with
                // none loaded, every request keeps exactly the confirmation the
                // deterministic policy already demanded.
                diagnostics.record(.init(
                    category: "Context",
                    name: "reasoner.load_failed",
                    level: .error,
                    // Only the closed reason kind: nothing about the pending request or
                    // the environment beyond why no model could be built.
                    fields: [
                        "reason": (error as? TapQReasonerUnavailableError)?.reasonKind
                            ?? "load_error",
                    ]
                ))
                reasoner = nil
                reasonerMode = .off
                reasonerStatus = "unavailable, running without risk escalation"
                    + " (\(error.localizedDescription))"
            }
        }
        // -- Wearer-speech signal source (WP5/WP6/WP7) --
        // When --wearer-gate or --imu-turn-control is enabled, the motion sample stream
        // feeds a WearerSpeechSignalSource whose children provide WearerSpeechSignaling
        // to WearerGatedVoice (gate) and WearerTurnCoordinator (turn control). Both
        // flags share one source.
        let needsWearerSpeechSource = configuration.wearerGateEnabled
            || configuration.imuTurnControlEnabled
        var wearerSpeechSource: WearerSpeechSignalSource?
        var wearerSpeechStatus: String?
        if needsWearerSpeechSource {
            let wearerSpeechConfig: WearerSpeechConfig
            if store.exists(.wearerSpeech) {
                do {
                    wearerSpeechConfig = try store.loadWearerSpeech().config
                } catch {
                    // Match the loadGestureIfPresent / loadTapIfPresent semantics: a
                    // malformed profile throws and aborts serve, exactly as gesture/tap do.
                    throw error
                }
            } else {
                wearerSpeechConfig = WearerSpeechConfig()
            }
            let source = WearerSpeechSignalSource(config: wearerSpeechConfig)
            gestures.setMotionSampleObserver(source)
            source.isAttached = true
            wearerSpeechSource = source
            switch (configuration.wearerGateEnabled, configuration.imuTurnControlEnabled) {
            case (true, true): wearerSpeechStatus = "gate+turn-control"
            case (true, false): wearerSpeechStatus = "gate"
            case (false, true): wearerSpeechStatus = "turn-control"
            case (false, false): break
            }
        }

        // -- Wearer turn signal liveness --
        // The one question the realtime path asks at each window open: is TapQ's own
        // endpointer working right now? A `nil` signal — no `--imu-turn-control` — answers
        // no forever, because without the flag no coordinator is listening and nothing on
        // TapQ's side would ever commit the turn. With the flag, the answer starts yes and
        // is retracted by a confirmed motion loss below, which is what catches AirPods that
        // are paired but sitting in their case. Its own child signal, not the coordinator's:
        // each child owns one `onWearerSpeakingChange` slot.
        let turnSignalLiveness = WearerTurnSignalLiveness(
            signal: configuration.imuTurnControlEnabled
                ? wearerSpeechSource?.makeSignal()
                : nil
        )

        // -- Voice composition --
        // `apple` is the shipped path and stays literally the shipped path: the same
        // `VoiceListener` instance, wrapped by the same `SpeechGatedVoice`, with nothing
        // between them. Any other provider swaps only what sits inside that gate — the
        // arbiter, the controllers, and the mic-lifecycle rules above are untouched.
        let rawVoice: any VoiceCommandProviding
        var backendProvider: VoiceBackendCommandProvider?
        var playback: BackendAudioPlayback?
        /// The run's voice-failure latch, or nil on the Apple path, which composes no
        /// `VoiceBackend` at all — `VoiceListener` is a command provider, emits no
        /// `sessionFailed`, and has nothing to latch. Held so the wait registry built much
        /// further down can be handed to it.
        var voiceBrokenState: VoiceBrokenState?
        /// The narration model, on the model-backed path only.
        ///
        /// nil on the Apple path, and that nil is the whole of "the Apple path is
        /// unchanged": the stop-question coordinator's narration fork is entered only when
        /// this is non-nil, so with no cloud to call there is nothing to disable and no flag
        /// to read — the classifier and the spoken summarizer keep every boundary they had.
        var boundaryNarrator: (any BoundaryNarrating)?
        /// The deliberation loop's reasoner, on the model-backed path only — the same
        /// ``OpenAINarrationModel`` value the narrator is, because one client family is what
        /// keeps the failure posture from diverging. `nil` on the Apple path, and that nil is
        /// what makes the loop structurally absent there rather than disabled.
        var taskReasoner: (any WearerTaskReasoning)?
        /// The connected agents' session transcripts, on the model-backed path only.
        ///
        /// nil on the Apple path, and that nil is load-bearing twice over: the broker gets
        /// no callback to hand a forwarded transcript path to, so nothing is ever read from
        /// disk; and the voice provider gets no answerer, so `ask_about_work` is never
        /// declared and a call for it is a protocol failure rather than a feature that
        /// quietly worked. TapQ persists nothing here — offsets and a bounded tail, both of
        /// which die with this object.
        var transcriptStore: TranscriptStore?
        /// Pillar B retrieval, on the model-backed path only. Held out here because the
        /// deliberation loop's `read_transcript` reaches the store through it — the same
        /// session resolution, the same on-demand re-read, the same three unavailability
        /// sentences — and the loop is built much further down.
        var transcriptAnswerer: TranscriptQuestionAnswerer?
        /// Where `ask_about_work` goes. See ``WorkQuestionRoute``.
        var workQuestionRoute: WorkQuestionRoute?
        /// Where `start_task` goes. See ``WearerTaskHandle``.
        var wearerTaskHandle: WearerTaskHandle?
        var wearerFollowupHandle: WearerFollowupHandle?
        switch configuration.voiceBackend {
        case .apple:
            rawVoice = VoiceListener(
                diagnosticSink: diagnostics,
                voiceProcessingEnabled: configuration.voiceProcessingEnabled
            )
        case .openaiRealtime:
            // The realtime primary's output half, held so the player built below can report
            // a dead output device to the one object allowed to act on it. Assigned inside
            // the decorator closure, which runs synchronously during `select`.
            var playbackDependent: PlaybackDependentVoiceBackend?
            // The two halves that have to be able to tell TapQ's own voice from the
            // wearer's, held for the same reason and assigned in the same closure. The
            // player they ask about does not exist yet — it is built below, and it reports
            // its dead output to `playbackDependent` above — so the question is wired the
            // moment it does.
            var realtimeAdapter: OpenAIRealtimeVoiceBackend?
            var microphonePump: MicrophonePumpVoiceBackend?
            // Throwing aborts serve, like a misconfigured question classifier: the operator
            // asked for a specific pipe and must not be given a different one in silence.
            let selection = try VoiceBackendFactory.select(
                provider: configuration.voiceBackend,
                openAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
                // The microphone pump wraps the realtime primary so the pipe actually
                // hears the wearer. The decorator keeps AVFoundation out of the portable
                // factory: only this executable — already macOS-only — constructs one.
                //
                // The playback dependency wraps the pump rather than the other way round,
                // so ending the session on a dead output closes the microphone with it:
                // there is no state in which TapQ is still listening to a wearer it cannot
                // answer.
                decorateRealtimePrimary: { primary in
                    realtimeAdapter = primary as? OpenAIRealtimeVoiceBackend
                    let pumped = MicrophonePumpVoiceBackend(
                        inner: primary,
                        voiceProcessingEnabled: configuration.voiceProcessingEnabled,
                        diagnosticSink: diagnostics
                    )
                    microphonePump = pumped
                    let dependent = PlaybackDependentVoiceBackend(
                        inner: pumped,
                        diagnosticSink: diagnostics
                    )
                    playbackDependent = dependent
                    return dependent
                },
                diagnosticSink: diagnostics,
                // Never invoked from this call site: the factory builds an Apple backend
                // only for `provider: .apple`, and this branch is `.openaiRealtime`. The
                // specified backend is the whole pipe, so nothing is composed underneath it.
                makeAppleBackend: { AppleVoiceBackend(speech: speech, diagnosticSink: diagnostics) }
            )
            // The failure boundary for the run. Everything below is the specified backend's
            // to succeed at; the first time it does not — an open that fails after startup,
            // a socket that drops mid-run, a playback engine that gives up — hands-free
            // voice ends here rather than continuing as a different backend.
            let broken = VoiceBrokenState(
                inner: selection.backend,
                provider: configuration.voiceBackend,
                diagnosticSink: diagnostics
            )
            // The local synthesizer, deliberately, and not the routed presenter: the routed
            // one prefers the backend's own voice, and the backend is what just died. This
            // is the same engine the voice-only notice and the motion-loss notice use.
            //
            // It ignores `--no-announcements` for the reason the mid-window motion-loss
            // announcement does: an inaudible state change strands the wearer, and a wearer
            // who is not told the microphone is dead goes on talking to it.
            broken.speakNotice = { [weak speech] notice in
                speech?.speak(notice, priority: .notification, onFinish: nil)
            }
            voiceBrokenState = broken
            let player = BackendAudioPlayback(diagnosticSink: diagnostics)
            // An engine that cannot start, or a buffer the engine refused, means the wearer
            // would hear nothing the backend says — including the sentence announcing that
            // the voice session ended. Rather than re-speaking that one utterance locally
            // and leaving the run half-alive, the session is terminated, and the termination
            // lands where every other failure of this backend lands: the break above.
            player.onUnavailable = { [weak playbackDependent] detail in
                playbackDependent?.notePlaybackUnavailable(detail: detail)
            }
            playback = player
            // -- Self-hearing, the half `SpeechGatedVoice` cannot cover --
            //
            // The gate closes the microphone while TapQ speaks, and on this path that is not
            // enough. With no AirPods there is no wearer turn signal, so the backend's own
            // VAD decides where sentences end, and TapQ's answer leaves the Mac's speaker
            // into the same room as the microphone the gate reopens the instant playback
            // drains. On hardware (2026-08-30) the service heard the tail, called it the
            // wearer's turn, committed it, and TapQ answered its own last sentence — a
            // repeat after a beat of silence, over and over.
            //
            // So both halves of the pipe get to ask what TapQ's voice was doing at a given
            // instant: the pump, so echo is never captured in the first place, and the
            // adapter, so a segment that slipped through anyway is dropped rather than
            // turned into a model turn. The player is the only thing that knows, and its
            // one observer slot is already spoken for by `CombinedSpeechActivity`, so the
            // question is a read of the span it records rather than a second subscription.
            //
            // Weak: the player is owned by the provider and the activity signal below, and
            // neither of these two should keep an output device alive on its own.
            let selfAudio: @MainActor () -> VoiceSelfAudioActivity = { [weak player] in
                player?.selfAudioActivity ?? .silent
            }
            realtimeAdapter?.selfAudioActivity = selfAudio
            microphonePump?.selfAudioActivity = selfAudio
            // Both halves are wired through optionals, and a nil here is a fix that is half
            // off with nothing to show for it. Said out loud rather than left to be inferred
            // from an echo that came back.
            diagnostics.record(.init(
                category: "VoiceBackend",
                name: "self_audio.wired",
                level: (realtimeAdapter != nil && microphonePump != nil) ? .info : .warning,
                fields: [
                    "adapter": "\(realtimeAdapter != nil)",
                    "microphone": "\(microphonePump != nil)",
                ]
            ))

            // -- Transcript context (TRANSCRIPT_CONTEXT_PLAN.md, phase 1) --
            //
            // Composed here and nowhere else. Selecting a cloud voice backend *is* the
            // consent for TapQ to read connected agents' sessions (maintainer, 2026-08-28),
            // so the store, the answer model, and the `ask_about_work` declaration all hang
            // off this branch: on the Apple path there is no store, the tool is not
            // declared, and the wire field the shim now sends reaches a broker with nowhere
            // to put it. Structurally absent, not disabled.
            //
            // The key is guaranteed present — `VoiceBackendFactory.select` above threw
            // without it — and re-read from the environment for the same reason narration
            // re-reads it below: this composes from exactly the environment the pipe did.
            guard let transcriptKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !transcriptKey.isEmpty else {
                throw VoiceBackendConfigurationError.missingOpenAIAPIKey
            }
            let store = TranscriptStore(diagnosticSink: diagnostics)
            transcriptStore = store
            let answerer = TranscriptQuestionAnswerer(
                store: store,
                // The narration-family model, the same client and the same key: one cloud
                // call per question, decided by prompt rather than by code, and speech out
                // the other end.
                model: OpenAINarrationModel(
                    apiKey: transcriptKey,
                    model: OpenAINarrationModel.resolvedModel(),
                    diagnosticSink: diagnostics
                ),
                diagnosticSink: diagnostics
            )
            transcriptAnswerer = answerer
            let route = WorkQuestionRoute(direct: answerer)
            workQuestionRoute = route
            let taskHandle = WearerTaskHandle()
            wearerTaskHandle = taskHandle
            let followupHandle = WearerFollowupHandle()
            wearerFollowupHandle = followupHandle
            let provider = VoiceBackendCommandProvider(
                backend: broken,
                // No matcher, and the absence is the feature. Ratified 2026-08-28: for the
                // entire openai-realtime path there is no keyword matching and no heuristic.
                // What the wearer meant is resolved by the model that heard them, reported as
                // a tool call, and executed; a transcript on this path is a log line. Passing
                // `VoiceCommandMatcher.match` here is what ended a live session on a fragment
                // of dictation containing the word "no", and there is now no object in this
                // composition a future edit could reach for to "also check the words".
                intentSource: .modelToolCalls,
                sessionPolicy: .conversation(idleClose: 60),
                supportsBargeIn: true,
                responseAudio: player,
                // Inert under `.modelToolCalls` and passed anyway, so the two paths keep one
                // shape. Free-form delivery is a transcript→intent step — an unmatched
                // sentence promoted to a command — and it goes with the rest of them. The
                // capabilities it carried are not lost: a dictated sentence at a held boundary
                // arrives as `queue_instruction`, and a free-form *question* is answered by
                // the model itself, out loud, from the grounding TapQ supplies per turn.
                freeformEnabled: configuration.voiceFreeformEnabled
                    || configuration.voiceSessionEnabled,
                isWearerTurnSignalLive: { [turnSignalLiveness] in turnSignalLiveness.isLive },
                // Present, so `ask_about_work` is declared to every session this provider
                // opens. The provider knows nothing about transcripts beyond this closure:
                // it asks a question and gets back a sentence, a spoken refusal, or a
                // failure to break on.
                //
                // Since M2 it goes through the deliberation loop (Pillar B's one revision:
                // an answer may now combine transcript slices with TapQ's own memory). The
                // three outcomes the provider handles are unchanged, and so is what the
                // wearer hears in each; only where the evidence comes from moved.
                answerWorkQuestion: { [route] question, agent in
                    await route.answer(question: question, agentDisplayName: agent)
                },
                // Present, so `start_task` is declared to every session this provider
                // opens — the loop itself is built much further down, once its seven tool
                // surfaces exist, and the M2 hookup fills this handle then.
                startWearerTask: taskHandle,
                // Present, so `set_followup` and `cancel_followup` are declared too — the
                // wearer's own door to the one-shot book. Same boxed-handle shape as
                // `start_task`, filled by the M3 hookup once the scheduler exists.
                followups: followupHandle,
                diagnosticSink: diagnostics
            )
            // A sentence the specified backend cannot say is not a cue to say it in a
            // second voice — it is the pipe failing at the job the operator named it for.
            // Same latch, same one notice, same dead-for-the-run consequence as a dropped
            // socket, reached from the one seam that can tell TapQ was not heard.
            provider.onScriptedSpeechUndeliverable = { [weak broken] reason in
                broken?.noteBackendFailed(reason: "scripted speech undeliverable: \(reason)")
            }
            // The mirror of the line above, and the same latch. That one fires when TapQ
            // cannot be heard; this one fires when the wearer cannot be understood — an
            // undeclared tool, arguments that will not parse, a call on a session that
            // declared none. Neither degrades: there is no second voice for the first and no
            // grammar to fall back on for the second, which is the whole of the 2026-08-28
            // decision. A run whose tool protocol is wrong ends its voice channel loudly
            // rather than quietly resuming keyword matching.
            provider.onIntentPipelineFailed = { [weak broken] detail in
                broken?.noteBackendFailed(reason: "intent tool protocol: \(detail)")
            }
            // The third sibling, same latch. The cloud call behind `ask_about_work` is the
            // narration model on the narration endpoint with the narration key, so its
            // failure gets narration's answer: break, loudly, once. A transcript that cannot
            // be *read* never arrives here — that is spoken to the wearer and the session
            // lives, which is the whole of the two-class failure posture.
            provider.onWorkAnswerFailed = { [weak broken] reason in
                broken?.noteBackendFailed(reason: "work answer: \(reason)")
            }
            backendProvider = provider
            rawVoice = provider

            // -- The outbound half (NARRATION_MODEL_PLAN, rule 2) --
            //
            // What TapQ says at a turn boundary is decided by a model on this path, not by
            // the spoken-summary templates and the question-mark gate. It is a side call over
            // plain HTTPS with the same key the realtime session uses, and deliberately not
            // the realtime session itself: that pipe renders text by generating from it, and
            // the utterance decided here is spoken back verbatim on the scripted channel
            // instead, which is what keeps the run to one voice saying one agreed sentence.
            //
            // The key is guaranteed present — `VoiceBackendFactory.select` above threw
            // without it — and re-read rather than threaded through so this composes from
            // exactly the environment the pipe did.
            guard let narrationKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !narrationKey.isEmpty else {
                throw VoiceBackendConfigurationError.missingOpenAIAPIKey
            }
            let narrationModel = OpenAINarrationModel.resolvedModel()
            let narrator = OpenAINarrationModel(
                apiKey: narrationKey,
                model: narrationModel,
                diagnosticSink: diagnostics
            )
            boundaryNarrator = narrator
            // The same value, in its third role. `OpenAINarrationModel` narrates boundaries,
            // answers questions, and now drives the deliberation loop's turns — one client,
            // one key, one timeout race, one way to fail. A separate reasoner here would be
            // a second place for a cloud call to learn how to degrade.
            taskReasoner = narrator
            diagnostics.record(.init(
                category: "Context",
                name: "narration.selected",
                fields: [
                    "model": narrationModel,
                    "overridden": "\(narrationModel != OpenAINarrationModel.defaultModel)",
                ]
            ))
        }
        let voiceAuthorized = configuration.voiceEnabled
            ? await VoiceListener.requestAuthorization()
            : false

        // -- Gate composition --
        // Stacking order: SpeechGatedVoice(WearerGatedVoice(rawVoice)). The outer gate
        // owns the mic lifecycle (TTS + playback); the inner gate filters what survives.
        // The attribution gate is composed ONLY when --wearer-gate is set. --imu-turn-control
        // alone shares the signal source (for the coordinator) but must not alter command
        // delivery — its help text promises only endpointing and barge-in.
        let gatedInner: any VoiceCommandProviding
        // The same gate, asked a second and opposite question by the dictation path: the
        // command filter above fails open, and `isWearerAttributedNow` fails closed. Only
        // `--wearer-gate` composes it, which is why `--voice-instructions` requires that
        // flag — without it there is no attribution to be fail-closed about.
        var wearerAttribution: (any WearerAttributionChecking)?
        if configuration.wearerGateEnabled, let wearerSpeechSource {
            let gate = WearerGatedVoice(
                wrapping: rawVoice,
                signal: wearerSpeechSource.makeSignal(),
                diagnosticSink: diagnostics
            )
            wearerAttribution = gate
            gatedInner = gate
        } else {
            gatedInner = rawVoice
        }
        // When a backend audio player exists, the speech gate must watch both TTS and
        // playback: CombinedSpeechActivity merges the two signals. Without a player the
        // speech engine is the sole activity source, byte-identical to M1.
        let activitySignal: SpeechActivitySignaling
        if let playback {
            activitySignal = CombinedSpeechActivity(tts: speech, playback: playback)
        } else {
            activitySignal = speech
        }
        let gatedVoice = SpeechGatedVoice(
            wrapping: gatedInner,
            activity: activitySignal,
            diagnosticSink: diagnostics
        )
        let voice: (any VoiceCommandProviding)? = voiceAuthorized ? gatedVoice : nil

        // The run's one record of what TapQ's own voice is doing (sweep finding F3). Command
        // windows read it to decide when their eight seconds may start counting: the window
        // that just closed spoke its last answer on the way out, and without this the next
        // window's countdown runs through audio `gatedVoice` is holding the microphone shut
        // for. Measured at 12 of 40 windows on hardware.
        //
        // `isSpeaking` is *read*, never subscribed to: `activitySignal.onSpeakingChange` is a
        // single-observer slot and `SpeechGatedVoice` owns it two lines up. Reading the same
        // property the gate reads is what makes the window's clock and the microphone agree
        // by construction rather than by estimate — this is the same signal, engine plus
        // player, that decides whether the microphone opens at all.
        //
        // Captured strongly, deliberately: the drain outlives no one here (the composition
        // holds it for the run) and there is no cycle to make, while a weak capture that went
        // nil would report "quiet" — the one answer that silently restores the bug.
        let voiceChannelDrain = VoiceChannelDrain { activitySignal.isSpeaking }

        // -- IMU turn coordinator (WP7) --
        // When --imu-turn-control is enabled, the coordinator watches the wearer-speech
        // signal and calls endActiveTurn (endpointing) or interrupts playback (barge-in).
        // Both are additive; a dead signal means neither fires.
        //
        // On the .apple/VoiceListener path the coordinator composes with
        // interruptPlayback = speech.stopAll() and no endpoint (VoiceListener has no
        // turn API) — barge-in-only there. On the backend-provider path both
        // endpointing and barge-in are available.
        var turnCoordinator: WearerTurnCoordinator?
        if configuration.imuTurnControlEnabled, let wearerSpeechSource {
            switch configuration.voiceBackend {
            case .openaiRealtime:
                let coordinator = WearerTurnCoordinator(
                    signal: wearerSpeechSource.makeSignal(),
                    endpoint: { [weak backendProvider] in
                        backendProvider?.endActiveTurn()
                    },
                    interruptPlayback: { [weak playback, weak backendProvider] in
                        playback?.stopAndFlush()
                        backendProvider?.cancelActiveResponse()
                        speech.stopAll()
                    },
                    isResponsePlaying: { [weak playback] in
                        (playback?.isPlaying ?? false) || speech.isSpeaking
                    },
                    isUserTurnActive: { [weak backendProvider] in
                        backendProvider?.isUserTurnActiveForCoordination ?? false
                    }
                )
                // The coordinator is armed once for the serve lifetime. Between windows
                // no motion samples flow (the detector stops on InputArbiter.finish),
                // so the signal goes stale and isSignalAvailable returns false, which
                // makes the coordinator ignore all transitions. The isUserTurnActive
                // guard is the second line of defense: no endpoint fires unless a turn
                // is actually open. No explicit stop() is needed at teardown because the
                // coordinator only adds calls, never blocks them, and the serve defer
                // block tears down everything below it.
                coordinator.start()
                turnCoordinator = coordinator
            case .apple:
                // VoiceListener has no turn API, so only barge-in is meaningful:
                // interrupt TTS when the wearer starts speaking during a prompt.
                let coordinator = WearerTurnCoordinator(
                    signal: wearerSpeechSource.makeSignal(),
                    endpoint: { /* no-op: VoiceListener has no turn API */ },
                    interruptPlayback: {
                        speech.stopAll()
                    },
                    isResponsePlaying: {
                        speech.isSpeaking
                    },
                    isUserTurnActive: { false /* no explicit turns on the Apple path */ }
                )
                coordinator.start()
                turnCoordinator = coordinator
            }
        }

        let approvalArbiter = InputArbiter(
            gestures: gestures,
            voice: voice,
            taps: gestures,
            diagnosticSink: diagnostics
        )
        // The run's one voice. With a specified backend composed, every sentence TapQ says
        // goes to it — prompts, read-backs, cues, notices, summaries — and the sink holds no
        // reference to the local synthesizer, so there is no seam through which a second
        // voice could come back. On the Apple path there is no backend to route to and the
        // controllers get the engine itself, exactly as before.
        //
        // The one sentence that stays local is spoken by `VoiceBrokenState` above, after
        // this pipe is dead and there is nothing left to route to.
        let routedSpeech: any SpeechPresenting = backendProvider.map { provider in
            BackendSpeechSink(
                route: { [weak provider] text in
                    provider?.speakScripted(text) ?? .dropped("no_provider")
                },
                stop: { [weak provider] in
                    provider?.dropScriptedSpeech(reason: "stop_all")
                },
                // The one door back to the local engine, and it only opens after the pipe is
                // dead. A broken run still opens windows and still resolves them by gesture,
                // tap, and timeout — a prompt nobody could hear would make those windows
                // unanswerable, which is a worse failure than the one already reported.
                localAfterBreak: speech,
                isBackendBroken: { [weak voiceBrokenState] in
                    voiceBrokenState?.isBroken ?? false
                },
                diagnosticSink: diagnostics
            )
        } ?? speech

        // -- Quiet output (RD5) --
        // Built only under `--quiet`, so a run without it never constructs an audio engine
        // for cues and never wraps the speech path. The cue player owns an engine of its
        // own for the reason `AudioCue` documents: a cue has to be audible at moments the
        // response path is idle, failed, or tearing down.
        let cues: AudioCue? = configuration.quietEnabled
            ? AudioCue(diagnosticSink: diagnostics)
            : nil
        let quietSpeech: QuietSpeech? = cues.map { player in
            QuietSpeech(wrapping: routedSpeech) { cue in
                player.play(cue == .prompt ? .prompt : .notification)
            }
        }
        let promptSpeech: any SpeechPresenting = quietSpeech ?? routedSpeech
        /// Plays a cue when quiet mode is on, and does nothing when it is not. The one
        /// place the runtime asks for a sound outside the speech path — the notification
        /// chokepoint and the motion-loss notice, both of which decide speak-or-chime from
        /// `NotificationPolicy` rather than from a priority.
        let playCue: @MainActor (NotificationCue) -> Void = { cue in
            cues?.play(cue == .prompt ? .prompt : .notification)
        }
        /// Marks the moment a request window opens, so quiet mode can tell the prompt it is
        /// about to speak from every later sentence in the same window — which are answers
        /// to something the wearer said and are never silenced. A no-op without `--quiet`.
        let armPrompt: @MainActor () -> Void = { quietSpeech?.armPrompt() }
        // The one instruction queue this run has (RC2). Three call sites share it — the
        // dictation flow that fills it, the broker arm that fills it from the SDK seam,
        // and the stop-question coordinator that drains it at a turn boundary — so it is
        // a reference type built once, here, and handed to all three. `nil` without
        // `--voice-instructions`: nothing to fill, nothing to drain, and every path below
        // takes the shape it had in Rung B.
        let instructions: InstructionMailbox? = configuration.voiceInstructionsEnabled
            ? InstructionMailbox(diagnosticSink: diagnostics)
            : nil
        // The turn boundaries this run is holding open (RH1), or `nil` without
        // `--voice-session` — in which case discovery advertises nothing, no shim ever
        // long-polls, and the broker's wait arm answers "no instruction" the moment it is
        // reached. The registry is the only thing that makes a Stop hook patient, so a run
        // without one cannot hold anything by accident.
        let instructionWaits: InstructionWaitRegistry? = configuration.voiceSessionEnabled
            ? InstructionWaitRegistry(diagnosticSink: diagnostics)
            : nil
        // Every way an instruction can arrive — a dictation, `tapq instruct`, the
        // voice-session window itself — goes through the mailbox, so this is the one place
        // a held boundary has to be woken from.
        if let instructionWaits {
            instructions?.onEnqueued = { [weak instructionWaits] session in
                instructionWaits?.noteInstructionQueued(session: session)
            }
            // The other way a boundary is let go: the voice channel died. A held Stop hook
            // is waiting for TapQ to listen, and with the microphone terminally gone it
            // would otherwise renew its lease forever for a window that can no longer hear
            // it — the one failure a boundary held indefinitely must not have. Released the
            // moment the break lands, exactly as serve teardown releases them: same call,
            // same reason, earlier. The lease is tombstoned with it, so the poll already in
            // flight cannot re-establish what the break just ended.
            voiceBrokenState?.releaseHolds = { [weak instructionWaits] in
                instructionWaits?.releaseAll()
            }
        }
        // What this run remembers about the sessions it serves, and the only thing recall
        // and grounded answers ever read. Built before the controllers because they take
        // its closures; every window below hands it what it may say and nothing else.
        //
        // The mailbox goes in here rather than beside it because everything an instruction
        // needs to know — which session is being spoken into, which agent is behind it —
        // is what this object already tracks for recall.
        let memory = ConversationMemory(instructions: instructions)
        // Handed to the run so `isRequestWindowOpen` can be asked from the notification
        // policy's closures, which outlive this scope. The same registry the policy's own
        // dedupe reads and the same one `AttentionArming` declines to open against — one
        // answer to "is a request in play", read from three places.
        requestWaits = memory.waitRegistry
        // The one fact a model-backed backend needs that TapQ has not already said out loud:
        // which names a wearer could address. Read per turn rather than captured once, because
        // sessions come and go inside a run — a name that resolves at the third window did not
        // exist at the first. Inert on the Apple path, whose provider never grounds anything.
        backendProvider?.liveAgentNames = { [weak memory] in
            memory?.liveAgentDisplayNames ?? []
        }
        // Whether a *spoken* input may end a voice session. True only on the Apple path, whose
        // transcript grammar is unchanged and whose end phrases still work. On the realtime
        // path no tool ends a session and `.deny` from the voice channel no longer does
        // either, so the loop is let go by the session budget, by a gesture or a tap, or by
        // shutting the runtime down. Ratified 2026-08-28; see docs/REALTIME_INTENT_PLAN.md.
        let voiceMayEndSession = configuration.voiceBackend == .apple
        // Where the wearer's intent comes from, handed to every window that can dictate.
        // It is the same fact the provider is composed with above (`intentSource:
        // .modelToolCalls` on the realtime branch) and must stay the same fact: a window
        // that believed it was reading a grammar's guess while the model was resolving tool
        // calls would put a confirmation in front of an instruction that has already been
        // resolved — which is the step that discarded a live dictation on 2026-08-30.
        //
        // On the model path a routed instruction is announced rather than confirmed; on the
        // Apple path the read-back-and-confirm flow is exactly what it has always been.
        let voiceIntentSource: VoiceIntentSource =
            configuration.voiceBackend == .apple ? .transcriptGrammar : .modelToolCalls
        // Fail-closed by composition, not by convention: with no gate there is no object
        // to ask, and the answer is no. The gate outlives every window (the voice chain
        // holds it), so the weak capture is bookkeeping rather than a lifetime it depends
        // on.
        let isWearerAttributed: WearerAttributionQuerying = { [weak wearerAttribution] in
            wearerAttribution?.isWearerAttributedNow ?? false
        }
        // Composed only under `--voice-trust environment` (RE2), and that is what keeps the
        // default run byte-identical: with `nil` every read-back asks for a nod exactly as
        // it always has, whatever the headphones are doing. Under environment trust the
        // wording follows the same probe the selection controls hint already reads, so a
        // wearer who puts their AirPods in mid-run is offered the gesture again on the next
        // read-back without a restart.
        let gesturesReachable: GestureConfirmationQuerying = {
            gestures.isMotionCurrentlyAvailable
        }
        let gestureConfirmation: GestureConfirmationQuerying? =
            configuration.voiceTrust == .environment ? gesturesReachable : nil
        let interaction = InteractionController(
            speech: promptSpeech,
            arbiter: approvalArbiter,
            timeout: configuration.interactionTimeout,
            presenter: DefaultApprovalRequestPresenter(
                // A notification carries the adapter's own short message. Speaking it is
                // part of the summary feature's spoken-content change, so it is on only
                // when a summarizer is: `off` has to mean nothing TapQ says has changed.
                speaksNotificationSummary: summarizerSelection.summarizer != nil
            ),
            diagnosticSink: diagnostics,
            recallResponder: memory.recallResponder,
            // Grounded answers exist only where a duplex backend can speak them. On the
            // Apple path there is nothing to route to, so the responder is absent and a
            // free-form transcript inside an approval is ignored exactly as it always was
            // — which is also what happens without `--voice-freeform`, since the provider
            // then never delivers one.
            freeformResponder: backendProvider.map { provider in
                memory.freeformResponder(speak: { [weak provider] grounded in
                    provider?.speakViaBackend(grounded) ?? false
                })
            },
            instructionCapability: memory.instructionCapability,
            wearerAttribution: isWearerAttributed,
            // The switch. `nil` without `--voice-instructions`, and the dictation flow
            // returns before it speaks a word — the grammar still matches "tell it to…",
            // and the window goes on listening exactly as it did before the phrase meant
            // anything.
            instructionEnqueue: memory.instructionEnqueue,
            // Name-addressed dictation ("tell Codex to …"). Composed from the same object
            // and gated on the same mailbox as the enqueue above, so a run without
            // `--voice-instructions` has no resolver either and the dictation flow never
            // looks for an address at all.
            instructionAddressResolver: memory.instructionAddressResolver,
            voiceTrust: configuration.voiceTrust,
            gestureConfirmation: gestureConfirmation,
            intentSource: voiceIntentSource
        )

        // The detector reads the *default output device's* volume, which without AirPods is
        // the built-in speaker — every volume-key press during a selection window would
        // navigate. The gate is re-consulted per window, so connecting AirPods mid-session
        // brings swipes back on the next prompt.
        let volumeSwipe = MotionGatedSwipes(
            wrapping: VolumeSwipeDetector(diagnosticSink: diagnostics),
            isEligible: { gestures.isMotionCurrentlyAvailable },
            diagnosticSink: diagnostics
        )
        let selectionArbiter = SelectionArbiter(
            voice: voice,
            // Tilt navigation is the roll-axis double tilt: roll is orthogonal to nod
            // (pitch) and shake (yaw), the analyzer requires roll dominance, and a
            // command needs two same-direction tilts — so the first half of a nod/tap
            // can no longer be misread as navigation, which is what forced the retired
            // pitch tilt off. Volume swipes remain the premium navigation channel on
            // hardware that has them.
            tilts: gestures,
            swipes: volumeSwipe,
            taps: gestures,
            gestures: gestures,
            diagnosticSink: diagnostics
        )
        let selection = SelectionController(
            speech: promptSpeech,
            arbiter: selectionArbiter,
            timeout: configuration.interactionTimeout,
            // Teach only controls that can actually resolve the question. Without a motion
            // device, volume swipes are gated off and nods never arrive, so naming them
            // would send the user through gestures that cannot work. Read per prompt, so
            // an explicit "repeat" after AirPods connect re-teaches the full controls.
            controlsHint: {
                gestures.isMotionCurrentlyAvailable
                    ? SelectionController.controlsHint
                    : SelectionController.voiceOnlyControlsHint
            },
            diagnosticSink: diagnostics,
            recallResponder: memory.recallResponder,
            // A wearer choosing between options may still want to say something to the
            // agent, and dictating never moves the cursor or picks an option.
            instructionCapability: memory.instructionCapability,
            wearerAttribution: isWearerAttributed,
            instructionEnqueue: memory.instructionEnqueue,
            instructionAddressResolver: memory.instructionAddressResolver,
            voiceTrust: configuration.voiceTrust,
            gestureConfirmation: gestureConfirmation,
            intentSource: voiceIntentSource
        )
        // Which voice is doing the talking, told to the two controllers that size their
        // viability floor by it. The backend voice reads about twice as fast as the local
        // synthesizer, so the same prompt is a very different fraction of the same window,
        // and a floor that assumed one of them would be wrong on the other in whichever
        // direction hurts: too small refuses nothing, too large refuses everything.
        let speechPath: SpokenPace.Path =
            configuration.voiceBackend == .apple ? .apple : .realtime
        interaction.speechPath = speechPath
        selection.speechPath = speechPath
        let interactionGate = InteractionGate()

        // -- Notification routing (RD5) --
        // One object decides speak / chime / suppress for every announcement the runtime
        // owns, and it decides about *audio only*. Recording is done by the caller,
        // unconditionally, before the verdict is consulted — which is the fix for the old
        // conflation where `--no-announcements` also erased the event from memory.
        //
        // It reads the wait registry conversation memory already keeps, rather than a
        // second one: "is this session already queued at the gate?" has exactly one right
        // answer per run, and two registries could disagree about it.
        //
        // It also asks whether a command window is open before making a sound. A
        // cross-session notification spoken into one is spoken at `.notification` priority
        // into the wearer's own listening window: the speech gate tears the recognizer down
        // for the utterance while the window's timer keeps counting, so most of eight
        // seconds goes on a sentence about a different agent and the wearer is recorded as
        // having said nothing. Held instead, and folded into the next legal moment.
        // M3: at most one follow-up announce-grace is in flight at a time, and this box is
        // how the policy's expiry can reach it. Armed when an announce is routed, settled the
        // moment the delivery is claimed — so an expired *review sentence* (post-claim) finds
        // it empty and aborts nothing. It also holds the announcement's own text, because the
        // expiry hook fires for every loop sentence that waits out the bound and only one of
        // them is this firing's business; see `FollowupGraceAbort`. Late-bound like the
        // presence query below, and for the same reason: the book is built far after this
        // policy.
        let followupGraceAbort = FollowupGraceAbort()
        let notificationPolicy = NotificationPolicy(
            settings: .init(
                quiet: configuration.quietEnabled,
                announcementsEnabled: configuration.announcementsEnabled
            ),
            waits: memory.waitRegistry,
            // Late-bound on purpose: both window owners are built two hundred lines below
            // this, and the closure is not called until a notification arrives — which
            // cannot happen before the broker is serving, which is later still.
            commandWindowOpen: { [weak self] in self?.isCommandWindowOpen ?? false },
            // Anything held goes into an idle wait rather than expiring behind it (second M3
            // hardware run, 2026-09-01): a follow-up's result above all, and — since the
            // review of that same run — a notice about a second agent, which was expiring at
            // the bound for as long as the wearer stayed in a voice session.
            idleListening: { [weak self] in self?.isIdleListening ?? false },
            // A follow-up whose announcement sat deferred for the full minute was never
            // heard, and a promise acted on unheard would break announce-everything — so
            // the expiry cancels the firing instead. The book records the cancellation;
            // the wearer's record is the trace.
            //
            // The text decides, and it has to: this hook fires for every loop sentence that
            // waits out the bound — a review's result, a held notice, a could-not-finish
            // notice — and until 2026-09-01 any of them cancelled whichever firing was in
            // flight, silently, with its announcement long since heard.
            onExpiredLoopSpeech: { text in followupGraceAbort.noteExpired(text) },
            diagnosticSink: diagnostics
        )

        // Said once, or never: the sentence that explains a voice-only run. It has two
        // callers because availability has two ways of saying "no AirPods". When the
        // detector's probe answers `false`, the startup poll below speaks it a bounded
        // moment into the run. When the probe answers `true` for AirPods that are paired
        // but sitting in their case — which is what macOS reports — the lie is only
        // discovered when the first subscription exhausts its startup watchdog without a
        // sample, and the `.neverStreamed` branch speaks it then. One flag, so a run that
        // hears it at startup never hears it again at the first window. A status line,
        // not a rescue: it respects `--no-announcements`.
        //
        // Spoken through the run's voice, not the local engine: "there are no AirPods" is a
        // status line like any other, and a wearer who hears it in a different voice from
        // everything else has been told, incorrectly, that something else is speaking.
        var voiceOnlyNoticeSpoken = false
        let voiceOnlyNotice: @MainActor () -> Void = {
            guard configuration.announcementsEnabled, !voiceOnlyNoticeSpoken else { return }
            voiceOnlyNoticeSpoken = true
            routedSpeech.speak(
                voiceAuthorized
                    ? "No AirPods detected. Running voice only."
                    : "No AirPods detected. Prompts will use the screen.",
                priority: .notification,
                onFinish: nil
            )
        }

        // A disconnect is only worth interrupting the user about when there was something
        // to disconnect. `.neverStreamed` means no sample has ever arrived this run — no
        // AirPods connected when this window opened, or AirPods paired but disconnected,
        // whose availability flag reads `true` while the stream stays mute. Every window
        // in such a session reports it once its bounded retry or startup watchdog
        // expires: announcing it would say "disconnected" about hardware the user never
        // put in, and cancelling would take the live voice window down with it. So the
        // one-time notice is spoken if startup's availability poll was lied to, and the
        // window stays open and resolves by voice or by its ordinary timeout.
        //
        // The remaining reasons are a real mid-window outage — the detector only reports
        // them once some window in this run has actually streamed samples. That
        // announcement deliberately ignores `--no-announcements`: an inaudible state
        // change mid-interaction strands the user. It stops at the state change, because
        // the cancel below already ends in `deferToScreen()`, which speaks "Deferring to
        // the screen." itself.
        //
        // Under `--quiet` the notice becomes the notification cue rather than the sentence:
        // `NotificationPolicy` never suppresses a motion loss outright, for the reason
        // above — a wearer who hears nothing waits for a prompt that is not coming — so the
        // wearer is still told, in the channel quiet mode leaves open.
        let turnDetectionProvider = backendProvider
        gestures.onMotionLost = { [weak turnDetectionProvider] reason in
            // Every reason means the same thing to the turn signal: there is no IMU
            // endpointer any more. On the realtime path the provider is re-asked
            // immediately rather than at the next window, because the window this fired
            // inside is the one a wearer with no AirPods is waiting on — see
            // `refreshTurnDetectionMode`. Recorded first, so the refresh reads the retracted
            // value. Both calls are inert on the Apple path.
            turnSignalLiveness.noteMotionUnavailable()
            turnDetectionProvider?.refreshTurnDetectionMode()
            guard reason != .neverStreamed else {
                voiceOnlyNotice()
                return
            }
            switch notificationPolicy.route(.motionLost) {
            case .speak:
                // The run's voice, for the reason the voice-only notice uses it. Losing the
                // IMU says nothing about the speech pipe, so there is no reason for this one
                // sentence to arrive in a different voice from the rest of the session.
                routedSpeech.speak(
                    "AirPods motion disconnected.",
                    priority: .notification,
                    onFinish: nil
                )
            case .chime(let cue):
                playCue(cue)
            case .suppress, .deferred:
                // A motion loss is never deferred — no `whenDeferred` is passed, and the
                // policy will not hold what it cannot hand back. Listed so the switch stays
                // exhaustive and this stays a decision rather than an omission.
                break
            }
            approvalArbiter.cancel()
            selectionArbiter.cancel()
        }

        // -- Always-on attention (RD3) --
        //
        // Two things have to be true for a wearer to be able to say something between
        // requests, and neither is true today. First, the motion stream has to still be
        // running: every arbiter `finish()` stops the detector, which stops feeding the
        // wearer-speech monitor, so between windows there is no onset to notice. The hold
        // is what keeps it up, and it is released with the run. Second, something has to be
        // listening for that onset and allowed to open a window — that is the arming below.
        //
        // Requires `--wearer-gate`, refused at the command line without it: the onset that
        // opens the window has to be attributable, or TapQ would answer a passing
        // conversation's questions about the wearer's agents.
        var detectionHold: HeadGestureDetectionHold?
        var attentionStatus: String?
        if configuration.attentionMode == .imu, let wearerSpeechSource {
            detectionHold = gestures.holdOpen()
            let arming = AttentionArming(
                waits: memory.waitRegistry,
                diagnosticSink: diagnostics,
                makeController: {
                    CommandWindowController(
                        // The un-quieted presenter, deliberately. Everything a command
                        // window says is an answer to something the wearer just said out
                        // loud, and RD5 keeps wearer-initiated speech spoken in every mode
                        // — a chime in reply to a spoken question is worse than silence,
                        // because it cannot be told from a misheard one.
                        speech: routedSpeech,
                        arbiter: approvalArbiter,
                        // The same gate every request window runs in. A private one would
                        // let an attention window talk over a request being answered — and
                        // sharing it is also what makes "nothing is waiting" true by
                        // construction rather than by timing.
                        gate: interactionGate,
                        agentDisplayName: memory.standingAgentDisplayName ?? "the agent",
                        diagnosticSink: diagnostics,
                        // The standing responder, not the in-prompt one: there is no
                        // request in hand here, and answering "status" with the last
                        // request's summary would tell the wearer something is waiting
                        // that is not.
                        recallResponder: memory.standingRecallResponder,
                        instructionCapability: memory.standingInstructionCapability,
                        wearerAttribution: isWearerAttributed,
                        instructionEnqueue: memory.standingInstructionEnqueue,
                        // The same fleet-wide resolver the request windows take. Who is
                        // live does not depend on which window is open, and a wearer who
                        // opened this one themselves is the likeliest to name an agent
                        // other than the last one TapQ served.
                        instructionAddressResolver: memory.instructionAddressResolver,
                        voiceTrust: configuration.voiceTrust,
                        gestureConfirmation: gestureConfirmation,
                        intentSource: voiceIntentSource,
                        // The run's shared record, so an attention window that opens while a
                        // notice or an earlier answer is still sounding waits for the
                        // microphone instead of counting through it.
                        voiceChannelDrain: voiceChannelDrain
                    )
                }
            )
            // A child of the same source the gate and the turn coordinator read, so all
            // three see one detector's transitions rather than three monitors racing for
            // the same samples. The source holds its children; the run holds the source.
            let attentionSignal = wearerSpeechSource.makeSignal()
            attentionSignal.onWearerSpeakingChange = { [weak arming] speaking in
                arming?.wearerSpeakingChanged(speaking)
            }
            // Held by the service, not by the signal: the child holds its observer closure,
            // the closure holds the arming weakly (no cycle), and something has to own it.
            // A local would be released at the next suspension and the feature would go
            // silently dead — the same ARC trap `_ = wearerSpeechSource` guards below.
            attentionArming = arming
            attentionStatus = "imu (\(Int(CommandWindowController.windowSeconds))s command"
                + " windows between requests)"
        }

        // -- Voice sessions (RH1) --
        //
        // The window a held turn boundary opens. It is the Rung D command window with two
        // differences, both in `CommandWindowKind.voiceSession`: an unmatched sentence is
        // dictation rather than silence, and "end voice session" lets the boundary go.
        // Everything else — the gate, the eight seconds, the grammar, the refusal to
        // resolve anything — is the same object the attention window is.
        var voiceSessionStatus: String?
        if let instructionWaits, let instructions {
            let listening = VoiceSessionListening(
                waits: instructionWaits,
                diagnosticSink: diagnostics,
                makeController: { sessionID, agent, cue in
                    CommandWindowController(
                        // The un-quieted presenter, for the reason the attention window
                        // uses it: everything said in here answers something the wearer
                        // just said out loud.
                        speech: routedSpeech,
                        arbiter: approvalArbiter,
                        gate: interactionGate,
                        cue: cue,
                        agentDisplayName: agent.displayName,
                        diagnosticSink: diagnostics,
                        // The standing responder: there is no request in hand at a
                        // boundary, and "status" must not describe one that is over.
                        recallResponder: memory.standingRecallResponder,
                        // The waiting agent's own capability, not the last one TapQ served:
                        // this window exists because *this* session's hook is parked, so
                        // the addressee is known rather than inferred.
                        instructionCapability: {
                            AgentCapabilities.of(agent).instructions
                        },
                        wearerAttribution: isWearerAttributed,
                        // Addressed to the held session for the same reason. It is the one
                        // enqueue path in the runtime that does not go through conversation
                        // memory's "last request" guess.
                        instructionEnqueue: { [weak instructions] text in
                            guard let instructions else { return .notQueued }
                            switch instructions.enqueue(text, session: sessionID) {
                            case .rejectedEmpty: return .notQueued
                            case .queued: return .queued
                            case .queuedDroppingOldest: return .queuedDroppingOldest
                            }
                        },
                        // Addressing still reaches the whole fleet from here. The held
                        // boundary is where an unaddressed sentence goes, not a wall around
                        // it: "tell Codex to …" at a Claude Code boundary is exactly the
                        // sentence this window exists to make sayable.
                        instructionAddressResolver: memory.instructionAddressResolver,
                        kind: .voiceSession,
                        voiceTrust: configuration.voiceTrust,
                        voiceMayEndSession: voiceMayEndSession,
                        gestureConfirmation: gestureConfirmation,
                        intentSource: voiceIntentSource,
                        // The window this matters most to, and the one the sweep measured.
                        // The loop below opens window N+1 in the same actor turn that window
                        // N spoke its closing sentence in, so *every* window after the first
                        // opens under drain unless this record crosses between them.
                        voiceChannelDrain: voiceChannelDrain
                    )
                }
            )
            voiceSessionListening = listening
            voiceSessionStatus = "holding turn boundaries open until you end them"
                + " with a tap or a gesture, or the runtime stops;"
                + " unmatched speech in a waiting window is dictation"
        }

        let discovery = BrokerRuntimeDiscovery(
            supportDirectory: configuration.brokerDirectory
        )
        try discovery.prepareDirectory()
        discovery.remove()

        // Captured by the approval closures below. Locals rather than `self`, so a
        // closure holds the composition it was built with and cannot observe a later
        // mutation of the service's properties mid-approval.
        let activeReasoner = reasoner
        let activeReasonerMode = reasonerMode
        let reasonerConfig = configuration.reasonerConfig
        // Voice availability is the real composed signal, not the flag: `voiceAuthorized`
        // is false both when `--no-voice` was passed and when the user declined speech
        // authorization, and it is exactly what decided whether the arbiter got a voice
        // channel at all. A `gesture_and_voice` requirement is unmeetable without one.
        let voiceAvailable = voiceAuthorized
        // Built only when a reasoner exists, so a run without one leaves no file behind.
        let shadowLog = activeReasoner.map { _ in
            ReasonerShadowLog(
                directory: discovery.supportDirectory,
                diagnosticSink: diagnostics
            )
        }
        // Same discipline, same directory, different question: the shadow log asks whether
        // the model would have been right, this one asks what the user's policy actually
        // did. Built only when the filter is armed, so a run without `--auto-answer` leaves
        // no file behind.
        //
        // Armed only when a reasoner is actually running in primary: a requested reasoner
        // that failed to load degraded `reasonerMode` to `.off` above, and a filter left
        // pointing at a reasoner that does not exist would be a filter whose gate can never
        // be evaluated. Belt and braces over the CLI's own refusal.
        let activeAutoAnswerPolicy = activeReasonerMode == .primary ? autoAnswerPolicy : nil
        let autoAnswerLog = activeAutoAnswerPolicy.map { _ in
            AutoAnswerLog(
                directory: discovery.supportDirectory,
                diagnosticSink: diagnostics
            )
        }

        // -- TapQ's own memory (docs/TAPQ_AGENT_PLAN.md, Pillar A, milestone M1) --
        //
        // The durable record of the dialogue TapQ has with the wearer: what they said,
        // what TapQ said back, what was decided, and which instructions reached which
        // agent. Third file in this directory and the same discipline as the other two —
        // 0600 inside the 0700 runtime directory, never leaves the machine — but the first
        // one TapQ reads back, which is what the bounded recent window below is for.
        //
        // `nil` on the Apple path, and that nil is the whole of "structurally absent, not
        // disabled": with no store there is nothing to record into and no window to read,
        // so the three hooks are never assigned, `currentGrounding` finds no memory block
        // to append, and a run on that path leaves no file behind. There is no flag.
        let wearerMemory: WearerConversationStore? =
            configuration.voiceBackend == .openaiRealtime
                ? WearerConversationStore(
                    directory: discovery.supportDirectory,
                    diagnosticSink: diagnostics
                )
                : nil
        if let wearerMemory, let backendProvider {
            // Every sentence TapQ speaks, at the moment it goes out to be spoken. The hook
            // sits inside the provider's existing grounding bookkeeping, which already
            // returns early on the grammar path — so this records the model-backed
            // session's speech and cannot reach an Apple one even by miswiring.
            backendProvider.onSpokenToWearer = { text in
                wearerMemory.recordSpokenSentence(text)
            }
            // Every final transcript, verbatim (ratified 2026-08-29). On this path a
            // transcript decides nothing — intent arrives separately as a tool call — so
            // what is being recorded is exactly what it claims to be: the words the wearer
            // said, with no inference attached.
            backendProvider.onTranscriptFinal = { transcript, _ in
                wearerMemory.recordWearerUtterance(transcript)
            }
            // The consumption half of M1: a bounded recent window joins the per-turn
            // grounding, so "the thing I asked you earlier" still resolves after the
            // realtime session has been recycled out from under the conversation.
            backendProvider.wearerMemoryGrounding = {
                WearerConversationRecall.grounding(for: wearerMemory.recentWindow())
            }
        }
        // -- Session focus (docs/SESSION_FOCUS_PLAN.md) --
        //
        // The book of sessions, beside the wearer's memory and on the same branch: the one
        // file that keeps a session id and a directory next to a goal, which the spoken
        // memory must not. Nothing reads it into speech. What it is for right now is a
        // restart: a session the book says was detached stays detached, so the focus does
        // not go to whichever terminal happens to speak first — and a session TapQ started
        // that the book never saw end went with the runtime that started it, so it is
        // detached too and recorded as ended.
        let sessionBook: SessionBook? = wearerMemory.map { _ in
            SessionBook(directory: discovery.supportDirectory, diagnosticSink: diagnostics)
        }
        if let sessionBook {
            var restoredDetached = 0
            for record in sessionBook.records() where record.endedAt == nil {
                if record.isDetached {
                    memory.markSessionDetached(sessionID: record.sessionID)
                    restoredDetached += 1
                } else if record.ownedByTapQ {
                    memory.markSessionDetached(sessionID: record.sessionID)
                    sessionBook.recordEnded(
                        sessionID: record.sessionID,
                        agent: AgentIdentity(
                            id: record.agentID, displayName: record.agentDisplayName
                        ),
                        ending: "lost at restart"
                    )
                    restoredDetached += 1
                }
            }
            diagnostics.record(.init(
                category: "SessionFocus",
                name: "book.restored",
                fields: ["detached": "\(restoredDetached)"]
            ))
        }
        /// Remembers how a selection window resolved, in the terms it was spoken in.
        ///
        /// A closure rather than a store method, because the mapping from a
        /// `SelectionResult` to a sentence is knowledge about this runtime's request types
        /// and the store deliberately accepts neither — it takes speech-cleared strings, so
        /// that no future caller can hand it a request and hope it remembers which fields
        /// are unspeakable.
        let rememberSelection: @MainActor (SelectionRequest, SelectionResult) -> Void = {
            request, result in
            guard let wearerMemory else { return }
            let outcome: String
            if let freeText = result.freeText, !freeText.isEmpty, result.choices.isEmpty {
                outcome = "answered " + freeText
            } else if result.choices.isEmpty {
                outcome = "deferred"
            } else {
                outcome = "chose " + result.choices.map(\.label).joined(separator: ", ")
            }
            wearerMemory.recordDecision(
                agentDisplayName: request.agent.displayName,
                summary: request.question,
                outcome: outcome
            )
        }

        // Every approval the runtime resolves goes through here — a broker tool call and
        // a yes/no question the stop coordinator raised alike. "Primary" has to mean every
        // approval, not the broker's: a question like "should I delete the old backups?"
        // authorizes exactly what the `rm -rf` behind it would, so leaving it at
        // `.standard` would have been a hole in the policy rather than a smaller scope.
        //
        // The two paths differ only in how the request maps onto a `ReasonerContext`, so
        // that mapping is the parameter. It arrives as a closure rather than a value to
        // keep the `.off` promise below literal: in `.off` nothing builds a context at all.
        //
        // Split in two: this is the gated resolution, and `resolveApproval` below wraps it
        // once so the wait registry and the memory recording cover all three of its exits
        // rather than being repeated at each.
        let runApproval: @MainActor (
            ApprovalRequest,
            ContinuousClock.Instant,
            @MainActor () -> ReasonerContext
        ) async -> Decision = { request, deadline, makeContext in
            // `.off`, and every run where no reasoner could be built, is today's path
            // byte for byte: no context assembled, no assessment started, no file
            // written, no extra await between the request and the prompt.
            guard activeReasonerMode != .off, let reasoner = activeReasoner else {
                return await interactionGate.run {
                    armPrompt()
                    return await interaction.resolve(request, deadline: deadline)
                }
            }
            let context = makeContext()

            // The enqueue moment. Starting the assessment here rather than inside the
            // gate is what lets it overlap the queue wait: the model runs while the
            // gate may still be draining an earlier approval, so in the common case
            // `primary` ends up waiting on nothing. Detached because a stage-2
            // assessment must never occupy the UI actor the interaction runs on.
            let assessment = Task.detached {
                await ReasonerEscalation.assess(
                    context,
                    using: reasoner,
                    under: reasonerConfig
                )
            }

            if activeReasonerMode == .shadow {
                // Shadow must not be observable anywhere: the interaction resolves
                // exactly as it would with no reasoner at all, and the decision goes
                // back to the agent the moment it exists.
                let outcome = await interactionGate.run {
                    armPrompt()
                    return await interaction.resolve(request, deadline: deadline)
                }
                // Joining the assessment happens off the reply path. Awaiting it here
                // would hold the hook open for whatever was left of the model's
                // budget — usually nothing, but "usually" is not what shadow mode
                // promises. The cost is that a record can be lost if the runtime exits
                // in the gap, which is the right way round for a review artifact.
                Task { @MainActor in
                    let observed = await assessment.value
                    shadowLog?.append(
                        mode: .shadow,
                        request: request,
                        context: context,
                        assessment: observed,
                        // The counterfactual: what this decision would have demanded.
                        // Recorded, never applied — `escalationApplied` says so.
                        requiredConfirmation: ReasonerEscalation.requiredConfirmation(
                            for: observed.decision,
                            under: reasonerConfig,
                            voiceAvailable: voiceAvailable
                        ),
                        escalationApplied: false,
                        outcome: outcome
                    )
                }
                return outcome
            }

            // Primary: the requirement has to be settled before the prompt is spoken,
            // so this is the one place the assessment is awaited first. The wait is
            // bounded inside `assess` — `config.timeoutSeconds` plus a small grace —
            // and every way it can end badly (abstention, unreadable answer, low
            // confidence, a backend that never returns) yields `.standard`, which is
            // the deterministic requirement this build has always used.
            let observed = await assessment.value
            let requirement = ReasonerEscalation.requiredConfirmation(
                for: observed.decision,
                under: reasonerConfig,
                voiceAvailable: voiceAvailable
            )

            // -- Delegation filter (RD1) --
            // The one slot where an approval can be answered without the wearer: after the
            // assessment exists and before the gate is entered. Answering here is what
            // makes it silent — no window opens, nothing is spoken, and a wearer in the
            // middle of some other prompt is not interrupted by a request they were never
            // going to be asked about.
            //
            // Nothing about the reasoner's authority changes. `ReasonerDecision` still has
            // no approve case; what it produced is the observation "this is routine", and
            // turning that into a yes is the user's standing policy doing it, here, in the
            // host. Every way the assessment can fail — abstention, timeout, low
            // confidence, a tier above routine — yields `.ask(reason)` and falls through to
            // exactly the window the request would have opened with the filter off.
            if let policy = activeAutoAnswerPolicy {
                let verdict = policy.decision(for: observed, toolName: context.toolName)
                if verdict.isAutoAllow {
                    // The audit trail, written before the answer goes back so a runtime
                    // killed in the gap has still recorded what it approved. Both logs: the
                    // shadow log's row keeps the primary-mode review complete, and the
                    // auto-answer log's row is the only record that nobody was asked.
                    autoAnswerLog?.append(
                        request: request,
                        context: context,
                        assessment: observed,
                        verdict: verdict,
                        policy: policy
                    )
                    shadowLog?.append(
                        mode: .primary,
                        request: request,
                        context: context,
                        assessment: observed,
                        requiredConfirmation: requirement,
                        escalationApplied: requirement != .standard,
                        outcome: .allow
                    )
                    // Counted for "who's waiting?", which is where a wearer finds out the
                    // filter has been running at all. The session-memory record happens in
                    // `resolveApproval`, on the way out, like every other decision's.
                    memory.noteAutoAnswer()
                    diagnostics.record(.init(
                        category: "AutoAnswer",
                        name: "approval.auto_allowed",
                        // Closed fields only: the tool name and the tier. Never the
                        // summary — that is the log's job, at 0600, and a console line is
                        // not.
                        fields: [
                            "tool": context.toolName,
                            "tier": observed.decision?.riskTier.rawValue ?? "unknown",
                        ]
                    ))
                    return .allow
                }
            }

            let outcome = await interactionGate.run {
                armPrompt()
                return await interaction.resolve(
                    request,
                    deadline: deadline,
                    requiredConfirmation: requirement
                )
            }
            shadowLog?.append(
                mode: .primary,
                request: request,
                context: context,
                assessment: observed,
                requiredConfirmation: requirement,
                escalationApplied: requirement != .standard,
                outcome: outcome
            )
            return outcome
        }

        // Every approval, wrapped once.
        //
        // The window opens before the gate *and* before any stage-2 assessment: a request
        // queued behind three others, or one whose reasoner is still thinking, is waiting
        // for the wearer in exactly the sense "who's waiting?" asks about. It closes on
        // every exit, including a cancelled hook, because `withWindow` defers it.
        //
        // The recording is here rather than inside the branches for the same reason: this
        // is the one place where a request and its final `Decision` are both in hand, on
        // every path, which is what makes "what changed" complete without a fifth caller
        // remembering to record.
        let resolveApproval: @MainActor (
            ApprovalRequest,
            ContinuousClock.Instant,
            @MainActor () -> ReasonerContext
        ) async -> Decision = { request, deadline, makeContext in
            let decision = await memory.withWindow(
                sessionID: request.sessionID,
                agent: request.agent,
                summary: request.summary,
                detail: request.detail
            ) {
                await runApproval(request, deadline, makeContext)
            }
            memory.record(approval: request, decision: decision)
            // The same resolution, kept durably (Pillar A). Session memory answers "what
            // changed in this session?" while a window is open; this answers "what did we
            // decide?" after the session, the realtime connection, and the runtime have
            // all been replaced. Only the fields TapQ has already spoken are passed.
            wearerMemory?.recordDecision(
                agentDisplayName: request.agent.displayName,
                summary: request.summary,
                outcome: Self.spokenOutcome(of: decision),
                toolName: request.toolName
            )
            return decision
        }

        // -- The deliberation loop (docs/TAPQ_AGENT_PLAN.md, Pillar C, milestone M2) --
        //
        // Composed here and nowhere else, on the same branch every other pillar hangs off:
        // with no reasoner there is no loop, no `start_task` to declare, and no second
        // route for `ask_about_work`. The Apple path builds nothing — structurally absent,
        // not disabled, and there is no flag.
        //
        // Built this far down because its seven tool surfaces are seven things the runtime
        // already has: the durable memory, the transcript store, conversation memory's
        // roster and recall, the mailbox behind rung E's resolver, the run's one voice, and
        // the prompt path. The engine knows none of those types; it knows seven closures.
        //
        // It has no authority the wearer does not already have. Every surface below is one
        // a wearer can reach by speaking, `queue_instruction` goes through the same
        // fail-closed name resolution a dictation does, and nothing here can approve
        // anything — `ask_wearer` *asks* the wearer, which is the opposite.
        // M3: the one-shot follow-up book and its voice-facing scheduler. Composed on the
        // same branch as the loop — no reasoner, no reviews — and additionally on the
        // instruction mailbox, because a follow-up's name resolution is rung E's resolver
        // and a run without `--voice-instructions` has no roster to resolve against. The
        // book records every lifecycle event to Pillar A through the same recorder seam
        // the loop's outcomes use; the scheduler owns every sentence the wearer hears
        // about a promise.
        let followupBook: WearerFollowupBook? = {
            guard wearerMemory != nil, taskReasoner != nil, instructions != nil else {
                return nil
            }
            return WearerFollowupBook(
                record: { [wearerMemory] agent, instruction, event in
                    wearerMemory?.recordFollowup(
                        agentDisplayName: agent, instruction: instruction, event: event
                    )
                },
                diagnosticSink: diagnostics
            )
        }()
        let followupScheduler: WearerFollowupScheduler? = followupBook.map { book in
            WearerFollowupScheduler(
                book: book,
                // Rung E's resolver is the one authority on names, here as everywhere. An
                // ambiguous name comes back nil and is refused out loud — the wording says
                // "not one TapQ can address", which is true of an ambiguous name too: a
                // promise armed on a guess between two sessions is the misroute the
                // resolver exists to prevent. `acceptsInstructions` is deliberately not
                // required: a follow-up may only speak, and hearing is not a capability.
                resolveAgent: { [memory] name in
                    guard case let .resolved(addressee)? =
                        memory.instructionAddressResolver?(name)
                    else { return nil }
                    return addressee.agentDisplayName
                },
                diagnosticSink: diagnostics
            )
        }

        // The existing question machinery: the same `ApprovalRequest(kind: .question)` the
        // narrated boundary path builds, through the same gate, answered the same three
        // ways by nod, tap, or voice. Two callers now — the loop's `ask_wearer`, and the
        // "mid-task, start a new session anyway?" confirmation below — so it is named once.
        //
        // Deliberately *not* through `resolveApproval`. That wrapper opens a session
        // window, which would put "TapQ" in the roster as an agent the loop could then
        // address, and it runs the stage-2 assessment and the delegation filter — which
        // could auto-answer TapQ's own question without the wearer. Both are right for an
        // agent's request and wrong for TapQ asking one. The durable record is kept here
        // instead.
        let askWearerQuestion: @MainActor (String) async -> WearerTaskWearerAnswer = {
            [wearerMemory] question in
                let request = ApprovalRequest(
                    id: UUID().uuidString,
                    sessionID: "tapq-task",
                    agent: AgentIdentity(id: "tapq", displayName: "TapQ"),
                    toolName: "TapQTask",
                    summary: question,
                    detail: "",
                    kind: .question,
                    spokenPreamble: nil
                )
                // The question machinery's own bound is the bound: a window that
                // nobody answers inside `InteractionBudget.total` resolves `.ask`,
                // and the loop ends audibly on it rather than waiting forever.
                let deadline = ContinuousClock.now
                    + .seconds(InteractionBudget.total)
                let decision = await interactionGate.run {
                    armPrompt()
                    return await interaction.resolve(request, deadline: deadline)
                }
                wearerMemory?.recordDecision(
                    agentDisplayName: "TapQ",
                    summary: question,
                    outcome: Self.spokenOutcome(of: decision)
                )
                switch decision {
                case .allow: return .yes
                case .deny: return .no
                case .ask: return .unanswered
                }
        }

        // -- Session focus: the launcher, the switch, and the detached fast path --
        //
        // Every sentence on this path goes out the way a follow-up's does: through the
        // notification policy as a deferrable producer, so a switch announced while a
        // command window is open waits for the window rather than sounding into it.
        let sayLoopSentence: @MainActor (String) -> Void = { [routedSpeech] text in
            let say: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                guard case .speak = verdict else { return }
                routedSpeech.speak(text, priority: .notification, onFinish: nil)
            }
            say(notificationPolicy.routeLoopSpeech(text, whenDeferred: say))
        }
        // The folder the launch in flight is using. Written once per launch by the shared
        // start body below, read by the launcher's own two closures.
        let chosenSessionDirectory = ChosenSessionDirectory()
        // The folders TapQ makes when nothing else supplies one (`docs/WAKE_WORD_PLAN.md`
        // §5). Composed on the hook command for the same reason the launcher is: the
        // settings this writes into a new folder are what make the session TapQ starts
        // visible to TapQ, and there is nothing to write without it.
        let sessionWorkspace: OwnedSessionWorkspace? = configuration.claudeHookCommand.map {
            hookCommand in
            OwnedSessionWorkspace(
                root: configuration.sessionWorkspace.path,
                hookCommand: hookCommand,
                gitInit: configuration.sessionGitEnabled,
                diagnosticSink: diagnostics
            )
        }
        // Where the next voice-started session works (§6, and `docs/WAKE_WORD_PLAN.md` §5):
        // the focused session's folder when the book has one, else the operator's
        // `--session-directory`, else a folder TapQ makes under its workspace. Never
        // inferred from the goal — the goal only names the folder — and a failure is a
        // refusal the wearer hears rather than a guess at somewhere close enough.
        //
        // The goal passed here is the wearer's own sentence, empty when they asked for a
        // session without saying what for. Never the goalless prompt: that paragraph is
        // TapQ talking to the agent, and slugging it would name the folder after TapQ.
        enum NewSessionDirectory {
            case at(String)
            case refused(OwnedSessionRefusal)
        }
        let sessionDirectoryForNewSession: @MainActor (String) -> NewSessionDirectory = {
            [memory, sessionBook] goal in
            if let focused = memory.focusedSession(agentID: AgentIdentity.claudeCode.id),
               let path = sessionBook?.workingDirectory(sessionID: focused.sessionID) {
                return .at(path)
            }
            if let path = configuration.sessionDirectory?.path {
                return .at(path)
            }
            guard let sessionWorkspace else { return .refused(.workingDirectoryUnusable) }
            do {
                return .at(try sessionWorkspace.makeSessionDirectory(goal: goal))
            } catch {
                diagnostics.record(.init(
                    category: "SessionFocus",
                    name: "workspace.failed",
                    level: .error,
                    fields: ["error": "\(error)"]
                ))
                return .refused(.workspaceUnwritable)
            }
        }
        // Rung H leg 2, wired. Composed on the loop's branch plus the mailbox — a session
        // TapQ starts is one it will instruct — and only where the CLI told the runtime
        // which hook command the integration installed, because a session started without
        // TapQ's hooks is one TapQ could never see. The child inherits this runtime's
        // environment, with the broker directory made explicit so the child's shims find
        // *this* broker even under `--broker-dir`.
        let ownedLauncher: OwnedClaudeSessionLauncher? = {
            guard let wearerMemory, instructions != nil, taskReasoner != nil,
                  let hookCommand = configuration.claudeHookCommand
            else { return nil }
            var environment = ProcessInfo.processInfo.environment
            if let brokerDirectory = configuration.brokerDirectory {
                environment["TAPQ_BROKER_DIR"] = brokerDirectory.path
            }
            return OwnedClaudeSessionLauncher(
                configuration: .init(environment: environment),
                processRunner: POSIXOwnedSessionProcessRunner(),
                // Hooks may be registered for the user or for the project the session
                // will start in: a wearer who keeps TapQ out of their other sessions
                // installs them in the arena's `.claude/settings.json`, and a session
                // started there loads them through `--setting-sources`. Either registration
                // makes the session visible, so either satisfies the check.
                //
                // The second candidate is the folder *this* launch chose, not the
                // operator's `--session-directory`: those are the same thing whenever the
                // operator named one, and different exactly when TapQ made the folder
                // itself — where the hooks were written a moment ago and nowhere else.
                hookStatus: { [chosenSessionDirectory] in
                    var candidates = [HookInstaller.claudeSettingsURL()]
                    if let chosen = chosenSessionDirectory.current {
                        candidates.append(URL(fileURLWithPath: chosen, isDirectory: true)
                            .appendingPathComponent(".claude/settings.json"))
                    }
                    for url in candidates {
                        let status = HookInstaller(settingsURL: url, hookCommand: hookCommand)
                            .installationStatus()
                        if status != .notInstalled { return status }
                    }
                    return .notInstalled
                },
                // Decided before the launch rather than during it, so the folder TapQ makes
                // is made once and the hook check above reads the same one.
                workingDirectory: { [chosenSessionDirectory] in
                    chosenSessionDirectory.current
                },
                // The goal when it starts, the outcome when it ends: the same pair the
                // task recorder writes, under the `session` kind (§4).
                record: { goal, outcome in
                    wearerMemory.recordSession(
                        agentDisplayName: AgentIdentity.claudeCode.displayName,
                        text: goal,
                        event: outcome
                    )
                },
                diagnosticSink: diagnostics
            )
        }()
        // Every ending of a session TapQ started, wherever it was noticed: the focus it
        // held is freed at once (so the next session to speak takes it, even the one that
        // was detached for it), the book gets the ending, and the endings that have a
        // sentence are spoken.
        ownedLauncher?.onClosed = { [memory, sessionBook] closure in
            memory.endSession(sessionID: closure.session.sessionID)
            sessionBook?.recordEnded(
                sessionID: closure.session.sessionID,
                agent: closure.session.agent,
                ending: closure.ending.recordedOutcome
            )
            guard let spoken = closure.ending.spoken else { return }
            sayLoopSentence(spoken)
        }
        // The sweep (`OwnedSessionBudget.sweepInterval`): a child that exited, one that
        // never reported in, and a detached one past its grace are all noticed here.
        let ownedSweep: Task<Void, Never>? = ownedLauncher.map { launcher in
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(OwnedSessionBudget.sweepInterval))
                    guard !Task.isCancelled else { return }
                    launcher.sweep(now: Date())
                }
            }
        }
        // The switch, in order (§3), for a session that has just lost the focus: release
        // its held boundary, drop its queued instructions, cancel its follow-ups, wind it
        // down if TapQ started it, and record all of it. Returns the clause the
        // announcement ends with — what happened to the old session and to anything the
        // wearer had waiting on it — because the switch is loud exactly once.
        let detachSession: @MainActor (AgentRoster.Entry) -> String = {
            [weak self, wearerMemory, sessionBook, followupBook, instructions,
             instructionWaits, ownedLauncher] old in
            instructionWaits?.release(session: old.sessionID)
            // The listening loop may be bound to this session; the new session's next poll
            // retargets it rather than being reported as a second agent asking.
            self?.voiceSessionListening?.noteDetached(sessionID: old.sessionID)
            let dropped = instructions?.clear(session: old.sessionID).count ?? 0
            let owned = ownedLauncher?.detach(sessionID: old.sessionID, now: Date()) ?? false
            var clauses = [
                owned
                    ? "The one I started is being stopped."
                    : "The previous one is back on the keyboard.",
            ]
            if let followupBook {
                switch followupBook.cancel(agent: old.agent.displayName) {
                case .cancelled(let followup), .aborted(let followup):
                    clauses.append("Your follow-up on \(old.agent.displayName) is cancelled: "
                        + WearerTaskLoop.spokenGoal(followup.instruction))
                case .nothingPending:
                    break
                }
            }
            if dropped > 0 {
                clauses.append(dropped == 1
                    ? "One waiting instruction was dropped."
                    : "\(dropped) waiting instructions were dropped.")
            }
            let ending = owned
                ? WearerSessionEvent.detachedAndStopped
                : WearerSessionEvent.detachedToKeyboard
            let goal = sessionBook?.record(sessionID: old.sessionID)?.goal ?? ""
            wearerMemory?.recordSession(
                agentDisplayName: old.agent.displayName,
                text: goal.isEmpty ? "keyboard session" : goal,
                event: ending
            )
            sessionBook?.recordDetached(sessionID: old.sessionID, agent: old.agent, ending: ending)
            diagnostics.record(.init(
                category: "SessionFocus",
                name: "detached",
                fields: [
                    "agent": old.agent.id,
                    "owned": "\(owned)",
                    "instructions_dropped": "\(dropped)",
                ]
            ))
            return clauses.joined(separator: " ")
        }
        // The head of every broker handler (§2): notes the session's traffic, moves the
        // focus when a session TapQ has never heard from speaks — newest wins, announced
        // once — and says whether *this* session is detached, in which case the handler
        // answers it at once and in silence through `DetachedSessionPolicy`.
        let sessionIsDetached: @MainActor (String, AgentIdentity) -> Bool = {
            [memory, wearerMemory, sessionBook, ownedLauncher] sessionID, agent in
            ownedLauncher?.noteContact(sessionID: sessionID)
            switch memory.noteSessionTraffic(sessionID: sessionID, agent: agent) {
            case .focused:
                return false
            case .detached:
                return true
            case .tookFocus(let displaced):
                if sessionBook?.record(sessionID: sessionID) == nil {
                    sessionBook?.recordStarted(
                        sessionID: sessionID,
                        agent: agent,
                        ownedByTapQ: ownedLauncher?.owns(sessionID: sessionID) ?? false
                    )
                }
                guard let displaced else { return false }
                let clause = detachSession(displaced)
                wearerMemory?.recordSession(
                    agentDisplayName: agent.displayName,
                    text: "keyboard session",
                    event: WearerSessionEvent.focusMoved
                )
                diagnostics.record(.init(
                    category: "SessionFocus",
                    name: "moved",
                    fields: ["agent": agent.id, "reason": "keyboard"]
                ))
                sayLoopSentence(
                    "A new \(agent.displayName) session has my attention now. " + clause
                )
                return false
            }
        }
        // What a shared start did, in the terms its three callers differ on.
        enum StartedOwnedSession {
            /// `spoken` is the whole sentence, switch clause included, for a caller that
            /// says it itself. `switchClause` is that clause alone, for a caller whose own
            /// flow composes the first half — the dictation announcement does, and losing
            /// the clause there would let a session be stopped without a word.
            case started(agentDisplayName: String, spoken: String, switchClause: String?)
            case refused(OwnedSessionRefusal)
        }
        // The body every door that starts a session runs (`docs/WAKE_WORD_PLAN.md` §4,
        // rule 3): choose the folder, launch, move the focus, write the book, compose the
        // sentence. Three doors, one function, so a session the wake word starts is the
        // same session `start_session` starts.
        //
        // The new session starts *before* the old one is touched, so a spawn failure leaves
        // the focused session exactly as it was.
        //
        // The mid-task confirmation is deliberately not in here, and that is the one seam
        // in the extraction. Asking the wearer runs through `interactionGate`, which is
        // documented as not reentrant, and two of the three doors are *inside* a window the
        // gate is already running: a confirmation there would not ask a question, it would
        // wedge the gate for the rest of the run. It stays on `start_session`, which is the
        // only door reachable from outside a window and also the only one that means "start
        // a new session" rather than "here is something to do" (§7, open decision 3).
        let startOwnedSession: (@MainActor (String) -> StartedOwnedSession)? =
            ownedLauncher.map { launcher in
                { [memory, wearerMemory, sessionBook] goal in
                    let agent = AgentIdentity.claudeCode
                    let directory: String
                    switch sessionDirectoryForNewSession(goal) {
                    case .at(let path):
                        directory = path
                    case .refused(let refusal):
                        // Recorded here because the launcher records its own refusals and
                        // this one never reached it — a refusal missing from the wearer's
                        // memory is a question tomorrow that nothing can answer.
                        wearerMemory?.recordSession(
                            agentDisplayName: agent.displayName,
                            text: goal,
                            event: refusal.recordedOutcome
                        )
                        return .refused(refusal)
                    }
                    chosenSessionDirectory.current = directory
                    // A session asked for with no goal still needs a prompt — `--print` runs
                    // one — so it gets one that ends at once, and the held Stop after it is
                    // where the wearer's first real instruction lands.
                    let prompt = goal.isEmpty ? Self.goallessSessionPrompt : goal
                    switch launcher.launchOwnedSession(goal: prompt) {
                    case .refused(let refusal):
                        return .refused(refusal)
                    case .started(let session):
                        let displaced = memory.focusSession(
                            sessionID: session.sessionID, agent: agent
                        )
                        sessionBook?.recordStarted(
                            sessionID: session.sessionID,
                            agent: agent,
                            workingDirectory: directory,
                            goal: prompt,
                            ownedByTapQ: true
                        )
                        var sentence = goal.isEmpty
                            ? "Started a new \(agent.displayName) session."
                            : "Started a new \(agent.displayName) session: "
                                + WearerTaskLoop.spokenGoal(goal) + "."
                        var switchClause: String?
                        if let displaced {
                            let clause = detachSession(displaced)
                            switchClause = clause
                            sentence += " " + clause
                            wearerMemory?.recordSession(
                                agentDisplayName: agent.displayName,
                                text: goal,
                                event: WearerSessionEvent.focusMoved
                            )
                        }
                        diagnostics.record(.init(
                            category: "SessionFocus",
                            name: "moved",
                            fields: ["agent": agent.id, "reason": "voice",
                                     "displaced": "\(displaced != nil)"]
                        ))
                        return .started(
                            agentDisplayName: agent.displayName,
                            spoken: sentence,
                            switchClause: switchClause
                        )
                    }
                }
            }
        // The loop's tenth tool (§5, step 4), and door 3 of the routing rule. Confirms first
        // when the focused session is mid-task (§1, rule 5), then runs the shared body and
        // speaks its sentence as the tool's announcement.
        let startSessionSurface: @MainActor (String) async -> WearerTaskToolOutput = {
            [memory] goal in
            guard let startOwnedSession else {
                return .ok(WearerTaskSurfaces.noSessionLauncherText)
            }
            let agent = AgentIdentity.claudeCode
            if let current = memory.focusedSession(agentID: agent.id),
               memory.isMidTask(sessionID: current.sessionID) {
                diagnostics.record(.init(
                    category: "SessionFocus", name: "start.confirming", fields: [:]
                ))
                switch await askWearerQuestion(
                    "\(agent.displayName) is mid-task. Start a new session anyway?"
                ) {
                case .yes:
                    break
                case .no:
                    return .ok("The wearer said no. Nothing was started and the current "
                        + "session keeps TapQ's attention. Finish by saying so in a few "
                        + "words.")
                case .unanswered:
                    return .ok("The wearer did not answer, so nothing was started and the "
                        + "current session keeps TapQ's attention. Finish by saying so in "
                        + "a few words.")
                }
            }
            switch startOwnedSession(goal) {
            case .refused(let refusal):
                return .announcing(
                    "TapQ could not start a session (\(refusal.recordedOutcome)) and has "
                        + "told the wearer why. Finish with a few words; do not repeat the "
                        + "reason.",
                    say: refusal.spoken
                )
            case .started(_, let sentence, _):
                return .announcing(
                    "The session is started and the wearer has heard so. Finish with a few "
                        + "words and no repetition.",
                    say: sentence
                )
            }
        }
        // The routing rule (`docs/WAKE_WORD_PLAN.md` §4). Whatever the wearer says, however
        // it arrives, this is what happens to it: queued into the session that is live, or
        // — with nothing live — the goal of a session that starts now, or a spoken refusal
        // saying why neither could happen. Doors 1 and 2 call it; door 3 is the tool above,
        // which shares the body rather than the decision because "start a new session" has
        // already made the decision.
        let instructionRouter = InstructionRouter(
            enqueueToLiveTarget: { [memory] text in
                // `nil` is the whole of "nothing is live", and it is the roster's judgement
                // (§1, rule 4): the standing enqueue answers `.notQueued` for a target that
                // has gone, which is a different sentence from the one this path owes the
                // wearer.
                guard memory.liveStandingTarget != nil,
                      let enqueue = memory.standingInstructionEnqueue
                else { return nil }
                return enqueue(text)
            },
            startSession: startOwnedSession.map { start in
                { goal in
                    switch start(goal) {
                    case .started(let agentDisplayName, _, let switchClause):
                        // The flow that took the sentence says "Started a new … session"
                        // itself. What only this knows is what the switch cost, so the
                        // clause goes out through the notification policy, which holds it
                        // until the window that is speaking has closed.
                        if let switchClause { sayLoopSentence(switchClause) }
                        return .started(agentDisplayName: agentDisplayName)
                    case .refused(let refusal):
                        return .refused(spoken: refusal.spoken)
                    }
                }
            },
            diagnosticSink: diagnostics
        )
        let routeInstruction = instructionRouter.dictating
        // The roster's resolver, plus one answer it cannot give: a name for the agent TapQ
        // can start, said while nothing is live, resolves to the session the routing rule
        // is about to start. Live sessions keep the roster's answer; only the roster's
        // silence is filled, and only for that one agent.
        let resolveOrStart: InstructionAddressResolving = { [memory] name in
            if let resolution = memory.instructionAddressResolver?(name) { return resolution }
            guard ownedLauncher != nil, memory.liveStandingTarget == nil,
                  InstructionRouter.namesStartableAgent(name) else { return nil }
            return .resolved(InstructionAddressee(
                agentDisplayName: AgentIdentity.claudeCode.displayName,
                acceptsInstructions: true,
                enqueue: routeInstruction
            ))
        }
        // The grounding's cold-start line (§4). It says an instruction *starts* a session
        // only where one could actually be started; with no launcher composed the model
        // keeps the old line, which is the honest grounding for a runtime that can do
        // nothing with a sentence it has nowhere to send. A constant rather than a live
        // read, because the launcher is composed once for the run: what changes inside a
        // run is which sessions are live, and that is `liveAgentNames`.
        if let backendProvider {
            let canStartSession = ownedLauncher != nil
            backendProvider.canStartSession = { canStartSession }
        }

        // -- The wake word (docs/WAKE_WORD_PLAN.md) --
        //
        // The one opener that needs nothing running. It is wired here rather than beside the
        // `.imu` arming above because it opens a window whose dictation is the routing rule,
        // and the routing rule needs the launcher, which is composed two hundred lines below
        // that. `.imu` is untouched, and the two cannot both be on: `--attention` takes one
        // value.
        if configuration.attentionMode == .wake {
            let spotter = WakeWordListener(
                phrase: configuration.wakeWord,
                diagnosticSink: diagnostics
            )
            // The run's own voice, undecorated by `--quiet`, for the reason the attention
            // window uses it: everything said here answers something the wearer said out
            // loud, and a chime in reply to their own name cannot be told from a misheard
            // one.
            let sayToWearer: @MainActor (String) -> Void = { [routedSpeech] text in
                routedSpeech.speak(text, priority: .notification, onFinish: nil)
            }
            // Whether a sentence said in a wake window could go anywhere at all. Either a
            // live session takes it, or TapQ can start one for it — and if neither is true
            // the window still opens and still refuses out loud, which is the difference
            // between a wearer who knows and a wearer who repeats themselves.
            let canStartSession = ownedLauncher != nil
            let arming = WakeWordArming(
                waits: memory.waitRegistry,
                isVoiceSessionListening: { [weak self] in
                    self?.voiceSessionListening?.isListening == true
                },
                speak: sayToWearer,
                diagnosticSink: diagnostics,
                makeController: {
                    CommandWindowController(
                        speech: routedSpeech,
                        arbiter: approvalArbiter,
                        // The gate every other window runs in. Sharing it is what makes
                        // "nothing is waiting" true by construction rather than by timing.
                        gate: interactionGate,
                        cue: Self.wakeWindowCue,
                        agentDisplayName: memory.standingAgentDisplayName ?? "the agent",
                        diagnosticSink: diagnostics,
                        recallResponder: memory.standingRecallResponder,
                        instructionCapability: {
                            memory.standingInstructionCapability() || canStartSession
                        },
                        wearerAttribution: isWearerAttributed,
                        // The whole difference from the attention window: a sentence here is
                        // routed rather than queued, so one with nothing live to receive it
                        // starts the session that receives it.
                        instructionEnqueue: routeInstruction,
                        instructionAddressResolver: resolveOrStart,
                        // A plain sentence is an instruction, which is what saying the name
                        // was for. The kind is the held boundary's; only the number is its
                        // own.
                        kind: .voiceSession,
                        voiceTrust: configuration.voiceTrust,
                        // There is no session to end: this window is not tied to one, and
                        // "end voice session" said into it would end a loop that is not
                        // running.
                        voiceMayEndSession: false,
                        gestureConfirmation: gestureConfirmation,
                        intentSource: voiceIntentSource,
                        voiceChannelDrain: voiceChannelDrain,
                        windowSeconds: CommandWindowController.wakeWindowSeconds
                    )
                }
            )
            let gate = WakeWordGate(
                spotter: spotter,
                // Ordered for the diagnostic: `wake.suspended reason=…` names the first one
                // that holds, which is the one to read when a spotter is unexpectedly deaf.
                conditions: [
                    .init(reason: "window") { [weak arming] in
                        arming?.isWindowOpen == true
                    },
                    // Never true under `--attention wake` — the mode that composes an
                    // attention arming is `imu` — and stated anyway, so a run that ever
                    // composes both is suspended rather than sharing a microphone.
                    .init(reason: "attention") { [weak self] in
                        self?.attentionArming?.isWindowOpen == true
                    },
                    .init(reason: "waiting") { [weak memory] in
                        (memory?.waitRegistry.waitingCount ?? 0) > 0
                    },
                    .init(reason: "listening") { [weak self] in
                        self?.voiceSessionListening?.isListening == true
                    },
                    .init(reason: "speaking") { [voiceChannelDrain] in
                        voiceChannelDrain.isBusy
                    },
                ],
                onWake: { [weak arming] in arming?.wakeWordHeard() },
                speak: sayToWearer,
                diagnosticSink: diagnostics
            )
            // Every transition of everything a condition reads. Three of them are edges this
            // plan added, each on the object that owns the fact; the fourth is the arming's
            // own window, which is the only one the gate causes itself.
            arming.onWindowChanged = { [weak gate] in gate?.reevaluate() }
            memory.waitRegistry.onWaitingChanged = { [weak gate] in gate?.reevaluate() }
            voiceSessionListening?.onListeningChanged = { [weak gate] in gate?.reevaluate() }
            // TapQ's own voice, fanned out from the speech gate rather than subscribed to
            // directly: `onSpeakingChange` is a single-observer slot and `SpeechGatedVoice`
            // owns it, for the self-hearing guard.
            gatedVoice.onSpeakingChanged = { [weak gate] _ in gate?.reevaluate() }
            wakeSpotter = spotter
            wakeArming = arming
            wakeGate = gate
            // Armed now, which with nothing running is immediately: the wake word has to
            // work before anything else in this runtime has happened.
            gate.reevaluate()
            attentionStatus = "wake (\"\(configuration.wakeWord)\" opens a "
                + "\(Int(CommandWindowController.wakeWindowSeconds))s command window "
                + "whenever nothing else is listening; a sentence with no live session "
                + "starts one)"
        }

        let loopSurfaces = WearerTaskSurfaces(
                    // Pillar A retrieval, the half M1 deferred to the loop: the whole
                    // retained record, ranked against the query, rather than the unranked
                    // recent window the realtime session already carries per turn.
                    searchMemory: { [wearerMemory] query in
                        guard let wearerMemory else {
                            return .ok(WearerMemorySearch.emptyMemoryText)
                        }
                        let found = WearerMemorySearch.search(
                            entries: wearerMemory.entries(),
                            query: query,
                            now: Date()
                        )
                        diagnostics.record(.init(
                            category: "WearerTask",
                            name: "memory.searched",
                            fields: [
                                "matches": "\(found.matches.count)",
                                "dropped": "\(found.droppedEntries)",
                            ]
                        ))
                        // The count rides along so the question lane's latency line can say
                        // what it answered from without a second log line to correlate.
                        return .ok(found.text, itemCount: found.matches.count)
                    },
                    // Pillar B retrieval. Excerpts, not an answer: the loop writes the
                    // answer itself, which is the whole of what folding `ask_about_work`
                    // into the loop buys — one sentence composed from the agent's history
                    // *and* TapQ's own memory of what the wearer asked for.
                    readTranscript: { [transcriptAnswerer] agent, query in
                        guard let transcriptAnswerer else {
                            return .localFailure(
                                "no transcript store",
                                tellingModel: "TapQ has no session history to read.",
                                saying: TranscriptQuestionAnswerer.notAttachedNotice
                            )
                        }
                        switch transcriptAnswerer.excerpts(
                            question: query, agentDisplayName: agent
                        ) {
                        case let .selected(slices, droppedEntries, droppedCharacters):
                            diagnostics.record(.init(
                                category: "WearerTask",
                                name: "transcript.read",
                                fields: [
                                    "slices": "\(slices.count)",
                                    "dropped_entries": "\(droppedEntries)",
                                    "dropped_chars": "\(droppedCharacters)",
                                ]
                            ))
                            return .ok(
                                TranscriptExcerpts.rendered(
                                    slices: slices, agentDisplayName: agent
                                ),
                                itemCount: slices.count
                            )
                        case let .unavailable(reason, notice):
                            // The other failure class, and it stays the other one: loud in
                            // the log, honest to the model, and the session lives. Only a
                            // cloud call breaks the voice.
                            return .localFailure(
                                reason.rawValue,
                                tellingModel: "TapQ cannot read that session's history "
                                    + "(\(reason.rawValue)), so there are no excerpts. Say "
                                    + "so plainly rather than guessing what it contained.",
                                saying: notice
                            )
                        }
                    },
                    // The surfaces `query_status` already answers out of, plus the roster —
                    // because the names it lists are the only names `queue_instruction`
                    // below will accept, and a loop told to guess would guess.
                    status: { [memory] in
                        var lines: [String] = []
                        let names = memory.liveAgentDisplayNames
                        lines.append(names.isEmpty
                            ? "No agent can be addressed by name right now."
                            : "Agents addressable by name right now: "
                                + names.joined(separator: ", ") + ".")
                        if let waiting = memory.standingRecallResponder(.status) {
                            lines.append("Waiting on the wearer: \(waiting)")
                        }
                        if let changed = memory.standingRecallResponder(.whatChanged) {
                            lines.append("Already done in this session: \(changed)")
                        }
                        return .ok(lines.joined(separator: "\n"))
                    },
                    // The existing instruction path, rung E resolution and all. Two
                    // differences from the dictation flow, both deliberate: a name is
                    // *required* here, because the loop is not standing in a window and
                    // "the agent that just asked me something" does not exist off one; and
                    // what was sent is announced, because a sentence delivered in the
                    // wearer's name while they are not listening has to be audible.
                    queueInstruction: { [memory] agent, text in
                        let sentence = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !sentence.isEmpty else {
                            return .ok("No instruction text was supplied, so nothing was "
                                + "queued.")
                        }
                        // Tagged `.loop`: the wearer asked for the goal, but TapQ composed
                        // this sentence — so the record and the agent's transcript say so,
                        // and the origin-aware cap can bound a chain of them even in a
                        // voice session, where the dictation cap deliberately stands down.
                        guard let resolve =
                            memory.instructionAddressResolver(origin: .loop)
                        else {
                            return .ok("This run has no instruction queue, so nothing can "
                                + "be sent to an agent. Tell the wearer.")
                        }
                        guard let name = agent, !name.isEmpty else {
                            // Door 2 (`docs/WAKE_WORD_PLAN.md` §4). With something live, a
                            // nameless call is still a guess TapQ will not make for the
                            // wearer — "the agent" is not an address when there are two.
                            // With nothing live there is nothing to name, and the sentence
                            // is the one thing that could start a session; refusing it for
                            // want of an address would refuse it for want of the very thing
                            // this door exists to supply.
                            guard memory.liveAgentDisplayNames.isEmpty else {
                                return .ok("An agent name is required. Call get_status for "
                                    + "the names that are addressable right now; never "
                                    + "guess one.")
                            }
                            return InstructionRouter.toolOutput(
                                for: routeInstruction(sentence),
                                instruction: sentence,
                                liveAgentDisplayName: memory.standingAgentDisplayName
                            )
                        }
                        switch resolve(name) {
                        case .none:
                            if ownedLauncher != nil, memory.liveStandingTarget == nil,
                               InstructionRouter.namesStartableAgent(name) {
                                // The name is the agent TapQ can start, and nothing is
                                // live: the same door an unaddressed sentence takes.
                                return InstructionRouter.toolOutput(
                                    for: routeInstruction(sentence),
                                    instruction: sentence,
                                    liveAgentDisplayName: nil
                                )
                            }
                            return .ok("Nothing live answers to \"\(name)\", so nothing was "
                                + "queued.")
                        case let .ambiguous(agentDisplayName):
                            return .ok("\(agentDisplayName) has more than one live session, "
                                + "so that name does not identify one of them. Nothing was "
                                + "queued.")
                        case let .resolved(addressee):
                            guard addressee.acceptsInstructions else {
                                return .ok("\(addressee.agentDisplayName) cannot be sent "
                                    + "instructions, so nothing was queued.")
                            }
                            let outcome = addressee.enqueue(sentence)
                            switch outcome {
                            case .notQueued:
                                return .ok("\(addressee.agentDisplayName) would not take "
                                    + "it, so nothing was queued.")
                            case .queued:
                                return .announcing(
                                    "Queued for \(addressee.agentDisplayName); it is "
                                        + "delivered at that agent's next turn boundary. It "
                                        + "authorizes nothing on its own.",
                                    say: "I've told \(addressee.agentDisplayName): "
                                        + WearerTaskLoop.spokenGoal(sentence)
                                )
                            case .queuedDroppingOldest:
                                // A full queue evicted its oldest sentence to take this
                                // one — possibly a sentence the wearer dictated. Said out
                                // loud, because a loop-composed instruction silently
                                // displacing a wearer's is the review-flagged failure.
                                return .announcing(
                                    "Queued for \(addressee.agentDisplayName); the queue "
                                        + "was full, so its oldest waiting instruction was "
                                        + "dropped to make room. It authorizes nothing on "
                                        + "its own.",
                                    say: "I've told \(addressee.agentDisplayName): "
                                        + WearerTaskLoop.spokenGoal(sentence)
                                        + " — the oldest waiting instruction was dropped "
                                        + "to make room."
                                )
                            case .startedSession, .refused:
                                // Structurally unreachable, and stated rather than folded
                                // into a `default:` so it stays a decision. This arm's
                                // addressee is a *resolved live session*: a live session
                                // queues, and it never starts anything or refuses with a
                                // sentence of its own. Both outcomes belong to the routing
                                // above, which is reached with no agent named at all
                                // (`docs/WAKE_WORD_PLAN.md` §4, door 2). Answered truthfully
                                // rather than fatally, because a wedged voice loop is a
                                // worse way to learn about a composition mistake.
                                return InstructionRouter.toolOutput(
                                    for: outcome,
                                    instruction: sentence,
                                    liveAgentDisplayName: addressee.agentDisplayName
                                )
                            }
                        }
                    },
                    // The run's one voice, at notification priority like every other
                    // sentence TapQ says that is not a prompt. Not routed through the quiet
                    // decorator: `--quiet` trades prompts and notifications for cues and
                    // says so on the status line — "answers still spoken" — and everything
                    // the loop says is an answer to something the wearer asked for.
                    speak: { [routedSpeech] text in
                        routedSpeech.speak(text, priority: .notification, onFinish: nil)
                    },
                    // The existing question machinery: the same `ApprovalRequest(kind:
                    // .question)` the narrated boundary path builds, through the same gate,
                    // answered the same three ways by nod, tap, or voice.
                    //
                    // Deliberately *not* through `resolveApproval`. That wrapper opens a
                    // session window, which would put "TapQ" in the roster as an agent the
                    // loop could then address, and it runs the stage-2 assessment and the
                    // delegation filter — which could auto-answer TapQ's own question
                    // without the wearer. Both are right for an agent's request and wrong
                    // for TapQ asking one. The durable record is kept here instead.
                    askWearer: askWearerQuestion,
                    // Pillar A, twice per task: the goal when it starts and the outcome when
                    // it ends. Only speech-cleared text — the goal is the sentence TapQ read
                    // back out loud when it accepted, and the outcome is one word.
                    recordTask: { [wearerMemory] goal, outcome in
                        wearerMemory?.recordTask(goal: goal, outcome: outcome)
                    },
                    // M3: a running task may register its own continuation — "tell Claude
                    // X, and when it finishes, check the result" as one goal. Same book,
                    // same read-back, tagged `.loop` inside the scheduler's surface.
                    setFollowup: followupScheduler.map { $0.taskSurface() } ?? { _, _ in
                        .ok(WearerTaskSurfaces.noFollowupBookText)
                    },
                    // Session focus: the tenth tool, composed above.
                    startSession: startSessionSurface
        )
        let wearerTaskLoop: WearerTaskLoop? = taskReasoner.map { reasoner in
            WearerTaskLoop(
                model: reasoner,
                surfaces: loopSurfaces,
                diagnosticSink: diagnostics
            )
        }
        // M3: the review lane's voice. The same surfaces, with one substitution — `speak`
        // enters the channel through `NotificationPolicy` as a deferrable producer, so a
        // review sentence waits out an open command window exactly as an agent
        // notification does, instead of sounding into it through the task lane's direct
        // path. The task lane keeps that direct path: its speech answers a wearer who is
        // mid-conversation, which is the opposite situation from a review nobody asked
        // for at this moment.
        var followupSurfaces = loopSurfaces
        followupSurfaces.speak = { [routedSpeech] text in
            let say: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                guard case .speak = verdict else { return }
                routedSpeech.speak(text, priority: .notification, onFinish: nil)
            }
            say(notificationPolicy.routeLoopSpeech(text, whenDeferred: say))
        }
        if let wearerTaskLoop {
            // The fourth sibling on the same latch. A cloud call that fails inside the loop
            // is the narration model on the narration endpoint with the narration key, so it
            // gets narration's answer: break, loudly, once. Its own hook rather than a reuse
            // of `onWorkAnswerFailed`, because an operator reading the log has to know
            // whether TapQ could not be heard, could not understand the wearer, could not
            // answer a question, or could not think.
            wearerTaskLoop.onLoopBroken = { [weak voiceBrokenState] reason in
                voiceBrokenState?.noteBackendFailed(reason: "task loop: \(reason)")
            }
            // `ask_about_work` now answers through the loop, so a question can draw on the
            // transcript and on TapQ's own memory in one sentence.
            workQuestionRoute?.loop = wearerTaskLoop
            // The wearer stepping out of the voice session is an ending, and a task ends
            // with it. Silently, like the shutdown case: they just told TapQ to stop.
            voiceSessionListening?.onEndedByWearer = { [weak wearerTaskLoop, weak followupBook] in
                wearerTaskLoop?.cancel(reason: "voice session ended by wearer")
                followupBook?.expireAll(reason: "voice session ended by wearer")
            }
            // And so is the pipe dying. `releaseHolds` is the one hook the latch fires, and
            // it is already carrying the boundary release, so this chains rather than
            // replaces. A loop that kept thinking past a break would be exactly the
            // degraded half-agent the posture forbids — its HTTP calls would keep working
            // while the channel the answer was for is gone.
            let releaseHoldsBeforeLoop = voiceBrokenState?.releaseHolds
            voiceBrokenState?.releaseHolds = { [weak wearerTaskLoop, weak followupBook] in
                releaseHoldsBeforeLoop?()
                wearerTaskLoop?.cancel(reason: "voice channel broken")
                // A promise held for a channel that can no longer announce keeping it is
                // expired, not kept quietly: the same posture as the task it would run.
                followupBook?.expireAll(reason: "voice channel broken")
            }
            // The M2 hookup: the provider has held the handle since its init, and the
            // loop exists now. The loop's `startTask` is `nonisolated` and hops to the
            // main actor internally, so the provider's `await` is safe from any isolation.
            wearerTaskHandle?.loop = wearerTaskLoop
            // The M3 hookup, same shape: `set_followup`/`cancel_followup` have been
            // declared since the provider's init, and the scheduler exists now.
            wearerFollowupHandle?.scheduler = followupScheduler
        }

        let stopQuestions = StopQuestionCoordinator(
            // Both of these are dead weight on the model-backed path and are passed anyway,
            // so the two compositions keep one shape: with a narrator present the
            // coordinator never reaches either, and with none — the Apple path — they are
            // still the whole of the delivery decision.
            classifier: classifierSelection.classifier,
            // nil under `--speech-summarizer off`: the coordinator then builds the same
            // requests it always did, with no preamble and an empty detail.
            summarizer: summarizerSelection.summarizer,
            narrator: boundaryNarrator,
            // The same latch a dropped socket and an unparseable tool call reach, for the
            // same reason: narration is not an enhancement on this path, it is how the
            // wearer is spoken to at all. A run that cannot decide what to say has no voice
            // left to say it with, and it ends loudly rather than falling back to the
            // heuristics this replaced — which are unreachable here by construction.
            onNarrationFailed: { [weak voiceBrokenState] reason in
                voiceBrokenState?.noteBackendFailed(reason: "narration: \(reason)")
            },
            diagnosticSink: diagnostics,
            // The drain side of the one queue. Delivery happens at the head of the
            // coordinator's handling, ahead of the repeat and classifier guards, because
            // an instruction is not an answer to anything the agent asked.
            instructions: instructions,
            // Session memory first, exactly as before; then the durable record, so "you
            // told Codex to rerun the failing suite" outlives the session that heard it.
            // Both are recorded at delivery, not at dictation — an instruction still
            // waiting in the mailbox may yet be dropped at capacity.
            recordInstruction: { session, agent, text in
                memory.recordInstruction(session: session, agent: agent, text: text)
                wearerMemory?.recordInstruction(
                    agentDisplayName: agent.displayName,
                    text: text
                )
                // The report-back (2026-09-01, third hardware run): an instruction has
                // just reached the agent, so its next finished boundary is the answer to
                // something the wearer asked for. Arm the one-shot that reads it back,
                // unless a follow-up is already waiting on that agent. Said through the
                // same deferral as every loop sentence.
                guard let followupScheduler,
                      let notice = followupScheduler.armReportBack(
                          agent: agent.displayName, about: text
                      )
                else { return }
                let say: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                    guard case .speak = verdict else { return }
                    routedSpeech.speak(notice, priority: .notification, onFinish: nil)
                }
                say(notificationPolicy.routeLoopSpeech(notice, whenDeferred: say))
            },
            // Two things come through here now. Without a narrator it is what it always
            // was: the status line about TapQ holding an instruction back, spoken at
            // notification priority in the run's voice. With one it is also the narrated
            // utterance for a boundary that turned out not to be a question — the agent's
            // turn outcome, in the words the model chose, spoken verbatim. Both are
            // notification-priority for the same reason: neither is a prompt the wearer is
            // answering, and a question *is* one, so it goes out through `runApproval`
            // below instead of here.
            //
            // (This used to be pinned to the local synthesizer to keep it "TapQ's own";
            // under voice-output isolation there is no such thing as a second voice to be
            // TapQ's own in, and a narrated sentence going out on the scripted channel is
            // also what puts it into the realtime model's per-turn grounding.)
            //
            // Under `--quiet` it becomes the notification cue, like every other
            // notification-priority line — including a narrated statement, which is the
            // honest reading of a flag that asks for sounds instead of sentences. A
            // narrated *question* still speaks, because it reaches the wearer through the
            // prompt path. Written here rather than by routing through the quiet decorator
            // because that decorator wraps the *prompt* path and would turn this into a
            // second cue for the same event.
            announce: { [routedSpeech] notice in
                guard !configuration.quietEnabled else {
                    playCue(.notification)
                    return
                }
                routedSpeech.speak(notice, priority: .notification, onFinish: nil)
            },
            // Stood down in a voice session (RH1): every boundary there is *supposed* to
            // carry an instruction, because the wearer is standing at it dictating them one
            // at a time. Off — the default — everywhere else, so RC2's cap is untouched for
            // every run that is not one.
            suppressesLoopCap: configuration.voiceSessionEnabled,
            // Not assessed, deliberately: a multi-option selection resolves to a *choice*,
            // not an allow/deny, so there is nothing here for a `RequiredConfirmation` to
            // raise — `SelectionController.resolve` has no such parameter. Wiring
            // escalation into selection is its own packet; until then the reasoner sees
            // the yes/no questions and not the pick-one ones, and
            // `ReasonerContext.init(questionRequest:optionLabels:)` records where the
            // labels will come from when it exists.
            runSelection: { request, deadline in
                let result = await memory.withWindow(
                    sessionID: request.sessionID,
                    agent: request.agent,
                    summary: request.question
                ) {
                    await interactionGate.run {
                        armPrompt()
                        return await selection.resolve(request, deadline: deadline)
                    }
                }
                // Recorded as a stop answer when the wearer spoke one, and as the
                // selection it is when they picked a label.
                memory.recordStopSelection(request, result: result)
                rememberSelection(request, result)
                return result
            },
            // The coordinator hands over an `ApprovalRequest` whose `summary` is the
            // question it classified, and takes back the same `Decision` an approval
            // produces — so the whole assessment path applies unchanged, including
            // `primary` passing the escalated requirement into `interaction.resolve`.
            runApproval: { request, deadline in
                await resolveApproval(request, deadline) {
                    ReasonerContext(questionRequest: request)
                }
            }
        )
        // Fifth hardware run (2026-09-02): a boundary the model read out word for word has
        // already told the wearer what the agent did, so the report-back waiting on that
        // agent is marked as kept here and discharged — not fired — when the finished
        // notification arrives a moment later. Verbatim only: a summarized boundary leaves
        // the fuller report still owed, and the follow-up fires for it as before.
        stopQuestions.onStatementNarrated = { [weak followupBook] agent, utterance in
            guard utterance.mode == .verbatim else { return }
            followupBook?.noteOutcomeHeard(agent: agent.displayName)
        }

        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath,
                                            diagnosticSink: diagnostics)
        let server = BrokerServer(
            transport: transport,
            token: token,
            diagnosticSink: diagnostics,
            onApproval: { request in
                // Session focus first (§2): a detached session's approval goes to its own
                // screen at once, and a headless one TapQ started is denied so it winds
                // down. Nothing is spoken and no window opens.
                if sessionIsDetached(request.sessionID, request.agent) {
                    let owned = ownedLauncher?.owns(sessionID: request.sessionID) ?? false
                    diagnostics.record(.init(
                        category: "SessionFocus",
                        name: DetachedSessionPolicy.diagnosticName,
                        fields: ["hook": "approval", "owned": "\(owned)"]
                    ))
                    return DetachedSessionPolicy.approval(ownedByTapQ: owned)
                }
                // The one hook that carries the session's folder, kept in the book (never
                // in speech) so a session started by voice can work where this one does.
                if let cwd = request.cwd {
                    sessionBook?.noteWorkingDirectory(
                        sessionID: request.sessionID, agent: request.agent, path: cwd
                    )
                }
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                return await resolveApproval(request, deadline) {
                    ReasonerContext(approvalRequest: request)
                }
            },
            onNotification: { notification in
                let detached = sessionIsDetached(notification.sessionID, notification.agent)
                // Recorded first and unconditionally (RD5). The old shape recorded only
                // what was spoken, which made `--no-announcements` quietly erase the event
                // from memory too — so a wearer who had asked for silence could then ask
                // "what changed?" and be told nothing had. Suppressing a sound and
                // forgetting an event are different acts; only the first is a flag.
                let turnEnding = memory.record(notification: notification)
                // A detached session's notification is logged and never spoken (§2), and
                // no follow-up fires for it — its follow-ups were cancelled at the switch.
                if detached {
                    diagnostics.record(.init(
                        category: "SessionFocus",
                        name: DetachedSessionPolicy.diagnosticName,
                        fields: ["hook": "notification", "kind": "\(notification.kind)"]
                    ))
                    return
                }
                // How this notification is played, whenever it is played. Named because it
                // has two callers now: the verdict below, and — when a command window is
                // open — the policy's own deferral, which hands the same verdict back once
                // the window has closed rather than speaking across it.
                let play: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                    switch verdict {
                    case .speak:
                        interaction.announce(notification)
                    case .chime(let cue):
                        // Played directly rather than through `announce`, whose utterance
                        // the quiet decorator would convert into a second cue for the same
                        // event.
                        playCue(cue)
                    case .suppress, .deferred:
                        break
                    }
                }
                play(notificationPolicy.route(
                    .agentNotification(
                        kind: notification.kind,
                        sessionID: notification.sessionID
                    ),
                    whenDeferred: play
                ))
                // M3: the boundary that fires a one-shot follow-up. The gate runs first —
                // cheap, silent, and logged — and the review model is consulted only for a
                // boundary that passes it. Ordered after the notification's own routing so
                // the wearer hears "finished" before "on your follow-up", through the same
                // deferral when a window is open.
                guard notification.kind == .finished,
                      let followupBook, let wearerTaskLoop,
                      followupBook.pending(for: notification.agent.displayName) != nil
                else { return }
                let agentName = notification.agent.displayName
                if turnEnding == .leftWorkRunning {
                    // The turn ended, the work did not: this turn launched a background
                    // command that is still running, so "finished" is not the boundary the
                    // wearer meant. Not consumed — the promise fires at the next one, after
                    // the agent has been woken with the result. Audible, because the wearer
                    // just heard "finished" and is waiting for what comes next.
                    diagnostics.record(.init(
                        category: "WearerFollowup",
                        name: "fire.held_work_running",
                        fields: ["agent": agentName]
                    ))
                    followupBook.recordHeld(agent: agentName)
                    let held = WearerFollowupScheduler.heldNotice(agent: agentName)
                    let sayHeld: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                        guard case .speak = verdict else { return }
                        routedSpeech.speak(held, priority: .notification, onFinish: nil)
                    }
                    sayHeld(notificationPolicy.routeLoopSpeech(held, whenDeferred: sayHeld))
                    return
                }
                if followupBook.dischargeHeard(agent: agentName) != nil {
                    // The report-back's promise was kept by this boundary's own narration
                    // (fifth hardware run, 2026-09-02): the model read the agent's final
                    // message out verbatim a moment ago, and firing now would read the
                    // same result again. Silent, and the record says why.
                    diagnostics.record(.init(
                        category: "WearerFollowup",
                        name: "fire.discharged_heard",
                        fields: ["agent": agentName]
                    ))
                    return
                }
                guard !wearerTaskLoop.isBusy else {
                    // Not consumed: the promise stays armed and fires at the next finished
                    // boundary instead. Distinct from `runFollowup`'s own busy race, which
                    // fires after consumption and is re-armed below.
                    diagnostics.record(.init(
                        category: "WearerFollowup",
                        name: "fire.deferred_busy",
                        fields: ["agent": agentName]
                    ))
                    return
                }
                guard let delivery = followupBook.consume(agent: agentName) else { return }
                let followup = delivery.followup
                let boundary = WearerFollowupBoundary(
                    agentDisplayName: agentName,
                    event: "finished",
                    summary: notification.summary ?? ""
                )
                // A report-back's sentence is TapQ's own, and "finished" was said a beat
                // ago; it announces itself in fewer words. The grace after either is the
                // same.
                let announce = followup.purpose == .reportBack
                    ? WearerFollowupScheduler.reportingBackNotice(agent: agentName)
                    : "\(agentName) finished — on your follow-up: "
                        + WearerTaskLoop.spokenGoal(followup.instruction)
                // The grace: the review runs a beat after the announcement has *sounded*,
                // so "cancel the follow-up" spoken into that gap retracts it before
                // anything acts — `claim()` is the atomic check. The abort box covers the
                // one path with no onFinish: an announcement that expired undelivered.
                let runReview: @MainActor () -> Void = {
                    followupGraceAbort.settle()
                    guard let claimed = delivery.claim() else { return }
                    Task { @MainActor in
                        let disposition = await wearerTaskLoop.runFollowup(
                            claimed, boundary: boundary, surfaces: followupSurfaces
                        )
                        followupBook.recordFiring(claimed, disposition: disposition)
                        switch disposition {
                        case .busy:
                            // Consumed but never ran — a task took the slot between the
                            // gate and the review. Re-armed silently; the book records
                            // both the miss and the new arming.
                            _ = followupBook.set(
                                agent: claimed.agentDisplayName,
                                instruction: claimed.instruction,
                                origin: claimed.origin
                            )
                        case let .broke(reason):
                            // A cloud failure inside the review is the narration model
                            // failing, and it gets narration's answer — the same latch the
                            // task lane's `onLoopBroken` pulls.
                            voiceBrokenState?.noteBackendFailed(
                                reason: "followup review: \(reason)"
                            )
                        case .ran:
                            break
                        }
                    }
                }
                followupGraceAbort.arm(announcement: announce) { [weak followupBook] in
                    // Loud, because the old shape's worst property was doing this in
                    // silence: the promise is gone and the wearer heard neither it fire nor
                    // it stop.
                    diagnostics.record(.init(
                        category: "WearerFollowup",
                        name: "fire.aborted_unheard",
                        fields: ["agent": agentName]
                    ))
                    _ = followupBook?.cancel(agent: agentName)
                }
                let sayThenGrace: @MainActor (NotificationPolicy.Verdict) -> Void = { verdict in
                    guard case .speak = verdict else { return }
                    routedSpeech.speak(announce, priority: .notification, onFinish: {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            runReview()
                        }
                    })
                }
                sayThenGrace(
                    notificationPolicy.routeLoopSpeech(announce, whenDeferred: sayThenGrace)
                )
            },
            onSelection: { request in
                if sessionIsDetached(request.sessionID, request.agent) {
                    diagnostics.record(.init(
                        category: "SessionFocus",
                        name: DetachedSessionPolicy.diagnosticName,
                        fields: ["hook": "selection"]
                    ))
                    return DetachedSessionPolicy.selection
                }
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                let result = await memory.withWindow(
                    sessionID: request.sessionID,
                    agent: request.agent,
                    summary: request.question
                ) {
                    await interactionGate.run {
                        armPrompt()
                        return await selection.resolve(request, deadline: deadline)
                    }
                }
                memory.record(selection: request, result: result)
                rememberSelection(request, result)
                return result
            },
            onStopQuestion: { question in
                if sessionIsDetached(question.sessionID, question.agent) {
                    diagnostics.record(.init(
                        category: "SessionFocus",
                        name: DetachedSessionPolicy.diagnosticName,
                        fields: ["hook": "stop_question"]
                    ))
                    return DetachedSessionPolicy.stopQuestionReply
                }
                return await stopQuestions.handle(question)
            },
            // The wire arm of the same queue (RC5). It is the device-adapter seam and what
            // `tapq instruct` speaks to; it accepts nothing the dictation path does not,
            // beyond trusting a caller that already holds the runtime's private token.
            //
            // `false` — an honest error on the wire — whenever this run has no queue,
            // which is every run without `--voice-instructions`.
            onInstruction: { submitted in
                guard let instructions else { return false }
                return instructions.enqueue(
                    submitted.text, session: submitted.sessionID
                ).accepted != nil
            },
            // The held turn boundary (RH1). A Stop hook that has nothing to deliver asks to
            // wait here instead of returning, and this is where TapQ decides what it hands
            // back: a sentence, "park again", or "carry on".
            //
            // `.none` — let the Stop proceed — covers the endings: no voice session
            // composed, a pre-lease shim's one-shot budget spent, the wearer ending the
            // session, the voice channel broken, or the runtime going away. `.renew` covers
            // the ordinary case of nothing having happened yet, which is not an ending at
            // all. And the delivery is the same one the stop-question path performs, through
            // the same coordinator, so a held boundary is not a second way for a sentence to
            // reach an agent.
            onInstructionWait: { [weak self] waiting in
                guard let instructionWaits else { return .none }
                // A detached session's boundary is not held (§2): the hook returns at once
                // and the session idles at its own prompt.
                if sessionIsDetached(waiting.sessionID, waiting.agent) {
                    diagnostics.record(.init(
                        category: "SessionFocus",
                        name: DetachedSessionPolicy.diagnosticName,
                        fields: ["hook": "instruction_wait"]
                    ))
                    return .none
                }
                // Something may already be queued: the wearer dictated during the agent's
                // turn and the boundary arrived afterwards — or between two polls of a
                // lease, where there was no waiter to wake. Deliver it without waiting.
                if let ready = stopQuestions.deliverInstruction(
                    sessionID: waiting.sessionID, agent: waiting.agent
                ) {
                    // This poll never parks, so nothing will end its lease later. Ending it
                    // here is what stops TapQ listening at a boundary that has already been
                    // answered and an agent that has already gone back to work.
                    if let lease = waiting.leaseID {
                        instructionWaits.release(lease: lease)
                    }
                    return .instruction(ready)
                }
                // Started before the suspension below, so the loop's first turn sees this
                // boundary registered. A renewal of a boundary already held announces
                // nothing and restarts nothing: the wearer said one thing to start this
                // session and should not hear "Listening." again every minute.
                self?.voiceSessionListening?.begin(
                    sessionID: waiting.sessionID, agent: waiting.agent
                )
                // A lease-bearing poll is one round of a boundary that ends only when the
                // wearer, the voice channel, or the runtime ends it. Without a lease this
                // is a shim from before renewals, which asks once — so it keeps the
                // one-shot budget it was built against.
                switch await instructionWaits.wait(
                    session: waiting.sessionID,
                    timeout: waiting.leaseID == nil
                        ? VoiceSessionBudget.brokerWait
                        : VoiceSessionBudget.brokerPoll,
                    lease: waiting.leaseID
                ) {
                case .instructionQueued:
                    return stopQuestions.deliverInstruction(
                        sessionID: waiting.sessionID, agent: waiting.agent
                    ).map { .instruction($0) } ?? .none
                case .renew:
                    // Nothing happened, and nothing about the session changed. The shim
                    // parks again and the listening loop never noticed.
                    return .renew
                case .timedOut, .released:
                    // A pre-lease shim's budget spent, the wearer done, the voice channel
                    // broken, or the runtime going away. All of them mean the same thing to
                    // the shim, and it is the safe one: carry on.
                    return .none
                }
            },
            // Where a session's transcript is, forwarded by the shim on messages it already
            // sends. `nil` without a store — the Apple path — so the field arrives, decodes,
            // and reaches nothing. Attaching is idempotent and cheap: every hook event
            // carries the path, and the store tails from its own byte offset.
            onTranscriptPath: transcriptStore.map { store in
                { attachment in
                    store.attach(session: attachment.sessionID, path: attachment.path)
                }
            }
        )

        do {
            try server.start()
            try discovery.publish(
                token: token,
                steeringEnabled: configuration.steeringEnabled,
                // Advertised rather than assumed: a shim that cannot see this field — an
                // older runtime, a dead one — never long-polls, so the mode cannot be
                // entered by a hook talking to a runtime that would not answer it.
                voiceSessionEnabled: configuration.voiceSessionEnabled
            )
        } catch {
            server.stop()
            discovery.remove()
            throw error
        }

        // The startup half of the one-time notice. With no AirPods connected nothing else
        // in the session will mention it — that is the point of the `.neverStreamed`
        // branch above — so without this the user hears prompts on the Mac speaker and is
        // left to infer why nodding does nothing.
        //
        // Polled on the detector's own availability cadence (6 × 250 ms is the same bounded
        // retry `waitForMotionAvailability` runs) so headphones that are merely slow to
        // appear never draw a spurious notice. An availability flag that reads `true` ends
        // the poll without a notice even when the AirPods are actually in their case; the
        // `.neverStreamed` branch above is what catches that lie, through the same
        // once-per-run gate.
        //
        // Started here, past every throwing step and immediately before the `defer` that
        // cancels it, so an aborted startup can never leave a notice to speak over the
        // failure. It does not block: `onReady` runs on the next line.
        let startupNotice: Task<Void, Never>? = configuration.announcementsEnabled
            ? Task { @MainActor in
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    guard !gestures.isMotionCurrentlyAvailable else { return }
                }
                voiceOnlyNotice()
            }
            : nil

        // Which endpointer the run is starting with, appended to the backend line rather
        // than given one of its own: it is a property of the pipe, and an operator reading
        // "openai-realtime" needs to know in the same breath whether the far end is deciding
        // where their sentences stop. Later windows may switch it — that is what the
        // `turn_detection.*` diagnostics are for — but a run that *starts* degraded should
        // say so on the line the operator is already reading.
        let voiceBackendStatus: String? = configuration.voiceBackend.statusDescription.map {
            base in
            guard backendProvider != nil else { return base }
            // "All speech in this voice" is a property of the run an operator should not have
            // to infer from hearing it: the alternative it replaced — two alternating voices
            // — was the observable symptom of a composition bug, so a run that has one voice
            // says so on the line naming the pipe that owns it.
            let voiced = base + ", all speech in this voice"
            return turnSignalLiveness.isLive
                ? voiced + ", turns ended by TapQ (IMU endpointing)"
                : voiced + ", turns ended when the model judges you finished "
                    + "(no IMU turn signal)"
        }

        onReady(.init(
            socketPath: discovery.socketPath,
            discoveryPath: discovery.discoveryURL.path,
            gestureProfileLoaded: gestureProfile != nil,
            tapProfileLoaded: tapProfile != nil,
            // The composed detector's own probe, not the static one: identical answer
            // without a second `CMHeadphoneMotionManager` competing for the headphones.
            motionAvailable: gestures.isMotionCurrentlyAvailable,
            voiceAvailable: voiceAuthorized,
            voiceBackendStatus: voiceBackendStatus,
            encoderStatus: encoderStatus,
            reasonerStatus: reasonerStatus,
            wearerSpeechStatus: wearerSpeechStatus,
            // Says which policy is in force, not just that the flag was passed: the
            // threshold is the difference between "answers almost everything routine" and
            // "answers nothing", and an operator who edited the wrong file should find out
            // on the first line of the run rather than from a log that stays empty.
            autoAnswerStatus: activeAutoAnswerPolicy.map { policy in
                "routine (min confidence \(policy.minimumConfidence),"
                    + " \(policy.neverAutoTools.count) never-auto tool"
                    + "\(policy.neverAutoTools.count == 1 ? "" : "s"))"
            } ?? (configuration.autoAnswerMode == .off
                ? nil
                : "off, no primary reasoner is running"),
            attentionStatus: attentionStatus,
            // Printed only for the non-default posture, and it states the cost rather than
            // the setting: an operator reading this line is being told that the room can
            // instruct, which is the whole of what they traded away.
            voiceTrustStatus: configuration.voiceTrust == .environment
                ? "environment (any voice the microphone hears may instruct;"
                    + " approvals are unchanged and an instruction authorizes nothing)"
                : nil,
            voiceSessionStatus: voiceSessionStatus,
            voiceProcessingStatus: configuration.voiceProcessingEnabled
                ? "experimental, enabled (half-duplex unchanged)"
                : nil,
            quietStatus: configuration.quietEnabled
                ? "cues for prompts and notifications; answers still spoken"
                : nil,
            // Says where a voice-started session would work, because the answer is the
            // one thing about this feature an operator cannot hear: a refusal for want of
            // a folder sounds the same as any other.
            sessionStatus: ownedLauncher.map { _ in
                let base = "\"start a new session\" starts Claude Code in the focused "
                    + "session's folder"
                guard let path = configuration.sessionDirectory?.path else {
                    return base + " (no --session-directory default)"
                }
                return base + ", else \(path)"
            }
        ))

        defer {
            finishShutdownWait()
            startupNotice?.cancel()
            // Before anything else is torn down: a hook parked on a boundary this runtime
            // is about to stop answering would otherwise sit there until its own socket
            // timed out, with the terminal showing a hook in flight and nothing to explain
            // it. Releasing first means every waiter is answered "carry on" by a broker
            // that is still listening.
            instructionWaits?.releaseAll()
            // The children TapQ started go with it: every owned session is stopped and
            // its ending recorded while the broker that would hear from it is still up.
            ownedSweep?.cancel()
            ownedLauncher?.shutdown()
            // Before the voice pipe goes: a task still thinking has a `speak` surface
            // pointing at a `BackendSpeechSink` this block is about to tear down, and one
            // more model turn would spend seconds resolving into a sentence nobody can
            // hear. It ends silently and on purpose — the record still gets `canceled`, so
            // a wearer who asks tomorrow finds out what happened to what they asked for.
            wearerTaskLoop?.cancel(reason: "runtime shutdown")
            // A one-shot promise does not survive the process, and the record says so —
            // the `expired` entry is the only trace a restart leaves of it.
            followupBook?.expireAll(reason: "runtime shutdown")
            voiceSessionListening = nil
            turnCoordinator?.stop()
            // Prevent ARC from releasing the wearer-speech source at the
            // waitForShutdown suspension. HeadGestureDetector and every ChildSignal hold
            // it weakly; without this reference, optimized builds can deallocate it
            // mid-serve, silently disabling --wearer-gate and --imu-turn-control.
            _ = wearerSpeechSource
            approvalArbiter.cancel()
            selectionArbiter.cancel()
            // Dropped before `gestures.stop()`, so the stop actually tears the motion
            // subscription down instead of finding a hold outstanding and leaving it up.
            attentionArming = nil
            // Before the voice pipe and the audio session go: a spotter left running would
            // hold a microphone under a runtime that is tearing its own down, and the gate
            // must not put one back up on a late transition.
            wakeGate?.shutdown()
            wakeGate = nil
            wakeArming = nil
            wakeSpotter = nil
            detectionHold?.release()
            cues?.stop()
            gestures.stop()
            // In conversation mode, shutdown() tears down the backend session cleanly.
            // In per-window mode (or for VoiceListener), stop() is the correct teardown.
            if let backendProvider {
                backendProvider.shutdown()
            } else {
                rawVoice.stop()
            }
            speech.stopAll()
            server.stop()
            discovery.remove()
        }
        await waitForShutdown()
    }

    private func loadGestureIfPresent(
        _ store: CalibrationStore
    ) throws -> TapQGestureCalibrationProfile? {
        guard store.exists(.gesture) else { return nil }
        return try store.loadGesture()
    }

    private func loadTapIfPresent(
        _ store: CalibrationStore
    ) throws -> TapQTapCalibrationProfile? {
        guard store.exists(.tap) else { return nil }
        return try store.loadTap()
    }

    /// One resolved approval, in the word the wearer would use for it.
    ///
    /// `.ask` is "deferred" and not "asked": from the wearer's side nothing was decided
    /// hands-free and the agent's own prompt took over, which is what
    /// ``SessionContextEvent/Outcome/deferred`` already means. A timed-out window lands
    /// here too.
    private static func spokenOutcome(of decision: Decision) -> String {
        switch decision {
        case .allow: return "approved"
        case .deny: return "denied"
        case .ask: return "deferred"
        }
    }

    private func waitForShutdown() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shutdownContinuation = continuation
                installSignalHandlers()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishShutdownWait() }
        }
    }

    private func installSignalHandlers() {
        guard signalSources.isEmpty else { return }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.finishShutdownWait() }
            source.resume()
            signalSources.append(source)
        }
    }

    private func finishShutdownWait() {
        signalSources.forEach { $0.cancel() }
        signalSources.removeAll()
        let continuation = shutdownContinuation
        shutdownContinuation = nil
        continuation?.resume()
    }
}
#endif
