import Foundation
import TapQContracts
import TapQDetectionBaseline

/// Event vocabulary of replay evaluation: the user-visible commands a backend can emit.
/// Labels mark command-level expectations — a `nod` segment contains the full double
/// nod, a `shake` segment the full double shake, a `tap` segment the full double tap —
/// because that is what a wearer actually performs and what a backend is expected to
/// turn into exactly one event.
enum ReplayEventLabel: String, Codable, CaseIterable, Equatable {
    case nod
    case shake
    case tiltLeft = "tilt_left"
    case tiltRight = "tilt_right"
    case tap
    case swipeUp = "swipe_up"
    case swipeDown = "swipe_down"
}

struct ReplayEvent: Equatable {
    let time: TimeInterval
    let label: ReplayEventLabel
}

extension MotionDetectionResult {
    var replayLabels: [ReplayEventLabel] {
        var labels: [ReplayEventLabel] = []
        switch gesture {
        case .nod: labels.append(.nod)
        case .shake: labels.append(.shake)
        case nil: break
        }
        if tap != nil { labels.append(.tap) }
        switch tilt {
        case .tiltLeft: labels.append(.tiltLeft)
        case .tiltRight: labels.append(.tiltRight)
        case nil: break
        }
        switch swipe {
        case .swipeUp: labels.append(.swipeUp)
        case .swipeDown: labels.append(.swipeDown)
        case nil: break
        }
        return labels
    }
}

enum CaptureReadError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case unrecognizedFormat(String)
    case missingColumns(String)
    case badLine(Int, String)
    case badLabelLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path):
            return "Could not read capture input at \(path)."
        case .unrecognizedFormat(let path):
            return "Could not recognize the capture format of \(path). Pass --format jsonl or --format csv."
        case .missingColumns(let details):
            return "The CSV header is missing required columns: \(details)."
        case .badLine(let line, let details):
            return "Could not parse capture line \(line): \(details)"
        case .badLabelLine(let line, let details):
            return "Could not parse label line \(line): \(details)"
        }
    }
}

/// Reads `tapq capture` output — JSONL or CSV, per-axis or the magnitude-only layout
/// that predates per-axis capture — back into portable samples.
enum MotionCaptureReader {
    static func samples(
        fromFileAt url: URL, formatHint: CaptureFormat?
    ) throws -> [HeadMotionSample] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw CaptureReadError.unreadable(url.path)
        }
        let format = formatHint
            ?? inferFormat(text: text, pathExtension: url.pathExtension)
        guard let format else { throw CaptureReadError.unrecognizedFormat(url.path) }
        return try samples(fromText: text, format: format)
    }

    static func inferFormat(text: String, pathExtension: String) -> CaptureFormat? {
        switch pathExtension.lowercased() {
        case "jsonl", "json": return .jsonl
        case "csv": return .csv
        default: break
        }
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: true).first
        else { return nil }
        if first.hasPrefix("{") { return .jsonl }
        if first.hasPrefix("timestamp,") { return .csv }
        return nil
    }

    static func samples(fromText text: String, format: CaptureFormat) throws -> [HeadMotionSample] {
        switch format {
        case .jsonl: return try jsonlSamples(text)
        case .csv: return try csvSamples(text)
        }
    }

    private static func jsonlSamples(_ text: String) throws -> [HeadMotionSample] {
        let decoder = JSONDecoder()
        var samples: [HeadMotionSample] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                let record = try decoder.decode(
                    ReplayCaptureRecord.self, from: Data(trimmed.utf8))
                samples.append(record.sample)
            } catch {
                throw CaptureReadError.badLine(index + 1, String(describing: error))
            }
        }
        return samples
    }

    private static func csvSamples(_ text: String) throws -> [HeadMotionSample] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return [] }
        let header = lines.removeFirst().split(separator: ",").map(String.init)
        var column: [String: Int] = [:]
        for (index, name) in header.enumerated() { column[name] = index }

        let required = ["timestamp", "pitch", "yaw",
                        "acceleration_magnitude", "rotation_magnitude"]
        let missing = required.filter { column[$0] == nil }
        guard missing.isEmpty else {
            throw CaptureReadError.missingColumns(missing.joined(separator: ", "))
        }
        let axisColumns = ["roll",
                           "user_acceleration_x", "user_acceleration_y", "user_acceleration_z",
                           "rotation_rate_x", "rotation_rate_y", "rotation_rate_z",
                           "gravity_x", "gravity_y", "gravity_z"]
        let hasAxisData = axisColumns.allSatisfy { column[$0] != nil }

        var samples: [HeadMotionSample] = []
        for (offset, line) in lines.enumerated() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map(String.init)
            func value(_ name: String) throws -> Double {
                guard let index = column[name], index < fields.count,
                      let parsed = Double(fields[index]) else {
                    throw CaptureReadError.badLine(offset + 2, "column '\(name)'")
                }
                return parsed
            }
            if hasAxisData {
                samples.append(HeadMotionSample(
                    timestamp: try value("timestamp"),
                    pitch: try value("pitch"),
                    yaw: try value("yaw"),
                    roll: try value("roll"),
                    userAcceleration: MotionVector(
                        x: try value("user_acceleration_x"),
                        y: try value("user_acceleration_y"),
                        z: try value("user_acceleration_z")),
                    rotationRate: MotionVector(
                        x: try value("rotation_rate_x"),
                        y: try value("rotation_rate_y"),
                        z: try value("rotation_rate_z")),
                    gravity: MotionVector(
                        x: try value("gravity_x"),
                        y: try value("gravity_y"),
                        z: try value("gravity_z"))
                ))
            } else {
                samples.append(HeadMotionSample(
                    timestamp: try value("timestamp"),
                    pitch: try value("pitch"),
                    yaw: try value("yaw"),
                    accelerationMagnitude: try value("acceleration_magnitude"),
                    rotationMagnitude: try value("rotation_magnitude")
                ))
            }
        }
        return samples
    }

    /// Decoding mirror of `MotionSampleFormatter.CaptureRecord`; per-axis keys are
    /// optional so magnitude-only captures from before per-axis capture still replay.
    private struct ReplayCaptureRecord: Decodable {
        let timestamp: TimeInterval
        let pitch: Double
        let yaw: Double
        let roll: Double?
        let accelerationMagnitude: Double
        let rotationMagnitude: Double
        let userAccelerationX: Double?
        let userAccelerationY: Double?
        let userAccelerationZ: Double?
        let rotationRateX: Double?
        let rotationRateY: Double?
        let rotationRateZ: Double?
        let gravityX: Double?
        let gravityY: Double?
        let gravityZ: Double?

        enum CodingKeys: String, CodingKey {
            case timestamp, pitch, yaw, roll
            case accelerationMagnitude = "acceleration_magnitude"
            case rotationMagnitude = "rotation_magnitude"
            case userAccelerationX = "user_acceleration_x"
            case userAccelerationY = "user_acceleration_y"
            case userAccelerationZ = "user_acceleration_z"
            case rotationRateX = "rotation_rate_x"
            case rotationRateY = "rotation_rate_y"
            case rotationRateZ = "rotation_rate_z"
            case gravityX = "gravity_x"
            case gravityY = "gravity_y"
            case gravityZ = "gravity_z"
        }

        var sample: HeadMotionSample {
            if let roll,
               let uax = userAccelerationX, let uay = userAccelerationY,
               let uaz = userAccelerationZ,
               let rrx = rotationRateX, let rry = rotationRateY, let rrz = rotationRateZ,
               let gx = gravityX, let gy = gravityY, let gz = gravityZ {
                return HeadMotionSample(
                    timestamp: timestamp, pitch: pitch, yaw: yaw, roll: roll,
                    userAcceleration: MotionVector(x: uax, y: uay, z: uaz),
                    rotationRate: MotionVector(x: rrx, y: rry, z: rrz),
                    gravity: MotionVector(x: gx, y: gy, z: gz)
                )
            }
            return HeadMotionSample(
                timestamp: timestamp, pitch: pitch, yaw: yaw,
                accelerationMagnitude: accelerationMagnitude,
                rotationMagnitude: rotationMagnitude
            )
        }
    }
}

/// One expected command in a labeled capture: the wearer performed `label` between
/// `start` and `end`, in the capture's own timestamp clock.
struct ReplayLabelSegment: Decodable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let label: ReplayEventLabel
}

enum ReplayLabelReader {
    static func segments(fromFileAt url: URL) throws -> [ReplayLabelSegment] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            throw CaptureReadError.unreadable(url.path)
        }
        return try segments(fromText: text)
    }

    static func segments(fromText text: String) throws -> [ReplayLabelSegment] {
        let decoder = JSONDecoder()
        var segments: [ReplayLabelSegment] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                let segment = try decoder.decode(
                    ReplayLabelSegment.self, from: Data(trimmed.utf8))
                guard segment.start <= segment.end else {
                    throw CaptureReadError.badLabelLine(index + 1, "start is after end")
                }
                segments.append(segment)
            } catch let error as CaptureReadError {
                throw error
            } catch {
                throw CaptureReadError.badLabelLine(index + 1, String(describing: error))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }
}

struct ReplayLabelMetrics: Equatable {
    let label: ReplayEventLabel
    let truePositives: Int
    let falseNegatives: Int
    let falsePositives: Int

    var precision: Double? {
        let emitted = truePositives + falsePositives
        return emitted == 0 ? nil : Double(truePositives) / Double(emitted)
    }

    var recall: Double? {
        let expected = truePositives + falseNegatives
        return expected == 0 ? nil : Double(truePositives) / Double(expected)
    }
}

struct ReplayReport: Equatable {
    let metrics: [ReplayLabelMetrics]
    let durationSeconds: TimeInterval

    var falsePositives: Int { metrics.reduce(0) { $0 + $1.falsePositives } }
    var falsePositivesPerMinute: Double? {
        durationSeconds > 0 ? Double(falsePositives) / (durationSeconds / 60) : nil
    }
}

enum ReplayEvaluator {
    /// A segment is satisfied by the first same-label event inside
    /// [start, end + tolerance] — commands complete (and therefore emit) after the
    /// motion ends. Extra same-segment events are double fires and count as false
    /// positives, as does any event no segment claims.
    static func evaluate(
        events: [ReplayEvent],
        segments: [ReplayLabelSegment],
        tolerance: TimeInterval,
        duration: TimeInterval
    ) -> ReplayReport {
        let ordered = events.sorted { $0.time < $1.time }
        var consumed = Array(repeating: false, count: ordered.count)
        var truePositives: [ReplayEventLabel: Int] = [:]
        var falseNegatives: [ReplayEventLabel: Int] = [:]

        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let match = ordered.indices.first { index in
                !consumed[index]
                    && ordered[index].label == segment.label
                    && ordered[index].time >= segment.start
                    && ordered[index].time <= segment.end + tolerance
            }
            if let match {
                consumed[match] = true
                truePositives[segment.label, default: 0] += 1
            } else {
                falseNegatives[segment.label, default: 0] += 1
            }
        }

        var falsePositives: [ReplayEventLabel: Int] = [:]
        for (index, event) in ordered.enumerated() where !consumed[index] {
            falsePositives[event.label, default: 0] += 1
        }

        let metrics = ReplayEventLabel.allCases.compactMap { label -> ReplayLabelMetrics? in
            let tp = truePositives[label] ?? 0
            let fn = falseNegatives[label] ?? 0
            let fp = falsePositives[label] ?? 0
            guard tp + fn + fp > 0 else { return nil }
            return ReplayLabelMetrics(
                label: label, truePositives: tp, falseNegatives: fn, falsePositives: fp)
        }
        return ReplayReport(metrics: metrics, durationSeconds: duration)
    }
}

/// Streams a capture through a detection backend and collects emitted events, stamped
/// with the producing sample's capture timestamp.
enum ReplayBackendRunner {
    /// Heuristic backend. Swipe detection is force-enabled: replay exists to evaluate
    /// channels offline, including experimental ones that ship disabled.
    static func heuristicEvents(
        samples: [HeadMotionSample],
        gestureConfig: HeadGestureConfig,
        tapConfig: TapConfig,
        tiltConfig: TiltConfig = .init(),
        swipeConfig: SwipeConfig = .init()
    ) -> [ReplayEvent] {
        var pipeline = MotionGesturePipeline(
            config: gestureConfig,
            tapConfig: tapConfig,
            tiltConfig: tiltConfig,
            swipeConfig: swipeConfig,
            swipeDetectionEnabled: true
        )
        return run(samples: samples) { pipeline.ingest($0) }
    }

    static func encoderEvents(
        samples: [HeadMotionSample],
        scorer: any MotionWindowScoring,
        config: EncoderConfig = .init()
    ) -> [ReplayEvent] {
        var pipeline = EncoderMotionPipeline(scorer: scorer, config: config)
        return run(samples: samples) { pipeline.ingest($0) }
    }

    private static func run(
        samples: [HeadMotionSample],
        ingest: (HeadMotionSample) -> MotionDetectionResult
    ) -> [ReplayEvent] {
        var events: [ReplayEvent] = []
        for sample in samples {
            for label in ingest(sample).replayLabels {
                events.append(ReplayEvent(time: sample.timestamp, label: label))
            }
        }
        return events
    }
}
