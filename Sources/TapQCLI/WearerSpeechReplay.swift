import Foundation
import TapQDetectionBaseline

/// A stretch of the capture's own timestamp clock during which the wearer was speaking —
/// either because a human labelled it, because the co-recorded microphone envelope was
/// loud there, or because `WearerSpeechDetector` said so.
///
/// Wearer speech is interval-valued, which is why it is evaluated by this file rather than
/// by `ReplayEvaluator`: a nod either happened at a moment or it did not, but speech is a
/// span whose edges are approximate on both sides. Folding it into `ReplayEventLabel`
/// would have forced an interval through an event-shaped evaluator whose consumed/tolerance
/// semantics are load-bearing for the existing gesture benchmarks.
struct ReplaySpeechSegment: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }

    /// True when `time` falls in the segment widened by `slack` on both edges.
    func contains(_ time: TimeInterval, slack: TimeInterval = 0) -> Bool {
        time >= start - slack && time <= end + slack
    }

    /// True when the two segments share any instant once both are widened by `slack`.
    func overlaps(_ other: ReplaySpeechSegment, slack: TimeInterval = 0) -> Bool {
        start - slack <= other.end + slack && other.start - slack <= end + slack
    }
}

/// A label file split into the two vocabularies it can carry.
struct ReplayLabelPartition: Equatable {
    let events: [ReplayLabelSegment]
    let speech: [ReplaySpeechSegment]
}

/// Reads a replay label file that may mix event labels with `wearer_speech` spans.
///
/// The event labels keep going through `ReplayLabelReader` untouched: label files written
/// before wearer speech existed parse byte-identically, and an unknown label that is *not*
/// `wearer_speech` still fails as `badLabelLine` rather than being silently dropped.
enum ReplaySpeechLabelReader {
    /// The one interval-valued label. Spelled exactly like
    /// `CalibrationProfileKind.wearerSpeech.rawValue`, so the on-disk vocabulary is one
    /// word everywhere in the milestone.
    static let speechLabel = "wearer_speech"

    static func partition(fromFileAt url: URL) throws -> ReplayLabelPartition {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw CaptureReadError.unreadable(url.path)
        }
        return try partition(fromText: text)
    }

    static func partition(fromText text: String) throws -> ReplayLabelPartition {
        let decoder = JSONDecoder()
        var speech: [ReplaySpeechSegment] = []
        // Speech lines are replaced by a blank placeholder rather than removed, so the
        // line numbers `ReplayLabelReader` reports on a malformed event line still name the
        // line the operator sees. A single space (not the empty string) survives the
        // reader's `split`, which omits empty subsequences, and is then skipped by its
        // whitespace guard.
        var eventLines: [String] = []

        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                eventLines.append(String(line))
                continue
            }
            let payload = Data(trimmed.utf8)
            guard let probe = try? decoder.decode(LabelProbe.self, from: payload),
                  probe.label == speechLabel else {
                eventLines.append(String(line))
                continue
            }
            let record: SpeechRecord
            do {
                record = try decoder.decode(SpeechRecord.self, from: payload)
            } catch {
                throw CaptureReadError.badLabelLine(index + 1, String(describing: error))
            }
            guard record.start <= record.end else {
                throw CaptureReadError.badLabelLine(index + 1, "start is after end")
            }
            speech.append(ReplaySpeechSegment(start: record.start, end: record.end))
            eventLines.append(" ")
        }

        let events = try ReplayLabelReader.segments(
            fromText: eventLines.joined(separator: "\n"))
        return ReplayLabelPartition(
            events: events, speech: speech.sorted { $0.start < $1.start })
    }

    private struct LabelProbe: Decodable {
        let label: String
    }

    private struct SpeechRecord: Decodable {
        let start: TimeInterval
        let end: TimeInterval
    }
}

/// How a microphone envelope track is turned into speech ground truth.
///
/// Every value here is study tooling, not runtime policy: the thresholds are relative to
/// the recording's own noise floor so one constant does not have to fit both a quiet room
/// and a noisy one, and the absolute guards below keep a *silent* recording from deriving
/// "speech" out of its own dither.
struct EnvelopeLabelDeriverConfig: Equatable, Sendable {
    /// Where between the noise floor and the loud reference a block starts counting as
    /// speech, and where it stops. Two fractions, so the derivation has hysteresis for the
    /// same reason the detector does: an envelope hovering at one threshold would otherwise
    /// shred a single utterance into dozens of segments.
    var enterFraction: Double
    var exitFraction: Double
    /// Quantiles of the track's RMS used as "the room" and "the wearer talking". Not min
    /// and max: one clipped block or one door slam would otherwise set the whole scale.
    var noiseFloorQuantile: Double
    var loudQuantile: Double
    /// A track whose loud reference is not at least this far above its noise floor is
    /// treated as containing no speech at all.
    var minimumContrast: Double
    /// Absolute floor under the derived enter threshold. Below this, RMS is silence on any
    /// normalised input, whatever the relative arithmetic says.
    var minimumEnterRMS: Double
    /// Segments closer together than this are merged — the pauses inside one utterance.
    var minimumGapSeconds: TimeInterval
    /// Merged segments shorter than this are dropped — a cough, a keystroke, a chair.
    var minimumSegmentSeconds: TimeInterval

    init(
        enterFraction: Double = 0.5,
        exitFraction: Double = 0.25,
        noiseFloorQuantile: Double = 0.2,
        loudQuantile: Double = 0.95,
        minimumContrast: Double = 0.01,
        minimumEnterRMS: Double = 0.01,
        minimumGapSeconds: TimeInterval = 0.3,
        minimumSegmentSeconds: TimeInterval = 0.2
    ) {
        self.enterFraction = enterFraction
        self.exitFraction = exitFraction
        self.noiseFloorQuantile = noiseFloorQuantile
        self.loudQuantile = loudQuantile
        self.minimumContrast = minimumContrast
        self.minimumEnterRMS = minimumEnterRMS
        self.minimumGapSeconds = minimumGapSeconds
        self.minimumSegmentSeconds = minimumSegmentSeconds
    }
}

/// Pure envelope-track → speech-truth derivation. Deterministic: the same track always
/// yields the same segments, because a metric whose ground truth moved between runs would
/// be worse than no metric.
enum EnvelopeLabelDeriver {
    struct Thresholds: Equatable {
        let noiseFloor: Double
        let loud: Double
        let enter: Double
        let exit: Double
    }

    /// nil when the track has no usable contrast — a silent recording has no speech in it,
    /// and inventing a threshold inside its noise would label the whole file as speech.
    static func thresholds(
        for samples: [MicEnvelopeSample],
        config: EnvelopeLabelDeriverConfig = .init()
    ) -> Thresholds? {
        guard !samples.isEmpty else { return nil }
        let levels = samples.map(\.rms).sorted()
        let noiseFloor = quantile(levels, config.noiseFloorQuantile)
        let loud = quantile(levels, config.loudQuantile)
        guard loud - noiseFloor >= config.minimumContrast else { return nil }
        let span = loud - noiseFloor
        return Thresholds(
            noiseFloor: noiseFloor,
            loud: loud,
            enter: max(config.minimumEnterRMS,
                       noiseFloor + config.enterFraction * span),
            // The absolute floor is halved for the exit threshold for the same reason the
            // relative one is lowered: leaving a segment must be harder than entering it.
            exit: max(config.minimumEnterRMS / 2,
                      noiseFloor + config.exitFraction * span)
        )
    }

    static func segments(
        from track: MicEnvelopeTrack,
        config: EnvelopeLabelDeriverConfig = .init()
    ) -> [ReplaySpeechSegment] {
        segments(from: track.samples, config: config)
    }

    static func segments(
        from samples: [MicEnvelopeSample],
        config: EnvelopeLabelDeriverConfig = .init()
    ) -> [ReplaySpeechSegment] {
        guard let thresholds = thresholds(for: samples, config: config) else { return [] }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }

        var raw: [ReplaySpeechSegment] = []
        var start: TimeInterval?
        var lastLoud: TimeInterval = 0
        for sample in ordered {
            if start == nil {
                if sample.rms >= thresholds.enter {
                    start = sample.timestamp
                    lastLoud = sample.timestamp
                }
            } else if sample.rms >= thresholds.exit {
                lastLoud = sample.timestamp
            } else {
                raw.append(ReplaySpeechSegment(start: start!, end: lastLoud))
                start = nil
            }
        }
        if let start { raw.append(ReplaySpeechSegment(start: start, end: lastLoud)) }

        return merged(raw, minimumGapSeconds: config.minimumGapSeconds)
            .filter { $0.duration >= config.minimumSegmentSeconds }
    }

    /// Joins segments separated by less than `minimumGapSeconds`. Input must be sorted by
    /// start, which every producer here guarantees.
    static func merged(
        _ segments: [ReplaySpeechSegment], minimumGapSeconds: TimeInterval
    ) -> [ReplaySpeechSegment] {
        var merged: [ReplaySpeechSegment] = []
        for segment in segments {
            if let last = merged.last, segment.start - last.end < minimumGapSeconds {
                merged[merged.count - 1] = ReplaySpeechSegment(
                    start: last.start, end: max(last.end, segment.end))
            } else {
                merged.append(segment)
            }
        }
        return merged
    }

    /// Nearest-rank quantile over an already sorted array.
    private static func quantile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = (Double(sorted.count - 1) * min(max(fraction, 0), 1)).rounded()
        return sorted[Int(position)]
    }
}

/// Streams a capture through `WearerSpeechDetector` and collects the spans it called
/// speech, stamped with the producing sample's capture timestamp — the same convention
/// `ReplayBackendRunner` uses for events.
enum WearerSpeechReplayRunner {
    static func intervals(
        samples: [HeadMotionSample],
        config: WearerSpeechConfig = .init()
    ) -> [ReplaySpeechSegment] {
        var detector = WearerSpeechDetector(config: config)
        var intervals: [ReplaySpeechSegment] = []
        var start: TimeInterval?
        for sample in samples {
            switch detector.ingestDetailed(sample).transition {
            case .startedSpeaking:
                start = sample.timestamp
            case .stoppedSpeaking:
                if let open = start {
                    intervals.append(
                        ReplaySpeechSegment(start: open, end: sample.timestamp))
                    start = nil
                }
            case nil:
                break
            }
        }
        // A capture that ends mid-utterance still detected that utterance; closing the
        // interval at the last sample is the only end the recording has evidence for.
        if let open = start, let last = samples.last {
            intervals.append(ReplaySpeechSegment(start: open, end: last.timestamp))
        }
        return intervals
    }
}

struct SpeechIntervalMetrics: Equatable {
    let framesTruePositive: Int
    let framesFalsePositive: Int
    let framesFalseNegative: Int
    let truthSegments: Int
    let detectedSegments: Int
    let matchedSegments: Int
    let falseActivations: Int
    /// Mean of (detected onset − truth onset) over matched segments; nil when nothing
    /// matched. Positive is late, which is the normal sign: the detector must see enough
    /// window to be sure.
    let onsetLatencyMeanSeconds: TimeInterval?
    let durationSeconds: TimeInterval

    var precision: Double? {
        let emitted = framesTruePositive + framesFalsePositive
        return emitted == 0 ? nil : Double(framesTruePositive) / Double(emitted)
    }

    var recall: Double? {
        let expected = framesTruePositive + framesFalseNegative
        return expected == 0 ? nil : Double(framesTruePositive) / Double(expected)
    }

    var f1: Double? {
        guard let precision, let recall, precision + recall > 0 else { return nil }
        return 2 * precision * recall / (precision + recall)
    }

    var falseActivationsPerMinute: Double? {
        durationSeconds > 0 ? Double(falseActivations) / (durationSeconds / 60) : nil
    }
}

/// Frame-level scoring of detected speech spans against truth spans.
///
/// Frames are the capture's own samples, so precision and recall are "what fraction of the
/// time was this right", which is the question a gating decision actually asks — a
/// segment-counting score would rate a detector that fires for 200 ms of a 10 s utterance
/// as perfect.
///
/// `tolerance` is edge slack, reusing replay's existing `--tolerance`: a frame the detector
/// claims within `tolerance` of a true segment is neither credited nor penalised, and the
/// same grace applies to true frames just outside a detected span. Onset latency is
/// reported separately precisely because that edge behaviour is excused here.
enum SpeechIntervalEvaluator {
    static func evaluate(
        detected: [ReplaySpeechSegment],
        truth: [ReplaySpeechSegment],
        frameTimes: [TimeInterval],
        tolerance: TimeInterval,
        duration: TimeInterval
    ) -> SpeechIntervalMetrics {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for time in frameTimes {
            let claimed = detected.contains { $0.contains(time) }
            let spoken = truth.contains { $0.contains(time) }
            if claimed, spoken {
                truePositive += 1
            } else if claimed {
                if !truth.contains(where: { $0.contains(time, slack: tolerance) }) {
                    falsePositive += 1
                }
            } else if spoken {
                if !detected.contains(where: { $0.contains(time, slack: tolerance) }) {
                    falseNegative += 1
                }
            }
        }

        // One detected span may answer at most one true segment, so a detector that fires
        // once for two adjacent utterances is not credited with both.
        var claimed = Set<Int>()
        var latencies: [TimeInterval] = []
        for segment in truth.sorted(by: { $0.start < $1.start }) {
            guard let index = detected.indices.first(where: {
                !claimed.contains($0) && detected[$0].overlaps(segment, slack: tolerance)
            }) else { continue }
            claimed.insert(index)
            latencies.append(detected[index].start - segment.start)
        }

        // A false activation is a detected span that answers no true segment at all.
        // Fragmentation — two spans inside one utterance — is not counted here; the
        // segment counts show it, and calling it a false activation would double-punish a
        // detector that was right about the utterance.
        let falseActivations = detected.filter { span in
            !truth.contains { $0.overlaps(span, slack: tolerance) }
        }.count

        return SpeechIntervalMetrics(
            framesTruePositive: truePositive,
            framesFalsePositive: falsePositive,
            framesFalseNegative: falseNegative,
            truthSegments: truth.count,
            detectedSegments: detected.count,
            matchedSegments: latencies.count,
            falseActivations: falseActivations,
            onsetLatencyMeanSeconds: latencies.isEmpty
                ? nil
                : latencies.reduce(0, +) / Double(latencies.count),
            durationSeconds: duration
        )
    }
}

/// Where a replay's wearer-speech ground truth came from. The value is reported verbatim
/// as the `truth_source` JSON key so a study run's provenance survives into its metrics.
enum WearerSpeechTruthSource: String, Equatable {
    case labels
    case micEnvelope = "mic_envelope"
}

/// Everything the wearer-speech section of a replay report needs.
struct WearerSpeechReplayReport: Equatable {
    let truthSource: WearerSpeechTruthSource
    let metrics: SpeechIntervalMetrics
}
