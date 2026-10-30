import Foundation
import TapQContracts
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(macOS)
// Only for the name of the system default input device, and only for the log. Nothing in
// this file routes, selects, or configures a device through CoreAudio — the engine opens
// whatever the system default is, exactly as it always has, and this reads back which one
// that was. Added 2026-09-20: a twelve-minute recording came back as fragments because the
// microphone in use was not the one anybody assumed, and no line of the record said which
// device or which format had been opened.
import CoreAudio
#endif

#if canImport(AVFoundation)
/// The microphone as wire-format PCM, with nothing behind it.
///
/// Open a source through `VoiceAudioSourceController`, convert every tap buffer from the
/// hardware's native format (typically 48 kHz float stereo) to the caller's wire format
/// (24 kHz PCM16 mono by default) on the tap thread, and hand the converted blocks to the
/// main actor **in order**. Transcription mode reads the `Block`s (with their level); the loop's
/// speech input reads it as `AudioCapturing`.
///
/// Blocks cross from the tap thread to the main actor through a single unbounded
/// `AsyncStream`, never through a `Task { @MainActor }` per buffer — task scheduling makes
/// no ordering promise, and interleaved audio is worse than no audio.
///
/// Each chunk is stamped with its first sample's capture instant,
/// `AVAudioTime.seconds(forHostTime:)` (07-9): the host-time clock, in seconds, which is
/// the clock `ProcessInfo.systemUptime` reads.
///
/// A capture is not a session: it opens and closes as often as its owner likes, and each
/// `start` builds a fresh `VoiceAudioSourceController`, because a source in production is
/// single-use — its `AVAudioEngine` cannot retain formats from an earlier audio route.
@MainActor public final class MicrophonePCMCapture {

    /// One converted block off the tap: the chunk exactly as it would go on the wire, plus
    /// the RMS computed where the float samples were still hot.
    ///
    /// The chunk is built on the tap thread rather than at delivery so that everything a
    /// block costs is paid once, in the place that already holds the samples.
    public struct Block: Sendable {
        public let chunk: VoiceAudioChunk
        public let rms: Double

        public init(chunk: VoiceAudioChunk, rms: Double) {
            self.chunk = chunk
            self.rms = rms
        }
    }

    /// How much audio one `capture.level` line covers.
    ///
    /// Thirty seconds: often enough that a room nobody can hear is named within the first
    /// minute, rare enough that an hour of recording costs 120 lines in a file that has to
    /// stay readable.
    nonisolated static let levelReportSeconds: Double = 30

    private let format: VoiceAudioFormat
    private let makeAudioSource: @MainActor () -> any VoiceAudioSource
    private let diagnostics: TapQDiagnosticEmitter

    private var controller: VoiceAudioSourceController?
    private var continuation: AsyncStream<Block>.Continuation?
    private var consumer: Task<Void, Never>?

    /// Invalidates stale tap-thread blocks and invalidation callbacks from a prior window.
    private var generation: UInt64 = 0

    /// Whether a microphone window is open. False before the first `start`, after `stop`,
    /// and after a `start` that threw.
    public var isCapturing: Bool { controller != nil }

    /// - Parameters:
    ///   - format: the wire format blocks are converted to. Default `.pcm16Mono24k`.
    ///   - diagnosticSink: the runtime's shared diagnostic sink.
    public init(
        format: VoiceAudioFormat = .pcm16Mono24k,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.format = format
        self.makeAudioSource = { AVAudioEngineVoiceAudioSource() }
        self.diagnostics = TapQDiagnosticEmitter(category: "MicCapture", sink: diagnosticSink)
    }

    /// Test seam: fakes exercise the conversion and hand-off without touching audio
    /// hardware.
    init(
        format: VoiceAudioFormat = .pcm16Mono24k,
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.format = format
        self.makeAudioSource = makeAudioSource
        self.diagnostics = TapQDiagnosticEmitter(category: "MicCapture", sink: diagnosticSink)
    }

    // MARK: - Lifecycle

    /// Opens the microphone and starts delivering converted blocks.
    ///
    /// `onBlock` runs on the main actor, once per block, in capture order. `onFailure` runs
    /// on the main actor when the source is invalidated mid-window — a route change, or the
    /// input device going away. The capture does not restart itself and does not decide what
    /// a dead microphone means; that is the owner's call.
    ///
    /// Throws the source's own start error when the window could not be opened at all. The
    /// capture is left stopped in that case, so a retry is an ordinary `start`. Starting an
    /// open capture is a caller bug.
    public func start(
        onBlock: @escaping @MainActor (Block) -> Void,
        onFailure: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
    ) throws {
        precondition(controller == nil, "the microphone is already open")

        generation &+= 1
        let generation = self.generation

        let controller = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.controller = controller

        // The converter is created lazily from the first buffer's format, since the tap
        // installs with a nil format and follows the live route.
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?

        // Operator observability, both owned by the tap thread and both cheap there.
        //
        // `capture.opened` is one line and fires once per window, at the first buffer,
        // because that is the first moment the input format exists — the tap installs with
        // a nil format and follows the live route.
        //
        // `capture.level` is the line that would have ended the 2026-09-20 diagnosis in a
        // second: the run that came back as fragments was peaking at −37 dBFS, which is an
        // RMS around 0.014, and nothing said so. Counted in delivered frames rather than
        // against a clock, so the number and the interval describe the same audio.
        var didReportOpen = false
        var levelPeak = 0.0
        var levelFrames = 0
        var totalFrames = 0

        let targetFormat = Self.avAudioFormat(for: format)
        if targetFormat == nil {
            // Without an output format every block is dropped for want of a converter, and
            // the window is silence that looks like a working microphone. Said once, here,
            // rather than per buffer on the realtime thread.
            diagnostics.record("capture.format_unsupported", level: .warning, fields: [
                "sample_rate": "\(Int(format.sampleRate))",
                "channels": "\(format.channels)",
                "pcm16": "\(format.pcm16)",
            ])
        }

        let (stream, continuation) = AsyncStream<Block>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation

        // Read here rather than on the tap thread: the engine opens the system default
        // input, so the answer is already settled by the time the first buffer arrives, and
        // a CoreAudio round trip does not belong in a realtime callback.
        let device = Self.defaultInputDeviceName()

        let result = controller.start(
            onBuffer: { [format, diagnostics] buffer, time in
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

                if !didReportOpen {
                    didReportOpen = true
                    diagnostics.record("capture.opened", fields: [
                        "device": device,
                        "input_rate": "\(Int(inputFormat.sampleRate))",
                        "input_channels": "\(inputFormat.channelCount)",
                        "output_rate": "\(Int(format.sampleRate))",
                        "output_channels": "\(format.channels)",
                    ])
                }

                // Compute RMS on the tap thread where the samples are already hot.
                let rms = Self.computeRMS(buffer)
                let timestamp = time.isHostTimeValid
                    ? AVAudioTime.seconds(forHostTime: time.hostTime)
                    : ProcessInfo.processInfo.systemUptime

                // Convert to the wire format.
                guard let converter, let target = targetFormat else {
                    // No usable converter: drop the block silently. This can happen if the
                    // hardware format is truly incompatible.
                    return
                }

                let outputFrameCount = AVAudioFrameCount(
                    Double(frames) * format.sampleRate / inputFormat.sampleRate
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

                let delivered = Int(outputBuffer.frameLength)
                levelPeak = max(levelPeak, rms)
                levelFrames += delivered
                totalFrames += delivered
                let interval = Int(format.sampleRate * Self.levelReportSeconds)
                if interval > 0, levelFrames >= interval {
                    diagnostics.record("capture.level", fields: [
                        "rms_peak": String(format: "%.4f", levelPeak),
                        "seconds": "\(totalFrames / max(Int(format.sampleRate), 1))",
                    ])
                    levelPeak = 0
                    levelFrames = 0
                }

                continuation.yield(Block(
                    chunk: VoiceAudioChunk(data: data, format: format, timestamp: timestamp),
                    rms: rms
                ))
            },
            onInvalidation: { [weak self] failure in
                guard let self, self.generation == generation else { return }
                onFailure(failure)
            }
        )

        if case .failed(let error) = result {
            // The controller has already torn its own source down; this clears the stream
            // and the handle, so `isCapturing` tells the truth and a retry is just `start`.
            stop()
            throw error
        }

        // Consumer task: reads converted blocks in order and hands them to the owner.
        consumer = Task { @MainActor [weak self] in
            for await block in stream {
                guard let self, self.generation == generation, self.isCapturing else { return }
                onBlock(block)
            }
        }
    }

    /// Closes the microphone window. Idempotent, and safe to call from inside `onFailure`.
    public func stop() {
        generation &+= 1
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
        controller?.stop()
        controller = nil
    }

    // MARK: - Which microphone

    /// The name of the system default input device, or `"unknown"`.
    ///
    /// Never throws and never traps: this is a log field, and a recording must not be lost to
    /// a CoreAudio call that did not answer. Every failure — no default device, a device
    /// with no name, a platform with no CoreAudio at all — is the same one word.
    ///
    /// It names the *default* input, which is what `AVAudioEngine` opens; the day this file
    /// grows a `--input-device` it will have to name the device actually opened instead.
    nonisolated static func defaultInputDeviceName() -> String {
        #if os(macOS)
        guard let device = DefaultInputDevice.id() else { return "unknown" }
        return DefaultInputDevice.name(of: device)
        #else
        return "unknown"
        #endif
    }

    // MARK: - Audio conversion helpers

    /// Creates an `AVAudioFormat` matching the wire format for use as the converter's output.
    private static func avAudioFormat(for format: VoiceAudioFormat) -> AVAudioFormat? {
        guard format.pcm16 else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        )
    }

    /// Raw PCM16 bytes from a converted buffer, which `avAudioFormat(for:)` makes
    /// interleaved: one contiguous run of samples.
    static func extractPCM16Data(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let int16Data = buffer.int16ChannelData, frames > 0, channels > 0 else {
            return Data()
        }
        return Data(bytes: int16Data[0], count: frames * channels * MemoryLayout<Int16>.size)
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

extension MicrophonePCMCapture: AudioCapturing {
    /// The capture as speech input reads it: chunks only, and the source's failure
    /// classified. A start the source refuses throws, as above.
    public func start(onBlock: @escaping @MainActor (VoiceAudioChunk) -> Void,
                      onFailure: @escaping @MainActor (AudioDeviceFailure) -> Void) throws {
        try start(onBlock: { (block: Block) in onBlock(block.chunk) },
                  onFailure: { (failure: VoiceAudioSourceFailure) in
                      onFailure(Self.deviceFailure(failure))
                  })
    }

    /// An `AVAudioEngineConfigurationChange` is the route moving, which the owner answers by
    /// reopening (D7); every other invalidation is a microphone that is gone.
    nonisolated static func deviceFailure(_ failure: VoiceAudioSourceFailure) -> AudioDeviceFailure {
        failure.stage == .configurationChanged
            ? .configurationChanged
            : .unavailable(failure.description)
    }
}
#endif
