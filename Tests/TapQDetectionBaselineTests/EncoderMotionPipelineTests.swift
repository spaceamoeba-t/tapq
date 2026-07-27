import XCTest
@testable import TapQDetectionBaseline
import TapQContracts

/// Returns scripted scores window-by-window; quiet once the script runs out.
private final class ScriptedScorer: MotionWindowScoring {
    private(set) var callCount = 0
    private let script: [GestureScores]

    init(_ script: [GestureScores]) {
        self.script = script
    }

    func score(_ window: EncoderInputWindow) throws -> GestureScores {
        defer { callCount += 1 }
        guard callCount < script.count else { return GestureScores(values: [.quiet: 1.0]) }
        return script[callCount]
    }
}

private struct FailingScorer: MotionWindowScoring {
    struct Failure: Error {}
    func score(_ window: EncoderInputWindow) throws -> GestureScores { throw Failure() }
}

/// Defaults: window 32, hop 8 at 25 Hz → windows end at samples 31, 39, 47, …;
/// agreement 2 → an atom lands on the second consecutive qualified window.
final class EncoderMotionPipelineTests: XCTestCase {
    private func sample(at time: TimeInterval) -> HeadMotionSample {
        HeadMotionSample(
            timestamp: time, pitch: 0, yaw: 0, roll: 0,
            userAcceleration: MotionVector(x: 0.01, y: 0, z: 0),
            rotationRate: .zero,
            gravity: MotionVector(x: 0, y: 0, z: -1)
        )
    }

    private func confident(_ gestureClass: GestureClass, _ probability: Float = 0.9) -> GestureScores {
        GestureScores(values: [gestureClass: probability])
    }

    private func run(
        _ pipeline: inout EncoderMotionPipeline, samples: Int
    ) -> [(index: Int, result: MotionDetectionResult)] {
        var events: [(Int, MotionDetectionResult)] = []
        for index in 0..<samples {
            let result = pipeline.ingest(sample(at: Double(index) * 0.04))
            if result != MotionDetectionResult() { events.append((index, result)) }
        }
        return events
    }

    func testTwoNodAtomsPairIntoOneNod() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.nod), confident(.nod), confident(.nod), confident(.nod),
            ])
        )
        let events = run(&pipeline, samples: 64)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].index, 55)
        XCTAssertEqual(events[0].result, MotionDetectionResult(gesture: .nod))
    }

    func testLoneNodAtomNeverEmits() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([confident(.nod), confident(.nod)])
        )
        XCTAssertTrue(run(&pipeline, samples: 120).isEmpty)
    }

    func testTwoShakeAtomsPairIntoOneShake() {
        // Deny is the most consequential command; it carries the same doubling
        // requirement as the heuristic backend.
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.shake), confident(.shake), confident(.shake), confident(.shake),
            ])
        )
        let events = run(&pipeline, samples: 64)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].index, 55)
        XCTAssertEqual(events[0].result, MotionDetectionResult(gesture: .shake))
    }

    func testLoneShakeAtomNeverDenies() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([confident(.shake), confident(.shake)])
        )
        XCTAssertTrue(run(&pipeline, samples: 120).isEmpty)
    }

    func testNodAfterShakeClearsThePendingShake() {
        // A nod between two shakes must not leave a half-formed deny armed.
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.shake), confident(.shake),
                confident(.nod), confident(.nod),
                confident(.shake), confident(.shake),
            ])
        )
        XCTAssertTrue(run(&pipeline, samples: 96).isEmpty)
    }

    func testStalePendingShakeExpires() {
        let quiet = GestureScores(values: [.quiet: 1.0])
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(
                [confident(.shake), confident(.shake)]
                    + Array(repeating: quiet, count: 5)
                    + Array(repeating: confident(.shake), count: 4)
            )
        )
        let events = run(&pipeline, samples: 112)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].index, 111)
        XCTAssertEqual(events[0].result, MotionDetectionResult(gesture: .shake))
    }

    func testTapAtomEmitsDirectly() {
        // A tap atom already carries the whole double-tap pattern.
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([confident(.tap), confident(.tap)])
        )
        let events = run(&pipeline, samples: 48)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].result, MotionDetectionResult(tap: .tap))
    }

    func testSwipeEmitsDirectly() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([confident(.swipeDown), confident(.swipeDown)])
        )
        let events = run(&pipeline, samples: 48)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].result, MotionDetectionResult(swipe: .swipeDown))
    }

    func testTiltAtomsPairSameDirection() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.tiltLeft), confident(.tiltLeft),
                confident(.tiltLeft), confident(.tiltLeft),
            ])
        )
        let events = run(&pipeline, samples: 64)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].result, MotionDetectionResult(tilt: .tiltLeft))
    }

    func testOppositeTiltReplacesPendingInsteadOfEmitting() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.tiltLeft), confident(.tiltLeft),
                confident(.tiltRight), confident(.tiltRight),
                confident(.tiltRight), confident(.tiltRight),
            ])
        )
        let events = run(&pipeline, samples: 80)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].index, 71)
        XCTAssertEqual(events[0].result, MotionDetectionResult(tilt: .tiltRight))
    }

    func testBelowThresholdNeverEmits() {
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(Array(repeating: confident(.shake, 0.6), count: 4))
        )
        XCTAssertTrue(run(&pipeline, samples: 64).isEmpty)
    }

    func testNarrowMarginNeverEmits() {
        let nearTie = GestureScores(values: [.nod: 0.8, .shake: 0.65])
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(Array(repeating: nearTie, count: 4))
        )
        XCTAssertTrue(run(&pipeline, samples: 64).isEmpty)
    }

    func testAlternatingWindowsNeverReachAgreement() {
        let quiet = GestureScores(values: [.quiet: 1.0])
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer([
                confident(.shake), quiet, confident(.shake), quiet,
                confident(.shake), quiet,
            ])
        )
        XCTAssertTrue(run(&pipeline, samples: 96).isEmpty)
    }

    func testEventDebounceSuppressesSustainedMotionThenRearms() {
        // Uses tap, which emits per atom, so the debounce is measured on its own
        // rather than through a pairing channel.
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(Array(repeating: confident(.tap), count: 6))
        )
        let events = run(&pipeline, samples: 72)
        // Windows 3–4 produce an atom 0.64 s after the first event — inside the 1 s
        // event debounce — so only windows 5–6 may fire again.
        XCTAssertEqual(events.map(\.index), [39, 71])
    }

    func testStalePendingNodExpiresBeforePairing() {
        let quiet = GestureScores(values: [.quiet: 1.0])
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(
                [confident(.nod), confident(.nod)]
                    + Array(repeating: quiet, count: 5)
                    + Array(repeating: confident(.nod), count: 4)
            )
        )
        let events = run(&pipeline, samples: 112)
        // The pending armed at 1.56 s expires (pair window 1.5 s) during the quiet
        // stretch; the third atom re-arms and only the fourth completes the pair.
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].index, 111)
        XCTAssertEqual(events[0].result, MotionDetectionResult(gesture: .nod))
    }

    func testScorerFailureIsContained() {
        var pipeline = EncoderMotionPipeline(scorer: FailingScorer())
        XCTAssertTrue(run(&pipeline, samples: 64).isEmpty)
    }

    func testMagnitudeOnlySamplesNeverReachTheScorer() {
        let scorer = ScriptedScorer([confident(.shake), confident(.shake)])
        var pipeline = EncoderMotionPipeline(scorer: scorer)
        for index in 0..<64 {
            let legacy = HeadMotionSample(
                timestamp: Double(index) * 0.04, pitch: 0, yaw: 0,
                accelerationMagnitude: 0.1, rotationMagnitude: 0.1
            )
            XCTAssertEqual(pipeline.ingest(legacy), MotionDetectionResult())
        }
        XCTAssertEqual(scorer.callCount, 0)
    }

    func testResetClearsPendingPairing() {
        // A pair window far beyond the test duration isolates reset from expiry: if the
        // pending armed before reset survived, the single post-reset atom would pair
        // with it and emit.
        var pipeline = EncoderMotionPipeline(
            scorer: ScriptedScorer(Array(repeating: confident(.nod), count: 6)),
            config: EncoderConfig(nodPairWindowSeconds: 10)
        )
        for index in 0..<48 {
            _ = pipeline.ingest(sample(at: Double(index) * 0.04))
        }
        pipeline.reset()
        var events = 0
        for index in 48..<120 {
            if pipeline.ingest(sample(at: Double(index) * 0.04)) != MotionDetectionResult() {
                events += 1
            }
        }
        XCTAssertEqual(events, 0)
    }
}
