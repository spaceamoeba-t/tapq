import AVFoundation
import XCTest
import TapQAudioCaptureBridge
import TapQAudioCaptureBridgeTestSupport
import TapQContracts
@testable import TapQAppleAdapters

/// One tick per nanosecond and a round anchor, so every expected timestamp in the source
/// tests is readable arithmetic. File scope keeps it reachable from the `@Sendable` anchor
/// provider the source is built with.
private let testAnchor = AudioClockAnchor(
    hostTime: 1_000_000_000,
    uptime: 500,
    timebaseNumerator: 1,
    timebaseDenominator: 1
)

@MainActor
final class MicrophoneEnvelopeSourceTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private final class FakeAudioSource: VoiceAudioSource {
        var startFailure: (any Error)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var buffers: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
        private var invalidation: (@MainActor (VoiceAudioSourceFailure) -> Void)?

        func start(
            onBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
            onInvalidation: @escaping @MainActor (VoiceAudioSourceFailure) -> Void
        ) throws {
            starts += 1
            buffers = onBuffer
            invalidation = onInvalidation
            if let startFailure { throw startFailure }
        }

        func stop() {
            stops += 1
        }

        func emit(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
            buffers?(buffer, AVAudioTime(hostTime: hostTime))
        }

        func invalidate(
            _ failure: VoiceAudioSourceFailure = .init(
                stage: .configurationChanged,
                detail: "audio input route changed"
            )
        ) {
            invalidation?(failure)
        }
    }

    // MARK: - Envelope math

    func testEnvelopeOfAConstantToneIsItsAmplitude() throws {
        let buffer = try pcmBuffer(channels: [[0.5, -0.5, 0.5, -0.5]])
        let envelope = try XCTUnwrap(MicrophoneEnvelopeSource.envelope(of: buffer))
        XCTAssertEqual(envelope.rms, 0.5, accuracy: 1e-6)
        XCTAssertEqual(envelope.peak, 0.5, accuracy: 1e-6)
    }

    func testEnvelopeSeparatesPeakFromRMS() throws {
        // A single loud frame in an otherwise quiet block: peak sees it, RMS averages it
        // away. Keeping both is what lets the study distinguish a tap from speech.
        let buffer = try pcmBuffer(channels: [[0, 0, 0, 1.0]])
        let envelope = try XCTUnwrap(MicrophoneEnvelopeSource.envelope(of: buffer))
        XCTAssertEqual(envelope.rms, 0.5, accuracy: 1e-6)
        XCTAssertEqual(envelope.peak, 1.0, accuracy: 1e-6)
    }

    func testEnvelopeOfSilenceIsZero() throws {
        let buffer = try pcmBuffer(channels: [[0, 0, 0, 0]])
        let envelope = try XCTUnwrap(MicrophoneEnvelopeSource.envelope(of: buffer))
        XCTAssertEqual(envelope.rms, 0)
        XCTAssertEqual(envelope.peak, 0)
    }

    func testEnvelopeAveragesAcrossChannels() throws {
        let buffer = try pcmBuffer(channels: [[1, 1], [0, 0]])
        let envelope = try XCTUnwrap(MicrophoneEnvelopeSource.envelope(of: buffer))
        // Mean square is (1 + 1 + 0 + 0) / 4.
        XCTAssertEqual(envelope.rms, (0.5 as Double).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(envelope.peak, 1.0, accuracy: 1e-6)
    }

    func testEmptyBlockHasNoEnvelope() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 0
        XCTAssertNil(MicrophoneEnvelopeSource.envelope(of: buffer))
    }

    func testIntegerBlockHasNoEnvelope() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        XCTAssertNil(
            MicrophoneEnvelopeSource.envelope(of: buffer),
            "a format the tap cannot reduce is dropped rather than guessed at"
        )
    }

    // MARK: - Clock alignment

    func testAnchorConvertsHostTimeToTheMotionClock() {
        // Apple silicon's timebase: 125 nanoseconds per 3 ticks.
        let anchor = AudioClockAnchor(
            hostTime: 1_000_000,
            uptime: 1_234.5,
            timebaseNumerator: 125,
            timebaseDenominator: 3
        )

        XCTAssertEqual(anchor.uptime(forHostTime: 1_000_000), 1_234.5, accuracy: 1e-9)
        // +24_000 ticks = 1_000_000 ns = 1 ms.
        XCTAssertEqual(anchor.uptime(forHostTime: 1_024_000), 1_234.501, accuracy: 1e-9)
        XCTAssertEqual(
            anchor.uptime(forHostTime: 976_000), 1_234.499, accuracy: 1e-9,
            "a block stamped before the anchor read converts to a time before it"
        )
    }

    func testAnchorSurvivesADegenerateTimebase() {
        let anchor = AudioClockAnchor(
            hostTime: 0, uptime: 10, timebaseNumerator: 1, timebaseDenominator: 0)
        XCTAssertEqual(anchor.timebaseDenominator, 1)
        XCTAssertEqual(anchor.uptime(forHostTime: 1_000_000_000), 11, accuracy: 1e-9)
    }

    func testCurrentAnchorReadsAUsableTimebase() {
        let anchor = AudioClockAnchor.current()
        XCTAssertGreaterThan(anchor.hostTime, 0)
        XCTAssertGreaterThan(anchor.uptime, 0)
        XCTAssertGreaterThan(anchor.timebaseNumerator, 0)
        XCTAssertGreaterThan(anchor.timebaseDenominator, 0)
    }

    // MARK: - Source lifecycle

    func testTrackIsReportedOnceBeforeBlocksOnTheMotionClock() async throws {
        let audio = FakeAudioSource()
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: { audio },
            anchorProvider: { testAnchor }
        )
        var tracks: [MicrophoneEnvelopeTrack] = []
        var blocks: [MicrophoneEnvelopeBlock] = []
        let received = expectation(description: "two blocks")
        received.expectedFulfillmentCount = 2

        try source.start(
            onTrack: { tracks.append($0) },
            onBlock: {
                XCTAssertEqual(tracks.count, 1, "the track is known before any block")
                blocks.append($0)
                received.fulfill()
            },
            onInvalidation: { XCTFail("unexpected invalidation: \($0)") }
        )
        audio.emit(
            try pcmBuffer(channels: [[0.5, -0.5, 0.5, -0.5]]),
            hostTime: 1_000_000_000
        )
        audio.emit(
            try pcmBuffer(channels: [[0, 0, 0, 1.0]]),
            hostTime: 1_500_000_000
        )
        await fulfillment(of: [received], timeout: 2)

        XCTAssertEqual(tracks, [MicrophoneEnvelopeTrack(sampleRate: 48_000, blockFrames: 4)])
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].timestamp, 500, accuracy: 1e-9)
        XCTAssertEqual(blocks[0].rms, 0.5, accuracy: 1e-6)
        XCTAssertEqual(
            blocks[1].timestamp, 500.5, accuracy: 1e-9,
            "half a second of host ticks is half a second on the motion clock"
        )
        XCTAssertEqual(blocks[1].peak, 1.0, accuracy: 1e-6)
    }

    func testStopIsIdempotentAndDropsBlocksQueuedBehindIt() async throws {
        let audio = FakeAudioSource()
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: { audio },
            anchorProvider: { testAnchor }
        )
        var blocks: [MicrophoneEnvelopeBlock] = []
        let first = expectation(description: "first block")

        try source.start(
            onTrack: { _ in },
            onBlock: { blocks.append($0); first.fulfill() },
            onInvalidation: { XCTFail("unexpected invalidation: \($0)") }
        )
        audio.emit(try pcmBuffer(channels: [[0.5, 0.5]]), hostTime: 1_000_000_000)
        await fulfillment(of: [first], timeout: 2)

        source.stop()
        source.stop()
        XCTAssertEqual(audio.stops, 1)
        XCTAssertFalse(source.isRunning)

        audio.emit(try pcmBuffer(channels: [[0.9, 0.9]]), hostTime: 1_100_000_000)
        for _ in 0..<8 { await Task.yield() }
        XCTAssertEqual(blocks.count, 1, "a block delivered after teardown is dropped")
    }

    func testStartFailureThrowsATypedFailureAndLeavesNothingOpen() {
        let audio = FakeAudioSource()
        audio.startFailure = VoiceAudioSourceFailure(
            stage: .engineStart, detail: "input device disappeared")
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: { audio },
            anchorProvider: { testAnchor }
        )

        XCTAssertThrowsError(
            try source.start(
                onTrack: { _ in XCTFail("a failed start has no track") },
                onBlock: { _ in XCTFail("a failed start has no blocks") },
                onInvalidation: { _ in }
            )
        ) { error in
            XCTAssertEqual(
                error as? MicrophoneEnvelopeFailure,
                MicrophoneEnvelopeFailure(
                    stage: .engineStart, detail: "input device disappeared")
            )
        }
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(audio.stops, 1)
    }

    func testSecondStartWhileOpenIsRejectedWithoutDisturbingTheFirst() throws {
        let audio = FakeAudioSource()
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: { audio },
            anchorProvider: { testAnchor }
        )

        try source.start(onTrack: { _ in }, onBlock: { _ in }, onInvalidation: { _ in })
        XCTAssertThrowsError(
            try source.start(onTrack: { _ in }, onBlock: { _ in }, onInvalidation: { _ in })
        ) { error in
            XCTAssertEqual(
                (error as? MicrophoneEnvelopeFailure)?.stage, .alreadyRunning)
        }
        XCTAssertTrue(source.isRunning)
        XCTAssertEqual(audio.starts, 1)
        XCTAssertEqual(audio.stops, 0)
    }

    func testRouteChangeSurfacesATypedFailureAndTearsDownOnce() throws {
        let audio = FakeAudioSource()
        let sink = RecordingSink()
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: { audio },
            anchorProvider: { testAnchor },
            diagnosticSink: sink
        )
        var failures: [MicrophoneEnvelopeFailure] = []

        try source.start(
            onTrack: { _ in },
            onBlock: { _ in },
            onInvalidation: { failures.append($0) }
        )
        audio.invalidate()
        audio.invalidate()

        XCTAssertEqual(failures, [MicrophoneEnvelopeFailure(
            stage: .configurationChanged, detail: "audio input route changed")])
        XCTAssertFalse(source.isRunning)
        XCTAssertEqual(audio.stops, 1)
        let event = sink.events.last { $0.name == "capture.invalidated" }
        XCTAssertEqual(event?.level, .warning)
        XCTAssertEqual(event?.fields["stage"], "configuration_changed")
    }

    func testFreshWindowAfterARouteChangeIgnoresTheOldSource() async throws {
        let first = FakeAudioSource()
        let second = FakeAudioSource()
        let sources = [first, second]
        var factoryCalls = 0
        let source = MicrophoneEnvelopeSource(
            makeAudioSource: {
                defer { factoryCalls += 1 }
                return sources[factoryCalls]
            },
            anchorProvider: { testAnchor }
        )

        try source.start(onTrack: { _ in }, onBlock: { _ in }, onInvalidation: { _ in })
        first.invalidate()

        var blocks: [MicrophoneEnvelopeBlock] = []
        let delivered = expectation(description: "block from the second window")
        try source.start(
            onTrack: { _ in },
            onBlock: { blocks.append($0); delivered.fulfill() },
            onInvalidation: { XCTFail("unexpected invalidation: \($0)") }
        )
        first.emit(try pcmBuffer(channels: [[0.9, 0.9]]), hostTime: 1_000_000_000)
        second.emit(try pcmBuffer(channels: [[0.25, -0.25]]), hostTime: 1_000_000_000)
        await fulfillment(of: [delivered], timeout: 2)
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(factoryCalls, 2)
        XCTAssertEqual(blocks.count, 1, "the discarded source's blocks never arrive")
        XCTAssertEqual(blocks[0].rms, 0.25, accuracy: 1e-6)
    }

    // MARK: - Teardown reporting

    func testEngineTeardownFailureReachesItsOwner() {
        let engine = TapQThrowingAudioCaptureEngine()
        let audio = AVAudioEngineVoiceAudioSource(capture: engine)
        var failures: [VoiceAudioSourceFailure] = []
        audio.onTeardownFailure = { failures.append($0) }

        audio.stop()

        XCTAssertEqual(failures.count, 1, "a failed engine stop is reported, not discarded")
        XCTAssertEqual(failures.first?.stage, .audioTeardown)
        XCTAssertTrue(failures.first?.detail.contains("engine-running") == true)
    }

    // MARK: - Helpers

    /// Builds a float PCM buffer from per-channel frames. Needs no audio hardware.
    private func pcmBuffer(
        channels: [[Float]],
        sampleRate: Double = 48_000
    ) throws -> AVAudioPCMBuffer {
        let frames = try XCTUnwrap(channels.first?.count)
        let format = try XCTUnwrap(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count)
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for (index, samples) in channels.enumerated() {
            XCTAssertEqual(samples.count, frames, "channels must be the same length")
            for (frame, value) in samples.enumerated() {
                data[index][frame * buffer.stride] = value
            }
        }
        return buffer
    }
}
