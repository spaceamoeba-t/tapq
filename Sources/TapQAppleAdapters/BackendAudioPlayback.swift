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
            // notification. Yield first, then let BackendAudioPlayback fail open.
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
/// ## Fail-open, and the one failure that is not
///
/// Any start/schedule failure or engine configuration change: drop audio for the rest of
/// the response, emit a `playback.unavailable` diagnostic, transition `isPlaying` -> `false`.
/// Transcripts and the window are unaffected (the provider keeps consuming events;
/// `CombinedSpeechActivity` just never sees busy). The next response attempts a fresh engine.
///
/// That is right for a configuration change — an output route moved, this response is lost,
/// the next one comes up on the new route — and wrong for an engine that could not start or
/// a buffer the engine refused. Those say the machine cannot render backend audio at all,
/// and a run that keeps listening while nothing it says is audible is the failure this class
/// used to hide. So they additionally call `onUnavailable`, whose owner ends the voice
/// session rather than letting it continue half-alive. Nothing is re-spoken here: this class
/// plays audio or reports that it cannot, and never quietly borrows another voice.
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

    /// Fired when the engine could not start, or refused a buffer: this machine cannot
    /// render backend response audio, and the caller must decide what a voice session
    /// without a voice is worth. Composition points it at
    /// `PlaybackDependentVoiceBackend.notePlaybackUnavailable`, which ends the session.
    ///
    /// Fires once per failure rather than once per run — the owner is the one that keeps
    /// the run-lifetime verdict — and carries only the failure's own description. It is not
    /// fired for a configuration change: that costs one response, not the output device.
    public var onUnavailable: (@MainActor (String) -> Void)?

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
        if !engineRunning, case .failure(let failure) = startEngine(for: chunk) {
            enterFailedState(outputLost: failure.description)
            return
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
            enterFailedState(outputLost: failure.description)
        }
    }

    public func finishStream() {
        // A finished stream ends the current response. Clear the per-response
        // failure flag so the *next* response can attempt a fresh engine. After
        // enterFailedState(), outstandingBuffers is 0 and the engine is already
        // stopped, so checkDrain is a no-op and the reset is safe.
        failedForCurrentResponse = false
        streamFinished = true
        checkDrain()
    }

    public func stopAndFlush() {
        generation &+= 1
        outstandingBuffers = 0
        streamFinished = false
        failedForCurrentResponse = false
        scheduler.onConfigurationChange = nil

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
        let gen = generation
        scheduler.onConfigurationChange = { [weak self] in
            guard let self, self.generation == gen, self.engineRunning else { return }
            self.diagnostics.record("playback.configuration_changed", level: .warning)
            self.enterFailedState()
        }
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
            scheduler.onConfigurationChange = nil
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
        scheduler.onConfigurationChange = nil
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
    ///
    /// - Parameter outputLost: the failure description when the output device itself is the
    ///   casualty (the engine would not start, or refused a buffer), which additionally
    ///   fires `onUnavailable`. `nil` — a configuration change — costs this response only.
    ///
    /// `onUnavailable` fires last, after this player is fully idle: its handler tears the
    /// voice session down, and a teardown that re-entered a player still holding an engine
    /// would be stopping something that had already been stopped.
    private func enterFailedState(outputLost: String? = nil) {
        failedForCurrentResponse = true
        outstandingBuffers = 0
        scheduler.onConfigurationChange = nil
        diagnostics.record("playback.unavailable", level: .warning)
        if engineRunning {
            _ = scheduler.stop()
            engineRunning = false
        }
        setPlaying(false)
        if let outputLost {
            onUnavailable?(outputLost)
        }
    }

    // MARK: - Activity transitions

    private func setPlaying(_ value: Bool) {
        guard value != isPlaying else { return }
        isPlaying = value
        onPlayingChange?(value)
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
