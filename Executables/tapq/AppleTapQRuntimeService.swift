#if canImport(TapQAppleAdapters)
import Foundation
import TapQAppleAdapters
import TapQBrokerRuntime
import TapQCLI
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
/// every window is the same bounded eight seconds the rest of TapQ uses, with the same
/// gate, the same grammar, and the same half-duplex behavior.
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

    init(waits: InstructionWaitRegistry,
         diagnosticSink: any TapQDiagnosticSink,
         makeController: @escaping @MainActor (String, AgentIdentity, String?) -> CommandWindowController) {
        self.waits = waits
        self.makeController = makeController
        self.diagnostics = TapQDiagnosticEmitter(category: "VoiceSession", sink: diagnosticSink)
    }

    /// Whether a listening loop is running. For diagnostics and tests.
    var isListening: Bool { isRunning }

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
            if listeningSession != sessionID {
                diagnostics.record("listening.already_running", fields: [
                    "session": sessionID, "listening": listeningSession ?? "",
                ])
            }
            return
        }
        isRunning = true
        listeningSession = sessionID
        diagnostics.record("listening.began", fields: ["agent": agent.id])
        Task { @MainActor [weak self] in
            await self?.loop(sessionID: sessionID, agent: agent)
        }
    }

    private func loop(sessionID: String, agent: AgentIdentity) async {
        defer {
            isRunning = false
            listeningSession = nil
            diagnostics.record("listening.ended")
        }
        var windows = 0
        while waits.isWaiting {
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
                    let pumped = MicrophonePumpVoiceBackend(
                        inner: primary,
                        voiceProcessingEnabled: configuration.voiceProcessingEnabled,
                        diagnosticSink: diagnostics
                    )
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
            gestureConfirmation: gestureConfirmation
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
            gestureConfirmation: gestureConfirmation
        )
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
        let notificationPolicy = NotificationPolicy(
            settings: .init(
                quiet: configuration.quietEnabled,
                announcementsEnabled: configuration.announcementsEnabled
            ),
            waits: memory.waitRegistry
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
            case .suppress:
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
                        gestureConfirmation: gestureConfirmation
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
                        gestureConfirmation: gestureConfirmation
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
        let wearerTaskLoop: WearerTaskLoop? = taskReasoner.map { reasoner in
            WearerTaskLoop(
                model: reasoner,
                surfaces: WearerTaskSurfaces(
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
                        return .ok(found.text)
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
                            return .ok(TranscriptExcerpts.rendered(
                                slices: slices, agentDisplayName: agent
                            ))
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
                        guard let resolve = memory.instructionAddressResolver else {
                            return .ok("This run has no instruction queue, so nothing can "
                                + "be sent to an agent. Tell the wearer.")
                        }
                        guard let name = agent, !name.isEmpty else {
                            return .ok("An agent name is required. Call get_status for the "
                                + "names that are addressable right now; never guess one.")
                        }
                        switch resolve(name) {
                        case .none:
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
                            switch addressee.enqueue(sentence) {
                            case .notQueued:
                                return .ok("\(addressee.agentDisplayName) would not take "
                                    + "it, so nothing was queued.")
                            case .queued, .queuedDroppingOldest:
                                return .announcing(
                                    "Queued for \(addressee.agentDisplayName); it is "
                                        + "delivered at that agent's next turn boundary. It "
                                        + "authorizes nothing on its own.",
                                    say: "I've told \(addressee.agentDisplayName): "
                                        + WearerTaskLoop.spokenGoal(sentence)
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
                    askWearer: { [wearerMemory] question in
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
                    },
                    // Pillar A, twice per task: the goal when it starts and the outcome when
                    // it ends. Only speech-cleared text — the goal is the sentence TapQ read
                    // back out loud when it accepted, and the outcome is one word.
                    recordTask: { [wearerMemory] goal, outcome in
                        wearerMemory?.recordTask(goal: goal, outcome: outcome)
                    }
                ),
                diagnosticSink: diagnostics
            )
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
            voiceSessionListening?.onEndedByWearer = { [weak wearerTaskLoop] in
                wearerTaskLoop?.cancel(reason: "voice session ended by wearer")
            }
            // And so is the pipe dying. `releaseHolds` is the one hook the latch fires, and
            // it is already carrying the boundary release, so this chains rather than
            // replaces. A loop that kept thinking past a break would be exactly the
            // degraded half-agent the posture forbids — its HTTP calls would keep working
            // while the channel the answer was for is gone.
            let releaseHoldsBeforeLoop = voiceBrokenState?.releaseHolds
            voiceBrokenState?.releaseHolds = { [weak wearerTaskLoop] in
                releaseHoldsBeforeLoop?()
                wearerTaskLoop?.cancel(reason: "voice channel broken")
            }
            // The M2 hookup: the provider has held the handle since its init, and the
            // loop exists now. The loop's `startTask` is `nonisolated` and hops to the
            // main actor internally, so the provider's `await` is safe from any isolation.
            wearerTaskHandle?.loop = wearerTaskLoop
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

        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath,
                                            diagnosticSink: diagnostics)
        let server = BrokerServer(
            transport: transport,
            token: token,
            diagnosticSink: diagnostics,
            onApproval: { request in
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                return await resolveApproval(request, deadline) {
                    ReasonerContext(approvalRequest: request)
                }
            },
            onNotification: { notification in
                // Recorded first and unconditionally (RD5). The old shape recorded only
                // what was spoken, which made `--no-announcements` quietly erase the event
                // from memory too — so a wearer who had asked for silence could then ask
                // "what changed?" and be told nothing had. Suppressing a sound and
                // forgetting an event are different acts; only the first is a flag.
                memory.record(notification: notification)
                switch notificationPolicy.route(
                    .agentNotification(
                        kind: notification.kind,
                        sessionID: notification.sessionID
                    )
                ) {
                case .speak:
                    interaction.announce(notification)
                case .chime(let cue):
                    // Played directly rather than through `announce`, whose utterance the
                    // quiet decorator would convert into a second cue for the same event.
                    playCue(cue)
                case .suppress:
                    break
                }
            },
            onSelection: { request in
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
                await stopQuestions.handle(question)
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
                : nil
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
            // Before the voice pipe goes: a task still thinking has a `speak` surface
            // pointing at a `BackendSpeechSink` this block is about to tear down, and one
            // more model turn would spend seconds resolving into a sentence nobody can
            // hear. It ends silently and on purpose — the record still gets `canceled`, so
            // a wearer who asks tomorrow finds out what happened to what they asked for.
            wearerTaskLoop?.cancel(reason: "runtime shutdown")
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
