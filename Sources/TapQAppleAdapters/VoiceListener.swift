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
    /// Decides *when* a matched command may fire. The recognizer reports a growing
    /// transcript and this listener tears itself down on the first command it delivers, so
    /// without the gate the first fragment of a sentence is the whole sentence — which is
    /// how "ok, skip the command" approved a request on hardware. See
    /// `VoicePartialCommandGate`.
    private var gate: VoicePartialCommandGate
    /// The pending "has the transcript stopped changing yet?" re-ask. Exactly one is armed
    /// at a time: a fresh transcript supersedes it, and teardown cancels it, so a window
    /// that has closed can never be resolved by a timer it left behind.
    private var stabilityRecheck: Task<Void, Never>?
    /// Monotonic seconds, read only for differences. `systemUptime` rather than wall clock
    /// so a clock adjustment mid-utterance cannot make a fragment look settled.
    private let monotonicNow: () -> TimeInterval
    public var preferOnDevice = true

    var recognizerLocaleForTesting: String? {
        #if canImport(Speech)
        return recognizer.localeIdentifier
        #else
        return nil
        #endif
    }

    /// - Parameter voiceProcessingEnabled: experimental (RD4). Turns Apple's echo
    ///   cancellation and AGC on for the recognizer's input node. `false` — the default and
    ///   every run without `--voice-processing` — builds exactly the source this listener
    ///   always built, so the audio path is unchanged byte for byte.
    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
                voiceProcessingEnabled: Bool = false) {
        self.gate = VoicePartialCommandGate()
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        #if canImport(Speech)
        self.recognizer = AppleVoiceSpeechRecognizer(locale: Self.grammarLocale)
        #endif
        #if canImport(AVFoundation)
        self.audioSource = VoiceAudioSourceController {
            AVAudioEngineVoiceAudioSource(voiceProcessingEnabled: voiceProcessingEnabled)
        }
        #endif
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
    }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Test seam: fakes exercise listener lifecycle without touching Speech or AVFAudio.
    ///
    /// - Parameter stabilityWindow: shortened by tests that need the stability re-check to
    ///   actually elapse. The scheduling under it stays real — the timer, the main-actor
    ///   hop, and the generation check are the parts a fake clock would stop proving.
    init(
        recognizer: any VoiceSpeechRecognizing,
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
        stabilityWindow: TimeInterval = VoicePartialCommandGate.defaultStabilityWindow
    ) {
        self.recognizer = recognizer
        self.audioSource = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
        self.gate = VoicePartialCommandGate(stabilityWindow: stabilityWindow)
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
    }

    /// Test seam: `SFSpeechRecognitionResult` has no initializer a test can use, so the
    /// recognition callback is driven directly — the same seam `AppleVoiceBackend` opens
    /// for the same reason.
    func deliverRecognitionForTesting(transcript: String? = nil, isFinal: Bool = false,
                                      error: (any Error)? = nil,
                                      generation: UInt64? = nil) {
        handleRecognition(transcript: transcript, isFinal: isFinal, error: error,
                          generation: generation ?? sessionGeneration)
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
            onBuffer: { buffer, _ in
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
            // The result is read here rather than carried across the hop: what the handler
            // needs is the transcript and its finality, and both are values.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                self?.handleRecognition(
                    transcript: transcript,
                    isFinal: isFinal,
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
    /// One recognizer callback — partial or final — offered to the grammar through the
    /// firing gate.
    ///
    /// The grammar still sees every transcript, partial included, and still sees the whole
    /// utterance so far rather than a delta: nothing about *what* a transcript means has
    /// moved. What the gate adds is that a command which decides something is delivered
    /// only once the text behind it has stopped changing, so the leading fragment of a
    /// sentence can no longer resolve the window and tear the recognizer down before the
    /// rest of the sentence exists.
    private func handleRecognition(
        transcript: String?,
        isFinal: Bool,
        error: (any Error)?,
        generation: UInt64
    ) {
        guard running, sessionGeneration == generation else { return }

        if let transcript {
            switch gate.admit(transcript: transcript, isFinal: isFinal, at: monotonicNow()) {
            case .fire(let command):
                diagnostics.record("transcript.received")
                fire(command, generation: generation)
                return
            case .hold(let recheckAfter):
                diagnostics.record("transcript.received")
                if error == nil {
                    // Logged because this is the one delay a wearer can feel, and a "my yes
                    // did nothing" report should be answerable from the log file alone.
                    diagnostics.record(
                        "command.deferred",
                        fields: [
                            "reason": "awaiting_stable_transcript",
                            "recheck_ms": "\(Int((recheckAfter * 1000).rounded()))",
                        ]
                    )
                    scheduleStabilityRecheck(after: recheckAfter, generation: generation)
                    return
                }
                // A failing recognizer will never produce the settled transcript this
                // candidate is waiting for, so the error below wins and the candidate is
                // dropped with the session. Only a *matched and settled* command outranks
                // an error, which is the precedence this path has always had.
            case .idle:
                break
            }
        }

        if error != nil {
            teardown(expectedGeneration: generation)
        } else if let transcript, isFinal {
            // The user said something the grammar doesn't know — log it so a
            // "voice does nothing" report is diagnosable from the log file.
            diagnostics.record("transcript.received")
            diagnostics.record(
                "transcript.rejected",
                fields: ["reason": "unmatched", "length": "\(transcript.count)"]
            )
        }
    }

    /// Arms the single pending re-ask for a held command.
    ///
    /// Only one is ever outstanding: a later transcript replaces the question it was going
    /// to ask, and teardown cancels it, so the timer can never resolve a window that has
    /// already closed. The generation check on the way back out is the same one every other
    /// delayed callback in this file makes, for the same reason.
    private func scheduleStabilityRecheck(after delay: TimeInterval, generation: UInt64) {
        stabilityRecheck?.cancel()
        stabilityRecheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recheckStability(generation: generation)
        }
    }

    private func recheckStability(generation: UInt64) {
        guard running, sessionGeneration == generation else { return }
        switch gate.recheck(at: monotonicNow()) {
        case .fire(let command):
            fire(command, generation: generation)
        case .hold(let recheckAfter):
            scheduleStabilityRecheck(after: recheckAfter, generation: generation)
        case .idle:
            break
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
        // A command still waiting for its transcript to settle when the window closes is
        // one the wearer never got a decision out of. It is dropped rather than flushed:
        // TapQ fails open, and an unanswered request goes back to the on-screen prompt.
        stabilityRecheck?.cancel()
        stabilityRecheck = nil
        gate.reset()
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
