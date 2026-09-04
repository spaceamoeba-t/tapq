import Foundation
import TapQContracts
#if canImport(Speech)
import Speech
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Hears the wake phrase with nothing else running (`docs/WAKE_WORD_PLAN.md` §2).
///
/// This is Apple's Speech framework used as a keyword spotter, and nothing more. It is
/// **not** the deprecated Apple voice backend: it never speaks, never matches a command
/// grammar, and never touches a `VoiceBackend`. The one thing it produces is the fact that
/// the wearer said the phrase; what the wearer says *after* the phrase belongs to the
/// realtime session, which is why a hit ends the recognition request that carried it.
///
/// `VoiceListener` is the template for the mechanics — the same request setup, the same
/// generation-guarded teardown, the same single-use `AVAudioEngineVoiceAudioSource` per
/// microphone window — but no logic is shared with it, because `VoiceListener` is on its
/// way out with the backend it serves.
///
/// The microphone here is long-lived in a way no other TapQ listener is, so the runtime's
/// gate owns `start`/`stop` and keeps this off whenever anything else wants the mic. This
/// type's own job past that is only to stay alive: on-device requests end by themselves
/// after about a minute, and every one of those endings is a restart.
@MainActor public final class WakeWordListener: WakeWordSpotting {
    /// The phrase `--wake-word` defaults to.
    nonisolated public static let defaultPhrase = "hey tapq"

    /// The recognizer is pinned to the locale the folded spellings below belong to. A
    /// device-locale recognizer on a non-English Mac transcribes the phrase into words
    /// this matcher can never fold, which would be a wake word that silently never fires.
    nonisolated public static let recognitionLocale = Locale(identifier: "en-US")

    /// First restart delay; each consecutive failure doubles it up to `maximumBackoff`.
    nonisolated static let firstBackoff: TimeInterval = 0.5
    nonisolated static let maximumBackoff: TimeInterval = 8
    /// A request that lived at least this long did its job, however it ended: on-device
    /// requests expire after about a minute, and that expiry is health, not failure.
    nonisolated static let healthyRequestSeconds: TimeInterval = 10
    /// Consecutive short-lived requests before the listener gives up and says so.
    nonisolated static let failureLimit = 10

    /// The spellings Apple's recognizer produces for the product name. Folded to one token
    /// so `tap q`, `tap queue`, `tap cue` and `tap-q` are all the same word to the matcher.
    nonisolated private static let nameSuffixes: Set<String> = [
        "q", "queue", "cue", "cu", "que", "kew",
    ]

    private let phrase: String
    #if canImport(Speech)
    private let recognizer: any VoiceSpeechRecognizing
    private var task: (any VoiceRecognitionTasking)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    #endif
    #if canImport(AVFoundation)
    private let audioSource: VoiceAudioSourceController
    #endif
    private let diagnostics: TapQDiagnosticEmitter
    /// The back-off wait, injected so tests do not spend eight real seconds proving the
    /// doubling. Main-actor isolated: the restart it guards is main-actor work either way.
    private let sleep: @MainActor (TimeInterval) async -> Void
    /// Monotonic seconds, read only for differences, so a clock adjustment mid-request
    /// cannot make a healthy request look like a failing one.
    private let monotonicNow: () -> TimeInterval

    private var onWake: (@MainActor (String) -> Void)?
    public var onStopped: (@MainActor (String) -> Void)?

    private var spotting = false
    /// Invalidates callbacks from a recognition request that has already been replaced —
    /// by a wake hit, by a restart, or by the caller's `stop()`.
    private var generation: UInt64 = 0
    private var firedThisRequest = false
    private var restartTask: Task<Void, Never>?
    private var attempt = 0
    private var consecutiveFailures = 0
    private var requestStartedAt: TimeInterval = 0

    public var isSpotting: Bool { spotting }

    public init(phrase: String = WakeWordListener.defaultPhrase,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.phrase = phrase
        #if canImport(Speech)
        self.recognizer = AppleVoiceSpeechRecognizer(locale: Self.recognitionLocale)
        #endif
        #if canImport(AVFoundation)
        self.audioSource = VoiceAudioSourceController {
            AVAudioEngineVoiceAudioSource()
        }
        #endif
        self.diagnostics = TapQDiagnosticEmitter(category: "WakeWord", sink: diagnosticSink)
        self.sleep = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
    }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Test seam: fakes exercise the restart ladder without touching Speech or AVFAudio.
    init(phrase: String = WakeWordListener.defaultPhrase,
         recognizer: any VoiceSpeechRecognizing,
         makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink(),
         sleep: @escaping @MainActor (TimeInterval) async -> Void,
         monotonicNow: @escaping () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         }) {
        self.phrase = phrase
        self.recognizer = recognizer
        self.audioSource = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.diagnostics = TapQDiagnosticEmitter(category: "WakeWord", sink: diagnosticSink)
        self.sleep = sleep
        self.monotonicNow = monotonicNow
    }

    /// Test seam: `SFSpeechRecognitionResult` has no initializer a test can build, so the
    /// recognition callback is driven directly — the same seam `VoiceListener` opens.
    func deliverRecognitionForTesting(transcript: String? = nil, isFinal: Bool = false,
                                      error: (any Error)? = nil,
                                      generation: UInt64? = nil) {
        handleRecognition(transcript: transcript, isFinal: isFinal, error: error,
                          generation: generation ?? self.generation)
    }

    /// Test seam: the generation a callback would have to carry to still count.
    var generationForTesting: UInt64 { generation }

    /// Test seam: waits for the pending restart to have started its request, so a test
    /// never has to guess how many scheduler turns a restart takes.
    func awaitPendingRestartForTesting() async {
        await restartTask?.value
    }
    #endif

    public func start(onWake: @escaping @MainActor (String) -> Void) {
        #if canImport(Speech) && canImport(AVFoundation)
        guard !spotting else {
            diagnostics.record("start.skipped", fields: ["reason": "already_running"])
            return
        }
        guard recognizer.isAvailable else {
            // Not a restartable failure: there is no recognizer to restart. The runtime
            // hears this through `onStopped` and says it, because a wake word that is not
            // listening has to be announced or the wearer talks to a dead room.
            diagnostics.record("start.skipped", level: .warning,
                               fields: ["reason": "recognizer_unavailable"])
            spotting = false
            onStopped?("recognizer_unavailable")
            return
        }

        self.onWake = onWake
        spotting = true
        attempt = 0
        consecutiveFailures = 0
        beginRequest()
        #else
        _ = onWake
        #endif
    }

    public func stop() {
        teardown()
    }

    #if canImport(Speech) && canImport(AVFoundation)
    /// Opens one recognition request and one microphone window for it.
    private func beginRequest() {
        guard spotting else { return }

        generation &+= 1
        let generation = self.generation
        firedThisRequest = false
        requestStartedAt = monotonicNow()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice {
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
            diagnostics.record("capture.start_failed", level: .error,
                               fields: ["reason": "audio_source_already_running"])
            requestFailed(reason: "audio_source_already_running", generation: generation)
            return
        case .failed(let error):
            var fields = Self.failureFields(error)
            fields["reason"] = "audio_start_failed"
            diagnostics.record("capture.start_failed", level: .warning, fields: fields)
            requestFailed(reason: "audio_start_failed", generation: generation)
            return
        }

        // A source that invalidated itself during `start` has already restarted us.
        guard self.generation == generation else { return }

        let recognitionTask = recognizer.recognitionTask(with: request) {
            [weak self] result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                self?.handleRecognition(transcript: transcript, isFinal: isFinal,
                                        error: error, generation: generation)
            }
        }
        guard let recognitionTask else {
            diagnostics.record("recognition.start_failed", level: .warning,
                               fields: ["reason": "task_unavailable"])
            requestFailed(reason: "task_unavailable", generation: generation)
            return
        }
        task = recognitionTask
        diagnostics.record("listening.started", fields: [
            "locale": recognizer.localeIdentifier ?? Self.recognitionLocale.identifier,
            "on_device": onDevice ? "true" : "false",
        ])
    }

    /// One recognizer callback, partial or final. A partial is enough: the wearer should
    /// not have to stop talking for the phrase to land, and the sentence after it is not
    /// ours to hear.
    private func handleRecognition(transcript: String?, isFinal: Bool,
                                   error: (any Error)?, generation: UInt64) {
        guard spotting, self.generation == generation else { return }

        if let transcript, !firedThisRequest, Self.matches(transcript, phrase: phrase) {
            firedThisRequest = true
            // The transcript itself is debug-only. At info level a wake event says how
            // much was heard, never what — this microphone is open with nobody asking.
            diagnostics.record("wake.fired",
                               fields: ["transcript_length": "\(transcript.count)"])
            diagnostics.record("wake.transcript", level: .debug,
                               fields: ["transcript": transcript])
            let callback = onWake
            endRequest()
            // The restart is scheduled before the callback runs, and it is a task, so a
            // `stop()` from inside that callback — the gate's ordinary response to a
            // window opening — still wins.
            noteRequestEnded(healthy: true, reason: "wake_fired")
            callback?(transcript)
            return
        }

        guard error != nil || isFinal else { return }

        // How an ending is *classified* is the request's lifetime, not the shape of the
        // ending. Apple does not promise whether the roughly-one-minute on-device expiry
        // arrives as a final result or as an error, and a listener that treated ten
        // expiries as ten failures would give up after ten quiet minutes.
        let lived = monotonicNow() - requestStartedAt
        endRequest()
        noteRequestEnded(healthy: lived > Self.healthyRequestSeconds,
                         reason: error != nil ? "recognition_error" : "request_ended")
    }

    private func audioSourceInvalidated(_ failure: VoiceAudioSourceFailure,
                                        generation: UInt64) {
        guard spotting, self.generation == generation else { return }
        diagnostics.record("capture.invalidated", level: .warning, fields: [
            "stage": failure.stage.rawValue,
            "error": failure.detail,
        ])
        endRequest()
        noteRequestEnded(healthy: false, reason: "capture_invalidated")
    }

    /// A request that never got as far as running. The generation guard keeps this from
    /// scheduling a second restart when the failure already went through invalidation.
    private func requestFailed(reason: String, generation: UInt64) {
        guard spotting, self.generation == generation else { return }
        endRequest()
        noteRequestEnded(healthy: false, reason: reason)
    }

    /// The one place that decides whether an ending is a restart or the end of listening.
    private func noteRequestEnded(healthy: Bool, reason: String) {
        guard spotting else { return }

        if healthy {
            attempt = 0
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
            guard consecutiveFailures < Self.failureLimit else {
                giveUp(reason: reason)
                return
            }
            attempt += 1
        }

        let delay = healthy ? 0 : Self.backoff(forAttempt: attempt)
        diagnostics.record("restart", level: .debug, fields: [
            "reason": reason,
            "attempt": "\(attempt)",
            "delay_ms": "\(Int((delay * 1000).rounded()))",
        ])
        scheduleRestart(after: delay)
    }

    /// Arms the one pending restart. Restarts are strictly sequential — the task that
    /// waits is the same one that opens the next request — so this never has to cancel a
    /// predecessor, and deliberately does not: the last call in a restart task's body is
    /// the `beginRequest` that schedules the next one, and a task that cancelled itself
    /// there would be betting on `Task.init` not inheriting cancellation.
    ///
    /// The generation, not cancellation, is what actually stops a stale restart: `stop()`
    /// and every ending bump it, so a task that wakes into a listener that has moved on
    /// finds a number it does not recognise and does nothing.
    private func scheduleRestart(after delay: TimeInterval) {
        let generation = self.generation
        restartTask = Task { @MainActor [weak self] in
            if delay > 0, let sleeper = self?.sleep {
                await sleeper(delay)
            }
            guard let self, self.spotting, self.generation == generation else { return }
            self.beginRequest()
        }
    }

    private func giveUp(reason: String) {
        diagnostics.record("stopped", level: .warning, fields: [
            "reason": reason,
            "failures": "\(consecutiveFailures)",
        ])
        let callback = onStopped
        // Teardown first: `isSpotting` must already read false to whatever the runtime
        // does in response, and nothing here may fire `onStopped` a second time.
        teardown()
        callback?(reason)
    }

    private func endRequest() {
        generation &+= 1
        firedThisRequest = false
        audioSource.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    nonisolated private static func backoff(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return firstBackoff }
        let scaled = firstBackoff * pow(2, Double(attempt - 1))
        return min(maximumBackoff, scaled)
    }

    nonisolated private static func failureFields(_ error: any Error) -> [String: String] {
        if let failure = error as? VoiceAudioSourceFailure {
            return ["stage": failure.stage.rawValue, "error": failure.detail]
        }
        return ["stage": "unknown", "error": String(describing: error)]
    }
    #endif

    private func teardown() {
        generation &+= 1
        spotting = false
        firedThisRequest = false
        onWake = nil
        attempt = 0
        consecutiveFailures = 0
        restartTask?.cancel()
        restartTask = nil
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

    // MARK: - Matching

    /// True when the normalized phrase occurs in the transcript as a whole-word sequence.
    ///
    /// Deliberately duplicated rather than shared with the portable phrase type in
    /// `TapQInteractionBaseline`: this target may not import it, and the rule is six lines.
    nonisolated static func matches(_ transcript: String, phrase: String) -> Bool {
        let haystack = normalizedWords(transcript)
        let needle = normalizedWords(phrase)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start ..< start + needle.count]) == needle {
            return true
        }
        return false
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed words, with the recognizer's
    /// spellings of the product name folded to one token. Folding requires adjacency, so
    /// "tap the queue" stays three ordinary words and never reads as the name.
    nonisolated static func normalizedWords(_ text: String) -> [String] {
        let raw = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        var folded: [String] = []
        var index = 0
        while index < raw.count {
            let word = raw[index]
            if word == "tap", index + 1 < raw.count,
               nameSuffixes.contains(raw[index + 1]) {
                folded.append("tapq")
                index += 2
                continue
            }
            folded.append(word)
            index += 1
        }
        return folded
    }
}
