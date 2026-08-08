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

/// Production microphone source. It contains every AVFAudio call that depends on live
/// route state and converts both NSError and legacy NSException failures into a failed
/// voice window.
@MainActor final class AVAudioEngineVoiceAudioSource: VoiceAudioSource {
    private let capture: TapQAudioCaptureEngine
    private var configurationObserver: NSObjectProtocol?
    private var subscriptionGeneration: UInt64 = 0
    private var started = false
    /// Teardown failures have nowhere to go in a voice window — the window is over either
    /// way — but a study recording wants them in its diagnostics, so an owner may opt in.
    var onTeardownFailure: (@MainActor (VoiceAudioSourceFailure) -> Void)?

    init(capture: TapQAudioCaptureEngine = TapQAudioCaptureEngine()) {
        self.capture = capture
    }

    func start(
        onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) throws {
        guard !started else { return }

        subscriptionGeneration &+= 1
        let generation = subscriptionGeneration
        observeConfigurationChanges(generation: generation, onInvalidation: onInvalidation)

        var captureError: NSError?
        guard TapQAudioCaptureEngineStart(
            capture,
            1024,
            { buffer, time in onBuffer(buffer, time) },
            &captureError
        ) else {
            throw Self.failure(from: captureError)
        }
        started = true
    }

    func stop() {
        subscriptionGeneration &+= 1
        started = false

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
