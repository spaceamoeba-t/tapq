import Foundation
import TapQContracts
import TapQKernel
import TapQVoiceBackends

/// Speech in: the microphone, fed continuously to an OpenAI realtime transcription session
/// with server VAD, read back as the kernel's five speech events.
///
/// **Continuous feed.** Every captured block goes to the session, so the service's audio
/// clock is the capture clock and `at = origin + audio_start_ms` is exact. A block that
/// overlaps TapQ's own voice (the player's span, plus the hysteresis) is sent as zeros of
/// the same length, not dropped: the VAD hears silence while TapQ talks. After a route
/// change the capture gap is sent as zeros too, for the same clock.
///
/// **Commit order.** Transcripts and transcription failures are forwarded in
/// `input_audio_buffer.committed` order: one that arrives ahead of an earlier item's waits
/// for it. An expiry fails every committed item it left without a result.
///
/// Fail out loud: an error frame other than `session_expired`, a dropped transport, a
/// microphone that is gone or delivers only digital silence (07-2), and an outbound queue
/// past its cap (07-10) all become `.failed`.
@MainActor public final class RealtimeSpeechInput: SpeechInput {
    public nonisolated static let modelEnvironmentKey = "TAPQ_STT_MODEL"
    /// The agent names, so the transcriber spells them the way the intent model knows them
    /// (the chats since 2026-10-13).
    public nonisolated static let prompt =
        "The speaker gives instructions to coding agents named Claude, Claude Code and Codex, "
        + "and to the chat assistants Claude chat and ChatGPT."
    /// The service can return its prompt as the transcript of a segment with no speech in it
    /// (gpt-4o-transcribe, live 2026-10-11, just after "Codex, yes."). Nobody said it, so it
    /// is a failed segment, never an utterance: routed, it reached Codex as an instruction.
    public nonisolated static let promptEchoReason = "the transcriber returned its own prompt"
    /// Pinned because `audio_start_ms` includes it: `at` can sit this far before the first
    /// word, which is what the hysteresis floor below covers.
    public nonisolated static let prefixPaddingMs = 300
    /// The longest capture gap sent to the service as zeros (2026-10-20). A longer one, such as
    /// another app holding the microphone, would pass the outbound queue's cap
    /// (`RealtimeDefaults.outboundQueueLimit`, about 30 s of audio once encoded) and fail the
    /// session; the session rolls over instead, as at its expiry (D4).
    public nonisolated static let maximumZeroFill: TimeInterval = 10
    /// A pause shorter than this stays inside one utterance. The recording path's measured
    /// 600 ms: the service's own 200 ms cuts an instruction at the first breath, and the
    /// half after the cut is no longer addressed.
    public nonisolated static let silenceDurationMs = 600
    /// The least echo hysteresis this input accepts: the 300 ms prefix padding plus margin,
    /// so `at > played` holds for any speech that begins after a prompt.
    public nonisolated static let minimumHysteresis: TimeInterval = 0.4

    /// The one transcription session shape this input opens: `TAPQ_STT_MODEL` (default
    /// `gpt-4o-transcribe`), the agent-name prompt (`prompt` unless the host names its own
    /// agents), the language, and pinned server VAD.
    public nonisolated static func configuration(environment: [String: String],
                                     language: String?,
                                     prompt: String = RealtimeSpeechInput.prompt) -> RealtimeTranscriptionConfiguration {
        let model = environment[modelEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RealtimeTranscriptionConfiguration(
            model: model.flatMap { $0.isEmpty ? nil : $0 } ?? RealtimeDefaults.inputTranscriptionModel,
            prompt: prompt,
            language: language,
            turnDetection: .serverVAD(prefixPaddingMs: prefixPaddingMs,
                                      silenceDurationMs: silenceDurationMs))
    }

    /// `transcript` is the prompt, whatever its case, spacing and punctuation. Exact: a
    /// sentence that merely names the agents is the user's.
    public nonisolated static func isPromptEcho(_ transcript: String,
                                                prompt: String = RealtimeSpeechInput.prompt) -> Bool {
        words(transcript) == words(prompt)
    }

    private nonisolated static func words(_ text: String) -> [Substring] {
        let kept = text.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(kept).split(separator: " ")
    }

    private let capture: any AudioCapturing
    private let makeSession: @MainActor () -> RealtimeTranscriptionSession
    private let selfAudio: @MainActor () -> VoiceSelfAudioActivity
    private let hysteresis: TimeInterval
    /// The prompt the sessions are given, which a segment with no speech can come back as.
    private let transcriptionPrompt: String
    private let diagnostics: TapQDiagnosticEmitter
    private let continuation: AsyncStream<SpeechInputEvent>.Continuation

    public let events: AsyncStream<SpeechInputEvent>

    /// The live session; `nil` from an expiry until `reopen()`, and after `close()`.
    private var session: RealtimeTranscriptionSession?
    /// Capture instant of the first sample the current session was fed.
    private var origin: TimeInterval?
    /// Capture instant just past the last delivered block.
    private var deliveredUntil: TimeInterval?
    /// A route change restarted the capture; the next block's gap is owed as zeros.
    private var restarted = false
    private var zeroFilling = false
    private var silence = DigitalSilenceWatch()
    /// Committed items whose result is not yet forwarded, in commit order.
    private var committed: [String] = []
    /// Results that arrived ahead of an earlier committed item's.
    private var held: [String: SpeechInputEvent] = [:]
    private var ended = false

    /// - Parameters:
    ///   - capture: the microphone, delivering `VoiceAudioChunk.pcm16Mono24k`.
    ///   - makeSession: a fresh transcription session, once at `open()` and once per
    ///     `reopen()`.
    ///   - selfAudio: the player's self-audio span (`BackendAudioPlayback.selfAudioActivity`).
    ///   - hysteresis: how long after TapQ's voice stops the microphone is still hearing it
    ///     (`VoiceSelfAudioEcho.resolvedHysteresis`). Clamped to ``minimumHysteresis``.
    ///   - transcriptionPrompt: the prompt `makeSession`'s sessions carry, for the echo check.
    public init(capture: any AudioCapturing,
                makeSession: @escaping @MainActor () -> RealtimeTranscriptionSession,
                selfAudio: @escaping @MainActor () -> VoiceSelfAudioActivity,
                hysteresis: TimeInterval,
                transcriptionPrompt: String = RealtimeSpeechInput.prompt,
                diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.capture = capture
        self.makeSession = makeSession
        self.selfAudio = selfAudio
        self.hysteresis = max(hysteresis, Self.minimumHysteresis)
        self.transcriptionPrompt = transcriptionPrompt
        self.diagnostics = TapQDiagnosticEmitter(category: "speech-input", sink: diagnosticSink)
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: - SpeechInput

    public func open() async throws {
        try await openSession()
        try startCapture()
    }

    /// D4: a new session on the same capture. Blocks captured during its handshake queue
    /// behind its `session.update`; the audio origin resets with it.
    public func reopen() async throws {
        session?.close()
        releaseStranded()
        try await openSession()
    }

    public func close() {
        guard !ended else { return }
        ended = true
        capture.stop()
        session?.close()
        session = nil
        continuation.finish()
    }

    // MARK: - Session

    private func openSession() async throws {
        let session = makeSession()
        self.session = session
        origin = nil
        let events = session.events
        Task { @MainActor [weak self] in
            for await event in events {
                guard let self, self.session === session else { return }
                self.handle(event)
            }
        }
        do {
            try await session.open()
        } catch {
            if self.session === session { self.session = nil }
            throw error
        }
    }

    private func handle(_ event: RealtimeTranscriptionEvent) {
        switch event {
        case .speechStarted(let itemID, let audioStartMs):
            guard let itemID else { return fail("the service named no item for speech it heard") }
            var at: TimeInterval?
            if let origin, let audioStartMs { at = origin + TimeInterval(audioStartMs) / 1_000 }
            continuation.yield(.speechStarted(itemID: itemID, at: at))
        case .speechStopped(let itemID, _):
            guard let itemID else { return fail("the service named no item for speech it heard") }
            continuation.yield(.speechStopped(itemID: itemID))
        case .committed(let itemID):
            if let itemID { committed.append(itemID) }
        case .completed(let itemID, let transcript):
            guard let itemID else { return fail("the service named no item for a transcript") }
            guard !Self.isPromptEcho(transcript, prompt: transcriptionPrompt) else {
                return release(itemID, .utteranceFailed(itemID: itemID, reason: Self.promptEchoReason))
            }
            release(itemID, .utterance(itemID: itemID, text: transcript))
        case .transcriptionFailed(let itemID, let reason):
            guard let itemID else { return fail("the service named no item for a failed transcript") }
            release(itemID, .utteranceFailed(itemID: itemID, reason: reason))
        case .expired:
            session = nil
            releaseStranded()
            continuation.yield(.sessionExpired)
        case .failed(let reason), .dropped(let reason):
            // A dropped transport is fatal for the loop, as it always was (07-2).
            fail(reason)
        case .commitEmpty:
            // Only a client's commit draws one, and the loop never commits: a peer that sends
            // one anyway is not speaking the protocol the loop was built on.
            fail("the service answered a commit the loop never sent (input_audio_buffer_commit_empty)")
        case .delta:
            break
        }
    }

    /// Forwards every result whose earlier committed items have theirs. An item that was
    /// never committed takes the last place.
    private func release(_ itemID: String, _ result: SpeechInputEvent) {
        if !committed.contains(itemID) { committed.append(itemID) }
        held[itemID] = result
        while let first = committed.first, let ready = held.removeValue(forKey: first) {
            committed.removeFirst()
            continuation.yield(ready)
        }
    }

    /// The session is gone: each committed item gets its result, or fails.
    private func releaseStranded() {
        for itemID in committed {
            continuation.yield(held[itemID] ?? .utteranceFailed(
                itemID: itemID, reason: "the session ended before it was transcribed"))
        }
        committed = []
        held = [:]
    }

    // MARK: - Capture

    private func startCapture() throws {
        try capture.start(onBlock: { [weak self] in self?.deliver($0) },
                          onFailure: { [weak self] in self?.captureFailed($0) })
    }

    private func deliver(_ chunk: VoiceAudioChunk) {
        guard !ended else { return }
        // The bytes the microphone delivered, before any zero-fill of TapQ's own: a long
        // reading must not look like a dead microphone.
        if silence.observe(chunk) {
            return fail("microphone delivers only silence")
        }
        if restarted, let gapStart = deliveredUntil, chunk.timestamp > gapStart {
            if chunk.timestamp - gapStart > Self.maximumZeroFill {
                restarted = false
                deliveredUntil = chunk.timestamp + (chunk.durationSeconds ?? 0)
                return rollOver(gap: chunk.timestamp - gapStart)
            }
            let frames = Int(((chunk.timestamp - gapStart) * chunk.format.sampleRate).rounded())
            send(VoiceAudioChunk(data: Data(count: frames * 2 * chunk.format.channels),
                                 format: chunk.format, timestamp: gapStart))
        }
        restarted = false
        deliveredUntil = chunk.timestamp + (chunk.durationSeconds ?? 0)

        let echo = overlapsSelfAudio(chunk)
        if echo != zeroFilling {
            zeroFilling = echo
            diagnostics.record(echo ? "self_audio.zero_fill.began" : "self_audio.zero_fill.ended")
        }
        send(echo ? VoiceAudioChunk(data: Data(count: chunk.data.count),
                                    format: chunk.format, timestamp: chunk.timestamp)
                  : chunk)
    }

    private func send(_ chunk: VoiceAudioChunk) {
        guard let session else { return }
        if origin == nil { origin = chunk.timestamp }
        session.sendAudio(chunk)
    }

    /// A capture gap too long to send as zeros (another app held the microphone):
    /// the service's audio clock cannot follow the capture clock across it, so the session rolls
    /// over as at its expiry (D4), and the kernel clears who is speaking and reopens. Audio until
    /// the new session is lost, as at an expiry. With no session, a reopen is already coming.
    private func rollOver(gap: TimeInterval) {
        guard let session else { return }
        diagnostics.record("capture.gap_rollover", fields: ["gap_ms": "\(Int((gap * 1000).rounded()))"])
        session.close()
        self.session = nil
        releaseStranded()
        continuation.yield(.sessionExpired)
    }

    /// Whether any part of the block falls inside TapQ's span plus the hysteresis.
    private func overlapsSelfAudio(_ chunk: VoiceAudioChunk) -> Bool {
        let span = selfAudio()
        guard let start = span.startedAt else { return false }
        let end = span.stoppedAt.map { $0 + hysteresis } ?? .infinity
        return chunk.timestamp <= end && chunk.timestamp + (chunk.durationSeconds ?? 0) > start
    }

    /// D7: a configuration change reopens the capture on the new default device.
    private func captureFailed(_ failure: AudioDeviceFailure) {
        guard !ended else { return }
        switch failure {
        case .configurationChanged:
            capture.stop()
            do {
                try startCapture()
            } catch {
                return fail("the microphone could not be reopened after a route change: \(error)")
            }
            restarted = true
            diagnostics.record("capture.reopened")
        case .unavailable(let reason):
            fail("the microphone is unavailable: \(reason)")
        }
    }

    private func fail(_ reason: String) {
        guard !ended else { return }
        diagnostics.record("speech_input.failed", level: .warning, fields: ["detail": reason])
        continuation.yield(.failed(reason: reason))
        close()
    }
}
