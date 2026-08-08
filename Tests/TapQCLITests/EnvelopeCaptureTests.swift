import Foundation
import XCTest
@testable import TapQCLI

final class EnvelopeCaptureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tapq-envelope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Formatting

    func testMetaLineCarriesSchemaAndClock() {
        let line = EnvelopeSampleFormatter.metaLine(
            for: MicEnvelopeTrackMeta(sampleRate: 48_000, blockFrames: 1_024))
        XCTAssertEqual(
            line,
            #"{"block_frames":1024,"clock":"boottime","sample_rate":48000,"schema":"tapq-mic-envelope-v1"}"#
        )
    }

    func testSampleLineIsSortedJSONOnTheMotionClock() {
        let line = EnvelopeSampleFormatter.line(
            for: MicEnvelopeSample(timestamp: 12.5, rms: 0.25, peak: 0.5))
        XCTAssertEqual(line, #"{"peak":0.5,"rms":0.25,"timestamp":12.5}"#)
    }

    // MARK: - Reading

    func testWriterReaderRoundTrip() throws {
        let meta = MicEnvelopeTrackMeta(sampleRate: 44_100, blockFrames: 512)
        let samples = [
            MicEnvelopeSample(timestamp: 100.0, rms: 0.01, peak: 0.02),
            MicEnvelopeSample(timestamp: 100.0116, rms: 0.2, peak: 0.44),
            MicEnvelopeSample(timestamp: 100.0232, rms: 0.18, peak: 0.4),
        ]
        var lines = [EnvelopeSampleFormatter.metaLine(for: meta)]
        lines += samples.map(EnvelopeSampleFormatter.line(for:))

        let track = try EnvelopeTrackReader.track(fromText: lines.joined(separator: "\n"))

        XCTAssertEqual(track.meta, meta)
        XCTAssertEqual(track.samples, samples)
    }

    func testReaderRoundTripsThroughTheSidecarRecorder() async throws {
        let url = directory.appendingPathComponent("env.jsonl")
        let meta = MicEnvelopeTrackMeta(sampleRate: 48_000, blockFrames: 1_024)
        let recorder = try await MainActor.run { try EnvelopeSidecarRecorder(url: url, force: false) }
        await MainActor.run {
            recorder.writeTrack(meta)
            recorder.append(MicEnvelopeSample(timestamp: 1, rms: 0.5, peak: 0.75))
            recorder.append(MicEnvelopeSample(timestamp: 2, rms: 0.05, peak: 0.09))
            recorder.close()
        }

        let track = try EnvelopeTrackReader.track(fromFileAt: url)
        XCTAssertEqual(track.meta, meta)
        XCTAssertEqual(track.samples.count, 2)
        XCTAssertEqual(track.samples[1].peak, 0.09)
        await MainActor.run { XCTAssertEqual(recorder.sampleCount, 2) }
    }

    func testReaderSkipsBlankLinesAndAcceptsATrackWithNoSamples() throws {
        let meta = EnvelopeSampleFormatter.metaLine(
            for: MicEnvelopeTrackMeta(sampleRate: 16_000, blockFrames: 256))
        let track = try EnvelopeTrackReader.track(fromText: "\n" + meta + "\n\n")
        XCTAssertEqual(track.meta.sampleRate, 16_000)
        XCTAssertTrue(track.samples.isEmpty)
    }

    func testReaderRejectsAnUnknownSchema() throws {
        let text = #"{"block_frames":1024,"clock":"boottime","sample_rate":48000,"schema":"tapq-mic-envelope-v2"}"#
        XCTAssertThrowsError(try EnvelopeTrackReader.track(fromText: text)) { error in
            XCTAssertEqual(
                error as? EnvelopeTrackReadError,
                .unsupportedSchema("tapq-mic-envelope-v2")
            )
        }
    }

    func testReaderRejectsATrackWithoutItsHeaderLine() throws {
        let sample = EnvelopeSampleFormatter.line(
            for: MicEnvelopeSample(timestamp: 1, rms: 0.1, peak: 0.2))
        XCTAssertThrowsError(
            try EnvelopeTrackReader.track(fromText: sample, path: "/tmp/env.jsonl")
        ) { error in
            XCTAssertEqual(error as? EnvelopeTrackReadError, .missingMeta("/tmp/env.jsonl"))
        }
        XCTAssertThrowsError(try EnvelopeTrackReader.track(fromText: "")) { error in
            XCTAssertEqual(error as? EnvelopeTrackReadError, .missingMeta("<text>"))
        }
    }

    func testReaderReportsTheOffendingSampleLineNumber() throws {
        let text = [
            EnvelopeSampleFormatter.metaLine(
                for: MicEnvelopeTrackMeta(sampleRate: 48_000, blockFrames: 1_024)),
            EnvelopeSampleFormatter.line(
                for: MicEnvelopeSample(timestamp: 1, rms: 0.1, peak: 0.2)),
            #"{"timestamp":2,"rms":"loud"}"#,
        ].joined(separator: "\n")

        XCTAssertThrowsError(try EnvelopeTrackReader.track(fromText: text)) { error in
            guard case .badLine(let line, _)? = error as? EnvelopeTrackReadError else {
                return XCTFail("expected a bad-line error, got \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    func testReaderReportsAnUnreadablePath() throws {
        let missing = directory.appendingPathComponent("absent.jsonl")
        XCTAssertThrowsError(try EnvelopeTrackReader.track(fromFileAt: missing)) { error in
            XCTAssertEqual(error as? EnvelopeTrackReadError, .unreadable(missing.path))
        }
    }

    // MARK: - Recorder

    @MainActor
    func testRecorderRefusesToOverwriteWithoutForce() async throws {
        let url = directory.appendingPathComponent("env.jsonl")
        try Data("stale".utf8).write(to: url)

        XCTAssertThrowsError(try EnvelopeSidecarRecorder(url: url, force: false))

        let recorder = try EnvelopeSidecarRecorder(url: url, force: true)
        recorder.writeTrack(MicEnvelopeTrackMeta(sampleRate: 48_000, blockFrames: 1_024))
        recorder.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("stale"))
    }

    @MainActor
    func testRecorderDropsBlocksThatLandAfterClose() async throws {
        let url = directory.appendingPathComponent("env.jsonl")
        let recorder = try EnvelopeSidecarRecorder(url: url, force: false)
        recorder.writeTrack(MicEnvelopeTrackMeta(sampleRate: 48_000, blockFrames: 1_024))
        recorder.append(MicEnvelopeSample(timestamp: 1, rms: 0.1, peak: 0.2))
        recorder.close()

        // A block queued behind teardown must not reach a closed descriptor.
        recorder.append(MicEnvelopeSample(timestamp: 2, rms: 0.1, peak: 0.2))
        recorder.writeTrack(MicEnvelopeTrackMeta(sampleRate: 1, blockFrames: 1))
        recorder.close()

        XCTAssertEqual(recorder.sampleCount, 1)
        let track = try EnvelopeTrackReader.track(fromFileAt: url)
        XCTAssertEqual(track.samples.count, 1)
    }

    // MARK: - Errors

    func testCaptureErrorsExplainWhatSurvived() {
        XCTAssertTrue(
            TapQEnvelopeCaptureError.startFailed("engine_start: no input")
                .localizedDescription.contains("Nothing was recorded")
        )
        let truncated = TapQEnvelopeCaptureError
            .invalidated("configuration_changed: audio input route changed")
            .localizedDescription
        XCTAssertTrue(truncated.contains("truncated"))
        XCTAssertTrue(truncated.contains("motion capture finished"))
    }
}
