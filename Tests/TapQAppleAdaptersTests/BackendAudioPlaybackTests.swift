import AVFoundation
import XCTest
import TapQContracts
@testable import TapQAppleAdapters

@MainActor
final class BackendAudioPlaybackTests: XCTestCase {

    // MARK: - Test doubles

    /// Records every scheduler call and replays completions synchronously on demand.
    @MainActor
    private final class FakeScheduler: AudioPlaybackScheduling {
        enum Call: Equatable, CustomStringConvertible {
            case start(sampleRate: Double, channels: Int)
            case schedule(frameCount: Int)
            case stop

            var description: String {
                switch self {
                case .start(let rate, let ch): return "start(\(rate), \(ch))"
                case .schedule(let frames): return "schedule(\(frames))"
                case .stop: return "stop"
                }
            }
        }

        private(set) var calls: [Call] = []
        /// Pending completions from `schedule` calls, in FIFO order.
        private var completions: [@MainActor () -> Void] = []

        var startFailure: AudioPlaybackSchedulerFailure?
        var scheduleFailure: AudioPlaybackSchedulerFailure?
        var stopFailure: AudioPlaybackSchedulerFailure?
        var onConfigurationChange: (@MainActor () -> Void)?

        func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.start(sampleRate: sampleRate, channels: channels))
            if let failure = startFailure { return .failure(failure) }
            return .success(())
        }

        func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.schedule(frameCount: Int(buffer.frameLength)))
            if let failure = scheduleFailure { return .failure(failure) }
            completions.append(completion)
            return .success(())
        }

        func stop() -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.stop)
            completions.removeAll()
            if let failure = stopFailure { return .failure(failure) }
            return .success(())
        }

        /// Fires the next pending completion (FIFO). Returns true if a completion was fired.
        /// Runs synchronously on the main actor — the completion calls `bufferCompleted`
        /// directly without a Task hop, so the state machine advances in-line.
        @discardableResult
        func fireNextCompletion() -> Bool {
            guard !completions.isEmpty else { return false }
            let completion = completions.removeFirst()
            completion()
            return true
        }

        /// Fires all pending completions in order.
        func fireAllCompletions() {
            while fireNextCompletion() {}
        }

        var pendingCompletionCount: Int { completions.count }
    }

    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.name)
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    // MARK: - Fixture

    /// A clock the test moves by hand, so the recorded self-audio span can be asserted
    /// against instants rather than against whatever `systemUptime` happened to be.
    private final class TestClock {
        var now: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private struct Fixture {
        let playback: BackendAudioPlayback
        let scheduler: FakeScheduler
        let sink: RecordingSink
        let clock: TestClock
    }

    private func makeFixture() -> Fixture {
        let scheduler = FakeScheduler()
        let sink = RecordingSink()
        let clock = TestClock()
        let playback = BackendAudioPlayback(scheduler: scheduler,
                                            monotonicNow: { clock.now },
                                            diagnosticSink: sink)
        return Fixture(playback: playback, scheduler: scheduler, sink: sink, clock: clock)
    }

    // MARK: - The self-audio span

    /// The span is the half of the self-hearing guard `isPlaying` cannot carry: a remote VAD
    /// reports the speech it heard hundreds of milliseconds late, and by then the flag has
    /// gone false. What the echo check needs is not "is TapQ speaking" but "was TapQ
    /// speaking *then*".
    func testTheSpanRecordsWhenTapQsVoiceStartedAndStopped() {
        let f = makeFixture()
        XCTAssertEqual(f.playback.selfAudioActivity, .silent)

        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(f.playback.selfAudioActivity.startedAt, 1_000)
        XCTAssertTrue(f.playback.selfAudioActivity.isSounding)

        f.clock.advance(3)
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        XCTAssertFalse(f.playback.selfAudioActivity.isSounding)
        XCTAssertEqual(f.playback.selfAudioActivity.startedAt, 1_000)
        XCTAssertEqual(f.playback.selfAudioActivity.stoppedAt, 1_003)
    }

    /// And it outlives the drain, which is the whole point: the microphone reopens on that
    /// falling edge, and the question about the tail arrives after it.
    func testTheSpanAnswersAboutTheTailAfterTheDrain() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.clock.advance(2)
        f.playback.stopAndFlush()

        let span = f.playback.selfAudioActivity
        XCTAssertTrue(span.wasAudible(at: 1_002.3, hysteresis: 0.6),
                      "a room does not go quiet the moment the last buffer is handed over")
        XCTAssertFalse(span.wasAudible(at: 1_003, hysteresis: 0.6))
    }

    // MARK: - Chunk helpers

    /// Creates a `VoiceAudioChunk` with `sampleCount` PCM16 mono samples at the given rate.
    private func pcm16Chunk(
        sampleCount: Int = 120,
        sampleRate: Double = 24_000,
        channels: Int = 1,
        timestamp: TimeInterval = 0
    ) -> VoiceAudioChunk {
        let bytesPerSample = 2 * channels
        var data = Data(count: sampleCount * bytesPerSample)
        // Fill with a simple ramp so values are nonzero.
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<(sampleCount * channels) {
                base[i] = Int16(clamping: i)
            }
        }
        return VoiceAudioChunk(
            data: data,
            format: VoiceAudioFormat(sampleRate: sampleRate, channels: channels),
            timestamp: timestamp
        )
    }

    // MARK: - isPlaying rises synchronously on first enqueue

    func testIsPlayingRisesSynchronouslyOnFirstEnqueue() {
        let f = makeFixture()
        XCTAssertFalse(f.playback.isPlaying)

        f.playback.enqueue(pcm16Chunk())

        XCTAssertTrue(f.playback.isPlaying,
                      "isPlaying must be true immediately after the first enqueue")
    }

    func testOnPlayingChangeFiresOnFirstEnqueue() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(edges, [true])
    }

    func testSubsequentEnqueueDoesNotFireDuplicateEdge() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())

        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(edges, [], "no duplicate rising edge for subsequent enqueues")
    }

    // MARK: - PCM16 to AVAudioPCMBuffer conversion

    func testPCM16ConversionProducesCorrectFrameCount() {
        let f = makeFixture()
        let chunk = pcm16Chunk(sampleCount: 240, sampleRate: 24_000, channels: 1)

        f.playback.enqueue(chunk)

        let scheduled = f.scheduler.calls.compactMap { call -> Int? in
            if case .schedule(let frames) = call { return frames }
            return nil
        }
        XCTAssertEqual(scheduled, [240])
    }

    func testPCM16ConversionPreservesValues() {
        // Create a chunk with known values.
        let values: [Int16] = [1000, -1000, 32767, -32768]
        var data = Data(count: values.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: Int16.self)
            for (i, v) in values.enumerated() {
                base[i] = v
            }
        }
        let chunk = VoiceAudioChunk(
            data: data,
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 1),
            timestamp: 0
        )

        // Use a spy scheduler that captures the buffer.
        let scheduler = BufferCapturingScheduler()
        let playback = BackendAudioPlayback(scheduler: scheduler)
        playback.enqueue(chunk)

        guard let buffer = scheduler.lastBuffer else {
            return XCTFail("expected a scheduled buffer")
        }
        XCTAssertEqual(buffer.frameLength, 4)
        // Float32, not the wire's int16: an integer format on a player node's output bus is
        // -10868, so the buffer must arrive in the standard format the bus is connected in.
        XCTAssertEqual(buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(buffer.format.sampleRate, 24_000)
        XCTAssertEqual(buffer.format.channelCount, 1)
        guard let floatData = buffer.floatChannelData else {
            return XCTFail("expected float channel data")
        }
        XCTAssertEqual(floatData[0][0], 1000.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(floatData[0][1], -1000.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(floatData[0][2], 32767.0 / 32768.0, accuracy: 1e-6)
        XCTAssertEqual(floatData[0][3], -1.0, accuracy: 1e-6)
    }

    func testStereoConversionDeinterleaves() {
        // Interleaved on the wire (L0 R0 L1 R1), deinterleaved in the buffer.
        let values: [Int16] = [16384, -16384, 8192, -8192]
        var data = Data(count: values.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: Int16.self)
            for (i, v) in values.enumerated() { base[i] = v }
        }
        let chunk = VoiceAudioChunk(
            data: data,
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 2),
            timestamp: 0
        )

        let scheduler = BufferCapturingScheduler()
        let playback = BackendAudioPlayback(scheduler: scheduler)
        playback.enqueue(chunk)

        guard let buffer = scheduler.lastBuffer,
              let floatData = buffer.floatChannelData else {
            return XCTFail("expected a scheduled float buffer")
        }
        XCTAssertEqual(buffer.frameLength, 2)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertEqual(floatData[0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(floatData[0][1], 0.25, accuracy: 1e-6)
        XCTAssertEqual(floatData[1][0], -0.5, accuracy: 1e-6)
        XCTAssertEqual(floatData[1][1], -0.25, accuracy: 1e-6)
    }

    // MARK: - Reporting a dead output device

    func testEngineStartFailureReportsOutputUnavailable() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSetup, detail: "-10868")
        var reported: [String] = []
        f.playback.onUnavailable = { reported.append($0) }

        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(reported.count, 1,
                       "an engine that cannot start means the machine cannot render backend audio")
        XCTAssertTrue(reported[0].contains("-10868"))
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testScheduleFailureMidResponseReportsOutputUnavailable() {
        let f = makeFixture()
        var reported: [String] = []
        f.playback.onUnavailable = { reported.append($0) }

        // The response starts healthy, then the engine refuses a buffer mid-stream.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(reported, [], "a healthy start reports nothing")
        f.scheduler.scheduleFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSchedule, detail: "engine died")
        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported[0].contains("engine died"))
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testConfigurationChangeDoesNotReportOutputUnavailable() {
        let f = makeFixture()
        var reported: [String] = []
        f.playback.onUnavailable = { reported.append($0) }

        f.playback.enqueue(pcm16Chunk())
        f.scheduler.onConfigurationChange?()

        XCTAssertEqual(reported, [],
                       "a route change costs one response, not the output device")
        XCTAssertTrue(f.sink.names.contains("playback.unavailable"),
                      "it is still a failed response")
    }

    func testHealthyResponseNeverReportsOutputUnavailable() {
        let f = makeFixture()
        var reported: [String] = []
        f.playback.onUnavailable = { reported.append($0) }

        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        XCTAssertEqual(reported, [])
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testOutputUnavailableIsReportedAfterThePlayerIsIdle() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSetup, detail: "-10868")
        var playingWhenReported: Bool?
        f.playback.onUnavailable = { [weak playback = f.playback] _ in
            playingWhenReported = playback?.isPlaying
        }

        f.playback.enqueue(pcm16Chunk())

        // The handler tears the session down; it must not find a player still holding an
        // engine it would then be asked to stop a second time.
        XCTAssertEqual(playingWhenReported, false)
    }

    func testMonoConversionFrameCount() {
        let f = makeFixture()
        let chunk = pcm16Chunk(sampleCount: 100, sampleRate: 24_000, channels: 1)
        f.playback.enqueue(chunk)

        let scheduled = f.scheduler.calls.compactMap { call -> Int? in
            if case .schedule(let frames) = call { return frames }
            return nil
        }
        XCTAssertEqual(scheduled, [100])
    }

    // MARK: - Engine lifecycle

    func testEngineStartedLazilyOnFirstEnqueue() {
        let f = makeFixture()
        XCTAssertFalse(f.scheduler.calls.contains(where: {
            if case .start = $0 { return true }; return false
        }))

        f.playback.enqueue(pcm16Chunk(sampleRate: 24_000, channels: 1))

        let starts = f.scheduler.calls.compactMap { call -> (Double, Int)? in
            if case .start(let rate, let ch) = call { return (rate, ch) }
            return nil
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts[0].0, 24_000)
        XCTAssertEqual(starts[0].1, 1)
    }

    func testEngineStoppedAfterDrain() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        XCTAssertTrue(f.scheduler.calls.contains(.stop),
                      "engine stops after all buffers drain")
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testEngineNotStoppedBeforeDrain() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()

        // Completion has not fired yet.
        XCTAssertFalse(f.scheduler.calls.contains(.stop),
                       "engine stays running while buffers are outstanding")
        XCTAssertTrue(f.playback.isPlaying)
    }

    // MARK: - Drain requires finishStream + all completions

    func testDrainOnlyAfterFinishStreamAndLastCompletion() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())

        // Only completions, no finishStream yet.
        f.scheduler.fireAllCompletions()
        XCTAssertTrue(f.playback.isPlaying, "not drained: finishStream not called")

        f.playback.finishStream()
        XCTAssertFalse(f.playback.isPlaying, "drained: finishStream + all completions")
    }

    func testFinishStreamThenCompletionsDrains() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())

        f.playback.finishStream()
        XCTAssertTrue(f.playback.isPlaying, "still playing: completions pending")

        f.scheduler.fireNextCompletion()
        XCTAssertTrue(f.playback.isPlaying, "still playing: one completion pending")

        f.scheduler.fireNextCompletion()
        XCTAssertFalse(f.playback.isPlaying, "drained after last completion")
    }

    // MARK: - stopAndFlush

    func testStopAndFlushCancelsOutstandingAndFiresFallingEdge() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(edges, [true])

        f.playback.stopAndFlush()

        XCTAssertFalse(f.playback.isPlaying)
        XCTAssertEqual(edges, [true, false], "exactly one falling edge")
        XCTAssertTrue(f.scheduler.calls.contains(.stop))
    }

    func testStopAndFlushWhenIdleDoesNotFireEdge() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.stopAndFlush()

        XCTAssertEqual(edges, [], "no edge when already idle")
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testStopAndFlushIsIdempotent() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())

        f.playback.stopAndFlush()
        f.playback.stopAndFlush()
        f.playback.stopAndFlush()

        // Only one stop call (the second and third see engineRunning == false).
        let stopCount = f.scheduler.calls.filter { $0 == .stop }.count
        XCTAssertEqual(stopCount, 1)
    }

    // MARK: - Generation-counted completions: stale completions after flush are ignored

    func testStaleCompletionsAfterFlushAreIgnored() {
        let f = makeFixture()

        // Capture the completion by using a different scheduler approach:
        // The FakeScheduler stores completions; we can fire them after stopAndFlush.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(f.scheduler.pendingCompletionCount, 1)

        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.stopAndFlush()
        XCTAssertEqual(edges, [false])

        // Now "fire" the stale completion. stopAndFlush cleared the completions array
        // in the fake, but in production the completion would still arrive from the
        // internal AVAudioEngine thread. Simulate by calling bufferCompleted directly.
        // Since the FakeScheduler clears completions on stop, we simulate the stale
        // completion indirectly by enqueuing a fresh response and checking no extra edges.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(edges, [false, true], "fresh response starts cleanly")
    }

    func testStaleCompletionFromPriorResponseDoesNotAffectNewResponse() {
        let f = makeFixture()

        // First response.
        f.playback.enqueue(pcm16Chunk())
        f.playback.stopAndFlush()

        // Second response.
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(edges, [true])

        // Second response drains normally.
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()
        XCTAssertEqual(edges, [true, false])
    }

    // MARK: - Scheduler failure -> fail-open

    func testEngineStartFailureGoesFailOpen() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart,
            detail: "no output device"
        )

        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())

        // isPlaying rose synchronously then fell on failure.
        XCTAssertFalse(f.playback.isPlaying)
        XCTAssertEqual(edges, [true, false])
        XCTAssertTrue(f.sink.names.contains("playback.unavailable"),
                      "fail-open diagnostic recorded")
    }

    func testSubsequentEnqueuesDroppedAfterEngineStartFailure() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart,
            detail: "no output device"
        )

        f.playback.enqueue(pcm16Chunk())
        let callsAfterFirstEnqueue = f.scheduler.calls.count

        // Further enqueues for the same response are silently dropped.
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(f.scheduler.calls.count, callsAfterFirstEnqueue,
                       "subsequent enqueues are dropped in the fail-open state")
    }

    func testFreshResponseAfterFailureAttemptsNewEngine() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart,
            detail: "no output device"
        )

        f.playback.enqueue(pcm16Chunk())
        XCTAssertFalse(f.playback.isPlaying)

        // Clear the failure.
        f.scheduler.startFailure = nil
        // A fresh response (after stopAndFlush resets the fail state).
        f.playback.stopAndFlush()

        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying, "fresh engine attempt succeeds")
    }

    /// Regression for defect 2: finishStream (not stopAndFlush) must clear the
    /// per-response failure flag so the next response can attempt a fresh engine.
    ///
    /// In the composed flow, VoiceBackendCommandProvider calls finishStream() on
    /// responseCompleted — it never calls stopAndFlush() between responses inside
    /// one window. Before the fix, failedForCurrentResponse stayed true after
    /// finishStream, silencing every subsequent response until the window ended.
    func testFreshResponseAfterFailureViaFinishStreamAttemptsNewEngine() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart,
            detail: "no output device"
        )

        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        // First response: engine start fails.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertFalse(f.playback.isPlaying)
        XCTAssertTrue(f.sink.names.contains("playback.unavailable"),
                      "fail-open diagnostic for the first response")

        // The provider calls finishStream() on responseCompleted — NOT stopAndFlush.
        f.playback.finishStream()

        // Clear the injected failure so the next engine start succeeds.
        f.scheduler.startFailure = nil

        // Second response: must attempt a fresh engine (not silently drop).
        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying,
                      "the second response must attempt a fresh engine after finishStream")

        // Verify the scheduler received a second start call.
        let startCount = f.scheduler.calls.compactMap { call -> Bool? in
            if case .start = call { return true }
            return nil
        }.count
        XCTAssertEqual(startCount, 2,
                       "two start calls: one failed, one succeeded")

        // Drain the second response normally.
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()
        XCTAssertFalse(f.playback.isPlaying)
    }

    func testScheduleFailureGoesFailOpen() {
        let f = makeFixture()

        // First enqueue succeeds (starts engine), then inject schedule failure.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying)

        f.scheduler.scheduleFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSchedule,
            detail: "node not playing"
        )

        f.playback.enqueue(pcm16Chunk())

        // Should have entered fail-open.
        XCTAssertFalse(f.playback.isPlaying)
        XCTAssertTrue(f.sink.names.contains("playback.unavailable"))
    }

    // MARK: - Multiple sequential responses

    func testMultipleSequentialResponses() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        // Response 1.
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()
        XCTAssertEqual(edges, [true, false])

        // Response 2.
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()
        XCTAssertEqual(edges, [true, false, true, false])
    }

    func testEachResponseGetsAFreshEngineStart() {
        let f = makeFixture()

        // Response 1.
        f.playback.enqueue(pcm16Chunk(sampleRate: 24_000))
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        // Response 2 (different sample rate).
        f.playback.enqueue(pcm16Chunk(sampleRate: 16_000))
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        let starts = f.scheduler.calls.compactMap { call -> (Double, Int)? in
            if case .start(let rate, let ch) = call { return (rate, ch) }
            return nil
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].0, 24_000)
        XCTAssertEqual(starts[1].0, 16_000)
    }

    // MARK: - stopAndFlush mid-response then new response

    func testStopAndFlushMidResponseThenNewResponse() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        // Start first response.
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())

        // Barge-in: stop everything.
        f.playback.stopAndFlush()
        XCTAssertEqual(edges, [true, false])

        // New response.
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream()
        f.scheduler.fireAllCompletions()
        XCTAssertEqual(edges, [true, false, true, false])
    }

    // MARK: - Empty/invalid chunks

    func testEmptyChunkDoesNotCrash() {
        let f = makeFixture()
        let emptyChunk = VoiceAudioChunk(
            data: Data(),
            format: .pcm16Mono24k,
            timestamp: 0
        )

        // Should not crash; isPlaying rises but the buffer conversion returns nil (0 frames),
        // so nothing is scheduled. The engine start may or may not fire depending on ordering.
        f.playback.enqueue(emptyChunk)

        // No schedule call for an empty chunk.
        let scheduled = f.scheduler.calls.filter {
            if case .schedule = $0 { return true }; return false
        }
        XCTAssertEqual(scheduled.count, 0)
    }

    func testOddByteCountChunkTruncatesToWholeFrames() {
        let f = makeFixture()
        // 5 bytes of PCM16 mono = 2 whole frames (4 bytes), 1 byte remainder.
        let chunk = VoiceAudioChunk(
            data: Data(repeating: 0, count: 5),
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 1),
            timestamp: 0
        )

        f.playback.enqueue(chunk)

        let scheduled = f.scheduler.calls.compactMap { call -> Int? in
            if case .schedule(let frames) = call { return frames }
            return nil
        }
        XCTAssertEqual(scheduled, [2], "truncated to 2 whole frames")
    }

    // MARK: - Diagnostic events

    func testEngineStartRecordsDiagnostic() {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())

        XCTAssertTrue(f.sink.names.contains("playback.engine_started"))
    }

    func testFailOpenRecordsUnavailableDiagnostic() {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart, detail: "test")

        f.playback.enqueue(pcm16Chunk())

        XCTAssertTrue(f.sink.names.contains("playback.unavailable"))
    }

    // MARK: - Interleaved buffers in order

    func testBuffersScheduledInFIFOOrder() {
        let f = makeFixture()

        f.playback.enqueue(pcm16Chunk(sampleCount: 100))
        f.playback.enqueue(pcm16Chunk(sampleCount: 200))
        f.playback.enqueue(pcm16Chunk(sampleCount: 300))

        let scheduled = f.scheduler.calls.compactMap { call -> Int? in
            if case .schedule(let frames) = call { return frames }
            return nil
        }
        XCTAssertEqual(scheduled, [100, 200, 300])
    }

    // MARK: - Full lifecycle integration

    func testFullResponseLifecycle() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        // Enqueue 3 chunks.
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(edges, [true])
        XCTAssertTrue(f.playback.isPlaying)

        // Signal end of stream.
        f.playback.finishStream()
        XCTAssertTrue(f.playback.isPlaying, "still draining")

        // Complete buffers one at a time.
        f.scheduler.fireNextCompletion()
        XCTAssertTrue(f.playback.isPlaying)
        f.scheduler.fireNextCompletion()
        XCTAssertTrue(f.playback.isPlaying)
        f.scheduler.fireNextCompletion()

        // Now fully drained.
        XCTAssertFalse(f.playback.isPlaying)
        XCTAssertEqual(edges, [true, false])
    }

    // MARK: - Configuration change -> fail-open (defect 4)

    func testConfigurationChangeMidResponseEntersFailOpen() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying)
        XCTAssertEqual(edges, [true])

        // Simulate an AVAudioEngineConfigurationChange (e.g. AirPods disconnect).
        f.scheduler.onConfigurationChange?()

        // Should have entered the fail-open state.
        XCTAssertFalse(f.playback.isPlaying,
                       "isPlaying must be false after configuration change")
        XCTAssertEqual(edges, [true, false])
        XCTAssertTrue(f.sink.names.contains("playback.configuration_changed"),
                      "configuration change diagnostic recorded")
        XCTAssertTrue(f.sink.names.contains("playback.unavailable"),
                      "fail-open diagnostic recorded")
    }

    func testConfigurationChangeDropsSubsequentEnqueues() {
        let f = makeFixture()

        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying)
        let callsBeforeChange = f.scheduler.calls.count

        // Configuration change.
        f.scheduler.onConfigurationChange?()
        XCTAssertFalse(f.playback.isPlaying)

        // Further enqueues for the same response are silently dropped.
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(f.scheduler.calls.count, callsBeforeChange + 1,
                       "only the stop from enterFailedState, no new schedules")
    }

    func testFreshResponseAfterConfigurationChangeAttemptsNewEngine() {
        let f = makeFixture()

        f.playback.enqueue(pcm16Chunk())
        f.scheduler.onConfigurationChange?()
        XCTAssertFalse(f.playback.isPlaying)

        // Reset for a new response.
        f.playback.stopAndFlush()

        // A fresh response should attempt a new engine.
        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.isPlaying, "fresh engine attempt after config change succeeds")
    }

    func testStaleConfigurationChangeAfterStopAndFlushIsIgnored() {
        let f = makeFixture()
        var edges: [Bool] = []
        f.playback.onPlayingChange = { edges.append($0) }

        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(edges, [true])

        // Capture the callback before stopAndFlush clears it.
        let staleCallback = f.scheduler.onConfigurationChange

        f.playback.stopAndFlush()
        XCTAssertEqual(edges, [true, false])

        // Fire the stale callback. It should be nil (cleared by stopAndFlush).
        XCTAssertNil(f.scheduler.onConfigurationChange,
                     "onConfigurationChange cleared by stopAndFlush")

        // Even if someone held a reference and fired it, the generation guard would block it.
        staleCallback?()

        // No extra edges from the stale callback.
        XCTAssertEqual(edges, [true, false])
    }

    func testConfigurationChangeCallbackClearedOnDrain() {
        let f = makeFixture()

        f.playback.enqueue(pcm16Chunk())
        XCTAssertNotNil(f.scheduler.onConfigurationChange,
                        "callback set while engine is running")

        f.playback.finishStream()
        f.scheduler.fireAllCompletions()

        // After drain, the engine is stopped and the callback is cleared.
        XCTAssertNil(f.scheduler.onConfigurationChange,
                     "callback cleared after drain")
    }

    // MARK: - Buffer capturing scheduler (for value-level assertions)

    @MainActor
    private final class BufferCapturingScheduler: AudioPlaybackScheduling {
        var lastBuffer: AVAudioPCMBuffer?
        private var completions: [@MainActor () -> Void] = []
        var onConfigurationChange: (@MainActor () -> Void)?

        func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure> {
            .success(())
        }

        func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) -> Result<Void, AudioPlaybackSchedulerFailure> {
            lastBuffer = buffer
            completions.append(completion)
            return .success(())
        }

        func stop() -> Result<Void, AudioPlaybackSchedulerFailure> {
            completions.removeAll()
            return .success(())
        }
    }
}
