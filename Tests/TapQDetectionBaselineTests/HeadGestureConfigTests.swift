import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class HeadGestureConfigTests: XCTestCase {
    func testDefaultsForDoubleGesturePairing() {
        let config = HeadGestureConfig()
        XCTAssertEqual(config.doubleNodWindowSeconds, 1.5)
        XCTAssertEqual(config.minDoubleNodGap, 0.3)
        XCTAssertEqual(config.doubleShakeWindowSeconds, 1.5)
        XCTAssertEqual(config.minDoubleShakeGap, 0.3)
        // The deadlock invariant: a second nod must be able to land after the
        // echo-rejection gap but inside the pairing window.
        XCTAssertLessThan(config.minDoubleNodGap, config.doubleNodWindowSeconds)
        XCTAssertLessThan(config.minDoubleShakeGap, config.doubleShakeWindowSeconds)
    }

    func testDecodesLegacyJSONWithoutNewKeys() throws {
        // Exactly what a pre-fix calibration blob in UserDefaults looks like.
        let legacy = """
        {"amplitudeThreshold":0.12,"dominanceRatio":2.0,"windowSeconds":1.2,
         "minReversals":2,"debounceSeconds":1.0,"minSamples":6,
         "doubleNodWindowSeconds":1.0}
        """
        let config = try JSONDecoder().decode(HeadGestureConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(config.amplitudeThreshold, 0.12)   // calibration preserved
        XCTAssertEqual(config.doubleNodWindowSeconds, 1.0) // persisted value kept
        XCTAssertEqual(config.minDoubleNodGap, 0.3)        // new key defaulted
        XCTAssertEqual(config.doubleShakeWindowSeconds, 1.5)
        XCTAssertEqual(config.minDoubleShakeGap, 0.3)
    }

    func testRoundTripsThroughCodable() throws {
        var config = HeadGestureConfig()
        config.minDoubleNodGap = 0.4
        config.minDoubleShakeGap = 0.45
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(HeadGestureConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }
}
