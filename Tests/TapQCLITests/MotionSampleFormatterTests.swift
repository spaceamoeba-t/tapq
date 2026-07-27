import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

final class MotionSampleFormatterTests: XCTestCase {
    private let sample = HeadMotionSample(
        timestamp: 12.5,
        pitch: 0.25,
        yaw: -0.5,
        roll: 0.125,
        userAcceleration: MotionVector(x: 0.75, y: 0, z: 0),
        rotationRate: MotionVector(x: 0, y: 1.25, z: 0),
        gravity: MotionVector(x: 0, y: 0, z: -1)
    )

    private let legacySample = HeadMotionSample(
        timestamp: 12.5,
        pitch: 0.25,
        yaw: -0.5,
        accelerationMagnitude: 0.75,
        rotationMagnitude: 1.25
    )

    func testJSONLUsesStableSnakeCaseFields() throws {
        let line = MotionSampleFormatter.line(for: sample, format: .jsonl)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Double]
        )
        XCTAssertEqual(object["timestamp"], 12.5)
        XCTAssertEqual(object["acceleration_magnitude"], 0.75)
        XCTAssertEqual(object["rotation_magnitude"], 1.25)
        XCTAssertEqual(object["roll"], 0.125)
        XCTAssertEqual(object["user_acceleration_x"], 0.75)
        XCTAssertEqual(object["rotation_rate_y"], 1.25)
        XCTAssertEqual(object["gravity_z"], -1)
    }

    func testCSVHeaderAndLine() {
        XCTAssertEqual(
            MotionSampleFormatter.csvHeader,
            "timestamp,pitch,yaw,acceleration_magnitude,rotation_magnitude,"
                + "roll,user_acceleration_x,user_acceleration_y,user_acceleration_z,"
                + "rotation_rate_x,rotation_rate_y,rotation_rate_z,gravity_x,gravity_y,gravity_z"
        )
        XCTAssertEqual(
            MotionSampleFormatter.line(for: sample, format: .csv),
            "12.5,0.25,-0.5,0.75,1.25,0.125,0.75,0,0,0,1.25,0,0,0,-1"
        )
    }

    /// A magnitude-only sample (legacy adapter) still writes every column; per-axis
    /// values are zero, and the magnitudes keep their original positions.
    func testLegacySampleKeepsColumnPositions() {
        XCTAssertEqual(
            MotionSampleFormatter.line(for: legacySample, format: .csv),
            "12.5,0.25,-0.5,0.75,1.25,0,0,0,0,0,0,0,0,0,0"
        )
    }
}
