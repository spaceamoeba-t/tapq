import XCTest
import AVFoundation
@testable import TapQAppleAdapters

/// The wake listener's level line is only as good as the meter behind it: silence must read
/// as silence and a full-scale sample as full scale, in both sample formats the input node
/// can hand over, or the diagnostic would misreport the very case it exists for.
final class AudioLevelMeterTests: XCTestCase {
    private func floatBuffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.floatChannelData![0][index] = sample }
        return buffer
    }

    private func int16Buffer(_ samples: [Int16]) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() { buffer.int16ChannelData![0][index] = sample }
        return buffer
    }

    func testSilenceReadsAsSilenceAndAFullScaleSampleAsZeroDecibels() throws {
        XCTAssertEqual(AudioLevelMeter.peak(of: try floatBuffer([0, 0, 0, 0])), 0)
        XCTAssertEqual(AudioLevelMeter.decibels(0), -120)
        XCTAssertEqual(AudioLevelMeter.peak(of: try floatBuffer([0.1, -1.0, 0.5])), 1.0)
        XCTAssertEqual(AudioLevelMeter.decibels(1.0), 0, accuracy: 0.001)
        XCTAssertEqual(AudioLevelMeter.decibels(0.1), -20, accuracy: 0.01)
    }

    func testInt16SamplesAreScaledToTheSameRange() throws {
        XCTAssertEqual(AudioLevelMeter.peak(of: try int16Buffer([0, 0])), 0)
        XCTAssertEqual(AudioLevelMeter.peak(of: try int16Buffer([100, Int16.max, -200])), 1.0,
                       accuracy: 0.0001)
        XCTAssertEqual(AudioLevelMeter.peak(of: try int16Buffer([Int16.min])), 1.0,
                       accuracy: 0.0001, "the one value abs() cannot take is still full scale")
    }

    func testDrainReportsTheIntervalsPeakAndCountThenStartsOver() throws {
        let meter = AudioLevelMeter()
        meter.note(try floatBuffer([0.2, -0.3]))
        meter.note(try floatBuffer([0.05]))
        let first = meter.drain()
        XCTAssertEqual(first.peak, 0.3, accuracy: 0.0001)
        XCTAssertEqual(first.buffers, 2)
        let second = meter.drain()
        XCTAssertEqual(second.peak, 0)
        XCTAssertEqual(second.buffers, 0)
    }
}
