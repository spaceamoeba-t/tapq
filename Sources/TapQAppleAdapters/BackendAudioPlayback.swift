import Foundation
import TapQContracts
#if canImport(AVFoundation)
import AVFoundation
import TapQAudioCaptureBridge
#endif

#if canImport(AVFoundation)
/// Internal protocol wrapping the three ObjC bridge functions for the playback engine.
///
/// Production uses `LiveAudioPlaybackScheduler`, which calls through to the
/// `TapQAudioPlaybackEngine*` ObjC boundary. Tests inject a `FakeScheduler` that records
/// calls and fires completions synchronously on the main actor, so no test emits audible
/// audio or touches real audio hardware.
///
/// The pattern mirrors `VoiceAudioSource` / `AVAudioEngineVoiceAudioSource`: the thin live
/// layer is untested (one line per method); all behavioral logic lives in `BackendAudioPlayback`
/// and is exercised through the fake.
@MainActor protocol AudioPlaybackScheduling: AnyObject {
    /// Starts the playback engine for the given PCM format.
    /// Returns false and describes the failure in `detail` on error.
    func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure>

    /// Schedules a buffer for playback with a completion handler.
    ///
    /// The scheduler is responsible for delivering the completion on the MainActor. In
    /// production (`LiveAudioPlaybackScheduler`) this means hopping from AVAudioEngine's
    /// internal thread via `Task { @MainActor }`. In tests (`FakeScheduler`) the completion
    /// fires synchronously on the main actor, so the state machine can be driven without
    /// async yields.
    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) -> Result<Void, AudioPlaybackSchedulerFailure>

    /// Stops and resets the engine. Best-effort and idempotent.
    func stop() -> Result<Void, AudioPlaybackSchedulerFailure>
}

struct AudioPlaybackSchedulerFailure: Error, Equatable, CustomStringConvertible {
    enum Stage: String {
        case playbackSetup = "playback_setup"
        case playbackEngineStart = "playback_engine_start"
        case playbackSchedule = "playback_schedule"
        case playbackTeardown = "playback_teardown"
    }

    let stage: Stage
    let detail: String

    var description: String {
        "\(stage.rawValue): \(detail)"
    }
}

/// Production scheduler that calls through to the ObjC exception-boundary functions.
@MainActor final class LiveAudioPlaybackScheduler: AudioPlaybackScheduling {
    private var engine: TapQAudioPlaybackEngine?

    func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure> {
        let playback = TapQAudioPlaybackEngine()
        var error: NSError?
        guard TapQAudioPlaybackEngineStart(playback, sampleRate, AVAudioChannelCount(channels), &error) else {
            return .failure(Self.failure(from: error, defaultStage: .playbackEngineStart))
        }
        self.engine = playback
        return .success(())
    }

    func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) -> Result<Void, AudioPlaybackSchedulerFailure> {
        guard let engine else {
            return .failure(AudioPlaybackSchedulerFailure(
                stage: .playbackSchedule,
                detail: "engine not started"
            ))
        }
        var error: NSError?
        // The ObjC bridge fires the block on an internal AVAudioEngine thread. Hop to the
        // MainActor here so BackendAudioPlayback never needs to think about threading.
        guard TapQAudioPlaybackEngineSchedule(engine, buffer, {
            Task { @MainActor in completion() }
        }, &error) else {
            return .failure(Self.failure(from: error, defaultStage: .playbackSchedule))
        }
        return .success(())
    }

    func stop() -> Result<Void, AudioPlaybackSchedulerFailure> {
        guard let engine else { return .success(()) }
        self.engine = nil
        var error: NSError?
        guard TapQAudioPlaybackEngineStop(engine, &error) else {
            return .failure(Self.failure(from: error, defaultStage: .playbackTeardown))
        }
        return .success(())
    }

    private static func failure(from error: NSError?, defaultStage: AudioPlaybackSchedulerFailure.Stage) -> AudioPlaybackSchedulerFailure {
        let stageName = error?.userInfo[TapQAudioPlaybackFailureStageKey] as? String
        let stage = AudioPlaybackSchedulerFailure.Stage(rawValue: stageName ?? "")
            ?? defaultStage
        return AudioPlaybackSchedulerFailure(
            stage: stage,
            detail: error?.localizedDescription ?? "audio playback failed"
        )
    }
}

/// The macOS implementation of `VoiceResponseAudioPlaying`: converts backend PCM16 audio
/// chunks into `AVAudioPCMBuffer`s and schedules them through an `AVAudioEngine` +
/// `AVAudioPlayerNode`.
///
/// ## Lifecycle
///
/// The engine is lazily started on the first `enqueue` of a response and stopped when the
/// response drains (no idle audio unit). Each response gets a fresh engine start — the cost
/// is negligible compared to the audio latency budget, and it avoids holding an output device
/// open between responses.
///
/// ## isPlaying invariant
///
/// `isPlaying` becomes `true` synchronously within the first `enqueue` call, before that
/// call returns. The mic gate (`CombinedSpeechActivity` -> `SpeechGatedVoice`) reads
/// `isPlaying` on every activity-change edge; making the flag rise inside `enqueue` closes
/// the race window to zero.
///
/// ## Fail-open
///
/// Any start/schedule failure or engine configuration change: drop audio for the rest of
/// the response, emit a `playback.unavailable` diagnostic, transition `isPlaying` -> `false`.
/// Transcripts and the window are unaffected (the provider keeps consuming events;
/// `CombinedSpeechActivity` just never sees busy). The next response attempts a fresh engine.
///
/// ## Generation-counted completions
///
/// Completions from `AVAudioPlayerNode` arrive on an internal queue. The Swift side hops to
/// `@MainActor` and checks a generation counter before touching shared state. A `stopAndFlush`
/// bumps the generation, so completions from flushed buffers are silently ignored — they
/// never produce a spurious `isPlaying` edge.
@MainActor public final class BackendAudioPlayback: VoiceResponseAudioPlaying {
    private let scheduler: AudioPlaybackScheduling
    private let diagnostics: TapQDiagnosticEmitter

    /// Number of scheduled buffers whose completion has not yet fired.
    private var outstandingBuffers: Int = 0
    /// True after `finishStream()` has been called for the current response.
    private var streamFinished = false
    /// Bumped on every `stopAndFlush` and on each fresh response start; completions from
    /// a prior generation are silently dropped.
    private var generation: UInt64 = 0
    /// True when the engine is running for the current response.
    private var engineRunning = false
    /// True when the current response has encountered a failure and all subsequent chunks
    /// should be dropped (fail-open: the response is silent, the window proceeds).
    private var failedForCurrentResponse = false

    public private(set) var isPlaying: Bool = false
    public var onPlayingChange: (@MainActor (Bool) -> Void)?

    /// Production initializer: uses the live ObjC bridge through `LiveAudioPlaybackScheduler`.
    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = LiveAudioPlaybackScheduler()
        self.diagnostics = TapQDiagnosticEmitter(category: "Playback", sink: diagnosticSink)
    }

    /// Test seam: injects a fake scheduler so tests exercise the full state machine without
    /// touching audio hardware.
    init(scheduler: AudioPlaybackScheduling,
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = scheduler
        self.diagnostics = TapQDiagnosticEmitter(category: "Playback", sink: diagnosticSink)
    }

    // MARK: - VoiceResponseAudioPlaying

    public func enqueue(_ chunk: VoiceAudioChunk) {
        guard !failedForCurrentResponse else { return }

        // Synchronous isPlaying invariant: rise BEFORE any audio reaches the hardware.
        if !isPlaying {
            // New response starting.
            streamFinished = false
            setPlaying(true)
        }

        // Lazily start the engine on the first chunk.
        if !engineRunning {
            let result = startEngine(for: chunk)
            guard case .success = result else {
                enterFailedState()
                return
            }
        }

        // Convert PCM16 data to an AVAudioPCMBuffer.
        guard let buffer = makeBuffer(from: chunk) else {
            diagnostics.record("playback.buffer_conversion_failed", level: .warning,
                               fields: ["dataSize": "\(chunk.data.count)",
                                         "sampleRate": "\(chunk.format.sampleRate)",
                                         "channels": "\(chunk.format.channels)"])
            // A single bad buffer does not fail the whole response; just skip it.
            return
        }

        // Schedule the buffer with a generation-guarded completion.
        let gen = generation
        outstandingBuffers += 1

        let result = scheduler.schedule(buffer) { [weak self] in
            // The scheduler delivers this on the MainActor (production: Task hop in
            // LiveAudioPlaybackScheduler; tests: synchronous call from FakeScheduler).
            self?.bufferCompleted(generation: gen)
        }

        if case .failure(let failure) = result {
            outstandingBuffers -= 1
            diagnostics.record("playback.schedule_failed", level: .warning,
                               fields: ["error": failure.description])
            enterFailedState()
        }
    }

    public func finishStream() {
        streamFinished = true
        checkDrain()
    }

    public func stopAndFlush() {
        generation &+= 1
        outstandingBuffers = 0
        streamFinished = false
        failedForCurrentResponse = false

        if engineRunning {
            let result = scheduler.stop()
            if case .failure(let failure) = result {
                diagnostics.record("playback.stop_failed", level: .warning,
                                   fields: ["error": failure.description])
            }
            engineRunning = false
        }

        // Exactly one falling edge, or none if already idle.
        setPlaying(false)
    }

    // MARK: - Engine lifecycle

    private func startEngine(for chunk: VoiceAudioChunk) -> Result<Void, AudioPlaybackSchedulerFailure> {
        let result = scheduler.start(
            sampleRate: chunk.format.sampleRate,
            channels: chunk.format.channels
        )
        switch result {
        case .success:
            engineRunning = true
            diagnostics.record("playback.engine_started",
                               fields: ["sampleRate": "\(chunk.format.sampleRate)",
                                         "channels": "\(chunk.format.channels)"])
        case .failure(let failure):
            diagnostics.record("playback.engine_start_failed", level: .warning,
                               fields: ["error": failure.description])
        }
        return result
    }

    // MARK: - Buffer completion

    private func bufferCompleted(generation gen: UInt64) {
        guard gen == generation else { return }
        guard outstandingBuffers > 0 else { return }
        outstandingBuffers -= 1
        checkDrain()
    }

    /// Transitions to idle if the stream is finished and all buffers have drained.
    private func checkDrain() {
        guard streamFinished, outstandingBuffers == 0 else { return }
        // Response fully drained: stop the engine (no idle audio unit).
        if engineRunning {
            let result = scheduler.stop()
            if case .failure(let failure) = result {
                diagnostics.record("playback.stop_failed", level: .warning,
                                   fields: ["error": failure.description])
            }
            engineRunning = false
        }
        setPlaying(false)
    }

    // MARK: - Fail-open

    /// Enters the failed state for the current response: drops all future audio for this
    /// response, stops the engine, and transitions to idle.
    private func enterFailedState() {
        failedForCurrentResponse = true
        outstandingBuffers = 0
        diagnostics.record("playback.unavailable", level: .warning)
        if engineRunning {
            _ = scheduler.stop()
            engineRunning = false
        }
        setPlaying(false)
    }

    // MARK: - Activity transitions

    private func setPlaying(_ value: Bool) {
        guard value != isPlaying else { return }
        isPlaying = value
        onPlayingChange?(value)
    }

    // MARK: - PCM16 -> AVAudioPCMBuffer conversion

    /// Converts a `VoiceAudioChunk` (PCM16 data) into an `AVAudioPCMBuffer` in int16 format.
    ///
    /// The engine's mixer will resample if the chunk's sample rate differs from the output
    /// device rate. We create the buffer in the same format as the engine was started with
    /// (int16, matching the chunk's declared rate and channels), so no Swift-side resampling
    /// is needed.
    private func makeBuffer(from chunk: VoiceAudioChunk) -> AVAudioPCMBuffer? {
        guard chunk.format.pcm16 else { return nil }
        let channels = AVAudioChannelCount(chunk.format.channels)
        let bytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = Int(channels) * bytesPerSample
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = chunk.data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: chunk.format.sampleRate,
            channels: channels,
            interleaved: true
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy PCM16 bytes directly into the buffer's int16 channel data.
        guard let int16Ptr = buffer.int16ChannelData else { return nil }
        let destCount = frameCount * Int(channels)
        chunk.data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            int16Ptr[0].update(from: src, count: destCount)
        }

        return buffer
    }
}
#endif
