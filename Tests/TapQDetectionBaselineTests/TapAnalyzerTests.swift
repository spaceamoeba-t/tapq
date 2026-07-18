import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

final class TapAnalyzerTests: XCTestCase {
    private let analyzer = TapAnalyzer()  // defaults: amp 0.45, rotQuiet 0.6, maxSpike 4, minSamples 4

    /// A firm tap: a lone acceleration spike that has subsided, head still throughout.
    func testCleanTapFires() {
        let accel = [0.01, 0.01, 1.24, 0.03, 0.01]
        let rot = [0.02, 0.03, 0.03, 0.02, 0.02]
        XCTAssertTrue(analyzer.detect(accel: accel, rot: rot))
    }

    func testCalibratedLowAmplitudeTapFiresAboveQuietBaseline() {
        let calibrated = TapAnalyzer(config: TapConfig(amplitudeThreshold: 0.05))
        let accel = [0.012, 0.0164, 0.0715, 0.018, 0.014]
        let rot = [0.04, 0.05, 0.04, 0.03, 0.03]

        XCTAssertTrue(calibrated.detect(accel: accel, rot: rot))
        XCTAssertFalse(calibrated.detect(
            accel: [0.012, 0.0164, 0.015, 0.013, 0.014],
            rot: rot
        ))
    }

    func testStillBaselineDoesNotFire() {
        let accel = [0.004, 0.006, 0.005, 0.003, 0.005]
        let rot = [0.02, 0.02, 0.03, 0.02, 0.02]
        XCTAssertFalse(analyzer.detect(accel: accel, rot: rot))
    }

    /// The decisive case: a shake turnaround has a lone low-rotation sample with high
    /// acceleration, but it's flanked by high rotation. The windowed rotation gate rejects it.
    func testShakeTurnaroundDoesNotFire() {
        let accel = [0.40, 0.45, 0.45, 0.50, 0.40]
        let rot = [3.0, 1.5, 0.30, 2.0, 4.0]   // lone 0.30 dip, neighbors high
        XCTAssertFalse(analyzer.detect(accel: accel, rot: rot))
    }

    /// A sustained high-acceleration plateau (even with low rotation, e.g. a knock-rub) is
    /// rejected by the brevity gate — a tap is brief, not a plateau.
    func testSustainedPlateauDoesNotFire() {
        let accel = [0.6, 0.7, 0.8, 0.7, 0.6, 0.7]
        let rot = [0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
        XCTAssertFalse(analyzer.detect(accel: accel, rot: rot))
    }

    /// While the spike is still rising (window ends high), don't fire yet — wait until it
    /// returns to baseline so a tap fires exactly once, just after the peak.
    func testRisingSpikeWaitsForBaseline() {
        let accel = [0.01, 0.01, 0.30, 0.90]   // last sample still elevated
        let rot = [0.02, 0.02, 0.03, 0.03]
        XCTAssertFalse(analyzer.detect(accel: accel, rot: rot))
    }

    func testTooFewSamplesDoesNotFire() {
        XCTAssertFalse(analyzer.detect(accel: [1.24, 0.01], rot: [0.03, 0.02]))
    }

    /// A real tap reaching tap-range acceleration but during head rotation (the tap happened
    /// mid-shake) is rejected — rotation isn't quiet across the window.
    func testTapDuringRotationDoesNotFire() {
        let accel = [0.02, 0.02, 1.20, 0.03, 0.02]
        let rot = [2.0, 2.5, 0.20, 2.2, 3.0]   // spike's own sample is quiet, neighbors aren't
        XCTAssertFalse(analyzer.detect(accel: accel, rot: rot))
    }

    func testAnalysisExplainsEveryExistingDecisionGate() {
        XCTAssertEqual(
            analyzer.analyze(accel: [1.24, 0.01], rot: [0.03, 0.02]).rejection,
            .insufficientSamples
        )
        XCTAssertEqual(
            analyzer.analyze(
                accel: [0.004, 0.006, 0.005, 0.003, 0.005],
                rot: [0.02, 0.02, 0.03, 0.02, 0.02]
            ).rejection,
            .belowAmplitude
        )
        XCTAssertEqual(
            analyzer.analyze(
                accel: [0.02, 0.02, 1.20, 0.03, 0.02],
                rot: [2.0, 2.5, 0.20, 2.2, 3.0]
            ).rejection,
            .rotationNotQuiet
        )
        XCTAssertEqual(
            analyzer.analyze(
                accel: [0.6, 0.7, 0.8, 0.7, 0.6, 0.7],
                rot: [0.1, 0.1, 0.1, 0.1, 0.1, 0.1]
            ).rejection,
            .spikeTooWide
        )
        XCTAssertEqual(
            analyzer.analyze(
                accel: [0.01, 0.01, 0.30, 0.90],
                rot: [0.02, 0.02, 0.03, 0.03]
            ).rejection,
            .notReturnedToBaseline
        )

        let clean = analyzer.analyze(
            accel: [0.01, 0.01, 1.24, 0.03, 0.01],
            rot: [0.02, 0.03, 0.03, 0.02, 0.02]
        )
        XCTAssertTrue(clean.detected)
        XCTAssertNil(clean.rejection)
        XCTAssertEqual(clean.peakAcceleration, 1.24)
        XCTAssertEqual(clean.maximumRotation, 0.03)
        XCTAssertEqual(clean.elevatedSamples, 1)
        XCTAssertTrue(clean.returnedToBaseline)
        XCTAssertEqual(analyzer.detect(
            accel: [0.01, 0.01, 1.24, 0.03, 0.01],
            rot: [0.02, 0.03, 0.03, 0.02, 0.02]
        ), clean.detected)
    }
}
