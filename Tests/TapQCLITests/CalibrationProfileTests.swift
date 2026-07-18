import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

final class CalibrationProfileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-cli-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultPathsHonorOverrideAndAreSeparate() {
        let store = CalibrationStore.defaultStore(
            environment: ["TAPQ_CONFIG_DIR": directory.path],
            homeDirectory: URL(fileURLWithPath: "/unused")
        )
        XCTAssertEqual(
            store.gestureProfileURL,
            directory.appendingPathComponent("gesture-calibration.json")
        )
        XCTAssertEqual(
            store.tapProfileURL,
            directory.appendingPathComponent("tap-calibration.json")
        )
    }

    func testIndependentRoundTripAndReset() throws {
        let store = testStore()
        let gesture = TapQGestureCalibrationProfile(
            calibratedAt: Date(timeIntervalSince1970: 1_700_000_000),
            config: HeadGestureConfig(amplitudeThreshold: 0.12),
            quality: GestureCalibrationQuality(
                restingSampleCount: 20,
                nodSampleCount: 30,
                shakeSampleCount: 30
            )
        )
        let tap = TapQTapCalibrationProfile(
            calibratedAt: Date(timeIntervalSince1970: 1_700_000_001),
            config: TapConfig(amplitudeThreshold: 0.42),
            quality: TapCalibrationQuality(
                restingSampleCount: 20,
                tapSampleCount: 25,
                restingAccelerationPeak: 0.02,
                tapAccelerationPeak: 0.84
            )
        )

        try store.save(gesture)
        try store.save(tap)
        XCTAssertEqual(try store.loadGesture(), gesture)
        XCTAssertEqual(try store.loadTap(), tap)

        XCTAssertTrue(try store.reset(.tap))
        XCTAssertTrue(store.exists(.gesture), "resetting tap must preserve gestures")
        XCTAssertFalse(store.exists(.tap))
        XCTAssertFalse(try store.reset(.tap))
    }

    func testRejectsUnsupportedSchemasIndependently() throws {
        let store = testStore()
        let profile = TapQTapCalibrationProfile(
            schemaVersion: 999,
            config: .init(),
            quality: .init(
                restingSampleCount: 1,
                tapSampleCount: 1,
                restingAccelerationPeak: 0.01,
                tapAccelerationPeak: 1
            )
        )
        XCTAssertThrowsError(try store.save(profile)) { error in
            XCTAssertEqual(
                error as? CalibrationStoreError,
                .unsupportedSchema(.tap, 999)
            )
        }
    }

    private func testStore() -> CalibrationStore {
        CalibrationStore(
            gestureProfileURL: directory.appendingPathComponent("nested/gesture.json"),
            tapProfileURL: directory.appendingPathComponent("nested/tap.json")
        )
    }
}
