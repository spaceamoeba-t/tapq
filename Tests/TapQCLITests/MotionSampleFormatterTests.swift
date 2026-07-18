import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

final class MotionSampleFormatterTests: XCTestCase {
    private let sample = HeadMotionSample(
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
    }

    func testCSVHeaderAndLine() {
        XCTAssertEqual(
            MotionSampleFormatter.csvHeader,
            "timestamp,pitch,yaw,acceleration_magnitude,rotation_magnitude"
        )
        XCTAssertEqual(
            MotionSampleFormatter.line(for: sample, format: .csv),
            "12.5,0.25,-0.5,0.75,1.25"
        )
    }
}
