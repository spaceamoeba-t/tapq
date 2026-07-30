import Foundation
import TapQContracts
import TapQDetectionBaseline
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Speech)
@MainActor protocol VoiceRecognitionTasking: AnyObject {
    func cancel()
}

extension SFSpeechRecognitionTask: VoiceRecognitionTasking {}

@MainActor protocol VoiceSpeechRecognizing: AnyObject {
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    var localeIdentifier: String? { get }
    func recognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
    ) -> (any VoiceRecognitionTasking)?
}

@MainActor final class AppleVoiceSpeechRecognizer: VoiceSpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?

    init(locale: Locale) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    var isAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    var supportsOnDeviceRecognition: Bool {
        recognizer?.supportsOnDeviceRecognition ?? false
    }

    var localeIdentifier: String? {
        recognizer?.locale.identifier
    }

    func recognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping (SFSpeechRecognitionResult?, (any Error)?) -> Void
    ) -> (any VoiceRecognitionTasking)? {
        recognizer?.recognitionTask(with: request, resultHandler: resultHandler)
    }
}
#endif

/// Opens the microphone for one window and resolves a short voice command via on-device
/// speech recognition. The mic is only live while `start` is active — never always-on.
@MainActor public final class VoiceListener: VoiceCommandProviding {
    /// The locale the hardcoded keyword grammar in `match(_:)` understands. The
    /// recognizer must be pinned to it: a device-locale recognizer on a non-English Mac
    /// produces transcripts the English grammar can never match, silently killing the
    /// voice channel. Localizing the grammar lifts this pin later.
    nonisolated public static let grammarLocale = Locale(identifier: "en-US")

    #if canImport(Speech)
    private let recognizer: any VoiceSpeechRecognizing
    private var task: (any VoiceRecognitionTasking)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    #endif
    #if canImport(AVFoundation)
    private let audioSource: VoiceAudioSourceController
    #endif

    private var onCommand: (@MainActor (VoiceCommand) -> Void)?
    private var running = false
    /// Invalidates delayed recognition/configuration callbacks from a prior route or
    /// listening window before a fresh session can start.
    private var sessionGeneration: UInt64 = 0
    private let diagnostics: TapQDiagnosticEmitter
    public var preferOnDevice = true

    var recognizerLocaleForTesting: String? {
        #if canImport(Speech)
        return recognizer.localeIdentifier
        #else
        return nil
        #endif
    }

    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        #if canImport(Speech)
        self.recognizer = AppleVoiceSpeechRecognizer(locale: Self.grammarLocale)
        #endif
        #if canImport(AVFoundation)
        self.audioSource = VoiceAudioSourceController {
            AVAudioEngineVoiceAudioSource()
        }
        #endif
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
    }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Test seam: fakes exercise listener lifecycle without touching Speech or AVFAudio.
    init(
        recognizer: any VoiceSpeechRecognizing,
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.recognizer = recognizer
        self.audioSource = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
    }
    #endif

    var isRunningForTesting: Bool {
        running
    }

    /// Requests speech + microphone authorization. Call once before first use.
    public static func requestAuthorization() async -> Bool {
        #if canImport(Speech)
        let speechGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        #if canImport(AVFoundation)
        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        return speechGranted && micGranted
        #else
        return speechGranted
        #endif
        #else
        return false
        #endif
    }

    public func start(onCommand: @escaping @MainActor (VoiceCommand) -> Void) {
        #if canImport(Speech) && canImport(AVFoundation)
        guard !running else {
            diagnostics.record(
                "start.skipped",
                fields: ["reason": "already_running", "running": "true"]
            )
            return
        }
        guard recognizer.isAvailable else {
            diagnostics.record(
                "start.skipped",
                level: .warning,
                fields: ["reason": "recognizer_unavailable", "running": "false"]
            )
            return
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        self.onCommand = onCommand

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let audioResult = audioSource.start(
            onBuffer: { buffer in
                request.append(buffer)
            },
            onInvalidation: { [weak self] failure in
                self?.audioSourceInvalidated(failure, generation: generation)
            }
        )
        switch audioResult {
        case .started:
            break
        case .alreadyRunning:
            diagnostics.record(
                "capture.start_failed",
                level: .error,
                fields: ["reason": "audio_source_already_running"]
            )
            teardown(expectedGeneration: generation)
            return
        case .failed(let error):
            diagnostics.record(
                "capture.start_failed",
                level: .warning,
                fields: Self.failureFields(error)
            )
            teardown(expectedGeneration: generation)
            return
        }

        guard sessionGeneration == generation else { return }
        running = true

        let recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(
                    result: result,
                    error: error,
                    generation: generation
                )
            }
        }
        guard let recognitionTask else {
            diagnostics.record(
                "recognition.start_failed",
                level: .warning,
                fields: ["reason": "task_unavailable"]
            )
            teardown(expectedGeneration: generation)
            return
        }
        task = recognitionTask
        diagnostics.record("listening.started", fields: ["locale": Self.grammarLocale.identifier])
        #else
        _ = onCommand
        #endif
    }

    public func stop() {
        teardown()
    }

    #if canImport(Speech) && canImport(AVFoundation)
    private func handleRecognition(
        result: SFSpeechRecognitionResult?,
        error: (any Error)?,
        generation: UInt64
    ) {
        guard running, sessionGeneration == generation else { return }

        if let result,
           VoiceCommandMatcher.match(result.bestTranscription.formattedString) != nil
            || result.isFinal {
            diagnostics.record("transcript.received")
        }
        if let result,
           let command = VoiceCommandMatcher.match(
               result.bestTranscription.formattedString
           ) {
            fire(command, generation: generation)
        } else if error != nil {
            teardown(expectedGeneration: generation)
        } else if let result, result.isFinal {
            // The user said something the grammar doesn't know — log it so a
            // "voice does nothing" report is diagnosable from the log file.
            let transcript = result.bestTranscription.formattedString
            diagnostics.record(
                "transcript.rejected",
                fields: ["reason": "unmatched", "length": "\(transcript.count)"]
            )
        }
    }

    private func audioSourceInvalidated(
        _ failure: VoiceAudioSourceFailure,
        generation: UInt64
    ) {
        guard running, sessionGeneration == generation else { return }
        diagnostics.record(
            "capture.invalidated",
            level: .warning,
            fields: [
                "stage": failure.stage.rawValue,
                "error": failure.detail,
            ]
        )
        teardown(expectedGeneration: generation)
    }

    private static func failureFields(_ error: any Error) -> [String: String] {
        if let failure = error as? VoiceAudioSourceFailure {
            return ["stage": failure.stage.rawValue, "error": failure.detail]
        }
        return ["stage": "unknown", "error": String(describing: error)]
    }
    #endif

    private func fire(_ command: VoiceCommand, generation: UInt64) {
        guard running, sessionGeneration == generation else { return }
        diagnostics.record("command.matched", fields: ["command": "\(command)"])
        let callback = onCommand
        teardown(expectedGeneration: generation)
        callback?(command)
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != sessionGeneration {
            return
        }
        sessionGeneration &+= 1
        running = false
        onCommand = nil
        #if canImport(AVFoundation)
        audioSource.stop()
        #endif
        #if canImport(Speech)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #endif
    }

}
