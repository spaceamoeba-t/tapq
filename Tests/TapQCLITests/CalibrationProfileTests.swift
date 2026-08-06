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
        XCTAssertEqual(
            store.wearerSpeechProfileURL,
            directory.appendingPathComponent("wearer-speech-calibration.json")
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

    func testWearerSpeechRoundTripsAndResetsWithoutTouchingTheOtherProfiles() throws {
        let store = testStore()
        try store.save(TapQGestureCalibrationProfile(
            config: HeadGestureConfig(amplitudeThreshold: 0.12),
            quality: GestureCalibrationQuality(
                restingSampleCount: 20, nodSampleCount: 30, shakeSampleCount: 30)
        ))
        try store.save(TapQTapCalibrationProfile(
            config: TapConfig(amplitudeThreshold: 0.42),
            quality: TapCalibrationQuality(
                restingSampleCount: 20, tapSampleCount: 25,
                restingAccelerationPeak: 0.02, tapAccelerationPeak: 0.84)
        ))

        let speech = TapQWearerSpeechCalibrationProfile(
            calibratedAt: Date(timeIntervalSince1970: 1_700_000_002),
            config: WearerSpeechConfig(
                envelopeEnterThreshold: 0.018, envelopeExitThreshold: 0.011),
            quality: WearerSpeechCalibrationQuality(
                restingSampleCount: 74,
                speakingSampleCount: 149,
                restingEnvelopePeak: 0.004,
                speakingEnvelopeLevel: 0.030
            )
        )
        try store.save(speech)
        XCTAssertEqual(try store.loadWearerSpeech(), speech)

        XCTAssertTrue(try store.reset(.wearerSpeech))
        XCTAssertFalse(store.exists(.wearerSpeech))
        XCTAssertTrue(store.exists(.gesture), "resetting wearer speech must preserve gestures")
        XCTAssertTrue(store.exists(.tap), "resetting wearer speech must preserve taps")
        XCTAssertFalse(try store.reset(.wearerSpeech))
    }

    /// Resetting either older profile must leave a wearer-speech calibration in place —
    /// the same independence guarantee, checked in the other direction.
    func testResettingGestureAndTapPreservesWearerSpeech() throws {
        let store = testStore()
        try store.save(TapQWearerSpeechCalibrationProfile(
            config: WearerSpeechConfig(),
            quality: WearerSpeechCalibrationQuality(
                restingSampleCount: 74, speakingSampleCount: 149,
                restingEnvelopePeak: 0.004, speakingEnvelopeLevel: 0.030)
        ))
        try store.save(TapQGestureCalibrationProfile(
            config: HeadGestureConfig(),
            quality: GestureCalibrationQuality(
                restingSampleCount: 20, nodSampleCount: 30, shakeSampleCount: 30)
        ))

        XCTAssertTrue(try store.reset(.gesture))
        XCTAssertFalse(try store.reset(.tap))
        XCTAssertTrue(store.exists(.wearerSpeech))
    }

    func testEachProfileKindHasItsOwnFile() {
        let store = testStore()
        let urls = CalibrationProfileKind.allCases.map { store.url(for: $0) }
        XCTAssertEqual(Set(urls).count, CalibrationProfileKind.allCases.count)
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

    func testRejectsUnsupportedWearerSpeechSchemaOnSaveAndLoad() throws {
        let store = testStore()
        let profile = TapQWearerSpeechCalibrationProfile(
            schemaVersion: 999,
            config: .init(),
            quality: .init(
                restingSampleCount: 1,
                speakingSampleCount: 1,
                restingEnvelopePeak: 0.001,
                speakingEnvelopeLevel: 0.03
            )
        )
        XCTAssertThrowsError(try store.save(profile)) { error in
            XCTAssertEqual(
                error as? CalibrationStoreError,
                .unsupportedSchema(.wearerSpeech, 999)
            )
        }

        // A future schema already on disk must be refused rather than silently reused.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: store.wearerSpeechProfileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(profile).write(to: store.wearerSpeechProfileURL)
        XCTAssertThrowsError(try store.loadWearerSpeech()) { error in
            XCTAssertEqual(
                error as? CalibrationStoreError,
                .unsupportedSchema(.wearerSpeech, 999)
            )
        }
    }

    /// A corrupt (non-JSON) wearer-speech profile must fail the same way a corrupt gesture
    /// or tap profile does: `store.loadWearerSpeech()` throws (the runtime propagates this
    /// to abort serve). When the file simply does not exist, `store.exists(.wearerSpeech)`
    /// is false and the runtime skips loading (uses defaults) — matching `loadGestureIfPresent`.
    func testMalformedWearerSpeechProfileThrowsLikeGestureAndTap() throws {
        let store = testStore()
        // Pre-condition: file absent → exists reports false.
        XCTAssertFalse(store.exists(.wearerSpeech))

        // Write invalid JSON.
        try FileManager.default.createDirectory(
            at: store.wearerSpeechProfileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(to: store.wearerSpeechProfileURL)
        XCTAssertTrue(store.exists(.wearerSpeech))
        XCTAssertThrowsError(try store.loadWearerSpeech(),
                             "malformed wearer-speech profile must throw, matching gesture/tap")
    }

    /// The raw value is the on-disk and JSON spelling and must stay snake_case; the display
    /// name is what CLI output uses so nothing prints "Wearer_speech".
    func testWearerSpeechKindSpelling() {
        XCTAssertEqual(CalibrationProfileKind.wearerSpeech.rawValue, "wearer_speech")
        XCTAssertEqual(CalibrationProfileKind.wearerSpeech.displayName, "Wearer speech")
        XCTAssertEqual(
            CalibrationStoreError.unsupportedSchema(.wearerSpeech, 2).localizedDescription,
            "The wearer speech calibration profile schema 2 is not supported by this TapQ version."
        )
    }

    private func testStore() -> CalibrationStore {
        CalibrationStore(
            gestureProfileURL: directory.appendingPathComponent("nested/gesture.json"),
            tapProfileURL: directory.appendingPathComponent("nested/tap.json"),
            wearerSpeechProfileURL: directory
                .appendingPathComponent("nested/wearer-speech.json")
        )
    }
}
