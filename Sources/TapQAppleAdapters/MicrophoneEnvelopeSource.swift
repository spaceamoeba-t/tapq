import Foundation
import TapQContracts
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Darwin)
import Darwin
#endif

#if canImport(AVFoundation)
/// Converts audio host times to the seconds-since-boot clock CoreMotion stamps head
/// motion with. Both clocks derive from `mach_absolute_time`, so one anchor pair captured
/// at the start of a recording — the host tick and the uptime read back to back — pins
/// them together for the whole session.
///
/// Pure and constant-injected on purpose: clock alignment is the failure mode that makes
/// a capture study quietly worthless, so it must be checkable without audio hardware.
public struct AudioClockAnchor: Equatable, Sendable {
    public let hostTime: UInt64
    public let uptime: TimeInterval
    public let timebaseNumerator: UInt32
    public let timebaseDenominator: UInt32

    public init(
        hostTime: UInt64,
        uptime: TimeInterval,
        timebaseNumerator: UInt32,
        timebaseDenominator: UInt32
    ) {
        self.hostTime = hostTime
        self.uptime = uptime
        self.timebaseNumerator = timebaseNumerator
        self.timebaseDenominator = max(timebaseDenominator, 1)
    }

    /// Reads the current host tick, uptime, and timebase as one anchor.
    public static func current() -> AudioClockAnchor {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // Host tick first: the pair is read back to back, and the residual skew between
        // the two reads is smaller than one audio block either way.
        let hostTime = mach_absolute_time()
        let uptime = ProcessInfo.processInfo.systemUptime
        return AudioClockAnchor(
            hostTime: hostTime,
            uptime: uptime,
            timebaseNumerator: timebase.numer == 0 ? 1 : timebase.numer,
            timebaseDenominator: timebase.denom == 0 ? 1 : timebase.denom
        )
    }

    /// Host ticks before the anchor are legitimate — a block can be timestamped at the
    /// moment its first frame was sampled, slightly ahead of the anchor read — so the
    /// difference is taken in signed arithmetic rather than on `UInt64`.
    public func uptime(forHostTime hostTime: UInt64) -> TimeInterval {
        let ticks = Double(hostTime) - Double(self.hostTime)
        let nanoseconds = ticks * Double(timebaseNumerator) / Double(timebaseDenominator)
        return uptime + nanoseconds / 1_000_000_000
    }
}

/// The hardware input format, learned from the first block the tap delivers rather than
/// asked of the engine: the tap installs with a nil format and follows the live route, so
/// the block itself is the only honest description of what is being recorded.
public struct MicrophoneEnvelopeTrack: Equatable, Sendable {
    public let sampleRate: Double
    public let blockFrames: Int
}

/// One audio block's loudness, already on the motion clock. No audio is retained.
public struct MicrophoneEnvelopeBlock: Equatable, Sendable {
    public let timestamp: TimeInterval
    public let rms: Double
    public let peak: Double
}

public struct MicrophoneEnvelopeFailure: Error, Equatable, CustomStringConvertible {
    public enum Stage: String, Sendable {
        case inputFormat = "input_format"
        case audioSetup = "audio_setup"
        case engineStart = "engine_start"
        case audioTeardown = "audio_teardown"
        case configurationChanged = "configuration_changed"
        case alreadyRunning = "already_running"
    }

    public let stage: Stage
    public let detail: String

    public var description: String {
        "\(stage.rawValue): \(detail)"
    }
}

/// Microphone arm of the capture study: opens one input window and reduces every audio
/// block to an RMS/peak pair stamped on the motion stream's clock.
///
/// It reuses `VoiceAudioSourceController` rather than opening a second `AVAudioEngine`
/// path, so route-change invalidation, NSException conversion, and generation-counted
/// teardown all behave exactly as they do for a voice window.
///
/// Blocks cross from the realtime audio thread to the main actor through one buffering
/// `AsyncStream`. A `Task { @MainActor }` per block would be simpler and wrong: task
/// scheduling makes no ordering promise, and an envelope delivered out of order is worse
/// than no envelope at all. The reduction to two doubles happens inside the tap so
/// nothing is allocated or retained on the audio thread.
@MainActor public final class MicrophoneEnvelopeSource {
    private let controller: VoiceAudioSourceController
    private let anchorProvider: @Sendable () -> AudioClockAnchor
    private let diagnostics: TapQDiagnosticEmitter

    private var continuation: AsyncStream<RawBlock>.Continuation?
    private var consumer: Task<Void, Never>?
    private var running = false
    /// Invalidates blocks and route callbacks left over from an earlier window.
    private var sessionGeneration: UInt64 = 0

    private struct RawBlock: Sendable {
        let hostTime: UInt64
        let sampleRate: Double
        let frames: Int
        let rms: Double
        let peak: Double
    }

    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        let diagnostics = TapQDiagnosticEmitter(
            category: "MicEnvelope", sink: diagnosticSink)
        self.diagnostics = diagnostics
        self.anchorProvider = { AudioClockAnchor.current() }
        self.controller = VoiceAudioSourceController {
            let source = AVAudioEngineVoiceAudioSource()
            // Teardown errors are dropped on the voice path, where the window is over
            // regardless. A study session wants them: a failed engine stop is the first
            // sign that the next recording will start on a wedged route.
            source.onTeardownFailure = { failure in
                diagnostics.record(
                    "capture.teardown_failed",
                    level: .warning,
                    fields: ["stage": failure.stage.rawValue, "error": failure.detail]
                )
            }
            return source
        }
    }

    /// Test seam: fakes exercise the envelope pipeline without touching audio hardware.
    init(
        makeAudioSource: @escaping @MainActor () -> any VoiceAudioSource,
        anchorProvider: @escaping @Sendable () -> AudioClockAnchor,
        diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()
    ) {
        self.controller = VoiceAudioSourceController(makeSource: makeAudioSource)
        self.anchorProvider = anchorProvider
        self.diagnostics = TapQDiagnosticEmitter(
            category: "MicEnvelope", sink: diagnosticSink)
    }

    public var isRunning: Bool { running }

    /// Opens the microphone. `onTrack` fires once, with the first block, before any
    /// `onBlock`. Throws `MicrophoneEnvelopeFailure` if the input never opened.
    public func start(
        onTrack: @escaping @MainActor (MicrophoneEnvelopeTrack) -> Void,
        onBlock: @escaping @MainActor (MicrophoneEnvelopeBlock) -> Void,
        onInvalidation: @escaping @MainActor (MicrophoneEnvelopeFailure) -> Void
    ) throws {
        guard !running else {
            throw MicrophoneEnvelopeFailure(
                stage: .alreadyRunning, detail: "an envelope capture is already open")
        }

        sessionGeneration &+= 1
        let generation = sessionGeneration
        let anchor = anchorProvider()
        let (stream, continuation) = AsyncStream<RawBlock>.makeStream(
            bufferingPolicy: .unbounded)
        self.continuation = continuation

        let result = controller.start(
            onBuffer: { buffer, time in
                guard let envelope = Self.envelope(of: buffer) else { return }
                let hostTime = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                continuation.yield(RawBlock(
                    hostTime: hostTime,
                    sampleRate: buffer.format.sampleRate,
                    frames: Int(buffer.frameLength),
                    rms: envelope.rms,
                    peak: envelope.peak
                ))
            },
            onInvalidation: { [weak self] failure in
                self?.invalidated(failure, generation: generation, handler: onInvalidation)
            }
        )

        switch result {
        case .started:
            break
        case .alreadyRunning:
            teardown(expectedGeneration: generation)
            throw MicrophoneEnvelopeFailure(
                stage: .alreadyRunning, detail: "the audio source is already open")
        case .failed(let error):
            teardown(expectedGeneration: generation)
            throw Self.failure(from: error)
        }

        running = true
        consumer = Task { @MainActor [weak self] in
            var reportedTrack = false
            for await block in stream {
                guard let self, self.sessionGeneration == generation else { return }
                if !reportedTrack {
                    reportedTrack = true
                    onTrack(MicrophoneEnvelopeTrack(
                        sampleRate: block.sampleRate, blockFrames: block.frames))
                }
                onBlock(MicrophoneEnvelopeBlock(
                    timestamp: anchor.uptime(forHostTime: block.hostTime),
                    rms: block.rms,
                    peak: block.peak
                ))
            }
        }
        diagnostics.record("capture.started")
    }

    public func stop() {
        guard running else { return }
        teardown(expectedGeneration: sessionGeneration)
    }

    /// Sum-of-squares and peak over every channel of one block. Returns nil for a format
    /// the tap cannot reduce (non-float or empty), which the caller drops silently rather
    /// than guessing a loudness for.
    static func envelope(of buffer: AVAudioPCMBuffer) -> (rms: Double, peak: Double)? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, frames > 0, channels > 0 else {
            return nil
        }
        let stride = buffer.stride
        var sumOfSquares = 0.0
        var peak = 0.0
        for channel in 0..<channels {
            let samples = data[channel]
            for frame in 0..<frames {
                let value = Double(samples[frame * stride])
                sumOfSquares += value * value
                peak = max(peak, abs(value))
            }
        }
        return ((sumOfSquares / Double(frames * channels)).squareRoot(), peak)
    }

    private func invalidated(
        _ failure: VoiceAudioSourceFailure,
        generation: UInt64,
        handler: @MainActor (MicrophoneEnvelopeFailure) -> Void
    ) {
        guard running, sessionGeneration == generation else { return }
        let mapped = Self.failure(from: failure)
        diagnostics.record(
            "capture.invalidated",
            level: .warning,
            fields: ["stage": mapped.stage.rawValue, "error": mapped.detail]
        )
        teardown(expectedGeneration: generation)
        handler(mapped)
    }

    private func teardown(expectedGeneration: UInt64) {
        guard expectedGeneration == sessionGeneration else { return }
        sessionGeneration &+= 1
        running = false
        continuation?.finish()
        continuation = nil
        consumer?.cancel()
        consumer = nil
        controller.stop()
    }

    private static func failure(from error: any Error) -> MicrophoneEnvelopeFailure {
        guard let failure = error as? VoiceAudioSourceFailure else {
            return MicrophoneEnvelopeFailure(
                stage: .audioSetup, detail: String(describing: error))
        }
        let stage = MicrophoneEnvelopeFailure.Stage(rawValue: failure.stage.rawValue)
            ?? .audioSetup
        return MicrophoneEnvelopeFailure(stage: stage, detail: failure.detail)
    }
}
#endif
