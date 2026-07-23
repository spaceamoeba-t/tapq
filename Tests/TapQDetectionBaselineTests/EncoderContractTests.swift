import XCTest
@testable import TapQDetectionBaseline

/// Pins the feature contract shared with `ml/tapq1/layout.py`. A failure here means the
/// Swift side changed without a new layout version — which would silently desynchronize
/// training and runtime.
final class EncoderContractTests: XCTestCase {
    func testFeatureLayoutIsPinned() {
        XCTAssertEqual(EncoderFeatureLayout.version, "tapq1-features-v1")
        XCTAssertEqual(EncoderFeatureLayout.windowLength, 32)
        XCTAssertEqual(EncoderFeatureLayout.accelerationFullScale, 2.0)
        XCTAssertEqual(EncoderFeatureLayout.rotationFullScale, 8.0)
        XCTAssertEqual(EncoderFeatureLayout.channelNames, [
            "user_acceleration_x", "user_acceleration_y", "user_acceleration_z",
            "rotation_rate_x", "rotation_rate_y", "rotation_rate_z",
            "gravity_x", "gravity_y", "gravity_z",
        ])
    }

    func testClassOrderIsPinned() {
        XCTAssertEqual(
            TapQ1ModelMetadata.expectedClasses,
            "quiet,nod,shake,tilt_left,tilt_right,tap,swipe_up,swipe_down"
        )
    }

    func testFeatureRowScalesAndClips() {
        let sample = HeadMotionSample(
            timestamp: 0, pitch: 0.3, yaw: -0.2, roll: 0.1,
            userAcceleration: MotionVector(x: 1.0, y: 5.0, z: -0.5),
            rotationRate: MotionVector(x: -100.0, y: -4.0, z: 2.0),
            gravity: MotionVector(x: 0.0, y: 0.5, z: -1.0)
        )
        XCTAssertEqual(EncoderFeatureLayout.featureRow(for: sample), [
            0.5, 1.0, -0.25,
            -1.0, -0.5, 0.25,
            0.0, 0.5, -1.0,
        ])
    }

    func testRankedBreaksTiesByClassOrder() {
        let scores = GestureScores(values: [.shake: 0.5, .nod: 0.5])
        XCTAssertEqual(scores.ranked.first?.gestureClass, .nod)
        XCTAssertEqual(scores.probability(of: .tap), 0)
    }

    private func perAxisSample(at time: TimeInterval) -> HeadMotionSample {
        HeadMotionSample(
            timestamp: time, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: 0.01, y: 0, z: 0),
            rotationRate: .zero,
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
    }

    func testWindowBuilderEmitsAtWindowLengthThenEveryHop() {
        var builder = EncoderWindowBuilder(windowLength: 32, hopSamples: 8)
        var windows: [EncoderInputWindow] = []
        for index in 0..<48 {
            if let window = builder.push(perAxisSample(at: Double(index) * 0.04)) {
                windows.append(window)
            }
        }
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].features.count, 32)
        XCTAssertEqual(windows[0].features[0].count, 9)
        XCTAssertEqual(windows[0].endTime, 31 * 0.04, accuracy: 1e-9)
        XCTAssertEqual(windows[1].endTime, 39 * 0.04, accuracy: 1e-9)
        XCTAssertEqual(windows[2].endTime, 47 * 0.04, accuracy: 1e-9)
        XCTAssertEqual(
            windows[2].endTime - windows[2].startTime, 31 * 0.04, accuracy: 1e-9)
    }

    func testWindowBuilderResetsAcrossStreamGap() {
        var builder = EncoderWindowBuilder(windowLength: 32, hopSamples: 8)
        for index in 0..<32 {
            _ = builder.push(perAxisSample(at: Double(index) * 0.04))
        }
        // A gap longer than gapResetSeconds must clear the buffer: a window spanning a
        // disconnect would splice unrelated motion.
        let resumeAt = 32 * 0.04 + 1.0
        var windows = 0
        for index in 0..<40 {
            if builder.push(perAxisSample(at: resumeAt + Double(index) * 0.04)) != nil {
                windows += 1
            }
        }
        XCTAssertEqual(windows, 2)
    }

    func testWindowBuilderIgnoresMagnitudeOnlySamples() {
        var builder = EncoderWindowBuilder(windowLength: 32, hopSamples: 8)
        for index in 0..<31 {
            XCTAssertNil(builder.push(perAxisSample(at: Double(index) * 0.04)))
        }
        let legacy = HeadMotionSample(
            timestamp: 31 * 0.04, pitch: 0, yaw: 0,
            accelerationMagnitude: 0.1, rotationMagnitude: 0.1
        )
        XCTAssertNil(builder.push(legacy))
        XCTAssertNotNil(builder.push(perAxisSample(at: 32 * 0.04)))
    }
}
