import AVFoundation
import XCTest
@testable import TapQAppleAdapters
import TapQContracts

/// Cue synthesis and cue-engine lifecycle. Nothing here reaches audio hardware: the
/// waveform is arithmetic, and the engine is a recording fake in the shape of the one
/// `BackendAudioPlayback` uses.
@MainActor
final class AudioCueTests: XCTestCase {
    private final class RecordingSink: TapQDiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TapQDiagnosticEvent] = []

        func record(_ event: TapQDiagnosticEvent) {
            lock.lock()
            storage.append(event)
            lock.unlock()
        }

        var events: [TapQDiagnosticEvent] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// Records every scheduler call and hands completions back synchronously on demand.
    @MainActor
    private final class FakeScheduler: AudioPlaybackScheduling {
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var startedFormats: [(sampleRate: Double, channels: Int)] = []
        private(set) var scheduled: [AVAudioPCMBuffer] = []
        private var completions: [@MainActor () -> Void] = []

        var startResult: Result<Void, AudioPlaybackSchedulerFailure> = .success(())
        var scheduleResult: Result<Void, AudioPlaybackSchedulerFailure> = .success(())

        var onConfigurationChange: (@MainActor () -> Void)?

        func start(
            sampleRate: Double, channels: Int
        ) -> Result<Void, AudioPlaybackSchedulerFailure> {
            startCount += 1
            startedFormats.append((sampleRate, channels))
            return startResult
        }

        func schedule(
            _ buffer: AVAudioPCMBuffer, completion: @escaping @MainActor () -> Void
        ) -> Result<Void, AudioPlaybackSchedulerFailure> {
            if case .failure = scheduleResult { return scheduleResult }
            scheduled.append(buffer)
            completions.append(completion)
            return .success(())
        }

        func stop() -> Result<Void, AudioPlaybackSchedulerFailure> {
            stopCount += 1
            return .success(())
        }

        /// Fires the oldest outstanding completion, as the player node eventually would.
        func completeOldest() {
            guard !completions.isEmpty else { return XCTFail("no cue is outstanding") }
            completions.removeFirst()()
        }
    }

    // MARK: - Synthesis

    func testTheTwoCuesAreAudiblyDifferent() {
        let prompt = AudioCueSynthesizer.tones(for: .prompt)
        let notification = AudioCueSynthesizer.tones(for: .notification)

        XCTAssertEqual(prompt.count, 2, "the prompt cue rises across two tones")
        XCTAssertEqual(notification.count, 1, "the notification cue is a single flat tone")
        XCTAssertGreaterThan(prompt[1].frequency, prompt[0].frequency, "prompt rises")
        XCTAssertNotEqual(
            AudioCueSynthesizer.samples(for: .prompt),
            AudioCueSynthesizer.samples(for: .notification)
        )
    }

    func testEveryCueSynthesizesAudibleNonClippingAudio() throws {
        for kind in AudioCueKind.allCases {
            let samples = AudioCueSynthesizer.samples(for: kind)
            XCTAssertFalse(samples.isEmpty, "\(kind) produced no audio")
            let peak = try XCTUnwrap(samples.map { abs(Int($0)) }.max())
            XCTAssertGreaterThan(peak, 1_000, "\(kind) is inaudible")
            XCTAssertLessThan(
                peak,
                Int(Double(Int16.max) * AudioCueSynthesizer.amplitude) + 2,
                "\(kind) exceeds its declared amplitude"
            )
        }
    }

    func testCuesFadeInAndOutSoTheBurstEdgesDoNotClick() throws {
        for kind in AudioCueKind.allCases {
            let samples = AudioCueSynthesizer.samples(for: kind)
            XCTAssertEqual(samples.first, 0, "\(kind) starts at silence")
            XCTAssertEqual(samples.last, 0, "\(kind) ends at silence")
        }
    }

    func testCueLengthMatchesTheDeclaredToneDurations() throws {
        for kind in AudioCueKind.allCases {
            let expected = AudioCueSynthesizer.tones(for: kind).reduce(0) { total, tone in
                total
                    + Int((tone.duration * AudioCueSynthesizer.sampleRate).rounded())
                    + Int((tone.gapAfter * AudioCueSynthesizer.sampleRate).rounded())
            }
            XCTAssertEqual(AudioCueSynthesizer.samples(for: kind).count, expected)
            let buffer = try XCTUnwrap(AudioCueSynthesizer.buffer(for: kind))
            XCTAssertEqual(Int(buffer.frameLength), expected)
            XCTAssertEqual(buffer.format.channelCount, 1)
            XCTAssertEqual(buffer.format.sampleRate, AudioCueSynthesizer.sampleRate)
            XCTAssertEqual(buffer.format.commonFormat, .pcmFormatInt16)
        }
    }

    func testTheBufferCarriesTheSynthesizedSamples() throws {
        let samples = AudioCueSynthesizer.samples(for: .prompt)
        let buffer = try XCTUnwrap(AudioCueSynthesizer.buffer(for: .prompt))
        let channel = try XCTUnwrap(buffer.int16ChannelData)
        let copied = Array(UnsafeBufferPointer(start: channel[0], count: samples.count))
        XCTAssertEqual(copied, samples)
    }

    // MARK: - Engine lifecycle

    func testPlayingACueStartsAnEngineAndStopsItWhenTheCueDrains() {
        let scheduler = FakeScheduler()
        let cue = AudioCue(scheduler: scheduler)

        cue.play(.prompt)

        XCTAssertEqual(scheduler.startCount, 1)
        XCTAssertEqual(scheduler.startedFormats.first?.channels, 1)
        XCTAssertEqual(scheduler.startedFormats.first?.sampleRate,
                       AudioCueSynthesizer.sampleRate)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertTrue(cue.isPlaying)
        XCTAssertEqual(scheduler.stopCount, 0, "no engine stop while a cue is outstanding")

        scheduler.completeOldest()

        XCTAssertFalse(cue.isPlaying)
        XCTAssertEqual(scheduler.stopCount, 1, "no idle audio unit between cues")
    }

    func testOverlappingCuesShareOneEngineAndStopOnce() {
        let scheduler = FakeScheduler()
        let cue = AudioCue(scheduler: scheduler)

        cue.play(.prompt)
        cue.play(.notification)

        XCTAssertEqual(scheduler.startCount, 1)
        XCTAssertEqual(scheduler.scheduled.count, 2)

        scheduler.completeOldest()
        XCTAssertEqual(scheduler.stopCount, 0, "one cue is still outstanding")
        scheduler.completeOldest()
        XCTAssertEqual(scheduler.stopCount, 1)
    }

    func testASecondCueAfterADrainStartsAFreshEngine() {
        let scheduler = FakeScheduler()
        let cue = AudioCue(scheduler: scheduler)

        cue.play(.notification)
        scheduler.completeOldest()
        cue.play(.notification)

        XCTAssertEqual(scheduler.startCount, 2)
        XCTAssertEqual(scheduler.stopCount, 1)
    }

    func testAFailedEngineStartIsSilentNotFatal() {
        let scheduler = FakeScheduler()
        scheduler.startResult = .failure(AudioPlaybackSchedulerFailure(
            stage: .playbackEngineStart, detail: "no output device"))
        let sink = RecordingSink()
        let cue = AudioCue(scheduler: scheduler, diagnosticSink: sink)

        cue.play(.prompt)

        XCTAssertEqual(scheduler.scheduled.count, 0)
        XCTAssertFalse(cue.isPlaying)
        XCTAssertTrue(sink.events.contains { $0.name == "cue.unavailable" })
    }

    func testAFailedScheduleStopsTheEngineAndLeavesNothingOutstanding() {
        let scheduler = FakeScheduler()
        scheduler.scheduleResult = .failure(AudioPlaybackSchedulerFailure(
            stage: .playbackSchedule, detail: "engine not started"))
        let sink = RecordingSink()
        let cue = AudioCue(scheduler: scheduler, diagnosticSink: sink)

        cue.play(.prompt)

        XCTAssertFalse(cue.isPlaying)
        XCTAssertEqual(scheduler.stopCount, 1)
        XCTAssertTrue(sink.events.contains { $0.name == "cue.schedule_failed" })
    }

    func testAConfigurationChangeAbandonsTheCueAndTheNextOneRecovers() {
        let scheduler = FakeScheduler()
        let sink = RecordingSink()
        let cue = AudioCue(scheduler: scheduler, diagnosticSink: sink)
        cue.play(.prompt)

        scheduler.onConfigurationChange?()

        XCTAssertFalse(cue.isPlaying)
        XCTAssertEqual(scheduler.stopCount, 1)
        XCTAssertTrue(sink.events.contains { $0.name == "cue.configuration_changed" })

        cue.play(.notification)
        XCTAssertEqual(scheduler.startCount, 2, "the next cue gets a fresh engine")
    }

    func testAStaleCompletionCannotStopAnEngineStartedAfterIt() {
        let scheduler = FakeScheduler()
        let cue = AudioCue(scheduler: scheduler)
        cue.play(.prompt)
        cue.stop()
        XCTAssertEqual(scheduler.stopCount, 1)

        cue.play(.notification)
        scheduler.completeOldest()   // the abandoned first cue's completion

        XCTAssertTrue(cue.isPlaying, "the live cue is untouched by the stale completion")
        XCTAssertEqual(scheduler.stopCount, 1)
    }

    func testStopIsIdempotent() {
        let scheduler = FakeScheduler()
        let cue = AudioCue(scheduler: scheduler)
        cue.play(.prompt)

        cue.stop()
        cue.stop()

        XCTAssertEqual(scheduler.stopCount, 1)
        XCTAssertFalse(cue.isPlaying)
    }
}
