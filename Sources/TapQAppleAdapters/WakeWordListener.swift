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
    /// A peak at or above this is speech-level audio: a request that has heard this much
    /// and answered nothing is being ignored, not waited on. Room noise on the 2026-09-04
    /// runs peaked around -26 dB; the wearer's speech peaked at -15.
    nonisolated static let loudPeakDecibels: Float = -20
    /// Level reports at speech level, with no callback yet on the request, before the
    /// request is judged deaf and reopened. Three reports is fifteen seconds of speech.
    nonisolated static let deafReportLimit = 3
    /// The same judgment for the listener's first request, made on one report. The deaf
    /// request is that one, every time it has been seen (four launches, 2026-09-04, each
    /// the first after a re-sign), and the request reopened in its place hears at once;
    /// a first request that has had five seconds of speech and answered nothing is not
    /// going to. Five seconds of deafness at start-up instead of fifteen.
    nonisolated static let firstRequestDeafReportLimit = 1
    /// Deaf requests in a row, with no callback between them, before the listener gives
    /// up and says so: a recognizer that ignores three fresh requests in one process is
    /// not going to answer a fourth.
    nonisolated static let deafRestartLimit = 3

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
    #if canImport(AVFoundation)
    /// Peak meter for the request's audio, read on the main actor every
    /// `levelReportInterval` and logged at debug level. Diagnostic only: on 2026-09-04 two
    /// first launches after a re-sign fed the recognizer for minutes without one callback,
    /// and nothing in the log said whether the microphone was delivering silence or the
    /// recognizer was ignoring speech. This is the line that tells the two apart.
    private var levelMeter: AudioLevelMeter?
    private var levelTask: Task<Void, Never>?
    private let levelReportInterval: TimeInterval
    nonisolated static let defaultLevelReportInterval: TimeInterval = 5
    /// Callbacks of any kind — partial, final, error — on the current request. Zero with
    /// speech-level audio flowing is the deaf recognizer this watchdog exists for: seen
    /// twice on 2026-09-04, both times on the first launch after a re-sign, with buffers
    /// reaching Apple's local recognition client and nothing ever coming back.
    private var callbacksThisRequest = 0
    private var loudReportsWithoutCallback = 0
    /// The last partial logged, so a recognizer that repeats itself is logged once.
    private var lastLoggedTranscript: String?
    /// Requests reopened for deafness with no callback in between.
    private var deafRestarts = 0
    /// Requests opened since the listener was created; the first is the suspect one.
    private var requestsOpened = 0
    #endif

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
        #if canImport(AVFoundation)
        self.levelReportInterval = Self.defaultLevelReportInterval
        #endif
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
         },
         levelReportInterval: TimeInterval = WakeWordListener.defaultLevelReportInterval) {
        self.phrase = phrase
        self.recognizer = recognizer
        self.audioSource = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.diagnostics = TapQDiagnosticEmitter(category: "WakeWord", sink: diagnosticSink)
        self.sleep = sleep
        self.monotonicNow = monotonicNow
        self.levelReportInterval = levelReportInterval
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
        callbacksThisRequest = 0
        loudReportsWithoutCallback = 0
        lastLoggedTranscript = nil
        requestsOpened += 1

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // The product name is not a word the recognizer knows: live it came back as "Hey
        // dad you" (2026-09-04). Contextual strings bias it toward the spellings the
        // matcher folds, and toward the phrase as a whole.
        request.contextualStrings = Self.contextualStrings(for: phrase)
        let onDevice = recognizer.supportsOnDeviceRecognition
        if onDevice {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let meter = AudioLevelMeter()
        levelMeter = meter
        let audioResult = audioSource.start(
            onBuffer: { buffer, _ in
                meter.note(buffer)
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
        beginLevelReports(generation: generation)
    }

    /// Logs the request's peak input level every `levelReportInterval` while it runs.
    ///
    /// A real sleep rather than the injected one: the injected sleeper is the restart
    /// ladder's, and a test double that returns at once would spin this loop.
    private func beginLevelReports(generation: UInt64) {
        levelTask?.cancel()
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.levelReportInterval else { return }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self, self.generation == generation,
                      let meter = self.levelMeter else { return }
                let (peak, buffers) = meter.drain()
                let decibels = AudioLevelMeter.decibels(peak)
                self.diagnostics.record("audio.level", level: .debug, fields: [
                    "peak_db": String(format: "%.1f", decibels),
                    "buffers": "\(buffers)",
                ])
                self.noteLevel(peakDecibels: decibels)
            }
        }
    }

    /// The deaf-recognizer watchdog: speech-level audio with no callback at all, for
    /// `deafReportLimit` reports running, ends the request and opens a fresh one, and the
    /// third such request in a row with nothing heard between them ends the listening.
    ///
    /// Not a failure in the ladder's sense — no back-off, no failure count — because the
    /// request did not fail: it ran, and was ignored. A quiet room never trips this; a
    /// loud one with no speech in it reopens a request every fifteen seconds and, if the
    /// recognizer keeps answering nothing, says so after the third.
    private func noteLevel(peakDecibels: Float) {
        guard callbacksThisRequest == 0 else {
            loudReportsWithoutCallback = 0
            return
        }
        guard peakDecibels >= Self.loudPeakDecibels else { return }
        loudReportsWithoutCallback += 1
        let limit = requestsOpened == 1 ? Self.firstRequestDeafReportLimit : Self.deafReportLimit
        guard loudReportsWithoutCallback >= limit else { return }
        deafRestarts += 1
        diagnostics.record("recognizer.deaf", level: .warning, fields: [
            "loud_reports": "\(loudReportsWithoutCallback)",
            "restarts": "\(deafRestarts)",
        ])
        guard deafRestarts < Self.deafRestartLimit else {
            giveUp(reason: "recognizer_deaf")
            return
        }
        endRequest()
        noteRequestEnded(healthy: true, reason: "recognizer_deaf")
    }

    /// One recognizer callback, partial or final. A partial is enough: the wearer should
    /// not have to stop talking for the phrase to land, and the sentence after it is not
    /// ours to hear.
    private func handleRecognition(transcript: String?, isFinal: Bool,
                                   error: (any Error)?, generation: UInt64) {
        guard spotting, self.generation == generation else { return }
        callbacksThisRequest += 1
        deafRestarts = 0
        // Every callback, at debug level: what the recognizer heard and did not match, and
        // what it failed with, are the two things a run that never wakes cannot be read
        // without. Info level says nothing about content, as `wake.fired` does not.
        if let error {
            diagnostics.record("recognition.error", level: .debug,
                               fields: ["error": String(describing: error)])
        }
        if let transcript, transcript != lastLoggedTranscript {
            lastLoggedTranscript = transcript
            diagnostics.record("recognition.heard", level: .debug, fields: [
                "transcript": transcript, "final": isFinal ? "true" : "false",
            ])
        }

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
        levelTask?.cancel()
        levelTask = nil
        levelMeter = nil
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
        #if canImport(AVFoundation)
        deafRestarts = 0
        #endif
        restartTask?.cancel()
        restartTask = nil
        #if canImport(AVFoundation)
        levelTask?.cancel()
        levelTask = nil
        levelMeter = nil
        audioSource.stop()
        #endif
        #if canImport(Speech)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        #endif
    }

    /// Vocabulary hints for the recognizer: the phrase itself, and the product name in
    /// the spellings the matcher folds, so "tapq" is offered as "tap Q" and "TapQ" rather
    /// than left for the recognizer to guess at.
    nonisolated static func contextualStrings(for phrase: String) -> [String] {
        var strings = [phrase]
        let lowered = phrase.lowercased()
        if lowered.contains("tapq") {
            strings.append(lowered.replacingOccurrences(of: "tapq", with: "tap Q"))
            strings.append(lowered.replacingOccurrences(of: "tapq", with: "TapQ"))
            strings.append(contentsOf: ["TapQ", "tap Q"])
        }
        return strings
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

#if canImport(AVFoundation)
/// Peak-holds the audio thread's buffers until the main actor reads them.
///
/// The audio callback may not block or allocate; a lock held for a few instructions is
/// the one thing it can afford, and this class does nothing else under it.
final class AudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var buffers = 0

    func note(_ buffer: AVAudioPCMBuffer) {
        let bufferPeak = Self.peak(of: buffer)
        lock.lock()
        if bufferPeak > peak { peak = bufferPeak }
        buffers += 1
        lock.unlock()
    }

    /// The peak and buffer count since the last drain, then a fresh interval.
    func drain() -> (peak: Float, buffers: Int) {
        lock.lock()
        defer {
            peak = 0
            buffers = 0
            lock.unlock()
        }
        return (peak, buffers)
    }

    /// Full scale is 0 dB; digital silence reads as -120.
    nonisolated static func decibels(_ peak: Float) -> Float {
        guard peak > 0 else { return -120 }
        return max(-120, 20 * log10(peak))
    }

    /// The largest absolute sample in the first channel, on a 0...1 scale.
    nonisolated static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        if let channel = buffer.floatChannelData?[0] {
            var peak: Float = 0
            for index in 0..<frames {
                let sample = abs(channel[index])
                if sample > peak { peak = sample }
            }
            return peak
        }
        if let channel = buffer.int16ChannelData?[0] {
            var peak: Int16 = 0
            for index in 0..<frames {
                let sample = channel[index] == Int16.min ? Int16.max : abs(channel[index])
                if sample > peak { peak = sample }
            }
            return Float(peak) / Float(Int16.max)
        }
        return 0
    }
}
#endif
