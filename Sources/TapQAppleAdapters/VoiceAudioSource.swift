import Foundation
import TapQAudioCaptureBridge
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
struct VoiceAudioSourceFailure: Error, Equatable, CustomStringConvertible {
    enum Stage: String {
        case inputFormat = "input_format"
        case audioSetup = "audio_setup"
        case engineStart = "engine_start"
        case audioTeardown = "audio_teardown"
        case configurationChanged = "configuration_changed"
        case voiceProcessing = "voice_processing"
    }

    let stage: Stage
    let detail: String

    var description: String {
        "\(stage.rawValue): \(detail)"
    }
}

/// Hardware boundary for one microphone window. A source is single-use in production:
/// its fresh AVAudioEngine cannot retain formats from an earlier audio route.
///
/// `onBuffer` runs on the realtime audio thread and carries the tap's own `AVAudioTime`.
/// Speech recognition ignores it; the capture study's envelope arm needs it to place each
/// block on the motion stream's clock.
@MainActor protocol VoiceAudioSource: AnyObject {
    func start(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) throws
    func stop()
}

enum VoiceAudioSourceStartResult {
    case started
    case alreadyRunning
    case failed(any Error)
}

/// Owns the current per-window source and rejects callbacks from discarded sources.
/// Keeping this lifecycle outside VoiceListener makes route/failure behavior testable
/// without asking XCTest to touch audio hardware.
@MainActor final class VoiceAudioSourceController {
    private let makeSource: @MainActor () -> any VoiceAudioSource
    private var source: (any VoiceAudioSource)?
    private var sourceGeneration: UInt64 = 0

    init(makeSource: @escaping @MainActor () -> any VoiceAudioSource) {
        self.makeSource = makeSource
    }

    var isRunning: Bool {
        source != nil
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) -> VoiceAudioSourceStartResult {
        guard source == nil else { return .alreadyRunning }

        sourceGeneration &+= 1
        let generation = sourceGeneration
        let newSource = makeSource()
        source = newSource
        var invalidationDuringStart: VoiceAudioSourceFailure?

        do {
            try newSource.start(
                onBuffer: onBuffer,
                onInvalidation: { [weak self] failure in
                    invalidationDuringStart = failure
                    self?.invalidate(
                        generation: generation,
                        failure: failure,
                        handler: onInvalidation
                    )
                }
            )
        } catch {
            guard sourceGeneration == generation else {
                return .failed(invalidationDuringStart ?? error)
            }
            stop()
            return .failed(error)
        }

        if let invalidationDuringStart {
            return .failed(invalidationDuringStart)
        }
        return .started
    }

    func stop() {
        sourceGeneration &+= 1
        let oldSource = source
        source = nil
        oldSource?.stop()
    }

    private func invalidate(
        generation: UInt64,
        failure: VoiceAudioSourceFailure,
        handler: @MainActor (VoiceAudioSourceFailure) -> Void
    ) {
        guard sourceGeneration == generation, source != nil else { return }
        stop()
        handler(failure)
    }
}

/// Decides whether an `AVAudioEngineConfigurationChange` is the one AVFAudio publishes when
/// Apple's voice-processing unit is switched on, or a genuine route change.
///
/// Turning voice processing on rebuilds the input node, and rebuilding the input node
/// republishes the engine's configuration — so a voice-processing start always produces one
/// notification that means "the thing you asked for happened", not "the microphone moved".
/// Exactly one change is forgiven, and only inside a short grace period after the start that
/// armed it: a route change that arrives a minute later is still fatal, and so is the second
/// change of a session. Anything the gate does not forgive keeps the pre-existing handling.
struct VoiceProcessingTransitionGate {
    /// How long the transition is allowed to take before a configuration change reads as a
    /// real route change again.
    let grace: TimeInterval
    private var armedAt: TimeInterval?

    init(grace: TimeInterval = 1.0) {
        self.grace = grace
    }

    var isArmed: Bool { armedAt != nil }

    mutating func arm(at now: TimeInterval) {
        armedAt = now
    }

    mutating func disarm() {
        armedAt = nil
    }

    /// Consumes the single forgiven change. Returns true only for a change that arrives
    /// while armed and within the grace period; either way the gate is disarmed afterwards,
    /// so a second change in the same session is never forgiven.
    mutating func tolerates(at now: TimeInterval) -> Bool {
        guard let armed = armedAt else { return false }
        armedAt = nil
        return now - armed <= grace
    }
}

/// Production microphone source. It contains every AVFAudio call that depends on live
/// route state and converts both NSError and legacy NSException failures into a failed
/// voice window.
@MainActor final class AVAudioEngineVoiceAudioSource: VoiceAudioSource {
    private let capture: TapQAudioCaptureEngine
    private var configurationObserver: NSObjectProtocol?
    private var subscriptionGeneration: UInt64 = 0
    private var started = false
    /// Experimental (RD4). When true the capture bridge enables voice processing on the
    /// input node before installing the tap, and the transition gate below forgives the one
    /// configuration change that transition causes. False keeps the audio path unchanged.
    private let voiceProcessingEnabled: Bool
    private var transitionGate: VoiceProcessingTransitionGate
    private let now: () -> TimeInterval
    /// Teardown failures have nowhere to go in a voice window — the window is over either
    /// way — but a study recording wants them in its diagnostics, so an owner may opt in.
    var onTeardownFailure: (@MainActor (VoiceAudioSourceFailure) -> Void)?
    /// Fires instead of the invalidation when the gate recognises the voice-processing
    /// transition. Owners use it for diagnostics; the window keeps running either way.
    var onVoiceProcessingTransition: (@MainActor () -> Void)?

    init(capture: TapQAudioCaptureEngine = TapQAudioCaptureEngine(),
         voiceProcessingEnabled: Bool = false,
         voiceProcessingTransitionGrace: TimeInterval = 1.0,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.transitionGate = VoiceProcessingTransitionGate(
            grace: voiceProcessingTransitionGrace)
        self.now = now
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) throws {
        guard !started else { return }

        beginObservation(onInvalidation: onInvalidation)

        var captureError: NSError?
        guard TapQAudioCaptureEngineStart(
            capture,
            1024,
            { buffer, time in onBuffer(buffer, time) },
            &captureError
        ) else {
            transitionGate.disarm()
            throw Self.failure(from: captureError)
        }
        started = true
    }

    /// Everything a start does except the one call that needs live audio hardware: bump the
    /// generation, tell the bridge whether to enable voice processing, arm the transition
    /// gate, and observe the engine.
    private func beginObservation(
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) {
        subscriptionGeneration &+= 1
        capture.voiceProcessingEnabled = voiceProcessingEnabled
        if voiceProcessingEnabled {
            transitionGate.arm(at: now())
        } else {
            transitionGate.disarm()
        }
        observeConfigurationChanges(
            generation: subscriptionGeneration, onInvalidation: onInvalidation)
    }

    /// Test seam: brings the source to the state a successful `start` leaves it in without
    /// asking an xctest host to open the microphone. Everything past the hardware call is
    /// ordinary Swift state, and that is the part the transition gate lives in.
    func beginObservingForTesting(
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) {
        beginObservation(onInvalidation: onInvalidation)
        started = true
    }

    func stop() {
        subscriptionGeneration &+= 1
        started = false
        transitionGate.disarm()

        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        var teardownError: NSError?
        if !TapQAudioCaptureEngineStop(capture, &teardownError) {
            onTeardownFailure?(Self.failure(from: teardownError))
        }
    }

    private func observeConfigurationChanges(
        generation: UInt64,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: capture.engine,
            queue: .main
        ) { [weak self] _ in
            // Apple warns against releasing the engine from inside its configuration
            // notification. Yield first, then let the controller tear this source down.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.subscriptionGeneration == generation,
                      self.started else { return }
                if self.transitionGate.tolerates(at: self.now()) {
                    self.onVoiceProcessingTransition?()
                    return
                }
                onInvalidation(VoiceAudioSourceFailure(
                    stage: .configurationChanged,
                    detail: "audio input route changed"
                ))
            }
        }
    }

    private static func failure(from error: NSError?) -> VoiceAudioSourceFailure {
        let stageName = error?.userInfo[TapQAudioCaptureFailureStageKey] as? String
        let stage = VoiceAudioSourceFailure.Stage(rawValue: stageName ?? "")
            ?? .audioSetup
        return VoiceAudioSourceFailure(
            stage: stage,
            detail: error?.localizedDescription ?? "audio capture failed"
        )
    }
}
#endif
