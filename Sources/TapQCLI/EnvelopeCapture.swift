import Foundation

/// Hardware boundary for the capture study's microphone arm, sibling to
/// `TapQMotionCapturing`. The envelope track is *ground truth for a study recording*,
/// never a runtime input: it exists so a wearer-speech detector trained on the IMU can be
/// scored against something that actually heard the room.
///
/// Lifecycle brackets the motion capture — `start` before the IMU stream opens, `stop`
/// after it closes — so both tracks cover the same wall-clock span. `start` is
/// synchronous and throws: a study session whose label track never opened must fail
/// before any motion is recorded, not halfway through.
///
/// Implementations must call `onTrack` exactly once, before the first `onSample`. The
/// audio format is only known once the hardware hands over its first block, so the
/// sidecar's header line is written from that block rather than from `start`.
/// `stop` is idempotent: the capture command stops explicitly on the success path and
/// again from a `defer` that covers the throwing one.
@MainActor public protocol TapQAudioEnvelopeCapturing: AnyObject {
    func start(
        onTrack: @escaping @MainActor (MicEnvelopeTrackMeta) -> Void,
        onSample: @escaping @MainActor (MicEnvelopeSample) -> Void,
        onInvalidation: @escaping @MainActor (TapQEnvelopeCaptureError) -> Void
    ) throws
    func stop()
}

/// One audio block reduced to its loudness envelope. Raw audio is deliberately not
/// retained: the study needs to know *when* the wearer spoke, and an RMS/peak pair
/// answers that without recording what was said.
public struct MicEnvelopeSample: Equatable, Sendable {
    /// Seconds on the same boot clock as `HeadMotionSample.timestamp`, so the two tracks
    /// overlay directly without a second alignment step at analysis time.
    public let timestamp: TimeInterval
    public let rms: Double
    public let peak: Double

    public init(timestamp: TimeInterval, rms: Double, peak: Double) {
        self.timestamp = timestamp
        self.rms = rms
        self.peak = peak
    }
}

/// Header record for an envelope sidecar. Written as the file's first line so a reader
/// can reject a track from a future schema instead of misinterpreting its samples.
public struct MicEnvelopeTrackMeta: Equatable, Sendable {
    public static let schema = "tapq-mic-envelope-v1"
    /// Names the clock `MicEnvelopeSample.timestamp` is expressed in — the same
    /// seconds-since-boot clock CoreMotion stamps motion samples with.
    public static let clock = "boottime"

    public let sampleRate: Double
    /// Frames in the hardware's audio block, which is what sets the envelope's own
    /// sample rate (`sampleRate / blockFrames` envelope points per second).
    public let blockFrames: Int

    public init(sampleRate: Double, blockFrames: Int) {
        self.sampleRate = sampleRate
        self.blockFrames = blockFrames
    }
}

public enum TapQEnvelopeCaptureError: Error, LocalizedError, Equatable {
    case unavailable
    case startFailed(String)
    case invalidated(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Microphone envelope co-recording is unavailable. On macOS, allow Microphone access for tapq. Linux does not yet include an audio acquisition adapter."
        case .startFailed(let detail):
            return "Could not start microphone envelope capture: \(detail). Nothing was recorded — a study session without its label track is not worth keeping."
        case .invalidated(let detail):
            return "The microphone envelope track ended early (\(detail)). The motion capture finished and was written, but its envelope sidecar is truncated and covers only part of the session."
        }
    }
}

enum EnvelopeSampleFormatter {
    static func metaLine(for meta: MicEnvelopeTrackMeta) -> String {
        encode(MetaRecord(
            schema: MicEnvelopeTrackMeta.schema,
            clock: MicEnvelopeTrackMeta.clock,
            sampleRate: meta.sampleRate,
            blockFrames: meta.blockFrames
        ))
    }

    static func line(for sample: MicEnvelopeSample) -> String {
        encode(SampleRecord(timestamp: sample.timestamp, rms: sample.rms, peak: sample.peak))
    }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    fileprivate struct MetaRecord: Codable {
        let schema: String
        let clock: String
        let sampleRate: Double
        let blockFrames: Int

        enum CodingKeys: String, CodingKey {
            case schema, clock
            case sampleRate = "sample_rate"
            case blockFrames = "block_frames"
        }
    }

    fileprivate struct SampleRecord: Codable {
        let timestamp: TimeInterval
        let rms: Double
        let peak: Double
    }
}

struct MicEnvelopeTrack: Equatable {
    let meta: MicEnvelopeTrackMeta
    let samples: [MicEnvelopeSample]
}

enum EnvelopeTrackReadError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case missingMeta(String)
    case unsupportedSchema(String)
    case badLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "Could not read the microphone envelope track at \(path)."
        case .missingMeta(let path):
            return "The microphone envelope track at \(path) is missing its \(MicEnvelopeTrackMeta.schema) header line."
        case .unsupportedSchema(let found):
            return "Unsupported microphone envelope schema '\(found)'; this build reads \(MicEnvelopeTrackMeta.schema)."
        case .badLine(let line, let details):
            return "Could not parse microphone envelope line \(line): \(details)"
        }
    }
}

/// Reads an envelope sidecar back into portable values. Consumed by replay tooling; kept
/// free of AVFoundation so the portable graph still builds on Linux.
enum EnvelopeTrackReader {
    static func track(fromFileAt url: URL) throws -> MicEnvelopeTrack {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw EnvelopeTrackReadError.unreadable(url.path)
        }
        return try track(fromText: text, path: url.path)
    }

    static func track(fromText text: String, path: String = "<text>") throws -> MicEnvelopeTrack {
        let decoder = JSONDecoder()
        var meta: MicEnvelopeTrackMeta?
        var samples: [MicEnvelopeSample] = []

        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let payload = Data(trimmed.utf8)

            if meta == nil {
                guard let record = try? decoder.decode(
                    EnvelopeSampleFormatter.MetaRecord.self, from: payload
                ) else {
                    throw EnvelopeTrackReadError.missingMeta(path)
                }
                guard record.schema == MicEnvelopeTrackMeta.schema else {
                    throw EnvelopeTrackReadError.unsupportedSchema(record.schema)
                }
                meta = MicEnvelopeTrackMeta(
                    sampleRate: record.sampleRate,
                    blockFrames: record.blockFrames
                )
                continue
            }

            do {
                let record = try decoder.decode(
                    EnvelopeSampleFormatter.SampleRecord.self, from: payload)
                samples.append(MicEnvelopeSample(
                    timestamp: record.timestamp, rms: record.rms, peak: record.peak))
            } catch {
                throw EnvelopeTrackReadError.badLine(index + 1, String(describing: error))
            }
        }

        guard let meta else { throw EnvelopeTrackReadError.missingMeta(path) }
        return MicEnvelopeTrack(meta: meta, samples: samples)
    }
}

/// Owns the sidecar file for one capture. Writes lines in the order the capture source
/// delivers them — the source contract puts the header first — and stops accepting them
/// once closed, so a block that lands after teardown cannot reach a closed descriptor.
@MainActor final class EnvelopeSidecarRecorder {
    let url: URL
    private let writer: CaptureFileWriter
    private(set) var sampleCount = 0
    private var closed = false

    init(url: URL, force: Bool) throws {
        self.url = url
        // jsonl: the sidecar is line-delimited JSON regardless of the motion track's
        // format, because its header line has no CSV equivalent.
        self.writer = try CaptureFileWriter(url: url, format: .jsonl, force: force)
    }

    func writeTrack(_ meta: MicEnvelopeTrackMeta) {
        guard !closed else { return }
        writer.write(EnvelopeSampleFormatter.metaLine(for: meta))
    }

    func append(_ sample: MicEnvelopeSample) {
        guard !closed else { return }
        writer.write(EnvelopeSampleFormatter.line(for: sample))
        sampleCount += 1
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? writer.close()
    }
}
