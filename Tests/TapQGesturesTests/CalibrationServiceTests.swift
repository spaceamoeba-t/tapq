import XCTest
@testable import TapQGestures
import TapQCalibrationStore
import TapQDetectionBaseline

/// The service is a save/reject wrapper over `GestureCalibrator` and `TapCalibrator`; the
/// threshold math itself is covered by `GestureCalibratorTests` and `TapCalibratorTests`.
/// What matters here is that an unusable capture never reaches the store.
final class CalibrationServiceTests: XCTestCase {
    /// A clean nod/shake capture: ±0.4 rad swings against near-silent rest.
    private func usableGestureSamples() -> GestureCalibrationSamples {
        GestureCalibrationSamples(
            restingPitch: [0.0, 0.002, -0.002, 0.0],
            restingYaw: [0.0, 0.002, -0.002, 0.0],
            nodPitch: [0.0, 0.4, -0.4, 0.0],
            shakeYaw: [0.0, 0.4, -0.4, 0.0],
            restingAccel: [0.01, 0.012, 0.009],
            tapAccel: [0.02, 0.8, 0.05]
        )
    }

    func testUsableGestureCaptureSavesADerivedProfile() throws {
        let store = InMemoryCalibrationStore()
        let service = CalibrationService(store: store)

        let profile = try service.calibrateGestures(from: usableGestureSamples())

        XCTAssertEqual(store.storedGesture, profile)
        XCTAssertEqual(profile.quality.nodSampleCount, 4)
        XCTAssertEqual(profile.quality.shakeSampleCount, 4)
        XCTAssertEqual(
            profile.config.amplitudeThreshold,
            GestureCalibrator.suggestedConfig(from: usableGestureSamples()).amplitudeThreshold,
            "the service must not invent its own threshold"
        )
    }

    func testGestureCalibrationInheritsNonThresholdFieldsFromTheStoredProfile() throws {
        var stored = HeadGestureConfig()
        stored.debounceSeconds = 2.5
        let store = InMemoryCalibrationStore(
            gesture: TapQGestureCalibrationProfile(
                config: stored,
                quality: GestureCalibrationQuality(
                    restingSampleCount: 1, nodSampleCount: 1, shakeSampleCount: 1)
            )
        )

        let profile = try CalibrationService(store: store)
            .calibrateGestures(from: usableGestureSamples())

        XCTAssertEqual(profile.config.debounceSeconds, 2.5,
                       "recalibration retunes amplitude, not everything else")
    }

    func testWeakGestureCaptureThrowsAndWritesNothing() {
        let store = InMemoryCalibrationStore()
        let samples = GestureCalibrationSamples(
            restingPitch: [0.0, 0.03, -0.03],
            restingYaw: [0.0, 0.03, -0.03],
            nodPitch: [0.0, 0.01, -0.01],      // barely moved
            shakeYaw: [0.0, 0.01, -0.01]
        )

        XCTAssertThrowsError(try CalibrationService(store: store).calibrateGestures(from: samples)) {
            XCTAssertEqual($0 as? CalibrationServiceError, .gestureCaptureUnusable)
        }
        XCTAssertNil(store.storedGesture)
    }

    func testUsableTapCaptureSavesADerivedProfile() throws {
        let store = InMemoryCalibrationStore()

        let profile = try CalibrationService(store: store)
            .calibrateTap(from: usableGestureSamples())

        XCTAssertEqual(store.storedTap, profile)
        XCTAssertEqual(profile.quality.tapAccelerationPeak, 0.8)
        XCTAssertEqual(profile.config.amplitudeThreshold, 0.4, accuracy: 1e-9)
    }

    func testTapCaptureWithoutSeparationThrowsCarryingItsAssessment() {
        let store = InMemoryCalibrationStore()
        let samples = GestureCalibrationSamples(
            nodPitch: [], shakeYaw: [],
            restingAccel: [0.05, 0.06],
            tapAccel: [0.07]                    // barely above rest
        )

        XCTAssertThrowsError(try CalibrationService(store: store).calibrateTap(from: samples)) {
            XCTAssertEqual(
                $0 as? CalibrationServiceError,
                .tapCaptureUnusable(TapCalibrator.assessment(of: samples))
            )
        }
        XCTAssertNil(store.storedTap)
    }

    func testPhaseInitializerReducesSamplesTheWayTheCalibratorsExpect() {
        let resting = [
            HeadMotionSample(timestamp: 0, pitch: 0.01, yaw: 0.02,
                             accelerationMagnitude: 0.03, rotationMagnitude: 0.04),
        ]
        let nod = [
            HeadMotionSample(timestamp: 1, pitch: 0.4, yaw: 0.0,
                             accelerationMagnitude: 0.1, rotationMagnitude: 0.2),
        ]
        let shake = [
            HeadMotionSample(timestamp: 2, pitch: 0.0, yaw: 0.5,
                             accelerationMagnitude: 0.1, rotationMagnitude: 0.2),
        ]
        let tap = [
            HeadMotionSample(timestamp: 3, pitch: 0.0, yaw: 0.0,
                             accelerationMagnitude: 0.9, rotationMagnitude: 0.05),
        ]

        let samples = GestureCalibrationSamples(
            resting: resting, nod: nod, shake: shake, tap: tap)

        XCTAssertEqual(samples.restingPitch, [0.01])
        XCTAssertEqual(samples.restingYaw, [0.02])
        XCTAssertEqual(samples.nodPitch, [0.4])
        XCTAssertEqual(samples.shakeYaw, [0.5])
        XCTAssertEqual(samples.restingAccel, [0.03])
        XCTAssertEqual(samples.tapAccel, [0.9])
    }
}
