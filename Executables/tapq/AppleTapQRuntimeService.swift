#if canImport(TapQAppleAdapters)
import Foundation
import TapQAppleAdapters
import TapQBrokerRuntime
import TapQCLI
import TapQContextBaseline
import TapQContracts
import TapQDetectionBaseline
import TapQInteractionBaseline
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
            tapProfileURL: configuration.tapProfileURL
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
        let rawVoice = VoiceListener(diagnosticSink: diagnostics)
        let voiceAuthorized = configuration.voiceEnabled
            ? await VoiceListener.requestAuthorization()
            : false
        let gatedVoice = SpeechGatedVoice(
            wrapping: rawVoice,
            activity: speech,
            diagnosticSink: diagnostics
        )
        let voice: (any VoiceCommandProviding)? = voiceAuthorized ? gatedVoice : nil

        let approvalArbiter = InputArbiter(
            gestures: gestures,
            voice: voice,
            taps: gestures,
            diagnosticSink: diagnostics
        )
        let interaction = InteractionController(
            speech: speech,
            arbiter: approvalArbiter,
            timeout: configuration.interactionTimeout,
            diagnosticSink: diagnostics
        )

        let volumeSwipe = VolumeSwipeDetector(diagnosticSink: diagnostics)
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
            speech: speech,
            arbiter: selectionArbiter,
            timeout: configuration.interactionTimeout,
            diagnosticSink: diagnostics
        )
        let interactionGate = InteractionGate()
        let stopQuestions = StopQuestionCoordinator(
            classifier: classifierSelection.classifier,
            diagnosticSink: diagnostics,
            runSelection: { request, deadline in
                await interactionGate.run {
                    await selection.resolve(request, deadline: deadline)
                }
            },
            runApproval: { request, deadline in
                await interactionGate.run {
                    await interaction.resolve(request, deadline: deadline)
                }
            }
        )

        gestures.onMotionLost = {
            speech.speak(
                "AirPods motion disconnected. Deferring to the screen.",
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

        // Captured by the approval closure below. Locals rather than `self`, so the
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

        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath)
        let server = BrokerServer(
            transport: transport,
            token: token,
            diagnosticSink: diagnostics,
            onApproval: { request in
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                // `.off`, and every run where no reasoner could be built, is today's path
                // byte for byte: no context assembled, no assessment started, no file
                // written, no extra await between the request and the prompt.
                guard activeReasonerMode != .off, let reasoner = activeReasoner else {
                    return await interactionGate.run {
                        await interaction.resolve(request, deadline: deadline)
                    }
                }

                // The enqueue moment. Starting the assessment here rather than inside the
                // gate is what lets it overlap the queue wait: the model runs while the
                // gate may still be draining an earlier approval, so in the common case
                // `primary` ends up waiting on nothing. Detached because a stage-2
                // assessment must never occupy the UI actor the interaction runs on.
                let assessment = Task.detached {
                    await ReasonerEscalation.assess(
                        ReasonerContext(approvalRequest: request),
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
                    assessment: observed,
                    requiredConfirmation: requirement,
                    escalationApplied: requirement != .standard,
                    outcome: outcome
                )
                return outcome
            },
            onNotification: { notification in
                guard configuration.announcementsEnabled else { return }
                interaction.announce(notification)
            },
            onSelection: { request in
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                return await interactionGate.run {
                    await selection.resolve(request, deadline: deadline)
                }
            },
            onStopQuestion: { question in
                await stopQuestions.handle(question)
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

        onReady(.init(
            socketPath: discovery.socketPath,
            discoveryPath: discovery.discoveryURL.path,
            gestureProfileLoaded: gestureProfile != nil,
            tapProfileLoaded: tapProfile != nil,
            motionAvailable: HeadGestureDetector.isAvailable,
            voiceAvailable: voiceAuthorized,
            encoderStatus: encoderStatus,
            reasonerStatus: reasonerStatus
        ))

        defer {
            finishShutdownWait()
            approvalArbiter.cancel()
            selectionArbiter.cancel()
            gestures.stop()
            rawVoice.stop()
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
