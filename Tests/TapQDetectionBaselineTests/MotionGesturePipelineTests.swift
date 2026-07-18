import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class MotionGesturePipelineTests: XCTestCase {
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

    private static let zigzag = [0.0, 0.35, -0.35, 0.35, -0.35, 0.0]
    private static let flat = [0.0, 0.01, -0.01, 0.01, -0.01, 0.0]

    private func feedNod(_ pipeline: inout MotionGesturePipeline,
                         at start: TimeInterval) -> [HeadGesture] {
        Self.zigzag.enumerated().compactMap { index, value in
            pipeline.ingestGesture(
                pitch: value, yaw: Self.flat[index],
                time: start + Double(index) * 0.04)
        }
    }

    private func feedShake(_ pipeline: inout MotionGesturePipeline,
                           at start: TimeInterval) -> [HeadGesture] {
        Self.zigzag.enumerated().compactMap { index, value in
            pipeline.ingestGesture(
                pitch: Self.flat[index], yaw: value,
                time: start + Double(index) * 0.04)
        }
    }

    private func feedTap(_ pipeline: inout MotionGesturePipeline,
                         at start: TimeInterval) -> [TapCommand] {
        let acceleration = [0.0, 0.6, 0.0, 0.0]
        return acceleration.enumerated().compactMap { index, value in
            pipeline.ingestTap(
                acceleration: value, rotation: 0,
                time: start + Double(index) * 0.02)
        }
    }

    func testDoubleNodEmitsOnce() {
        var pipeline = MotionGesturePipeline()
        XCTAssertTrue(feedNod(&pipeline, at: 0).isEmpty)
        XCTAssertEqual(feedNod(&pipeline, at: 0.8), [.nod])
    }

    func testShakeEmitsImmediatelyAndCancelsPendingNod() {
        var pipeline = MotionGesturePipeline()
        XCTAssertTrue(feedNod(&pipeline, at: 0).isEmpty)
        XCTAssertEqual(feedShake(&pipeline, at: 0.4), [.shake])
        XCTAssertTrue(feedNod(&pipeline, at: 1.64).isEmpty)
        XCTAssertEqual(feedNod(&pipeline, at: 2.44), [.nod])
    }

    func testDoubleTapEmitsOnce() {
        var pipeline = MotionGesturePipeline()
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)
        XCTAssertEqual(feedTap(&pipeline, at: 0.32), [.tap])
    }

    func testSingleTapWindowCannotEchoIntoDoubleTap() {
        var pipeline = MotionGesturePipeline()
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)

        let quietResults = (4...20).compactMap { index in
            pipeline.ingestTap(
                acceleration: 0,
                rotation: 0,
                time: Double(index) * 0.02
            )
        }

        XCTAssertTrue(quietResults.isEmpty)
    }

    func testTapDiagnosticsExplainNearMissAndPendingExpiration() throws {
        let sink = RecordingSink()
        var pipeline = MotionGesturePipeline(
            tapConfig: TapConfig(amplitudeThreshold: 0.5),
            diagnosticSink: sink
        )

        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)
        let nearMiss = [0.0, 0.3, 0.0, 0.0]
        for (index, value) in nearMiss.enumerated() {
            _ = pipeline.ingestTap(
                acceleration: value,
                rotation: 0.1,
                time: 0.32 + Double(index) * 0.02
            )
        }
        _ = pipeline.ingestTap(acceleration: 0, rotation: 0, time: 0.7)

        let pending = try XCTUnwrap(sink.events.first { $0.name == "tap.pending" })
        XCTAssertEqual(pending.fields["peak_g"], "0.6000")
        XCTAssertEqual(pending.fields["pair_window_ms"], "500")

        let rejected = try XCTUnwrap(
            sink.events.first { $0.name == "tap.candidate_rejected" }
        )
        XCTAssertEqual(rejected.fields["reason"], "below_amplitude")
        XCTAssertEqual(rejected.fields["peak_g"], "0.3000")
        XCTAssertEqual(rejected.fields["returned_to_baseline"], "true")
        XCTAssertNotNil(rejected.fields["pair_gap_ms"])

        let expired = try XCTUnwrap(
            sink.events.first { $0.name == "tap.pending_expired" }
        )
        XCTAssertEqual(expired.fields["pair_window_ms"], "500")
        XCTAssertNotNil(expired.fields["gap_ms"])
    }

    func testTapDiagnosticsReportWaitingForBaselineOnce() {
        let sink = RecordingSink()
        var pipeline = MotionGesturePipeline(diagnosticSink: sink)
        let rising = [0.0, 0.0, 0.0, 0.6]
        for (index, value) in rising.enumerated() {
            _ = pipeline.ingestTap(
                acceleration: value,
                rotation: 0.1,
                time: Double(index) * 0.02
            )
        }

        let waiting = sink.events.filter { $0.name == "tap.candidate_waiting" }
        XCTAssertEqual(waiting.count, 1)
        XCTAssertEqual(waiting.first?.fields["reason"], "not_returned_to_baseline")
        XCTAssertEqual(waiting.first?.fields["returned_to_baseline"], "false")

        _ = pipeline.ingestTap(acceleration: 0, rotation: 0.1, time: 0.08)
        XCTAssertEqual(sink.events.filter { $0.name == "tap.pending" }.count, 1)
        XCTAssertEqual(sink.events.filter { $0.name == "tap.candidate_waiting" }.count, 1)
    }

    func testResetReportsPendingTapCancellation() {
        let sink = RecordingSink()
        var pipeline = MotionGesturePipeline(diagnosticSink: sink)
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)

        pipeline.reset()

        let cancellation = sink.events.last { $0.name == "tap.pending_cancelled" }
        XCTAssertEqual(cancellation?.fields["reason"], "pipeline_reset")
    }

    func testTapSampleTraceRecordsEverySampleThroughSixHundredMilliseconds() throws {
        let sink = RecordingSink()
        var pipeline = MotionGesturePipeline(
            tapConfig: TapConfig(amplitudeThreshold: 0.5),
            diagnosticSink: sink
        )
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)

        _ = pipeline.ingestTap(acceleration: 0.04, rotation: 0.1, time: 0.08)
        _ = pipeline.ingestTap(acceleration: 0.06, rotation: 0.2, time: 0.66)
        _ = pipeline.ingestTap(acceleration: 0.07, rotation: 0.3, time: 0.68)

        let started = try XCTUnwrap(
            sink.events.first { $0.name == "tap.sample_trace_started" }
        )
        XCTAssertEqual(started.fields["duration_ms"], "600")
        XCTAssertEqual(started.fields["start_timestamp_s"], "0.060000")

        let samples = sink.events.filter { $0.name == "tap.sample" }
        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples.map { $0.fields["sample_index"] }, ["0", "1", "2"])
        XCTAssertEqual(samples.map { $0.fields["offset_ms"] }, ["0", "20", "600"])
        XCTAssertEqual(samples.map { $0.fields["timestamp_s"] },
                       ["0.060000", "0.080000", "0.660000"])
        XCTAssertEqual(samples[1].fields["acceleration_g"], "0.0400")
        XCTAssertEqual(samples[1].fields["rotation_rad_s"], "0.1000")
        XCTAssertEqual(samples[1].fields["threshold_g"], "0.5000")
        XCTAssertEqual(samples[1].fields["elevated_level_g"], "0.2500")

        let finished = try XCTUnwrap(
            sink.events.first { $0.name == "tap.sample_trace_finished" }
        )
        XCTAssertEqual(finished.fields["duration_ms"], "600")
        XCTAssertEqual(finished.fields["samples"], "3")
    }

    func testResetCancelsTapSampleTraceAndStopsSampleLogging() {
        let sink = RecordingSink()
        var pipeline = MotionGesturePipeline(diagnosticSink: sink)
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)
        XCTAssertEqual(sink.events.filter { $0.name == "tap.sample" }.count, 1)

        pipeline.reset()
        _ = pipeline.ingestTap(acceleration: 0.2, rotation: 0, time: 0.08)

        let cancellation = sink.events.last { $0.name == "tap.sample_trace_cancelled" }
        XCTAssertEqual(cancellation?.fields["reason"], "pipeline_reset")
        XCTAssertEqual(cancellation?.fields["samples"], "1")
        XCTAssertEqual(sink.events.filter { $0.name == "tap.sample" }.count, 1)
    }

    func testTapCanBeDisabledWithoutAffectingGesture() {
        var pipeline = MotionGesturePipeline(tapDetectionEnabled: false)
        XCTAssertTrue(feedTap(&pipeline, at: 0).isEmpty)
        XCTAssertTrue(feedTap(&pipeline, at: 0.32).isEmpty)
        XCTAssertEqual(feedShake(&pipeline, at: 1), [.shake])
    }

    func testCombinedSampleAPIProducesDetection() {
        var pipeline = MotionGesturePipeline()
        var result = MotionDetectionResult()
        for (index, value) in Self.zigzag.enumerated() {
            result = pipeline.ingest(.init(
                timestamp: Double(index) * 0.04,
                pitch: Self.flat[index], yaw: value,
                accelerationMagnitude: 0, rotationMagnitude: 0))
        }
        XCTAssertEqual(result.gesture, .shake)
    }

    func testResetClearsPendingPairState() {
        var pipeline = MotionGesturePipeline()
        XCTAssertTrue(feedNod(&pipeline, at: 0).isEmpty)
        pipeline.reset()
        XCTAssertTrue(feedNod(&pipeline, at: 0.8).isEmpty)
    }
}
