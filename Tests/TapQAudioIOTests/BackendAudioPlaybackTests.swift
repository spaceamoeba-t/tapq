import AVFoundation
import XCTest
import TapQContracts
@testable import TapQAudioIO

@MainActor
final class BackendAudioPlaybackTests: XCTestCase {

    // MARK: - Test doubles

    /// Records every scheduler call and replays completions on demand, synchronously on the
    /// main actor.
    @MainActor
    private final class FakeScheduler: AudioPlaybackScheduling {
        enum Call: Equatable {
            case start(sampleRate: Double, channels: Int)
            case schedule(frameCount: Int)
            case stop
        }

        private(set) var calls: [Call] = []
        private var completions: [@MainActor () -> Void] = []
        /// Completions of buffers a `stop` dropped: `AVAudioPlayerNode.stop()` still fires
        /// them, late, from its own thread.
        private var stoppedCompletions: [@MainActor () -> Void] = []

        var startFailure: AudioPlaybackSchedulerFailure?
        var scheduleFailure: AudioPlaybackSchedulerFailure?
        var onConfigurationChange: (@MainActor () -> Void)?

        var starts: Int { calls.filter { $0 == .start(sampleRate: 24_000, channels: 1) }.count }
        var stops: Int { calls.filter { $0 == .stop }.count }
        var scheduledFrames: [Int] {
            calls.compactMap { if case .schedule(let frames) = $0 { return frames }; return nil }
        }

        func start(sampleRate: Double, channels: Int) -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.start(sampleRate: sampleRate, channels: channels))
            return startFailure.map { .failure($0) } ?? .success(())
        }

        func schedule(_ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void) -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.schedule(frameCount: Int(buffer.frameLength)))
            if let scheduleFailure { return .failure(scheduleFailure) }
            completions.append(completion)
            return .success(())
        }

        func stop() -> Result<Void, AudioPlaybackSchedulerFailure> {
            calls.append(.stop)
            stoppedCompletions += completions
            completions.removeAll()
            return .success(())
        }

        /// The output reports the oldest pending buffer played back.
        func playNext() {
            guard !completions.isEmpty else { return }
            completions.removeFirst()()
        }

        func playAll() {
            while !completions.isEmpty { playNext() }
        }

        func fireStoppedCompletions() {
            let late = stoppedCompletions
            stoppedCompletions.removeAll()
            late.forEach { $0() }
        }

        /// The output route changes under the running engine.
        func changeRoute() {
            onConfigurationChange?()
        }
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
    }

    // MARK: - Fixture

    private final class TestClock {
        var now: TimeInterval = 1_000
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    /// Every report `finishStream` delivered, in order.
    private final class Endings {
        private(set) var all: [VoiceResponseStreamEnding] = []
        var record: @MainActor (VoiceResponseStreamEnding) -> Void {
            { [unowned self] in self.all.append($0) }
        }
    }

    private struct Fixture {
        let playback: BackendAudioPlayback
        let scheduler: FakeScheduler
        let sink: RecordingSink
        let clock: TestClock
        let endings = Endings()
        let unavailable: Unavailable
    }

    private final class Unavailable {
        var reasons: [String] = []
    }

    private func makeFixture() -> Fixture {
        let scheduler = FakeScheduler()
        let sink = RecordingSink()
        let clock = TestClock()
        let playback = BackendAudioPlayback(scheduler: scheduler,
                                            monotonicNow: { clock.now },
                                            diagnosticSink: sink)
        let unavailable = Unavailable()
        playback.onUnavailable = { unavailable.reasons.append($0) }
        return Fixture(playback: playback, scheduler: scheduler, sink: sink, clock: clock,
                       unavailable: unavailable)
    }

    /// `sampleCount` PCM16 samples per channel, a ramp so the values are nonzero.
    private func pcm16Chunk(sampleCount: Int = 120, sampleRate: Double = 24_000,
                            channels: Int = 1) -> VoiceAudioChunk {
        var data = Data(count: sampleCount * 2 * channels)
        data.withUnsafeMutableBytes { pointer in
            guard let base = pointer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<(sampleCount * channels) { base[index] = Int16(clamping: index) }
        }
        return VoiceAudioChunk(data: data,
                               format: VoiceAudioFormat(sampleRate: sampleRate, channels: channels),
                               timestamp: 0)
    }

    // MARK: - The self-audio span

    /// What the echo check needs is not "is TapQ speaking" but "was TapQ speaking *then*".
    func testTheSpanRecordsWhenTapQsVoiceStartedAndStopped() async {
        let f = makeFixture()
        XCTAssertEqual(f.playback.selfAudioActivity, .silent)

        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(f.playback.selfAudioActivity,
                       VoiceSelfAudioActivity(startedAt: 1_000, stoppedAt: nil))

        f.clock.advance(3)
        f.playback.finishStream()
        f.scheduler.playAll()

        XCTAssertEqual(f.playback.selfAudioActivity,
                       VoiceSelfAudioActivity(startedAt: 1_000, stoppedAt: 1_003))
    }

    func testTheSpanAnswersAboutTheTailAfterAFlush() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.clock.advance(2)
        f.playback.stopAndFlush()

        let span = f.playback.selfAudioActivity
        XCTAssertTrue(span.wasAudible(at: 1_002.3, hysteresis: 0.6),
                      "a room does not go quiet the moment the last buffer is handed over")
        XCTAssertFalse(span.wasAudible(at: 1_003, hysteresis: 0.6))
    }

    /// 07-1: the span ends when the last buffer has played, not when the stream is
    /// finished. `response.done` can land seconds after the sound stopped.
    func testTheSpanEndsWhenTheLastBufferPlaysNotAtFinishStream() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.clock.advance(1)
        f.scheduler.playAll()

        XCTAssertTrue(f.playback.engineRunning, "the stream is not finished")
        XCTAssertEqual(f.playback.selfAudioActivity,
                       VoiceSelfAudioActivity(startedAt: 1_000, stoppedAt: 1_001))

        f.clock.advance(2)
        f.playback.finishStream()

        XCTAssertFalse(f.playback.engineRunning)
        XCTAssertEqual(f.playback.selfAudioActivity.stoppedAt, 1_001,
                       "the engine stopping keeps the instant the speaker went quiet")
    }

    /// Audio that resumes after an underrun reopens the span with its original start: the
    /// gap is never mistaken for a quiet room.
    func testAudioAfterAnUnderrunReopensTheSpan() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.clock.advance(1)
        f.scheduler.playAll()
        f.clock.advance(0.2)
        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(f.playback.selfAudioActivity,
                       VoiceSelfAudioActivity(startedAt: 1_000, stoppedAt: nil))
        f.clock.advance(1)
        f.scheduler.playAll()
        XCTAssertEqual(f.playback.selfAudioActivity.stoppedAt, 1_002.2)
    }

    // MARK: - One stream

    func testTheEngineRunsFromTheFirstBufferUntilTheStreamDrains() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.engineRunning, "playing before the first sample can sound")
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        f.scheduler.playNext()
        XCTAssertEqual(f.endings.all, [], "one buffer is still to play")
        f.scheduler.playNext()

        XCTAssertEqual(f.endings.all, [.playedBack])
        XCTAssertEqual(f.scheduler.calls, [.start(sampleRate: 24_000, channels: 1),
                                           .schedule(frameCount: 120),
                                           .schedule(frameCount: 120), .stop])
        XCTAssertFalse(f.playback.engineRunning)
    }

    func testAStreamWithNothingOutstandingReportsAtOnce() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.scheduler.playAll()

        f.playback.finishStream(onDrained: f.endings.record)

        XCTAssertEqual(f.endings.all, [.playedBack])
        XCTAssertFalse(f.playback.engineRunning)
    }

    func testEachStreamStartsAFreshEngine() async {
        let f = makeFixture()
        for _ in 0..<2 {
            f.playback.enqueue(pcm16Chunk())
            f.playback.finishStream(onDrained: f.endings.record)
            f.scheduler.playAll()
        }

        XCTAssertEqual(f.endings.all, [.playedBack, .playedBack])
        XCTAssertEqual(f.scheduler.starts, 2)
        XCTAssertEqual(f.scheduler.stops, 2)
    }

    func testStopAndFlushReportsAFinishedStreamFlushedAndReturnsToIdle() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)

        f.playback.stopAndFlush()
        f.scheduler.fireStoppedCompletions()
        f.playback.stopAndFlush()

        XCTAssertEqual(f.endings.all, [.flushed], "once, and late completions change nothing")
        XCTAssertEqual(f.scheduler.stops, 1)
        XCTAssertFalse(f.playback.engineRunning)

        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        f.scheduler.playAll()
        XCTAssertEqual(f.endings.all, [.flushed, .playedBack], "the next stream plays")
    }

    func testAChunkThatIsNotAudioIsSkipped() async {
        let f = makeFixture()

        f.playback.enqueue(VoiceAudioChunk(data: Data(), format: .pcm16Mono24k, timestamp: 0))

        XCTAssertEqual(f.scheduler.calls, [], "no engine for nothing to play")
        XCTAssertTrue(f.sink.names.contains("playback.buffer_conversion_failed"))
    }

    // MARK: - A route change (D7)

    /// P1-1: AirPods connecting while TapQ speaks. The reading is dropped and reported
    /// `.flushed`, so its owner speaks it again; the device is not reported lost.
    func testARouteChangeUnderAFinishedStreamReportsItFlushedAtOnce() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        f.clock.advance(1)

        f.scheduler.changeRoute()

        XCTAssertEqual(f.endings.all, [.flushed])
        XCTAssertEqual(f.scheduler.stops, 1)
        XCTAssertFalse(f.playback.engineRunning)
        XCTAssertEqual(f.playback.selfAudioActivity,
                       VoiceSelfAudioActivity(startedAt: 1_000, stoppedAt: 1_001),
                       "the microphone is not zero-filled for a voice that stopped")
        XCTAssertEqual(f.unavailable.reasons, [])
    }

    /// The rest of the reading is discarded rather than played on the new route: the
    /// user hears it again from its start, not from where the route changed.
    func testARouteChangeMidStreamDropsTheRestAndReportsFlushedAtItsFinish() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())

        f.scheduler.changeRoute()
        f.playback.enqueue(pcm16Chunk())
        XCTAssertEqual(f.endings.all, [])
        f.playback.finishStream(onDrained: f.endings.record)

        XCTAssertEqual(f.endings.all, [.flushed])
        XCTAssertEqual(f.scheduler.calls, [.start(sampleRate: 24_000, channels: 1),
                                           .schedule(frameCount: 120), .stop])
        XCTAssertEqual(f.unavailable.reasons, [])

        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        f.scheduler.playAll()
        XCTAssertEqual(f.endings.all, [.flushed, .playedBack],
                       "the reading spoken again plays on a fresh engine")
        XCTAssertEqual(f.scheduler.starts, 2)
    }

    func testARouteChangeFromAStoppedEngineIsIgnored() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        let stale = f.scheduler.onConfigurationChange
        f.playback.stopAndFlush()
        XCTAssertNil(f.scheduler.onConfigurationChange)

        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        stale?()
        f.scheduler.playAll()

        XCTAssertEqual(f.endings.all, [.playedBack])
    }

    // MARK: - Output lost

    func testAnEngineThatWillNotStartFailsTheStreamAndIsReported() async {
        let f = makeFixture()
        f.scheduler.startFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSetup, detail: "-10868")
        var playingWhenReported: Bool?
        f.playback.onUnavailable = { [weak playback = f.playback] reason in
            playingWhenReported = playback?.engineRunning
            f.unavailable.reasons.append(reason)
        }

        f.playback.enqueue(pcm16Chunk())
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)

        XCTAssertEqual(f.unavailable.reasons, ["playback_setup: -10868"])
        XCTAssertEqual(playingWhenReported, false, "reported with the player already idle")
        XCTAssertEqual(f.endings.all, [.failed])
        XCTAssertEqual(f.scheduler.starts, 1, "the rest of the stream is dropped")

        f.scheduler.startFailure = nil
        f.playback.enqueue(pcm16Chunk())
        XCTAssertTrue(f.playback.engineRunning, "the next stream tries a fresh engine")
    }

    func testARefusedBufferFailsTheStreamAndIsReported() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk())
        f.playback.finishStream(onDrained: f.endings.record)
        f.scheduler.scheduleFailure = AudioPlaybackSchedulerFailure(
            stage: .playbackSchedule, detail: "refused")

        f.playback.enqueue(pcm16Chunk())

        XCTAssertEqual(f.endings.all, [.failed])
        XCTAssertEqual(f.unavailable.reasons, ["playback_schedule: refused"])
        XCTAssertFalse(f.playback.engineRunning)
        XCTAssertTrue(f.sink.names.contains("playback.schedule_failed"))
    }

    // MARK: - PCM16 to AVAudioPCMBuffer conversion

    func testPCM16ConversionProducesCorrectFrameCount() async {
        let f = makeFixture()
        f.playback.enqueue(pcm16Chunk(sampleCount: 240))
        f.playback.enqueue(pcm16Chunk(sampleCount: 100))
        XCTAssertEqual(f.scheduler.scheduledFrames, [240, 100])
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

    func testOddByteCountChunkTruncatesToWholeFrames() {
        let f = makeFixture()
        // 5 bytes of PCM16 mono = 2 whole frames (4 bytes), 1 byte remainder.
        let chunk = VoiceAudioChunk(
            data: Data(repeating: 0, count: 5),
            format: VoiceAudioFormat(sampleRate: 24_000, channels: 1),
            timestamp: 0
        )

        f.playback.enqueue(chunk)

        XCTAssertEqual(f.scheduler.scheduledFrames, [2], "truncated to 2 whole frames")
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
