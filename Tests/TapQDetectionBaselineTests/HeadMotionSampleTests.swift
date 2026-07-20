import XCTest
@testable import TapQDetectionBaseline

final class HeadMotionSampleTests: XCTestCase {
    func testFullInitDerivesMagnitudesFromVectors() {
        let sample = HeadMotionSample(
            timestamp: 1, pitch: 0.1, yaw: 0.2, roll: 0.3,
            userAcceleration: MotionVector(x: 3, y: 4, z: 0),
            rotationRate: MotionVector(x: 0, y: 0, z: 2),
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
        XCTAssertEqual(sample.accelerationMagnitude, 5, accuracy: 1e-12)
        XCTAssertEqual(sample.rotationMagnitude, 2, accuracy: 1e-12)
        XCTAssertTrue(sample.hasPerAxisData)
    }

    func testLegacyInitLeavesPerAxisAbsent() {
        let sample = HeadMotionSample(
            timestamp: 1, pitch: 0.1, yaw: 0.2,
            accelerationMagnitude: 0.5, rotationMagnitude: 0.6
        )
        XCTAssertEqual(sample.roll, 0)
        XCTAssertEqual(sample.userAcceleration, .zero)
        XCTAssertFalse(sample.hasPerAxisData)
    }

    /// Records serialized before per-axis capture existed must still decode.
    func testDecodingPrePerAxisRecordSucceeds() throws {
        let legacyJSON = Data("""
        {"timestamp": 2.5, "pitch": 0.1, "yaw": -0.2,
         "accelerationMagnitude": 0.4, "rotationMagnitude": 0.8}
        """.utf8)
        let sample = try JSONDecoder().decode(HeadMotionSample.self, from: legacyJSON)
        XCTAssertEqual(sample.timestamp, 2.5)
        XCTAssertEqual(sample.accelerationMagnitude, 0.4)
        XCTAssertEqual(sample.roll, 0)
        XCTAssertEqual(sample.gravity, .zero)
        XCTAssertFalse(sample.hasPerAxisData)
    }

    func testRoundTripPreservesPerAxisData() throws {
        let original = HeadMotionSample(
            timestamp: 3, pitch: 0.1, yaw: 0.2, roll: -0.3,
            userAcceleration: MotionVector(x: 0.1, y: -0.2, z: 0.3),
            rotationRate: MotionVector(x: -0.4, y: 0.5, z: -0.6),
            gravity: MotionVector(x: 0.0, y: 0.1, z: -0.99)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HeadMotionSample.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
