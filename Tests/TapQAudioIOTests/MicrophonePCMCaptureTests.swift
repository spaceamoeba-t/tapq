import AVFoundation
import XCTest
import TapQContracts
@testable import TapQAudioIO

/// `MicrophonePCMCapture`, the microphone as wire-format PCM: blocks arrive on the main
/// actor in capture order, `stop` is idempotent, and a source that dies mid-window reaches
/// the owner rather than the log.
@MainActor
final class MicrophonePCMCaptureTests: XCTestCase {

    // MARK: - Test doubles

    /// A `VoiceAudioSource` that replays buffers without hardware.
    private final class FakeAudioSource: VoiceAudioSource {
        var startFailure: (any Error)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var bufferHandler: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var invalidationHandler: (@MainActor (VoiceAudioSourceFailure) -> Void)?

        func start(
            onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
            onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
        ) throws {
            starts += 1
            bufferHandler = onBuffer
            invalidationHandler = onInvalidation
            if let startFailure { throw startFailure }
        }

        /// Deliberately keeps its handlers: a real tap thread does not stop the instant
        /// the main actor decides the window is over, and the stale-block and stale-failure
        /// tests below would be vacuous against a double that went inert on `stop`.
        func stop() {
            stops += 1
        }

        func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64 = 1_000_000_000) {
            bufferHandler?(buffer, AVAudioTime(hostTime: hostTime))
        }

        func invalidate(
            _ failure: VoiceAudioSourceFailure = .init(
                stage: .configurationChanged,
                detail: "audio input route changed"
            )
        ) {
            invalidationHandler?(failure)
        }
    }

    /// Reference box so blocks collected inside a closure survive teardown.
    @MainActor
    private final class BlockLog {
        private(set) var blocks: [MicrophonePCMCapture.Block] = []
        private(set) var failures: [VoiceAudioSourceFailure] = []
        func append(_ block: MicrophonePCMCapture.Block) { blocks.append(block) }
        func append(failure: VoiceAudioSourceFailure) { failures.append(failure) }
    }

    /// The block-level `start` with nothing to do: `{ _ in }` alone fits both overloads.
    private func startIgnoringBlocks(_ capture: MicrophonePCMCapture) throws {
        try capture.start(onBlock: { (_: MicrophonePCMCapture.Block) in },
                          onFailure: { (_: VoiceAudioSourceFailure) in })
    }

    /// Waits for `condition`, bounded: the event a test asserts, not a count of hops.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { await Task.yield() }
    }

    private func makeCapture(
        source: FakeAudioSource,
        format: VoiceAudioFormat = .pcm16Mono24k
    ) -> MicrophonePCMCapture {
        MicrophonePCMCapture(format: format, makeAudioSource: { source })
    }

    /// 480 frames = 10 ms at 48 kHz. Tiny buffers (< ~8 frames) may produce zero output
    /// after a 2:1 downsample because the SRC filter's priming delay consumes all input.
    private func monoFloatBuffer(
        values: [Float],
        sampleRate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(values.count)
        ))
        buffer.frameLength = AVAudioFrameCount(values.count)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (i, v) in values.enumerated() {
            data[0][i * buffer.stride] = v
        }
        return buffer
    }

    // MARK: - Delivery

    func testStartOpensTheSourceAndReportsCapturing() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        XCTAssertFalse(capture.isCapturing, "nothing is open before the first start")

        try startIgnoringBlocks(capture)

        XCTAssertEqual(source.starts, 1)
        XCTAssertTrue(capture.isCapturing)
    }

    func testBlocksArriveOnTheMainActorInCaptureOrder() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()

        try capture.start(
            onBlock: { log.append($0) },
            onFailure: { log.append(failure: $0) }
        )

        // Three windows, each louder than the last and each stamped later, so a reordered
        // hand-off would be visible in either the RMS or the timestamp.
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.1, count: 480)),
                    hostTime: 1_000_000_000)
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.4, count: 480)),
                    hostTime: 2_000_000_000)
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.8, count: 480)),
                    hostTime: 3_000_000_000)

        // Wait for delivery to finish rather than for a fixed number of scheduler turns: the
        // hand-off is done once nothing new has arrived for several polls (bounded at 2 s).
        var quiet = 0, seen = -1
        for _ in 0..<100 where quiet < 3 {
            try await Task.sleep(nanoseconds: 20_000_000)
            quiet = log.blocks.count == seen && seen > 0 ? quiet + 1 : 0
            seen = log.blocks.count
        }

        // Asserted as a subsequence rather than an exact triple: the SRC's priming delay is
        // the converter's business, and a block it declines to emit is not a hand-off bug.
        // What the hand-off promises is that whatever arrives, arrives in capture order.
        let stamps = log.blocks.map(\.chunk.timestamp)
        XCTAssertFalse(stamps.isEmpty, "converted audio must reach the owner")
        let expected = [UInt64(1_000_000_000), 2_000_000_000, 3_000_000_000]
            .map { AVAudioTime.seconds(forHostTime: $0) }
        XCTAssertEqual(stamps, expected.filter { stamps.contains($0) },
                       "blocks arrive in capture order, not scheduler order")
        let levels = log.blocks.map(\.rms)
        XCTAssertEqual(levels, levels.sorted(),
                       "each block's RMS travels with it, so order is visible twice")
        XCTAssertTrue(log.failures.isEmpty)
    }

    func testDeliveredChunksCarryTheDeclaredWireFormat() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()

        try capture.start(onBlock: { log.append($0) }, onFailure: { _ in })
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.5, count: 480)))

        for _ in 0..<30 { await Task.yield() }

        let chunk = try XCTUnwrap(log.blocks.first?.chunk)
        XCTAssertEqual(chunk.format, .pcm16Mono24k)
        XCTAssertGreaterThan(chunk.data.count, 0)
        XCTAssertEqual(chunk.data.count % 2, 0, "PCM16 mono: two bytes per frame")
    }

    // MARK: - Stop

    func testStopIsIdempotent() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        try startIgnoringBlocks(capture)

        capture.stop()
        capture.stop()
        capture.stop()

        XCTAssertEqual(source.stops, 1, "the source is torn down exactly once")
        XCTAssertFalse(capture.isCapturing)
    }

    func testStopBeforeStartIsHarmless() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)

        capture.stop()

        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(source.stops, 0)
        XCTAssertFalse(capture.isCapturing)
    }

    func testBlocksFromAStoppedWindowAreDropped() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()

        try capture.start(onBlock: { log.append($0) }, onFailure: { _ in })
        capture.stop()

        // A tap thread that has not noticed the teardown yet.
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.5, count: 480)))
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(log.blocks.isEmpty, "a closed window delivers nothing")
    }

    func testRestartAfterStopOpensAFreshSource() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        var sources = [first, second]
        let capture = MicrophonePCMCapture(makeAudioSource: { sources.removeFirst() })

        try startIgnoringBlocks(capture)
        capture.stop()
        try startIgnoringBlocks(capture)

        XCTAssertEqual(first.starts, 1)
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.starts, 1, "a production source cannot be reopened")
    }

    // MARK: - Failure

    func testStartThrowsAndLeavesTheCaptureStopped() async throws {
        let source = FakeAudioSource()
        source.startFailure = VoiceAudioSourceFailure(
            stage: .engineStart, detail: "input device disappeared")
        let capture = makeCapture(source: source)

        do {
            try startIgnoringBlocks(capture)
            return XCTFail("a source that cannot start must surface the error")
        } catch let failure as VoiceAudioSourceFailure {
            XCTAssertEqual(failure.stage, .engineStart)
        }

        XCTAssertFalse(capture.isCapturing, "a failed start leaves nothing open")
    }

    func testMidWindowInvalidationReachesTheOwner() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()

        try capture.start(
            onBlock: { log.append($0) },
            onFailure: { log.append(failure: $0) }
        )
        source.invalidate()

        XCTAssertEqual(log.failures.count, 1)
        XCTAssertEqual(log.failures.first?.stage, .configurationChanged)
    }

    func testInvalidationAfterStopIsDropped() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()

        try capture.start(onBlock: { _ in }, onFailure: { log.append(failure: $0) })
        capture.stop()
        // The source notices the route change after the owner already closed the window.
        source.invalidate()

        XCTAssertTrue(log.failures.isEmpty,
                      "a window the owner already closed has no news to deliver")
    }

    /// 07-9: a chunk is stamped on the host-time clock in seconds, not host ticks over 1e9
    /// (on Apple Silicon a tick is ~41.67 ns, so that was ~24 times off).
    func testAChunkIsStampedWithItsHostTimeInSeconds() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        let log = BlockLog()
        try capture.start(onBlock: { log.append($0) }, onFailure: { _ in })

        let hostTime = mach_absolute_time()
        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.5, count: 4_800)),
                    hostTime: hostTime)
        await waitUntil { !log.blocks.isEmpty }

        let stamp = try XCTUnwrap(log.blocks.first?.chunk.timestamp)
        XCTAssertEqual(stamp, AVAudioTime.seconds(forHostTime: hostTime))
        XCTAssertEqual(stamp, ProcessInfo.processInfo.systemUptime, accuracy: 5,
                       "the capture clock is the clock the player stamps its span on")
    }

    // MARK: - AudioCapturing

    func testTheAudioCapturingStartDeliversChunks() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        var chunks: [VoiceAudioChunk] = []
        let audio: any AudioCapturing = capture
        try audio.start(onBlock: { chunks.append($0) }, onFailure: { _ in })

        source.emit(try monoFloatBuffer(values: [Float](repeating: 0.5, count: 4_800)))
        await waitUntil { !chunks.isEmpty }

        XCTAssertEqual(chunks.first?.format, .pcm16Mono24k)
        audio.stop()
        XCTAssertFalse(capture.isCapturing)
    }

    /// D7: the route moving is a reopen; anything else is the microphone gone.
    func testSourceFailuresAreClassifiedForSpeechInput() async throws {
        let source = FakeAudioSource()
        let capture = makeCapture(source: source)
        var failures: [AudioDeviceFailure] = []
        let audio: any AudioCapturing = capture
        try audio.start(onBlock: { _ in }, onFailure: { failures.append($0) })

        source.invalidate()

        XCTAssertEqual(failures, [.configurationChanged])
        XCTAssertEqual(
            MicrophonePCMCapture.deviceFailure(.init(stage: .engineStart, detail: "gone")),
            .unavailable("engine_start: gone"))
    }

    // MARK: - Conversion helpers

    func testExtractPCM16DataFromInterleavedBuffer() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let int16Data = try XCTUnwrap(buffer.int16ChannelData)
        int16Data[0][0] = 1000
        int16Data[0][1] = -1000
        int16Data[0][2] = 32767
        int16Data[0][3] = -32768

        let data = MicrophonePCMCapture.extractPCM16Data(from: buffer)

        XCTAssertEqual(data.count, 8, "4 int16 samples = 8 bytes")
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(samples, [1000, -1000, 32767, -32768])
    }

    func testComputeRMS() async throws {
        let buffer = try monoFloatBuffer(values: [0.5, -0.5, 0.5, -0.5])

        XCTAssertEqual(MicrophonePCMCapture.computeRMS(buffer), 0.5, accuracy: 1e-6)
    }
}
