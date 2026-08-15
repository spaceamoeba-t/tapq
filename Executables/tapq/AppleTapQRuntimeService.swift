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

        // -- Voice composition --
        // `apple` is the shipped path and stays literally the shipped path: the same
        // `VoiceListener` instance, wrapped by the same `SpeechGatedVoice`, with nothing
        // between them. Any other provider swaps only what sits inside that gate — the
        // arbiter, the controllers, and the mic-lifecycle rules above are untouched.
        let rawVoice: any VoiceCommandProviding
        var backendProvider: VoiceBackendCommandProvider?
        var playback: BackendAudioPlayback?
        switch configuration.voiceBackend {
        case .apple:
            rawVoice = VoiceListener(diagnosticSink: diagnostics)
        case .openaiRealtime:
            // Throwing aborts serve, like a misconfigured question classifier: the operator
            // asked for a specific pipe and must not be given a different one in silence.
            let selection = try VoiceBackendFactory.select(
                provider: configuration.voiceBackend,
                openAIAPIKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"],
                // The microphone pump wraps the realtime primary so the pipe actually
                // hears the wearer. The decorator keeps AVFoundation out of the portable
                // factory: only this executable — already macOS-only — constructs one.
                decorateRealtimePrimary: { primary in
                    MicrophonePumpVoiceBackend(
                        inner: primary,
                        diagnosticSink: diagnostics
                    )
                },
                // Conversation mode uses sticky fail-through: once the primary fails, the
                // fallback handles every subsequent open until resetStickiness() on the
                // next conversation (idle-close reopen). Decision 3.
                failThroughStickiness: .stickyAfterFailure,
                diagnosticSink: diagnostics,
                // Shares the one `SpeechEngine`, so the fallback speaks through the same
                // activity signal `SpeechGatedVoice` gates the microphone on.
                makeAppleBackend: { AppleVoiceBackend(speech: speech, diagnosticSink: diagnostics) }
            )
            let player = BackendAudioPlayback(diagnosticSink: diagnostics)
            playback = player
            let provider = VoiceBackendCommandProvider(
                backend: selection.backend,
                match: { VoiceCommandMatcher.match($0) },
                sessionPolicy: .conversation(idleClose: 60),
                supportsBargeIn: true,
                responseAudio: player,
                freeformEnabled: configuration.voiceFreeformEnabled,
                diagnosticSink: diagnostics
            )
            // Wire the conversation-reopened seam so sticky fail-through resets on a new
            // conversation. The backend is a FailThroughVoiceBackend (created by the
            // factory above); we call resetStickiness() on idle-close reopen.
            if let failThrough = selection.backend as? FailThroughVoiceBackend {
                provider.onConversationReopened = { [weak failThrough] in
                    failThrough?.resetStickiness()
                }
            }
            backendProvider = provider
            rawVoice = provider
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
        // Notifications may go out in the backend's own voice; approvals never may. The
        // decorator enforces that split by priority, and it is composed on the presence of
        // a duplex backend, not on the summarizer flag: whose voice speaks and what the
        // words are are independent questions. On the Apple path there is no backend to
        // route to and the controllers get the engine itself, exactly as before.
        let promptSpeech: any SpeechPresenting = backendProvider.map { provider in
            BackendPreferredSpeech(
                wrapping: speech,
                route: { [weak provider] text in
                    provider?.speakViaBackend(text) ?? false
                },
                diagnosticSink: diagnostics
            )
        } ?? speech
        // The one instruction queue this run has (RC2). Three call sites share it — the
        // dictation flow that fills it, the broker arm that fills it from the SDK seam,
        // and the stop-question coordinator that drains it at a turn boundary — so it is
        // a reference type built once, here, and handed to all three. `nil` without
        // `--voice-instructions`: nothing to fill, nothing to drain, and every path below
        // takes the shape it had in Rung B.
        let instructions: InstructionMailbox? = configuration.voiceInstructionsEnabled
            ? InstructionMailbox(diagnosticSink: diagnostics)
            : nil
        // What this run remembers about the sessions it serves, and the only thing recall
        // and grounded answers ever read. Built before the controllers because they take
        // its closures; every window below hands it what it may say and nothing else.
        //
        // The mailbox goes in here rather than beside it because everything an instruction
        // needs to know — which session is being spoken into, which agent is behind it —
        // is what this object already tracks for recall.
        let memory = ConversationMemory(instructions: instructions)
        // Fail-closed by composition, not by convention: with no gate there is no object
        // to ask, and the answer is no. The gate outlives every window (the voice chain
        // holds it), so the weak capture is bookkeeping rather than a lifetime it depends
        // on.
        let isWearerAttributed: WearerAttributionQuerying = { [weak wearerAttribution] in
            wearerAttribution?.isWearerAttributedNow ?? false
        }
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
            instructionEnqueue: memory.instructionEnqueue
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
            instructionEnqueue: memory.instructionEnqueue
        )
        let interactionGate = InteractionGate()

        // A disconnect is only worth interrupting the user about when there was something
        // to disconnect. `.neverStreamed` means no AirPods were connected when this window
        // opened, which every window in a no-AirPods session reports once its bounded
        // availability retry expires: announcing it would say "disconnected" about hardware
        // the user never put in, and cancelling would take the live voice window down with
        // it. So the window stays open and resolves by voice or by its ordinary timeout.
        //
        // The remaining reasons are a real mid-window outage. That announcement deliberately
        // ignores `--no-announcements`: an inaudible state change mid-interaction strands
        // the user. It stops at the state change, because the cancel below already ends in
        // `deferToScreen()`, which speaks "Deferring to the screen." itself.
        gestures.onMotionLost = { reason in
            guard reason != .neverStreamed else { return }
            speech.speak(
                "AirPods motion disconnected.",
                priority: .notification,
                onFinish: nil
            )
            approvalArbiter.cancel()
            selectionArbiter.cancel()
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
                    await interaction.resolve(request, deadline: deadline)
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
                    await interaction.resolve(request, deadline: deadline)
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
            let outcome = await interactionGate.run {
                await interaction.resolve(
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
            return decision
        }

        let stopQuestions = StopQuestionCoordinator(
            classifier: classifierSelection.classifier,
            // nil under `--speech-summarizer off`: the coordinator then builds the same
            // requests it always did, with no preamble and an empty detail.
            summarizer: summarizerSelection.summarizer,
            diagnosticSink: diagnostics,
            // The drain side of the one queue. Delivery happens at the head of the
            // coordinator's handling, ahead of the repeat and classifier guards, because
            // an instruction is not an answer to anything the agent asked.
            instructions: instructions,
            recordInstruction: memory.instructionRecorder,
            // Said in TapQ's own voice at notification priority: it is a status line about
            // TapQ holding something back, not part of the prompt the wearer is answering.
            announce: { [weak speech] notice in
                speech?.speak(notice, priority: .notification, onFinish: nil)
            },
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
                        await selection.resolve(request, deadline: deadline)
                    }
                }
                // Recorded as a stop answer when the wearer spoke one, and as the
                // selection it is when they picked a label.
                memory.recordStopSelection(request, result: result)
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
        let transport = UnixSocketTransport(path: discovery.socketPath)
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
                guard configuration.announcementsEnabled else { return }
                interaction.announce(notification)
                // Recorded only where it is actually spoken. Under `--no-announcements`
                // TapQ says nothing, and recalling "the agent reported X" for something
                // the wearer never heard would be inventing a conversation.
                memory.record(notification: notification)
            },
            onSelection: { request in
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                let result = await memory.withWindow(
                    sessionID: request.sessionID,
                    agent: request.agent,
                    summary: request.question
                ) {
                    await interactionGate.run {
                        await selection.resolve(request, deadline: deadline)
                    }
                }
                memory.record(selection: request, result: result)
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
                ) != nil
            }
        )

        do {
            try server.start()
            try discovery.publish(
                token: token,
                steeringEnabled: configuration.steeringEnabled
            )
        } catch {
            server.stop()
            discovery.remove()
            throw error
        }

        // Said once, or never. With no AirPods connected nothing else in the session will
        // mention it — that is the point of the `.neverStreamed` branch above — so without
        // this the user hears prompts on the Mac speaker and is left to infer why nodding
        // does nothing.
        //
        // Polled on the detector's own availability cadence (6 × 250 ms is the same bounded
        // retry `waitForMotionAvailability` runs) so headphones that are merely slow to
        // appear never draw a spurious notice. Unlike the mid-window disconnect
        // announcement, which has to be audible or the user is stranded mid-interaction,
        // this is a status line and respects `--no-announcements`.
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
                speech.speak(
                    voiceAuthorized
                        ? "No AirPods detected. Running voice only."
                        : "No AirPods detected. Prompts will use the screen.",
                    priority: .notification,
                    onFinish: nil
                )
            }
            : nil

        onReady(.init(
            socketPath: discovery.socketPath,
            discoveryPath: discovery.discoveryURL.path,
            gestureProfileLoaded: gestureProfile != nil,
            tapProfileLoaded: tapProfile != nil,
            // The composed detector's own probe, not the static one: identical answer
            // without a second `CMHeadphoneMotionManager` competing for the headphones.
            motionAvailable: gestures.isMotionCurrentlyAvailable,
            voiceAvailable: voiceAuthorized,
            voiceBackendStatus: configuration.voiceBackend.statusDescription,
            encoderStatus: encoderStatus,
            reasonerStatus: reasonerStatus,
            wearerSpeechStatus: wearerSpeechStatus
        ))

        defer {
            finishShutdownWait()
            startupNotice?.cancel()
            turnCoordinator?.stop()
            // Prevent ARC from releasing the wearer-speech source at the
            // waitForShutdown suspension. HeadGestureDetector and every ChildSignal hold
            // it weakly; without this reference, optimized builds can deallocate it
            // mid-serve, silently disabling --wearer-gate and --imu-turn-control.
            _ = wearerSpeechSource
            approvalArbiter.cancel()
            selectionArbiter.cancel()
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
