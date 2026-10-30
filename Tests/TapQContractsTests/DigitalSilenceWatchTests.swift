import Foundation
import TapQContracts
import XCTest

/// The watch that tells a recording its microphone is delivering nothing.
///
/// Every case is stated in chunks, because the bytes on the wire are the thing the watch
/// judges: the first version of this read the capture's float RMS instead and did not fire
/// on hardware — Apple's voice-processing unit emits near-zero floats that the converter
/// quantizes to exact zeros, so the level said "sound" about a payload that was silence.
///
/// Not `@MainActor`: the watch is a value and the owner is whoever holds it, so the suite
/// has no actor to be on.
final class DigitalSilenceWatchTests: XCTestCase {

    /// 2 bytes × 24 000 frames per second, so half a second is 24 000 bytes.
    ///
    /// The boundary cases below are written in halves rather than the tenths the capture
    /// actually delivers, because `silentFor` accumulates `Double`s and a tenth is not a
    /// binary fraction: fifty of them sum to 4.999999999999998, and a test written in
    /// tenths would be asserting the behaviour of that dust rather than of the watch. On
    /// real blocks the same dust can delay the trip by at most one block, which is the
    /// slack the type documents.
    private func chunk(seconds: Double,
                       silent: Bool = true,
                       format: VoiceAudioFormat = .pcm16Mono24k) -> VoiceAudioChunk {
        let count = Int((format.sampleRate * seconds).rounded()) * 2
        var bytes = [UInt8](repeating: 0, count: count)
        if !silent, !bytes.isEmpty {
            // One byte of one sample. A chunk is silent only when every byte is zero, so
            // the faintest thing the wire can carry has to be enough to reset the run.
            bytes[bytes.count / 2] = 1
        }
        return VoiceAudioChunk(data: Data(bytes), format: format, timestamp: 0)
    }

    func testTripsOnTheChunkThatReachesTheLimit() {
        var watch = DigitalSilenceWatch(limit: 5)
        for _ in 0..<9 {
            XCTAssertFalse(watch.observe(chunk(seconds: 0.5)), "4.5 s is not 5 s")
        }
        XCTAssertFalse(watch.tripped)
        XCTAssertTrue(watch.observe(chunk(seconds: 0.5)), "the tenth reaches the limit")
        XCTAssertTrue(watch.tripped)
    }

    func testOneNonzeroByteResetsTheRun() {
        var watch = DigitalSilenceWatch(limit: 5)
        for _ in 0..<9 { _ = watch.observe(chunk(seconds: 0.5)) }
        XCTAssertFalse(watch.observe(chunk(seconds: 0.5, silent: false)),
                       "a single nonzero byte is a room")
        XCTAssertEqual(watch.silentFor, 0)
        for _ in 0..<9 {
            XCTAssertFalse(watch.observe(chunk(seconds: 0.5)), "the run starts over")
        }
        XCTAssertTrue(watch.observe(chunk(seconds: 0.5)))
    }

    func testEmptyChunksNeitherCountNorReset() {
        var watch = DigitalSilenceWatch(limit: 5)
        for _ in 0..<9 { _ = watch.observe(chunk(seconds: 0.5)) }
        // No payload is no evidence — not that the room is quiet, and not that it is loud.
        XCTAssertFalse(watch.observe(chunk(seconds: 0)))
        XCTAssertEqual(watch.silentFor, 4.5, "the run neither grew nor reset")
        XCTAssertTrue(watch.observe(chunk(seconds: 0.5)), "and the next real chunk trips it")
    }

    func testANonPCM16ChunkIsIgnored() {
        // `durationSeconds` is nil for a payload whose length does not map to a duration
        // without decoding it, and a chunk that cannot say how long it is says nothing.
        let opaque = VoiceAudioFormat(sampleRate: 24_000, channels: 1, pcm16: false)
        var watch = DigitalSilenceWatch(limit: 5)
        for _ in 0..<9 { _ = watch.observe(chunk(seconds: 0.5)) }
        XCTAssertFalse(watch.observe(chunk(seconds: 10, format: opaque)))
        XCTAssertEqual(watch.silentFor, 4.5)
        XCTAssertTrue(watch.observe(chunk(seconds: 0.5)))
    }

    func testReturnsTrueOnceOnly() {
        var watch = DigitalSilenceWatch(limit: 5)
        for _ in 0..<9 { _ = watch.observe(chunk(seconds: 0.5)) }
        XCTAssertTrue(watch.observe(chunk(seconds: 0.5)))
        for _ in 0..<20 {
            XCTAssertFalse(watch.observe(chunk(seconds: 0.5)), "one report, not a stream")
        }
        XCTAssertFalse(watch.observe(chunk(seconds: 0.5, silent: false)))
        for _ in 0..<60 {
            XCTAssertFalse(watch.observe(chunk(seconds: 0.5)), "and never again after that")
        }
        XCTAssertTrue(watch.tripped)
    }

    func testSilentForReportsTheRun() {
        var watch = DigitalSilenceWatch(limit: 5)
        XCTAssertEqual(watch.silentFor, 0)
        _ = watch.observe(chunk(seconds: 0.1))
        _ = watch.observe(chunk(seconds: 0.2))
        XCTAssertEqual(watch.silentFor, 0.3, accuracy: 0.000_001)
        // Past the limit it keeps counting: the trip is reported once, the measurement of
        // how long the microphone has been dead stays true.
        for _ in 0..<100 { _ = watch.observe(chunk(seconds: 0.1)) }
        XCTAssertEqual(watch.silentFor, 10.3, accuracy: 0.000_001)
    }

    func testDefaultLimitIsFiveSeconds() {
        XCTAssertEqual(DigitalSilenceWatch.defaultLimit, 5)
        XCTAssertEqual(DigitalSilenceWatch().limit, DigitalSilenceWatch.defaultLimit)
    }
}
