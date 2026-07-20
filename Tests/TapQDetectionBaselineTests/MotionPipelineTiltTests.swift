import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

/// Double-tilt pairing and swipe gating at the pipeline level. Analyzer-shape coverage
/// lives in `TiltAnalyzerTests`/`SwipeAnalyzerTests`; these tests drive timing.
final class MotionPipelineTiltTests: XCTestCase {
    private let sampleInterval = 0.04  // 25 Hz

    /// Feeds one complete lateral tilt excursion (out and back) starting at `start`,
    /// returning the timestamp after the excursion.
    @discardableResult
    private func feedTilt(
        _ pipeline: inout MotionGesturePipeline,
        direction: Double, start: TimeInterval,
        collecting: inout [TiltCommand]
    ) -> TimeInterval {
        let samples = 24
        for index in 0..<samples {
            let phase = Double(index) / Double(samples - 1)
            let roll = direction * 0.25 * sin(phase * .pi)
            let time = start + Double(index) * sampleInterval
            if let tilt = pipeline.ingestTilt(roll: roll, pitch: 0, yaw: 0, time: time) {
                collecting.append(tilt)
            }
        }
        return start + Double(samples) * sampleInterval
    }

    func testTwoSameDirectionTiltsEmitOneCommand() {
        var pipeline = MotionGesturePipeline()
        var emitted: [TiltCommand] = []
        let afterFirst = feedTilt(&pipeline, direction: 1, start: 0, collecting: &emitted)
        XCTAssertEqual(emitted, [], "a single tilt must never navigate")
        feedTilt(&pipeline, direction: 1, start: afterFirst + 0.3, collecting: &emitted)
        XCTAssertEqual(emitted, [.tiltRight])
    }

    func testTwoLeftTiltsEmitTiltLeft() {
        var pipeline = MotionGesturePipeline()
        var emitted: [TiltCommand] = []
        let afterFirst = feedTilt(&pipeline, direction: -1, start: 0, collecting: &emitted)
        feedTilt(&pipeline, direction: -1, start: afterFirst + 0.3, collecting: &emitted)
        XCTAssertEqual(emitted, [.tiltLeft])
    }

    func testOppositeDirectionsRestartThePairInsteadOfEmitting() {
        var pipeline = MotionGesturePipeline()
        var emitted: [TiltCommand] = []
        let afterFirst = feedTilt(&pipeline, direction: 1, start: 0, collecting: &emitted)
        let afterSecond = feedTilt(
            &pipeline, direction: -1, start: afterFirst + 0.3, collecting: &emitted)
        XCTAssertEqual(emitted, [], "a right-left wobble is ambiguity, not navigation")
        // The left tilt became the new pending half; a second left completes it.
        feedTilt(&pipeline, direction: -1, start: afterSecond + 0.3, collecting: &emitted)
        XCTAssertEqual(emitted, [.tiltLeft])
    }

    func testExpiredFirstTiltDoesNotPair() {
        var pipeline = MotionGesturePipeline()
        var emitted: [TiltCommand] = []
        let afterFirst = feedTilt(&pipeline, direction: 1, start: 0, collecting: &emitted)
        // Past doubleTiltWindowSeconds (1.6 s): the pending half expires; this tilt
        // becomes a fresh first half, so still nothing fires.
        feedTilt(&pipeline, direction: 1, start: afterFirst + 2.5, collecting: &emitted)
        XCTAssertEqual(emitted, [])
    }

    func testSwipeChannelIsInertByDefault() {
        var pipeline = MotionGesturePipeline()
        let gravity = MotionVector(x: 0, y: 0, z: -1)
        for index in 0..<30 {
            let level = (6..<13).contains(index) ? 0.2 : 0.01
            let sample = HeadMotionSample(
                timestamp: Double(index) * sampleInterval,
                pitch: 0, yaw: 0, roll: 0,
                userAcceleration: MotionVector(x: 0, y: 0, z: level),
                rotationRate: .zero,
                gravity: gravity
            )
            XCTAssertNil(pipeline.ingest(sample).swipe)
        }
    }

    func testSwipeEmitsWhenEnabledWithPerAxisData() {
        var pipeline = MotionGesturePipeline()
        pipeline.swipeDetectionEnabled = true
        let gravity = MotionVector(x: 0, y: 0, z: -1)
        var emitted: [MotionSwipeCommand] = []
        for index in 0..<30 {
            let level = (6..<13).contains(index) ? 0.2 : 0.01
            let sample = HeadMotionSample(
                timestamp: Double(index) * sampleInterval,
                pitch: 0, yaw: 0, roll: 0,
                userAcceleration: MotionVector(x: 0, y: 0, z: level),
                rotationRate: .zero,
                gravity: gravity
            )
            if let swipe = pipeline.ingest(sample).swipe { emitted.append(swipe) }
        }
        XCTAssertEqual(emitted, [.swipeUp])
    }

    func testSwipeStaysInertForMagnitudeOnlySamples() {
        var pipeline = MotionGesturePipeline()
        pipeline.swipeDetectionEnabled = true
        for index in 0..<30 {
            let level = (6..<13).contains(index) ? 0.2 : 0.01
            let sample = HeadMotionSample(
                timestamp: Double(index) * sampleInterval,
                pitch: 0, yaw: 0,
                accelerationMagnitude: level, rotationMagnitude: 0.05
            )
            XCTAssertNil(pipeline.ingest(sample).swipe)
        }
    }
}
