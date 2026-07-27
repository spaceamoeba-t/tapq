import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

final class CaptureReplayTests: XCTestCase {
    private func perAxisSample(at time: TimeInterval) -> HeadMotionSample {
        HeadMotionSample(
            timestamp: time, pitch: 0.1, yaw: -0.2, roll: 0.05,
            userAcceleration: MotionVector(x: 0.01, y: -0.02, z: 0.03),
            rotationRate: MotionVector(x: 0.4, y: -0.5, z: 0.6),
            gravity: MotionVector(x: 0, y: 0.1, z: -0.99)
        )
    }

    // MARK: Capture reading

    func testJSONLRoundTripsThroughFormatter() throws {
        let samples = (0..<3).map { perAxisSample(at: Double($0) * 0.04) }
        let text = samples
            .map { MotionSampleFormatter.line(for: $0, format: .jsonl) }
            .joined(separator: "\n")
        let decoded = try MotionCaptureReader.samples(fromText: text, format: .jsonl)
        XCTAssertEqual(decoded, samples)
        XCTAssertTrue(decoded.allSatisfy(\.hasPerAxisData))
    }

    func testCSVRoundTripsThroughFormatter() throws {
        let samples = (0..<3).map { perAxisSample(at: Double($0) * 0.04) }
        let text = ([MotionSampleFormatter.csvHeader]
            + samples.map { MotionSampleFormatter.line(for: $0, format: .csv) })
            .joined(separator: "\n")
        let decoded = try MotionCaptureReader.samples(fromText: text, format: .csv)
        XCTAssertEqual(decoded, samples)
    }

    func testLegacyMagnitudeOnlyJSONLStillDecodes() throws {
        let line = #"{"timestamp":1.5,"pitch":0.2,"yaw":-0.1,"acceleration_magnitude":0.3,"rotation_magnitude":0.4}"#
        let decoded = try MotionCaptureReader.samples(fromText: line, format: .jsonl)
        XCTAssertEqual(decoded, [HeadMotionSample(
            timestamp: 1.5, pitch: 0.2, yaw: -0.1,
            accelerationMagnitude: 0.3, rotationMagnitude: 0.4
        )])
        XCTAssertFalse(decoded[0].hasPerAxisData)
    }

    func testLegacyFiveColumnCSVStillDecodes() throws {
        let text = """
        timestamp,pitch,yaw,acceleration_magnitude,rotation_magnitude
        1.5,0.2,-0.1,0.3,0.4
        """
        let decoded = try MotionCaptureReader.samples(fromText: text, format: .csv)
        XCTAssertEqual(decoded, [HeadMotionSample(
            timestamp: 1.5, pitch: 0.2, yaw: -0.1,
            accelerationMagnitude: 0.3, rotationMagnitude: 0.4
        )])
    }

    func testFormatInferenceFromContentAndExtension() {
        XCTAssertEqual(
            MotionCaptureReader.inferFormat(text: "{\"a\":1}", pathExtension: ""), .jsonl)
        XCTAssertEqual(
            MotionCaptureReader.inferFormat(
                text: "timestamp,pitch,yaw", pathExtension: ""), .csv)
        XCTAssertEqual(
            MotionCaptureReader.inferFormat(text: "???", pathExtension: "csv"), .csv)
        XCTAssertNil(MotionCaptureReader.inferFormat(text: "???", pathExtension: "txt"))
    }

    func testMalformedJSONLReportsLineNumber() {
        XCTAssertThrowsError(
            try MotionCaptureReader.samples(fromText: "{}\nnot json", format: .jsonl)
        ) { error in
            guard case CaptureReadError.badLine(let line, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(line, 1)
        }
    }

    func testCSVMissingRequiredColumnFails() {
        XCTAssertThrowsError(
            try MotionCaptureReader.samples(fromText: "timestamp,pitch\n1,2", format: .csv)
        ) { error in
            guard case CaptureReadError.missingColumns = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: Labels

    func testLabelSegmentsParseAndSort() throws {
        let text = """
        {"start": 10.0, "end": 12.0, "label": "tilt_left"}
        {"start": 2.0, "end": 4.5, "label": "nod"}
        """
        let segments = try ReplayLabelReader.segments(fromText: text)
        XCTAssertEqual(segments, [
            ReplayLabelSegment(start: 2.0, end: 4.5, label: .nod),
            ReplayLabelSegment(start: 10.0, end: 12.0, label: .tiltLeft),
        ])
    }

    func testInvertedLabelSegmentFails() {
        XCTAssertThrowsError(
            try ReplayLabelReader.segments(
                fromText: #"{"start": 5, "end": 3, "label": "nod"}"#)
        )
    }

    func testUnknownLabelFails() {
        XCTAssertThrowsError(
            try ReplayLabelReader.segments(
                fromText: #"{"start": 1, "end": 2, "label": "wink"}"#)
        )
    }

    // MARK: Evaluation

    func testEvaluatorCountsMatchesMissesAndFalsePositives() {
        let segments = [
            ReplayLabelSegment(start: 2, end: 4, label: .nod),
            ReplayLabelSegment(start: 10, end: 12, label: .nod),
            ReplayLabelSegment(start: 20, end: 22, label: .shake),
        ]
        let events = [
            ReplayEvent(time: 4.5, label: .nod),    // inside tolerance → TP
            ReplayEvent(time: 30.0, label: .nod),   // matches nothing → FP
            ReplayEvent(time: 21.0, label: .tap),   // wrong label → FP
        ]
        let report = ReplayEvaluator.evaluate(
            events: events, segments: segments, tolerance: 1.0, duration: 60)
        XCTAssertEqual(report.metrics, [
            ReplayLabelMetrics(label: .nod, truePositives: 1, falseNegatives: 1, falsePositives: 1),
            ReplayLabelMetrics(label: .shake, truePositives: 0, falseNegatives: 1, falsePositives: 0),
            ReplayLabelMetrics(label: .tap, truePositives: 0, falseNegatives: 0, falsePositives: 1),
        ])
        XCTAssertEqual(report.falsePositives, 2)
        XCTAssertEqual(report.falsePositivesPerMinute ?? 0, 2.0, accuracy: 1e-9)
    }

    func testEvaluatorCountsDoubleFireAsFalsePositive() {
        let segments = [ReplayLabelSegment(start: 2, end: 4, label: .nod)]
        let events = [
            ReplayEvent(time: 3.0, label: .nod),
            ReplayEvent(time: 3.8, label: .nod),
        ]
        let report = ReplayEvaluator.evaluate(
            events: events, segments: segments, tolerance: 1.0, duration: 60)
        XCTAssertEqual(report.metrics, [
            ReplayLabelMetrics(label: .nod, truePositives: 1, falseNegatives: 0, falsePositives: 1),
        ])
    }

    func testEvaluatorRespectsToleranceBoundary() {
        let segments = [ReplayLabelSegment(start: 2, end: 4, label: .shake)]
        let lateEvent = [ReplayEvent(time: 5.5, label: .shake)]
        let missed = ReplayEvaluator.evaluate(
            events: lateEvent, segments: segments, tolerance: 1.0, duration: 60)
        XCTAssertEqual(missed.metrics, [
            ReplayLabelMetrics(label: .shake, truePositives: 0, falseNegatives: 1, falsePositives: 1),
        ])
        let allowed = ReplayEvaluator.evaluate(
            events: lateEvent, segments: segments, tolerance: 2.0, duration: 60)
        XCTAssertEqual(allowed.metrics, [
            ReplayLabelMetrics(label: .shake, truePositives: 1, falseNegatives: 0, falsePositives: 0),
        ])
    }

    func testPrecisionAndRecall() {
        let metrics = ReplayLabelMetrics(
            label: .nod, truePositives: 3, falseNegatives: 1, falsePositives: 2)
        XCTAssertEqual(metrics.precision ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertEqual(metrics.recall ?? 0, 0.75, accuracy: 1e-9)
        let silent = ReplayLabelMetrics(
            label: .nod, truePositives: 0, falseNegatives: 2, falsePositives: 0)
        XCTAssertNil(silent.precision)
        XCTAssertEqual(silent.recall, 0)
    }

    // MARK: Backend running

    func testHeuristicRunnerDetectsSyntheticDoubleNod() {
        // Two single-cycle nod bursts; each is one detection (0.5 rad peak-to-peak,
        // 2 reversals) and the pair completes the double nod. A longer burst would
        // itself contain two nod cycles and pair on its own.
        var samples: [HeadMotionSample] = []
        var time = 0.0
        func appendQuiet(_ seconds: Double) {
            let count = Int(seconds / 0.04)
            for _ in 0..<count {
                samples.append(HeadMotionSample(
                    timestamp: time, pitch: 0, yaw: 0,
                    accelerationMagnitude: 0, rotationMagnitude: 0))
                time += 0.04
            }
        }
        func appendNodBurst() {
            for index in 0..<20 {
                let pitch = 0.25 * sin(Double(index) / 19 * 2 * .pi)
                samples.append(HeadMotionSample(
                    timestamp: time, pitch: pitch, yaw: 0,
                    accelerationMagnitude: 0, rotationMagnitude: 0))
                time += 0.04
            }
        }
        appendQuiet(1.0)
        appendNodBurst()
        appendQuiet(0.6)
        appendNodBurst()
        appendQuiet(1.0)

        let events = ReplayBackendRunner.heuristicEvents(
            samples: samples, gestureConfig: HeadGestureConfig(), tapConfig: TapConfig())
        XCTAssertEqual(events.map(\.label), [.nod])
    }

    func testEncoderRunnerUsesInjectedScorer() {
        struct AlwaysShake: MotionWindowScoring {
            func score(_ window: EncoderInputWindow) throws -> GestureScores {
                GestureScores(values: [.shake: 0.95])
            }
        }
        // Shake pairs like the heuristics, so four agreeing windows (two atoms) are
        // needed for one deny event.
        let samples = (0..<56).map { perAxisSample(at: Double($0) * 0.04) }
        let events = ReplayBackendRunner.encoderEvents(
            samples: samples, scorer: AlwaysShake())
        XCTAssertEqual(events.map(\.label), [.shake])
    }

    func testReplayLabelsMapAllChannels() {
        XCTAssertEqual(
            MotionDetectionResult(gesture: .nod).replayLabels, [.nod])
        XCTAssertEqual(
            MotionDetectionResult(gesture: .shake).replayLabels, [.shake])
        XCTAssertEqual(MotionDetectionResult(tap: .tap).replayLabels, [.tap])
        XCTAssertEqual(
            MotionDetectionResult(tilt: .tiltLeft).replayLabels, [.tiltLeft])
        XCTAssertEqual(
            MotionDetectionResult(tilt: .tiltRight).replayLabels, [.tiltRight])
        XCTAssertEqual(
            MotionDetectionResult(swipe: .swipeUp).replayLabels, [.swipeUp])
        XCTAssertEqual(
            MotionDetectionResult(swipe: .swipeDown).replayLabels, [.swipeDown])
        XCTAssertEqual(MotionDetectionResult().replayLabels, [])
    }
}
