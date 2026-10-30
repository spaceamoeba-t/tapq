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

    /// Called when the engine reports `AVAudioEngineConfigurationChange` (e.g. output route
    /// change). The scheduler observes the notification on the engine it owns and fires this
    /// callback on the MainActor. The callback is set by `BackendAudioPlayback` after
    /// `start` succeeds and cleared on `stop`.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
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
    private var configurationObserver: NSObjectProtocol?
    private var observerGeneration: UInt64 = 0

    var onConfigurationChange: (@MainActor () -> Void)?

    func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure> {
        let playback = TapQAudioPlaybackEngine()
        var error: NSError?
        guard TapQAudioPlaybackEngineStart(playback, sampleRate, AVAudioChannelCount(channels), &error) else {
            return .failure(Self.failure(from: error, defaultStage: .playbackEngineStart))
        }
        self.engine = playback
        observeConfigurationChanges(for: playback)
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
        removeConfigurationObserver()
        guard let engine else { return .success(()) }
        self.engine = nil
        var error: NSError?
        guard TapQAudioPlaybackEngineStop(engine, &error) else {
            return .failure(Self.failure(from: error, defaultStage: .playbackTeardown))
        }
        return .success(())
    }

    // MARK: - Configuration change observation

    /// Observes `AVAudioEngineConfigurationChange` on the playback engine, generation-
    /// guarded so a stale notification after `stop()` is silently dropped. Copied from the
    /// capture-side pattern in `AVAudioEngineVoiceAudioSource.observeConfigurationChanges`
    /// including the yield-before-teardown note.
    private func observeConfigurationChanges(for playback: TapQAudioPlaybackEngine) {
        observerGeneration &+= 1
        let generation = observerGeneration
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: playback.engine,
            queue: .main
        ) { [weak self] _ in
            // Apple warns against releasing the engine from inside its configuration
            // notification. Yield first, then let BackendAudioPlayback drop the stream.
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self,
                      self.observerGeneration == generation,
                      self.engine != nil else { return }
                self.onConfigurationChange?()
            }
        }
    }

    private func removeConfigurationObserver() {
        observerGeneration &+= 1
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
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
/// **One stream at a time.** The stream is every chunk enqueued since the last report or
/// flush; `finishStream` reports how it ended once its last buffer has played back. The
/// engine starts on the stream's first buffer and stops when the stream drains, is
/// flushed, or fails, so no output device is held between streams.
///
/// **The self-audio span (07-1).** `selfAudioActivity` follows the speaker, not the stream:
/// it opens at the first buffer an engine plays and closes when no buffer is outstanding,
/// whether or not `finishStream` has come, so a response whose `response.done` never
/// arrives cannot hold the microphone shut. Audio after an underrun reopens it with its
/// original start.
///
/// **Route change.** A configuration change on the output stops the engine and drops the
/// stream: `.flushed`, at once for a finished stream, at `finishStream` otherwise, with the
/// rest of its audio discarded. The owner speaks it again. The next stream starts a fresh
/// engine on the new route.
///
/// **Output lost.** An engine that will not start or refuses a buffer drops the stream as
/// `.failed` the same way, then calls `onUnavailable`.
///
/// Completions arrive on the main actor and carry the generation they were scheduled in;
/// every engine stop bumps it, so a completion of dropped audio changes nothing.
@MainActor public final class BackendAudioPlayback: VoiceResponseAudioPlaying {
    private let scheduler: AudioPlaybackScheduling
    private let diagnostics: TapQDiagnosticEmitter
    /// The clock the span is stamped on: `systemUptime`, the clock microphone chunks are
    /// stamped on (`AVAudioTime.seconds(forHostTime:)`).
    private let monotonicNow: @MainActor () -> TimeInterval

    private var generation: UInt64 = 0
    private(set) var engineRunning = false
    /// Buffers scheduled on the running engine and not yet played back.
    private var outstanding = 0
    /// How the current stream ends, once something has dropped it; the rest of its audio
    /// is discarded until `finishStream`.
    private var dropped: VoiceResponseStreamEnding?
    /// Set by `finishStream`: the report owed when the stream's audio has played out.
    private var report: (@MainActor (VoiceResponseStreamEnding) -> Void)?

    /// When the current — or most recent — stretch of TapQ's own audio began and ended.
    public private(set) var selfAudioActivity: VoiceSelfAudioActivity = .silent

    /// Fired when the engine could not start, or refused a buffer: this machine cannot
    /// render response audio. Fired once per failure, after the stream is dropped.
    public var onUnavailable: (@MainActor (String) -> Void)?

    /// Production initializer: uses the live ObjC bridge through `LiveAudioPlaybackScheduler`.
    public init(diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = LiveAudioPlaybackScheduler()
        self.monotonicNow = { ProcessInfo.processInfo.systemUptime }
        self.diagnostics = TapQDiagnosticEmitter(category: "Playback", sink: diagnosticSink)
    }

    /// Test seam: injects a fake scheduler so tests exercise the full state machine without
    /// touching audio hardware.
    init(scheduler: AudioPlaybackScheduling,
         monotonicNow: @escaping @MainActor () -> TimeInterval = {
             ProcessInfo.processInfo.systemUptime
         },
         diagnosticSink: any TapQDiagnosticSink = NoOpTapQDiagnosticSink()) {
        self.scheduler = scheduler
        self.monotonicNow = monotonicNow
        self.diagnostics = TapQDiagnosticEmitter(category: "Playback", sink: diagnosticSink)
    }

    // MARK: - VoiceResponseAudioPlaying

    public func enqueue(_ chunk: VoiceAudioChunk) {
        guard dropped == nil else { return }
        guard let buffer = makeBuffer(from: chunk) else {
            return diagnostics.record("playback.buffer_conversion_failed", level: .warning,
                                      fields: ["dataSize": "\(chunk.data.count)",
                                               "sampleRate": "\(chunk.format.sampleRate)",
                                               "channels": "\(chunk.format.channels)"])
        }
        let fresh = !engineRunning
        if fresh, case .failure(let failure) = startEngine(for: chunk.format) {
            return outputLost(failure.description)
        }
        if !selfAudioActivity.isSounding {
            selfAudioActivity = VoiceSelfAudioActivity(
                startedAt: fresh ? monotonicNow() : selfAudioActivity.startedAt,
                stoppedAt: nil)
        }
        let scheduled = generation
        outstanding += 1
        let result = scheduler.schedule(buffer) { [weak self] in
            self?.bufferPlayed(generation: scheduled)
        }
        if case .failure(let failure) = result {
            outstanding -= 1
            diagnostics.record("playback.schedule_failed", level: .warning,
                               fields: ["error": failure.description])
            outputLost(failure.description)
        }
    }

    public func finishStream(onDrained: (@MainActor (VoiceResponseStreamEnding) -> Void)?) {
        report = onDrained ?? { _ in }
        if let dropped {
            self.dropped = nil
            settle(dropped)
        } else if outstanding == 0 {
            stopEngine()
            settle(.playedBack)
        }
    }

    /// Back to idle: the audio is dropped, a finished stream is reported `.flushed`, and the
    /// next chunk starts a new stream.
    public func stopAndFlush() {
        stopEngine()
        dropped = nil
        if report != nil { settle(.flushed) }
    }

    // MARK: - Engine

    private func startEngine(for format: VoiceAudioFormat) -> Result<Void, AudioPlaybackSchedulerFailure> {
        let started = generation
        scheduler.onConfigurationChange = { [weak self] in
            guard let self, self.generation == started else { return }
            self.diagnostics.record("playback.configuration_changed", level: .warning)
            self.drop(.flushed)
        }
        let result = scheduler.start(sampleRate: format.sampleRate, channels: format.channels)
        switch result {
        case .success:
            engineRunning = true
            diagnostics.record("playback.engine_started",
                               fields: ["sampleRate": "\(format.sampleRate)",
                                        "channels": "\(format.channels)"])
        case .failure(let failure):
            scheduler.onConfigurationChange = nil
            diagnostics.record("playback.engine_start_failed", level: .warning,
                               fields: ["error": failure.description])
        }
        return result
    }

    /// Stops the engine, if one runs, and forgets its buffers; the span closes now if the
    /// speaker was still sounding.
    private func stopEngine() {
        generation &+= 1
        outstanding = 0
        scheduler.onConfigurationChange = nil
        if selfAudioActivity.isSounding {
            selfAudioActivity = VoiceSelfAudioActivity(startedAt: selfAudioActivity.startedAt,
                                                       stoppedAt: monotonicNow())
        }
        guard engineRunning else { return }
        engineRunning = false
        if case .failure(let failure) = scheduler.stop() {
            diagnostics.record("playback.stop_failed", level: .warning,
                               fields: ["error": failure.description])
        }
    }

    private func bufferPlayed(generation played: UInt64) {
        guard played == generation, outstanding > 0 else { return }
        outstanding -= 1
        guard outstanding == 0 else { return }
        selfAudioActivity = VoiceSelfAudioActivity(startedAt: selfAudioActivity.startedAt,
                                                   stoppedAt: monotonicNow())
        if report != nil {
            stopEngine()
            settle(.playedBack)
        }
    }

    // MARK: - Endings

    /// The stream lost its audio: reported now if it is finished, at `finishStream` if not.
    private func drop(_ ending: VoiceResponseStreamEnding) {
        stopEngine()
        diagnostics.record("playback.dropped", level: .warning, fields: ["ending": ending.rawValue])
        if report != nil {
            settle(ending)
        } else {
            dropped = ending
        }
    }

    private func outputLost(_ reason: String) {
        drop(.failed)
        onUnavailable?(reason)
    }

    private func settle(_ ending: VoiceResponseStreamEnding) {
        let finished = report
        report = nil
        finished?(ending)
    }

    // MARK: - PCM16 -> AVAudioPCMBuffer conversion

    /// Converts a `VoiceAudioChunk` (interleaved PCM16 data) into an `AVAudioPCMBuffer` in
    /// AVAudioEngine's standard format: deinterleaved Float32 at the chunk's own rate.
    ///
    /// The format is not a choice. The player node's output bus is connected in that format
    /// — an integer bus format is `kAudioUnitErr_FormatNotSupported` (-10868), which is what
    /// made every backend-voiced sentence inaudible on a Mac speaker — and `scheduleBuffer`
    /// raises on a buffer whose format is not the bus's. So the deinterleave-and-scale to
    /// Float32 happens here, in the one place that knows the wire encoding.
    ///
    /// Sample rate is still the chunk's: the mixer resamples to the output device, which is
    /// the part that never needed fixing. Nothing here resamples.
    private func makeBuffer(from chunk: VoiceAudioChunk) -> AVAudioPCMBuffer? {
        guard chunk.format.pcm16 else { return nil }
        let channels = AVAudioChannelCount(chunk.format.channels)
        let bytesPerSample = MemoryLayout<Int16>.size
        let bytesPerFrame = Int(channels) * bytesPerSample
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = chunk.data.count / bytesPerFrame
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: chunk.format.sampleRate,
            channels: channels
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        // Deinterleave and scale: int16 full scale is 32768, so the reciprocal keeps the
        // conversion to one multiply per sample and never produces a value outside [-1, 1).
        guard let floatPtr = buffer.floatChannelData else { return nil }
        let channelCount = Int(channels)
        let scale = Float(1.0 / 32768.0)
        chunk.data.withUnsafeBytes { rawPtr in
            guard let src = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for channel in 0..<channelCount {
                let destination = floatPtr[channel]
                for frame in 0..<frameCount {
                    destination[frame] = Float(src[frame * channelCount + channel]) * scale
                }
            }
        }

        return buffer
    }
}
#endif
