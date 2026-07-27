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

    func serve(
        configuration: TapQRuntimeConfiguration,
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

        let token = BrokerRuntimeDiscovery.generateToken()
        let transport = UnixSocketTransport(path: discovery.socketPath)
        let server = BrokerServer(
            transport: transport,
            token: token,
            diagnosticSink: diagnostics,
            onApproval: { request in
                let deadline = ContinuousClock.now + .seconds(InteractionBudget.total)
                return await interactionGate.run {
                    await interaction.resolve(request, deadline: deadline)
                }
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
            encoderStatus: encoderStatus
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
