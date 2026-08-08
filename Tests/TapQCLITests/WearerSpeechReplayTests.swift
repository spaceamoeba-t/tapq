import XCTest
@testable import TapQCLI
import TapQDetectionBaseline

/// Builds a synthetic 25 Hz capture whose sample-to-sample acceleration change is exactly
/// the jerk asked for, so a "speaking" stretch is reproducible without hardware, a wearer,
/// or a room.
private struct CaptureStream {
    static let rate: TimeInterval = 1.0 / 25.0

    private(set) var samples: [HeadMotionSample] = []
    private(set) var time: TimeInterval
    private var sign: Double = 1

    init(start: TimeInterval = 100) { time = start }

    mutating func append(seconds: TimeInterval, jerk: Double, rotation: Double = 0.02) {
        let count = Int((seconds / Self.rate).rounded())
        for _ in 0..<count {
            sign = -sign
            samples.append(HeadMotionSample(
                timestamp: time, pitch: 0, yaw: 0,
                accelerationMagnitude: 0.05 + sign * jerk / 2,
                rotationMagnitude: rotation
            ))
            time += Self.rate
        }
    }
}

/// Builds a synthetic microphone envelope track at a fixed block rate.
private struct EnvelopeStream {
    static let rate: TimeInterval = 1.0 / 50.0

    private(set) var samples: [MicEnvelopeSample] = []
    private(set) var time: TimeInterval

    init(start: TimeInterval = 100) { time = start }

    mutating func append(seconds: TimeInterval, rms: Double) {
        let count = Int((seconds / Self.rate).rounded())
        for _ in 0..<count {
            samples.append(MicEnvelopeSample(
                timestamp: time, rms: rms, peak: rms * 2))
            time += Self.rate
        }
    }

    /// The same track heard on a clock that runs `offset` seconds ahead of the IMU's.
    func shifted(by offset: TimeInterval) -> [MicEnvelopeSample] {
        samples.map {
            MicEnvelopeSample(timestamp: $0.timestamp + offset, rms: $0.rms, peak: $0.peak)
        }
    }
}

final class WearerSpeechReplayTests: XCTestCase {
    private func frames(from: TimeInterval, to: TimeInterval,
                        step: TimeInterval = CaptureStream.rate) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var time = from
        while time <= to + 1e-9 {
            times.append(time)
            time += step
        }
        return times
    }

    // MARK: - Label partition

    func testWearerSpeechLinesAreRoutedAwayFromTheEventReader() throws {
        let text = """
        {"start": 1.0, "end": 2.0, "label": "nod"}
        {"start": 3.0, "end": 8.5, "label": "wearer_speech"}
        {"start": 9.0, "end": 9.5, "label": "tap"}
        """
        let partition = try ReplaySpeechLabelReader.partition(fromText: text)
        XCTAssertEqual(partition.events, [
            ReplayLabelSegment(start: 1.0, end: 2.0, label: .nod),
            ReplayLabelSegment(start: 9.0, end: 9.5, label: .tap),
        ])
        XCTAssertEqual(partition.speech, [ReplaySpeechSegment(start: 3.0, end: 8.5)])
    }

    /// A label file written before wearer speech existed must partition to exactly what
    /// `ReplayLabelReader` alone produces.
    func testEventOnlyFileIsIdenticalThroughBothReaders() throws {
        let text = """
        {"start": 1.0, "end": 2.0, "label": "shake"}
        {"start": 4.0, "end": 4.4, "label": "swipe_up"}
        {"start": 2.5, "end": 3.0, "label": "tilt_left"}
        """
        XCTAssertEqual(
            try ReplaySpeechLabelReader.partition(fromText: text).events,
            try ReplayLabelReader.segments(fromText: text)
        )
        XCTAssertTrue(try ReplaySpeechLabelReader.partition(fromText: text).speech.isEmpty)
    }

    func testUnknownLabelStillThrowsWithItsOriginalLineNumber() {
        let text = """
        {"start": 1.0, "end": 2.0, "label": "nod"}
        {"start": 3.0, "end": 8.5, "label": "wearer_speech"}
        {"start": 9.0, "end": 9.5, "label": "wink"}
        """
        XCTAssertThrowsError(try ReplaySpeechLabelReader.partition(fromText: text)) { error in
            guard case CaptureReadError.badLabelLine(let line, _) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(line, 3, "removing the speech line must not renumber the rest")
        }
    }

    func testReversedSpeechSegmentIsRejected() {
        let text = #"{"start": 8.0, "end": 3.0, "label": "wearer_speech"}"#
        XCTAssertThrowsError(try ReplaySpeechLabelReader.partition(fromText: text)) { error in
            XCTAssertEqual(error as? CaptureReadError, .badLabelLine(1, "start is after end"))
        }
    }

    func testSpeechSegmentsAreSortedByStart() throws {
        let text = """
        {"start": 8.0, "end": 9.0, "label": "wearer_speech"}
        {"start": 1.0, "end": 2.0, "label": "wearer_speech"}
        """
        XCTAssertEqual(
            try ReplaySpeechLabelReader.partition(fromText: text).speech,
            [ReplaySpeechSegment(start: 1, end: 2), ReplaySpeechSegment(start: 8, end: 9)]
        )
    }

    // MARK: - Envelope derivation

    func testDeriverFindsTheLoudStretchOfATrack() {
        var stream = EnvelopeStream()
        stream.append(seconds: 2, rms: 0.002)
        stream.append(seconds: 3, rms: 0.08)
        stream.append(seconds: 2, rms: 0.002)

        let segments = EnvelopeLabelDeriver.segments(from: stream.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 102, accuracy: 0.05)
        XCTAssertEqual(segments[0].end, 105, accuracy: 0.05)
    }

    /// The mid-band level sits above the exit threshold but below the enter threshold, so a
    /// track that dips into it mid-utterance stays one segment instead of two.
    func testDeriverHysteresisKeepsAnUtteranceWhole() {
        var stream = EnvelopeStream()
        stream.append(seconds: 2, rms: 0.002)
        stream.append(seconds: 1, rms: 0.08)
        stream.append(seconds: 0.2, rms: 0.03)
        stream.append(seconds: 1, rms: 0.08)
        stream.append(seconds: 2, rms: 0.002)

        let thresholds = EnvelopeLabelDeriver.thresholds(for: stream.samples)
        XCTAssertNotNil(thresholds)
        XCTAssertLessThan(0.03, thresholds!.enter)
        XCTAssertGreaterThan(0.03, thresholds!.exit)
        XCTAssertEqual(EnvelopeLabelDeriver.segments(from: stream.samples).count, 1)
    }

    /// A gap shorter than `minimumGapSeconds` is an inter-word pause, not two utterances.
    func testDeriverMergesShortGapsAndDropsShortSegments() {
        var stream = EnvelopeStream()
        stream.append(seconds: 2, rms: 0.002)
        stream.append(seconds: 0.8, rms: 0.08)
        stream.append(seconds: 0.2, rms: 0.002)
        stream.append(seconds: 0.8, rms: 0.08)
        stream.append(seconds: 1, rms: 0.002)
        // Too short to survive on its own once merging is done.
        stream.append(seconds: 0.1, rms: 0.08)
        stream.append(seconds: 2, rms: 0.002)

        let segments = EnvelopeLabelDeriver.segments(from: stream.samples)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 102, accuracy: 0.05)
        XCTAssertEqual(segments[0].end, 103.8, accuracy: 0.05)
    }

    /// A recording of an empty room has no contrast, and inventing a threshold inside its
    /// dither would label the entire session as speech.
    func testSilentTrackDerivesNoSpeech() {
        var stream = EnvelopeStream()
        stream.append(seconds: 5, rms: 0.0015)
        stream.append(seconds: 5, rms: 0.0022)
        XCTAssertNil(EnvelopeLabelDeriver.thresholds(for: stream.samples))
        XCTAssertTrue(EnvelopeLabelDeriver.segments(from: stream.samples).isEmpty)
        XCTAssertTrue(EnvelopeLabelDeriver.segments(from: []).isEmpty)
    }

    func testMergeJoinsOnlyGapsBelowTheMinimum() {
        let segments = [
            ReplaySpeechSegment(start: 0, end: 1),
            ReplaySpeechSegment(start: 1.2, end: 2),
            ReplaySpeechSegment(start: 3, end: 4),
        ]
        XCTAssertEqual(
            EnvelopeLabelDeriver.merged(segments, minimumGapSeconds: 0.5),
            [ReplaySpeechSegment(start: 0, end: 2), ReplaySpeechSegment(start: 3, end: 4)]
        )
        XCTAssertEqual(
            EnvelopeLabelDeriver.merged(segments, minimumGapSeconds: 0.1), segments)
    }

    // MARK: - Interval evaluator

    func testPerfectOverlapScoresOne() {
        let truth = [ReplaySpeechSegment(start: 2, end: 5)]
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: truth, truth: truth,
            frameTimes: frames(from: 0, to: 10), tolerance: 0.2, duration: 10)
        XCTAssertEqual(metrics.precision, 1)
        XCTAssertEqual(metrics.recall, 1)
        XCTAssertEqual(metrics.f1, 1)
        XCTAssertEqual(metrics.falseActivations, 0)
        XCTAssertEqual(metrics.matchedSegments, 1)
        XCTAssertEqual(metrics.onsetLatencyMeanSeconds, 0)
    }

    func testMissedSegmentCostsRecallNotPrecision() {
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: [ReplaySpeechSegment(start: 2, end: 3)],
            truth: [
                ReplaySpeechSegment(start: 2, end: 3),
                ReplaySpeechSegment(start: 6, end: 7),
            ],
            frameTimes: frames(from: 0, to: 10), tolerance: 0.2, duration: 10)
        XCTAssertEqual(metrics.precision, 1)
        XCTAssertEqual(metrics.recall ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(metrics.matchedSegments, 1)
        XCTAssertEqual(metrics.falseActivations, 0)
    }

    func testSpuriousActivationCostsPrecisionAndIsCounted() {
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: [
                ReplaySpeechSegment(start: 2, end: 3),
                ReplaySpeechSegment(start: 8, end: 9),
            ],
            truth: [ReplaySpeechSegment(start: 2, end: 3)],
            frameTimes: frames(from: 0, to: 10), tolerance: 0.2, duration: 60)
        XCTAssertEqual(metrics.precision ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(metrics.recall, 1)
        XCTAssertEqual(metrics.falseActivations, 1)
        XCTAssertEqual(metrics.falseActivationsPerMinute ?? 0, 1, accuracy: 1e-9)
    }

    /// Frames just outside a true segment are excused up to `tolerance` and penalised
    /// beyond it — the edges of an utterance are approximate on both sides.
    func testEdgeSlackIsForgivenOnlyUpToTolerance() {
        let truth = [ReplaySpeechSegment(start: 2, end: 5)]
        let sloppy = [ReplaySpeechSegment(start: 2, end: 5.5)]
        let forgiven = SpeechIntervalEvaluator.evaluate(
            detected: sloppy, truth: truth,
            frameTimes: frames(from: 0, to: 10), tolerance: 1.0, duration: 10)
        XCTAssertEqual(forgiven.framesFalsePositive, 0)
        XCTAssertEqual(forgiven.precision, 1)

        let penalised = SpeechIntervalEvaluator.evaluate(
            detected: sloppy, truth: truth,
            frameTimes: frames(from: 0, to: 10), tolerance: 0.1, duration: 10)
        XCTAssertGreaterThan(penalised.framesFalsePositive, 0)
        XCTAssertLessThan(penalised.precision ?? 1, 1)
    }

    func testOnsetLatencyIsMeanedOverMatchedSegmentsOnly() {
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: [
                ReplaySpeechSegment(start: 2.4, end: 3),
                ReplaySpeechSegment(start: 6.8, end: 7),
            ],
            truth: [
                ReplaySpeechSegment(start: 2, end: 3),
                ReplaySpeechSegment(start: 6, end: 7),
                ReplaySpeechSegment(start: 20, end: 21),
            ],
            frameTimes: frames(from: 0, to: 25), tolerance: 0.5, duration: 25)
        XCTAssertEqual(metrics.matchedSegments, 2)
        XCTAssertEqual(metrics.onsetLatencyMeanSeconds ?? 0, 0.6, accuracy: 1e-9)
    }

    func testOneDetectionCannotAnswerTwoTrueSegments() {
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: [ReplaySpeechSegment(start: 2, end: 9)],
            truth: [
                ReplaySpeechSegment(start: 2, end: 4),
                ReplaySpeechSegment(start: 7, end: 9),
            ],
            frameTimes: frames(from: 0, to: 10), tolerance: 0.2, duration: 10)
        XCTAssertEqual(metrics.matchedSegments, 1)
        XCTAssertEqual(metrics.detectedSegments, 1)
        XCTAssertEqual(metrics.truthSegments, 2)
    }

    func testEmptyTruthAndEmptyDetectionLeaveMetricsUndefined() {
        let metrics = SpeechIntervalEvaluator.evaluate(
            detected: [], truth: [],
            frameTimes: frames(from: 0, to: 10), tolerance: 0.2, duration: 10)
        XCTAssertNil(metrics.precision)
        XCTAssertNil(metrics.recall)
        XCTAssertNil(metrics.f1)
        XCTAssertNil(metrics.onsetLatencyMeanSeconds)
        XCTAssertEqual(metrics.falseActivationsPerMinute, 0)
    }

    // MARK: - Detector runner

    func testRunnerFindsTheSpokenStretchAndNothingElse() {
        var stream = CaptureStream()
        stream.append(seconds: 2, jerk: 0.002)
        let speechStart = stream.time
        stream.append(seconds: 3, jerk: 0.05)
        let speechEnd = stream.time
        stream.append(seconds: 2, jerk: 0.002)

        let intervals = WearerSpeechReplayRunner.intervals(samples: stream.samples)
        XCTAssertEqual(intervals.count, 1)
        // Onset lags by the window fill plus the sustain gate; release lags by the hangover.
        XCTAssertGreaterThan(intervals[0].start, speechStart)
        XCTAssertLessThan(intervals[0].start, speechStart + 1.2)
        XCTAssertGreaterThan(intervals[0].end, speechEnd)
        XCTAssertLessThan(intervals[0].end, speechEnd + 1.2)
    }

    func testRunnerReportsNothingForAQuietCapture() {
        var stream = CaptureStream()
        stream.append(seconds: 8, jerk: 0.002)
        XCTAssertTrue(WearerSpeechReplayRunner.intervals(samples: stream.samples).isEmpty)
    }

    /// A capture that stops mid-utterance still detected it; the interval closes at the
    /// last sample rather than being discarded.
    func testRunnerClosesAnOpenIntervalAtTheLastSample() {
        var stream = CaptureStream()
        stream.append(seconds: 2, jerk: 0.002)
        stream.append(seconds: 3, jerk: 0.05)

        let intervals = WearerSpeechReplayRunner.intervals(samples: stream.samples)
        XCTAssertEqual(intervals.count, 1)
        XCTAssertEqual(intervals[0].end, stream.samples.last!.timestamp)
    }

    func testRunnerHonoursACalibratedConfig() {
        var stream = CaptureStream()
        stream.append(seconds: 2, jerk: 0.002)
        stream.append(seconds: 3, jerk: 0.05)
        stream.append(seconds: 2, jerk: 0.002)

        // A profile calibrated on a much louder wearer never sees this stream as speech.
        let deaf = WearerSpeechConfig(
            envelopeEnterThreshold: 0.5, envelopeExitThreshold: 0.4)
        XCTAssertTrue(
            WearerSpeechReplayRunner.intervals(samples: stream.samples, config: deaf).isEmpty)
    }

    // MARK: - Clock alignment

    /// Ground truth on a clock that disagrees with the IMU's is the failure mode a study
    /// cannot see by eye. Scoring the very same detection against a shifted envelope must
    /// visibly collapse the metrics, so a misalignment shows up as a bad number rather than
    /// as a plausible one.
    func testOffsettingTheEnvelopeClockDegradesTheMetrics() {
        var capture = CaptureStream()
        capture.append(seconds: 2, jerk: 0.002)
        let speechStart = capture.time
        capture.append(seconds: 3, jerk: 0.05)
        let speechEnd = capture.time
        capture.append(seconds: 2, jerk: 0.002)

        var envelope = EnvelopeStream()
        envelope.append(seconds: speechStart - 100, rms: 0.002)
        envelope.append(seconds: speechEnd - speechStart, rms: 0.08)
        envelope.append(seconds: 2, rms: 0.002)

        let detected = WearerSpeechReplayRunner.intervals(samples: capture.samples)
        let frameTimes = capture.samples.map(\.timestamp)
        func score(offset: TimeInterval) -> SpeechIntervalMetrics {
            SpeechIntervalEvaluator.evaluate(
                detected: detected,
                truth: EnvelopeLabelDeriver.segments(from: envelope.shifted(by: offset)),
                frameTimes: frameTimes, tolerance: 0.5, duration: 7)
        }

        let aligned = score(offset: 0)
        let skewed = score(offset: 3.0)
        XCTAssertGreaterThan(aligned.f1 ?? 0, 0.7)
        XCTAssertLessThan(skewed.f1 ?? 1, (aligned.f1 ?? 0) / 2)
        XCTAssertGreaterThan(skewed.framesFalsePositive, 0)
        XCTAssertGreaterThan(skewed.framesFalseNegative, 0)
    }
}
