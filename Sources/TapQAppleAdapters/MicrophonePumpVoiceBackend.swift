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
/// through the pump's own event path, so `FailThroughVoiceBackend` fails over to Apple
/// exactly as for any network death.
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
@MainActor public final class MicrophonePumpVoiceBackend: VoiceBackend {
    public var capabilities: VoiceBackendCapabilities { inner.capabilities }

    private let inner: any VoiceBackend
    private let wireFormat: VoiceAudioFormat
    private let makeAudioSource: @MainActor () -> any VoiceAudioSource
    private let diagnostics: TapQDiagnosticEmitter

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
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.inner = inner
        self.wireFormat = format
        self.makeAudioSource = {
            AVAudioEngineVoiceAudioSource(voiceProcessingEnabled: voiceProcessingEnabled)
        }
        self.diagnostics = TapQDiagnosticEmitter(category: "MicPump", sink: diagnosticSink)
    }

    /// Test seam: fakes exercise the pump pipeline without touching audio hardware.
    init(
        inner: any VoiceBackend,
        format: VoiceAudioFormat = .pcm16Mono24k,
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.inner = inner
        self.wireFormat = format
        self.makeAudioSource = makeAudioSource
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
        // microphone here would leave it dangling: teardown would skip the primary because
        // the FailThrough wrapper already closed it, and the real mic stays open until
        // process exit.
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

    public func cancelResponse() {
        inner.cancelResponse()
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
            // Mic failure mid-turn: relay a session failure so FailThrough can fail over.
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
                let chunk = VoiceAudioChunk(
                    data: block.data,
                    format: self.wireFormat,
                    timestamp: block.timestamp
                )
                self.inner.sendAudio(chunk)
            }
        }
    }

    private func stopMicrophone() {
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
    /// the pump's own event relay, so FailThroughVoiceBackend fails over to Apple.
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
