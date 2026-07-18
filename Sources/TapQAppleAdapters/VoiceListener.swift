import Foundation
import TapQContracts
import TapQDetectionBaseline
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
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
    private let recognizer = SFSpeechRecognizer(locale: VoiceListener.grammarLocale)
    private var task: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    #endif
    #if canImport(AVFoundation)
    private let engine = AVAudioEngine()
    #endif

    private var onCommand: (@MainActor (VoiceCommand) -> Void)?
    private var running = false
    private let diagnostics: TapQDiagnosticEmitter
    public var preferOnDevice = true

    var recognizerLocaleForTesting: String? {
        #if canImport(Speech)
        return recognizer?.locale.identifier
        #else
        return nil
        #endif
    }

    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.diagnostics = TapQDiagnosticEmitter(category: "Voice", sink: diagnosticSink)
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
        guard !running, let recognizer, recognizer.isAvailable else {
            diagnostics.record("start.skipped", fields: ["running": "\(running)"])
            return
        }
        diagnostics.record("listening.started", fields: ["locale": Self.grammarLocale.identifier])
        self.onCommand = onCommand

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if preferOnDevice, recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            diagnostics.record("engine.start_failed", level: .error,
                               fields: ["error": "\(error)"])
            teardown()
            return
        }
        running = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result, VoiceCommandMatcher.match(result.bestTranscription.formattedString) != nil || result.isFinal {
                Task { @MainActor in
                    self.diagnostics.record("transcript.received")
                }
            }
            if let result, let command = VoiceCommandMatcher.match(result.bestTranscription.formattedString) {
                Task { @MainActor in self.fire(command) }
            } else if error != nil {
                Task { @MainActor in self.teardown() }
            } else if let result, result.isFinal {
                // The user said something the grammar doesn't know — log it so a
                // "voice does nothing" report is diagnosable from the log file.
                let transcript = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.diagnostics.record("transcript.rejected",
                                            fields: ["reason": "unmatched",
                                                     "length": "\(transcript.count)"])
                }
            }
        }
        #else
        _ = onCommand
        #endif
    }

    public func stop() {
        teardown()
    }

    private func fire(_ command: VoiceCommand) {
        guard running else { return }
        diagnostics.record("command.matched", fields: ["command": "\(command)"])
        let callback = onCommand
        teardown()
        callback?(command)
    }

    private func teardown() {
        running = false
        onCommand = nil
        #if canImport(AVFoundation)
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        #endif
        #if canImport(Speech)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #endif
    }

}
