import XCTest
import TapQContracts
import TapQDetectionBaseline
@testable import TapQCLI

/// Tier 1: generated traces are also `tapq replay` input.
///
/// No trace is checked in, so the guarantee that keeps them useful outside this suite is
/// that they survive the capture file format. If this fails, a trace can still be fed to
/// the pipeline in-process but can no longer be written out and replayed by hand.
@MainActor
final class CaptureTraceCompatibilityTests: XCTestCase {
    func testGeneratedTraceSurvivesCaptureJSONLAndReplaysIdentically() async throws {
        let trace = TraceGenerators.doubleNod()
        let jsonl = trace
            .map { MotionSampleFormatter.line(for: $0, format: .jsonl) }
            .joined(separator: "\n")

        let replayed = try MotionCaptureReader.samples(fromText: jsonl, format: .jsonl)

        XCTAssertEqual(replayed, trace, "capture JSONL must round-trip every sample field")
        XCTAssertEqual(Self.detections(in: trace), [.nod])
        XCTAssertEqual(Self.detections(in: replayed), Self.detections(in: trace),
                       "the replayed trace must reach the same detection as the live one")
    }

    private static func detections(in samples: [HeadMotionSample]) -> [HeadGesture] {
        var pipeline = MotionGesturePipeline()
        return samples.compactMap { pipeline.ingest($0).gesture }
    }
}
