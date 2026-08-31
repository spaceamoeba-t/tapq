import Foundation
import TapQContracts
#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(AVFoundation)
/// A `VoiceBackend` wrapper that owns the microphone for a pipe backend.
///
/// The gap this fills: `OpenAIRealtimeVoiceBackend` is a pure pipe — it has no mic of its
/// own, and nothing in the M1 composition called `sendAudio`. Consequently, a user turn
/// opened on the OpenAI path produced zero audio and no transcript could ever arrive.
///
/// The pump opens the microphone on `beginUserTurn`, converts buffers from the hardware's
/// native format (typically 48 kHz float stereo) to the pipe's wire format (24 kHz PCM16
/// mono by default), and streams them through `inner.sendAudio`. The mic closes on
/// `endUserTurn`, before the inner commit — matching `AppleVoiceBackend.swift:195-207`
/// ordering, where the hardware is silenced before the transcript is finalized.
///
/// Route-change invalidation mid-turn closes the mic and relays a synthetic session failure
/// through the pump's own event path, so it reaches `VoiceBrokenState` exactly as any
/// network death does — and takes hands-free voice down for the run with it.
///
/// Audio crosses from the realtime tap thread to the main actor through one ordered
/// buffering `AsyncStream` — the pattern `MicrophoneEnvelopeSource` already proves safe.
/// A `Task { @MainActor }` per buffer would be simpler and wrong: task scheduling makes
/// no ordering promise, and interleaved audio is worse than no audio.
///
/// Two invariants:
///
/// - **The microphone opens in `beginUserTurn` and closes in `endUserTurn`**, never in
///   `open`. A session can sit open between windows without the mic being live — the
///   "never always-on" guarantee.
/// - **The pump never ends a turn.** It delivers audio; only TapQ decides when the turn
///   is over.
///
/// ## The one thing it refuses to carry
///
/// On the voice-only path — no AirPods, so no wearer turn signal and the backend's own VAD
/// deciding where sentences end — TapQ's answers play out of the Mac's speaker into this
/// microphone. Captured while that is sounding, they are uploaded as the wearer's audio,
/// transcribed as the wearer's words, and endpointed as the wearer's turn; on hardware
/// (2026-08-30) that had TapQ answering its own last sentence back to the wearer.
///
/// So while `selfAudioActivity` says TapQ's voice is in the room (plus the echo hysteresis)
/// and native turn detection is on, captured buffers are dropped rather than sent. Nothing
/// is lost by it: barge-in on that path is IMU-driven and the IMU is precisely what is
/// missing, so wearer speech over TapQ's playback was never going to interrupt anything.
///
/// It is deliberately inert on the AirPods path (`setNativeTurnDetection(false)`), where the
/// wearer's own turn signal is live, barge-in works, and audio does not leak from headphones
/// into the microphone in the first place.
@MainActor public final class MicrophonePumpVoiceBackend: VoiceBackend {
    public var capabilities: VoiceBackendCapabilities { inner.capabilities }

    /// Forwarded rather than defaulted: taking the `nil` default would tell the composition
    /// above that this peer names no responses, and cost it the cross-check that keeps a
    /// suppression mark from firing on the wrong one.
    public var activeResponseIdentity: String? { inner.activeResponseIdentity }

    private let inner: any VoiceBackend
    private let wireFormat: VoiceAudioFormat
    private let makeAudioSource: @MainActor () -> any VoiceAudioSource
    private let diagnostics: TapQDiagnosticEmitter

    /// What TapQ's own voice is doing in the room, or `nil` where nothing renders it.
    ///
    /// Composition wires this to the audio player. Left unwired — every test that does not
    /// ask for it, and any host with no backend playback — the gate never closes and this
    /// pump sends exactly what it has always sent.
    public var selfAudioActivity: (@MainActor () -> VoiceSelfAudioActivity)?

    /// How long after TapQ's audio drains the microphone is still assumed to be hearing it.
    private let selfAudioHysteresis: TimeInterval

    /// The clock the audibility question is asked on. The same one the player stamps its own
    /// transitions with, or the comparison would be between two unrelated timelines.
    private let monotonicNow: @MainActor () -> TimeInterval

    /// Whether the backend's own VAD owns turn ends — which on this composition is the same
    /// question as "does this run have a wearer turn signal", and therefore the same question
    /// as "can TapQ's speaker reach this microphone". Tracked from the call that passes
    /// through rather than asked of the inner backend: the pump is the layer that has to act
    /// on it, and a mode it learned by reaching downwards would be a mode it could disagree
    /// with.
    private var nativeTurnDetectionOn = false

    /// Captured blocks dropped as TapQ's own voice since the last one that got through, and
    /// their duration. Counted rather than logged per block: buffers arrive every few
    /// milliseconds, and one line per buffer would bury the run's log in the middle of the
    /// event an operator is reading it for.
    private var suppressedBlocks = 0
    private var suppressedBytes = 0

    private var audioController: VoiceAudioSourceController?
    private var callerOnEvent: (@MainActor (VoiceBackendEvent) -> Void)?

    private var continuation: AsyncStream<RawAudioBlock>.Continuation?
    private var consumer: Task<Void, Never>?

    /// Invalidates stale tap-thread blocks and route callbacks from a prior turn.
    private var turnGeneration: UInt64 = 0
    /// Guards the session-level relay: events from the inner backend are valid only while
    /// the session identity matches.
    private var sessionGeneration: UInt64 = 0
    private var turnActive = false

    /// Per-buffer RMS, computed on the tap thread where the samples are already hot.
    /// Inert hook for a possible acoustic-silence endpoint fallback; costs a few lines now,
    /// avoids reopening the realtime-thread code later.
    public var onInputLevel: ((Double) -> Void)?

    /// Audio block reduced on the tap thread: raw PCM bytes already converted, plus the
    /// RMS for the input-level hook.
    private struct RawAudioBlock: Sendable {
        let data: Data
        let timestamp: TimeInterval
        let rms: Double
    }

    /// - Parameters:
    ///   - inner: the pipe backend (e.g. `OpenAIRealtimeVoiceBackend`) that receives audio.
    ///   - format: the wire format the inner backend speaks. Default `.pcm16Mono24k`.
    ///   - makeAudioSource: factory for the microphone source. Production: `AVAudioEngineVoiceAudioSource`.
    ///   - voiceProcessingEnabled: experimental (RD4). Turns Apple's echo cancellation and
    ///     AGC on for the pump's input node. `false` — the default and every run without
    ///     `--voice-processing` — builds exactly the source this pump always built.
    ///   - diagnosticSink: the runtime's shared diagnostic sink.
    public init(
        inner: any VoiceBackend,
        format: VoiceAudioFormat = .pcm16Mono24k,
        voiceProcessingEnabled: Bool = false,
        selfAudioHysteresis: TimeInterval = VoiceSelfAudioEcho.resolvedHysteresis(),
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.inner = inner
        self.wireFormat = format
        self.makeAudioSource = {
            AVAudioEngineVoiceAudioSource(voiceProcessingEnabled: voiceProcessingEnabled)
        }
        self.selfAudioHysteresis = selfAudioHysteresis
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        self.diagnostics = TapQDiagnosticEmitter(category: "MicPump", sink: diagnosticSink)
    }

    /// Test seam: fakes exercise the pump pipeline without touching audio hardware.
    init(
        inner: any VoiceBackend,
        format: VoiceAudioFormat = .pcm16Mono24k,
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        selfAudioHysteresis: TimeInterval = VoiceSelfAudioEcho.defaultHysteresis,
        monotonicNow: @escaping @MainActor () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.inner = inner
        self.wireFormat = format
        self.makeAudioSource = makeAudioSource
        self.selfAudioHysteresis = selfAudioHysteresis
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "MicPump", sink: diagnosticSink)
    }

    var isTurnActiveForTesting: Bool { turnActive }

    // MARK: - VoiceBackend forwarding

    public func open(onEvent: @escaping @MainActor (VoiceBackendEvent) -> Void) async throws {
        sessionGeneration &+= 1
        let sessGen = sessionGeneration
        callerOnEvent = onEvent
        try await inner.open { [weak self] event in
            self?.relayEvent(event, sessionGeneration: sessGen)
        }
    }

    public func close() {
        stopMicrophone()
        sessionGeneration &+= 1
        callerOnEvent = nil
        inner.close()
    }

    public func beginUserTurn() {
        let sessGen = sessionGeneration
        inner.beginUserTurn()
        // If the inner backend synchronously failed the session (e.g. a state-machine
        // violation that triggers failSession -> relayEvent(.sessionFailed) -> pump.close()),
        // the session generation has changed and callerOnEvent is nil. Opening the
        // microphone here would leave it dangling: teardown would skip a pipe the wrapper
        // above has already closed, and the real mic stays open until process exit.
        guard sessionGeneration == sessGen, callerOnEvent != nil else { return }
        turnActive = true
        openMicrophone()
    }

    @discardableResult
    public func endUserTurn(expectingResponse: Bool) -> Bool {
        // The mic closes before the inner commit, matching AppleVoiceBackend ordering:
        // hardware is silenced before the transcript is finalized.
        stopMicrophone()
        turnActive = false
        return inner.endUserTurn(expectingResponse: expectingResponse)
    }

    public func sendAudio(_ chunk: VoiceAudioChunk) {
        // The pump owns the mic for this backend; externally pushed audio is unexpected but
        // forwarded to the inner backend in case a composition above also feeds audio.
        inner.sendAudio(chunk)
    }

    public func requestResponse(text: String) {
        inner.requestResponse(text: text)
    }

    /// Forwarded explicitly rather than left to the protocol's default, which would send a
    /// scripted sentence down `requestResponse` and lose the inner adapter's verbatim
    /// channel. The pump owns the microphone and has no say in what is spoken.
    public func requestScriptedSpeech(text: String) {
        inner.requestScriptedSpeech(text: text)
    }

    public func cancelResponse() {
        inner.cancelResponse()
    }

    /// Forwarded verbatim: the mode is the inner pipe's business, and the pump has no
    /// opinion about who decides where a sentence ended.
    ///
    /// What matters here is what the pump does *not* do in response to the inner backend's
    /// native commits. A commit ends an utterance, not the turn, so the microphone stays
    /// open — the wearer may not be finished, and a pump that closed the mic on the first
    /// VAD commit would make every second sentence in a window inaudible. The mic still
    /// closes exactly where it always did: in `endUserTurn`, and nowhere else.
    public func setNativeTurnDetection(_ enabled: Bool) {
        nativeTurnDetectionOn = enabled
        inner.setNativeTurnDetection(enabled)
    }

    /// The three tool-path calls, forwarded explicitly for the reason
    /// `requestScriptedSpeech` is: the protocol's defaults are no-ops, and a pump that
    /// inherited them would leave the inner adapter's tools undeclared, its instructions
    /// empty, and every tool call it relayed upward unanswered — a microphone that hears the
    /// wearer perfectly and can do nothing about what they said. The pump owns audio; it has
    /// no opinion about intent.
    public func declareTools(_ tools: [VoiceToolDeclaration]) {
        inner.declareTools(tools)
    }

    public func updateInstructions(_ instructions: String) {
        inner.updateInstructions(instructions)
    }

    public func sendToolResult(callID: String, output: String) {
        inner.sendToolResult(callID: callID, output: output)
    }

    @discardableResult
    public func requestModelTurn() -> Bool {
        inner.requestModelTurn()
    }

    // MARK: - Event relay

    private func relayEvent(_ event: VoiceBackendEvent, sessionGeneration sessGen: UInt64) {
        guard self.sessionGeneration == sessGen else { return }
        if case .sessionFailed = event {
            // The inner backend died: stop the mic immediately so we do not pump into a
            // dead pipe, then forward the failure. Also bump the session generation and
            // clear the callback — beginUserTurn checks this to detect a session that died
            // synchronously during inner.beginUserTurn(), and no further events are valid
            // after sessionFailed anyway.
            stopMicrophone()
            turnActive = false
            let callback = callerOnEvent
            sessionGeneration &+= 1
            callerOnEvent = nil
            callback?(event)
            return
        }
        callerOnEvent?(event)
    }

    // MARK: - Microphone lifecycle

    private func openMicrophone() {
        turnGeneration &+= 1
        let generation = turnGeneration
        let sessGen = sessionGeneration

        let controller = VoiceAudioSourceController(makeSource: makeAudioSource)
        audioController = controller

        // The converter is created lazily from the first buffer's format, since the tap
        // installs with a nil format and follows the live route.
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?

        let targetFormat = avAudioFormat(for: wireFormat)

        let (stream, continuation) = AsyncStream<RawAudioBlock>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation

        let result = controller.start(
            onBuffer: { [wireFormat] buffer, time in
                // Realtime audio thread: no allocations beyond what AVAudioConverter needs,
                // no main-actor hops, no locks on shared state.
                let inputFormat = buffer.format
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return }

                // Recreate the converter if the input format changed (route sample-rate
                // change). The comparison is by pointer identity first (cheap), then by
                // value if the pointer differs.
                if converter == nil || inputFormat != converterInputFormat {
                    if let target = targetFormat {
                        converter = AVAudioConverter(from: inputFormat, to: target)
                    }
                    converterInputFormat = inputFormat
                }

                // Compute RMS on the tap thread where the samples are already hot.
                let rms = Self.computeRMS(buffer)
                let timestamp = time.isHostTimeValid
                    ? TimeInterval(time.hostTime) / 1_000_000_000
                    : ProcessInfo.processInfo.systemUptime

                // Convert to the wire format.
                guard let converter, let target = targetFormat else {
                    // No usable converter: drop the block silently. This can happen if the
                    // hardware format is truly incompatible.
                    return
                }

                let outputFrameCount = AVAudioFrameCount(
                    Double(frames) * wireFormat.sampleRate / inputFormat.sampleRate
                )
                guard outputFrameCount > 0 else { return }
                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: target,
                    frameCapacity: outputFrameCount
                ) else { return }

                var error: NSError?
                // One-shot: AVAudioConverter may call the input block more than
                // once per convert() call (SRC priming pulls twice on the first
                // buffer after converter creation). Returning .haveData every
                // time duplicates the tap buffer into the output stream.
                var inputConsumed = false
                let status = converter.convert(to: outputBuffer, error: &error) { _, status in
                    if inputConsumed {
                        status.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    status.pointee = .haveData
                    return buffer
                }
                guard status != .error, outputBuffer.frameLength > 0 else { return }

                let data = Self.extractPCM16Data(from: outputBuffer)
                guard !data.isEmpty else { return }

                continuation.yield(RawAudioBlock(
                    data: data,
                    timestamp: timestamp,
                    rms: rms
                ))
            },
            onInvalidation: { [weak self] failure in
                self?.microphoneInvalidated(failure, generation: generation,
                                            sessionGeneration: sessGen)
            }
        )

        switch result {
        case .started:
            diagnostics.record("mic.opened")
        case .alreadyRunning:
            diagnostics.record("mic.open_skipped", fields: ["reason": "already_running"])
            return
        case .failed(let error):
            diagnostics.record("mic.open_failed", level: .warning,
                               fields: ["error": String(describing: error)])
            // Mic failure mid-turn: relay a session failure, which ends the run's voice.
            micFailedSession(sessionGeneration: sessGen)
            return
        }

        // Consumer task: reads converted blocks in order and delivers to the inner backend.
        consumer = Task { @MainActor [weak self] in
            for await block in stream {
                guard let self,
                      self.turnGeneration == generation,
                      self.turnActive else { return }
                self.onInputLevel?(block.rms)
                // The level hook still sees every block: it reports what the microphone
                // heard, and what the microphone heard while TapQ was speaking is TapQ.
                // Only the pipe is gated.
                guard !self.dropAsSelfAudio(block) else { continue }
                let chunk = VoiceAudioChunk(
                    data: block.data,
                    format: self.wireFormat,
                    timestamp: block.timestamp
                )
                self.inner.sendAudio(chunk)
            }
        }
    }

    /// Whether this captured block is TapQ's own voice coming back, and must not be sent.
    ///
    /// Three conditions, all required. Native turn detection is on, so this is the path with
    /// no wearer turn signal and no barge-in to protect. A player is wired, so there is a
    /// voice that could be echoing at all. And TapQ's audio was in the room at this instant
    /// — sounding, or inside the hysteresis after it stopped, which is where the speaker's
    /// own output latency and the room's ring live.
    private func dropAsSelfAudio(_ block: RawAudioBlock) -> Bool {
        guard nativeTurnDetectionOn, let selfAudioActivity else {
            flushSelfAudioSuppression()
            return false
        }
        guard selfAudioActivity().wasAudible(at: monotonicNow(),
                                             hysteresis: selfAudioHysteresis) else {
            flushSelfAudioSuppression()
            return false
        }
        suppressedBlocks += 1
        suppressedBytes += block.data.count
        return true
    }

    /// Reports one stretch of dropped capture, once, when the gate opens again.
    private func flushSelfAudioSuppression() {
        guard suppressedBlocks > 0 else { return }
        let bytesPerFrame = max(1, 2 * wireFormat.channels)
        let milliseconds = Int(
            (Double(suppressedBytes / bytesPerFrame) / wireFormat.sampleRate * 1_000).rounded())
        diagnostics.record("mic.self_audio_suppressed", fields: [
            "blocks": "\(suppressedBlocks)",
            "ms": "\(milliseconds)",
        ])
        suppressedBlocks = 0
        suppressedBytes = 0
    }

    private func stopMicrophone() {
        // The turn is ending with the gate still closed on a stretch nobody will see the
        // other side of. Reported here so the log never silently loses the last one.
        flushSelfAudioSuppression()
        turnGeneration &+= 1
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
        audioController?.stop()
        audioController = nil
    }

    private func microphoneInvalidated(
        _ failure: VoiceAudioSourceFailure,
        generation: UInt64,
        sessionGeneration sessGen: UInt64
    ) {
        guard turnGeneration == generation else { return }
        diagnostics.record("mic.invalidated", level: .warning,
                           fields: ["stage": failure.stage.rawValue,
                                    "error": failure.detail])
        stopMicrophone()
        turnActive = false
        micFailedSession(sessionGeneration: sessGen)
    }

    /// Route change or mic failure: close the inner backend and emit sessionFailed through
    /// the pump's own event relay, which is what `VoiceBrokenState` latches the break on.
    private func micFailedSession(sessionGeneration sessGen: UInt64) {
        guard self.sessionGeneration == sessGen else { return }
        let callback = callerOnEvent
        inner.close()
        sessionGeneration &+= 1
        callerOnEvent = nil
        callback?(.sessionFailed(.network("microphone route changed or unavailable")))
    }

    // MARK: - Audio conversion helpers

    /// Creates an `AVAudioFormat` matching the wire format for use as the converter's output.
    private func avAudioFormat(for format: VoiceAudioFormat) -> AVAudioFormat? {
        guard format.pcm16 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        )
    }

    /// Extracts raw PCM16 bytes from a converted buffer.
    static func extractPCM16Data(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let int16Data = buffer.int16ChannelData, frames > 0, channels > 0 else {
            return Data()
        }
        // For interleaved int16, the data is contiguous.
        if buffer.format.isInterleaved {
            let byteCount = frames * channels * MemoryLayout<Int16>.size
            return Data(bytes: int16Data[0], count: byteCount)
        }
        // Non-interleaved: interleave manually.
        var result = Data(capacity: frames * channels * MemoryLayout<Int16>.size)
        for frame in 0..<frames {
            for channel in 0..<channels {
                var sample = int16Data[channel][frame]
                withUnsafeBytes(of: &sample) { result.append(contentsOf: $0) }
            }
        }
        return result
    }

    /// RMS over all channels of one float buffer. Returns 0 for non-float or empty buffers.
    static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, frames > 0, channels > 0 else { return 0 }
        let stride = buffer.stride
        var sumOfSquares = 0.0
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames {
                let value = Double(samples[frame * stride])
                sumOfSquares += value * value
            }
        }
        return (sumOfSquares / Double(frames * channels)).squareRoot()
    }
}
#endif
