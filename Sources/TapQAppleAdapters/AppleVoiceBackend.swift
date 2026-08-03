import Foundation
import TapQContracts
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// The default `VoiceBackend`: on-device Apple speech recognition, one microphone window
/// per user turn, no audio produced.
///
/// It is deliberately a sibling of `VoiceListener` rather than a refactor of it. The
/// shipped voice path is the one thing in this milestone that must not move, so the ~40
/// lines of recognition-window setup are duplicated here instead of being hoisted into a
/// shared helper that both paths would then depend on.
///
/// Two invariants this class exists to hold:
///
/// - **The microphone opens in `beginUserTurn` and closes in `endUserTurn`**, never in
///   `open`. A session can sit open for the length of an interaction without the mic being
///   live, which is the "never always-on" guarantee `VoiceListener` documents.
/// - **The backend never ends a turn.** `SFSpeechRecognizer` marks a result final on its
///   own silence heuristic; that is a transcript, not a turn boundary, and it is forwarded
///   as `transcriptFinal` while the turn stays exactly as open as TapQ left it. Everything
///   else routes through `VoiceTurnStateMachine`, so a turn-protocol mistake surfaces as
///   `sessionFailed(.protocolViolation)` rather than as a window that resolves itself.
///
/// The microphone plus recognizer pair is this backend's transport, so route changes,
/// engine-start failures, and recognizer errors all arrive as `VoiceBackendFailure.network`
/// — the same case a socket-backed adapter reports a dropped connection with, which is what
/// lets a fail-through wrapper treat them alike.
@MainActor public final class AppleVoiceBackend: VoiceBackend {
    public let capabilities = VoiceBackendCapabilities.transcriptOnly

    #if canImport(Speech)
    private let recognizer: any VoiceSpeechRecognizing
    private var task: (any VoiceRecognitionTasking)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    #endif
    #if canImport(AVFoundation)
    private let audioSource: VoiceAudioSourceController
    #endif

    private let speech: any SpeechPresenting
    private let diagnostics: TapQDiagnosticEmitter
    private var onEvent: (@MainActor (VoiceBackendEvent) -> Void)?
    private var turns = VoiceTurnStateMachine(capabilities: .transcriptOnly)
    /// Invalidates delayed recognition, route, and synthesizer callbacks from a prior
    /// session or turn. Bumped on every open and every teardown.
    private var sessionGeneration: UInt64 = 0

    /// Mirrors `VoiceListener.preferOnDevice`: on-device recognition when the recognizer
    /// offers it, so a voice window never leaves the machine.
    public var preferOnDevice = true
    /// Priority for `requestResponse(text:)`. An agent answer is a notification, not an
    /// approval prompt, so it must not preempt one.
    public var responsePriority: SpeechPriority = .notification

    /// - Parameter speech: the host's single `SpeechEngine`. A backend that produced its
    ///   own `AVSpeechSynthesizer` would speak outside the engine's activity signal, and
    ///   `SpeechGatedVoice` would open the microphone straight into it.
    public init(speech: any SpeechPresenting,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        #if canImport(Speech)
        self.recognizer = AppleVoiceSpeechRecognizer(locale: VoiceListener.grammarLocale)
        #endif
        #if canImport(AVFoundation)
        self.audioSource = VoiceAudioSourceController {
            AVAudioEngineVoiceAudioSource()
        }
        #endif
        self.speech = speech
        self.diagnostics = TapQDiagnosticEmitter(category: "AppleVoiceBackend",
                                                 sink: diagnosticSink)
    }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Test seam: fakes exercise the session and turn lifecycle without touching Speech,
    /// AVFAudio, or the synthesizer.
    init(recognizer: any VoiceSpeechRecognizing,
         makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
         speech: any SpeechPresenting,
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.recognizer = recognizer
        self.audioSource = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.speech = speech
        self.diagnostics = TapQDiagnosticEmitter(category: "AppleVoiceBackend",
                                                 sink: diagnosticSink)
    }
    #endif

    var turnStateForTesting: VoiceTurnStateMachine.State { turns.state }
    var sessionGenerationForTesting: UInt64 { sessionGeneration }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Test seam: `SFSpeechRecognitionResult` has no initializer a test can use, so the
    /// recognition callback is driven directly — including with a deliberately stale
    /// generation, which is the callback class this file most needs to prove it drops.
    func deliverRecognitionForTesting(transcript: String? = nil, isFinal: Bool = false,
                                      error: (any Error)? = nil,
                                      generation: UInt64? = nil) {
        handleRecognition(transcript: transcript, isFinal: isFinal, error: error,
                          generation: generation ?? sessionGeneration)
    }
    #endif

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        #if canImport(Speech) && canImport(AVFoundation)
        do {
            try turns.open()
        } catch {
            throw VoiceBackendFailure.protocolViolation(Self.describe(error))
        }
        guard recognizer.isAvailable else {
            turns.close()
            diagnostics.record("open.failed", level: .warning,
                               fields: ["reason": "recognizer_unavailable"])
            // Unavailability is almost always a permission or download state the user has
            // to resolve; retrying the same session would spin.
            throw VoiceBackendFailure.authorization(
                "speech recognition is unavailable for \(VoiceListener.grammarLocale.identifier)")
        }
        sessionGeneration &+= 1
        self.onEvent = onEvent
        diagnostics.record("session.opened",
                           fields: ["locale": VoiceListener.grammarLocale.identifier])
        #else
        _ = onEvent
        throw VoiceBackendFailure.closed("speech recognition is unavailable on this platform")
        #endif
    }

    public func close() {
        teardown()
        diagnostics.record("session.closed")
    }

    public func beginUserTurn() {
        #if canImport(Speech) && canImport(AVFoundation)
        do {
            try turns.beginUserTurn()
        } catch {
            return violated(error)
        }
        let generation = sessionGeneration

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
            return failSession(.network("a microphone window is already open"),
                               generation: generation)
        case .failed(let error):
            return failSession(Self.failure(from: error), generation: generation)
        }

        guard sessionGeneration == generation else { return }

        let recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            Task { @MainActor in
                self?.handleRecognition(
                    transcript: result?.bestTranscription.formattedString,
                    isFinal: result?.isFinal ?? false,
                    error: error,
                    generation: generation
                )
            }
        }
        guard let recognitionTask else {
            return failSession(.network("the speech recognizer returned no task"),
                               generation: generation)
        }
        task = recognitionTask
        diagnostics.record("turn.began")
        #endif
    }

    public func endUserTurn() {
        #if canImport(Speech) && canImport(AVFoundation)
        do {
            try turns.endUserTurn()
        } catch {
            return violated(error)
        }
        // The microphone closes the instant the turn commits; the recognition task stays
        // alive just long enough to deliver the settled transcript for what it already heard.
        audioSource.stop()
        request?.endAudio()
        diagnostics.record("turn.committed")
        #endif
    }

    /// Accepted and discarded: this backend records its own microphone, so pushed audio has
    /// no destination. The requirement exists for pipe-style backends that are handed bytes.
    public func sendAudio(_ chunk: VoiceAudioChunk) {
        diagnostics.record("audio.ignored",
                           fields: ["reason": "backend_owns_microphone",
                                    "bytes": "\(chunk.data.count)"])
    }

    public func requestResponse(text: String) {
        do {
            try turns.requestResponse()
        } catch {
            return violated(error)
        }
        let generation = sessionGeneration
        diagnostics.record("response.requested", fields: ["length": "\(text.count)"])
        speech.speak(text, priority: responsePriority) { [weak self] in
            Task { @MainActor in
                self?.responseFinished(generation: generation)
            }
        }
    }

    /// Always a violation here: `capabilities.supportsBargeIn` is false, and the contract
    /// requires that be surfaced rather than swallowed, so no caller can believe a response
    /// was abandoned when it was not.
    public func cancelResponse() {
        do {
            try turns.cancelResponse()
        } catch {
            return violated(error)
        }
    }

    #if canImport(Speech) && canImport(AVFoundation)
    private func handleRecognition(transcript: String?, isFinal: Bool,
                                   error: (any Error)?, generation: UInt64) {
        guard sessionGeneration == generation, onEvent != nil else { return }

        if let transcript, !transcript.isEmpty {
            diagnostics.record("transcript.received", fields: ["final": "\(isFinal)"])
            emit(isFinal ? .transcriptFinal(transcript) : .transcriptPartial(transcript))
            // A consumer may resolve its window and close us from inside that event.
            guard sessionGeneration == generation, onEvent != nil else { return }
        }

        if let error {
            return failSession(.network("recognition failed: \(Self.describe(error))"),
                               generation: generation)
        }
        guard isFinal else { return }

        if turns.isUserTurnActive {
            // The recognizer decided the utterance was over. Only TapQ decides that, so the
            // transcript is forwarded above and the turn is left untouched.
            diagnostics.record("transcript.final_during_turn",
                               fields: ["reason": "recognizer_vad_ignored"])
            return
        }

        do {
            try turns.responseCompleted()
        } catch {
            return
        }
        finishTurnResources()
        emit(.responseCompleted)
    }

    private func audioSourceInvalidated(_ failure: VoiceAudioSourceFailure,
                                        generation: UInt64) {
        guard sessionGeneration == generation, onEvent != nil else { return }
        failSession(Self.failure(from: failure), generation: generation)
    }

    private func finishTurnResources() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
    #endif

    private func responseFinished(generation: UInt64) {
        guard sessionGeneration == generation, onEvent != nil else { return }
        do {
            try turns.responseCompleted()
        } catch {
            return
        }
        emit(.responseCompleted)
    }

    private func violated(_ error: any Error) {
        failSession(.protocolViolation(Self.describe(error)), generation: sessionGeneration)
    }

    /// Ends the session and reports it. Teardown happens before the event is delivered, so
    /// a consumer that reacts by opening a fresh session never races this one's cleanup.
    private func failSession(_ failure: VoiceBackendFailure, generation: UInt64) {
        guard sessionGeneration == generation else { return }
        diagnostics.record("session.failed", level: .warning,
                           fields: ["detail": failure.localizedDescription])
        let callback = onEvent
        turns.sessionFailed()
        teardown(expectedGeneration: generation)
        callback?(.sessionFailed(failure))
    }

    private func emit(_ event: VoiceBackendEvent) {
        onEvent?(event)
    }

    private func teardown(expectedGeneration: UInt64? = nil) {
        if let expectedGeneration, expectedGeneration != sessionGeneration { return }
        sessionGeneration &+= 1
        onEvent = nil
        turns.close()
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

    private static func describe(_ error: any Error) -> String {
        if let violation = error as? VoiceTurnViolation {
            return violation.localizedDescription
        }
        if let failure = error as? VoiceBackendFailure {
            return failure.localizedDescription
        }
        return String(describing: error)
    }

    #if canImport(AVFoundation)
    private static func failure(from error: any Error) -> VoiceBackendFailure {
        guard let failure = error as? VoiceAudioSourceFailure else {
            return .network(String(describing: error))
        }
        return .network("\(failure.stage.rawValue): \(failure.detail)")
    }
    #endif
}
