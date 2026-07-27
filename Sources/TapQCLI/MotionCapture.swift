import Foundation
import TapQDetectionBaseline

@MainActor public protocol TapQMotionCapturing: AnyObject {
    func capture(
        for duration: TimeInterval,
        onSample: @escaping @MainActor (HeadMotionSample) -> Void
    ) async throws
}

public enum TapQMotionCaptureError: Error, LocalizedError, Equatable {
    case unavailable
    case disconnected
    case noSamples

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Headphone motion capture is unavailable. On macOS, connect compatible AirPods and allow Motion access. Linux does not yet include a headphone acquisition adapter."
        case .disconnected:
            return "The headphone motion stream disconnected during capture."
        case .noSamples:
            return "The headphone motion stream started but produced no samples. Keep compatible AirPods connected, in-ear, and selected as the audio output."
        }
    }
}

/// Tracks whether a capture's most recent connection loss remained unresolved. CoreMotion
/// can emit transient disconnect/connect transitions while establishing its initial
/// reference attitude; any later valid sample proves that the stream recovered.
public struct MotionCaptureHealth: Equatable {
    public private(set) var receivedSample = false
    public private(set) var hasUnrecoveredLoss = false

    public init() {}

    public mutating func recordLoss() {
        hasUnrecoveredLoss = true
    }

    public mutating func recordSample() {
        receivedSample = true
        hasUnrecoveredLoss = false
    }

    public var failure: TapQMotionCaptureError? {
        if hasUnrecoveredLoss { return .disconnected }
        if !receivedSample { return .noSamples }
        return nil
    }
}

enum MotionSampleFormatter {
    /// The original five columns keep their positions so existing capture tooling keeps
    /// working; per-axis columns are appended.
    static let csvHeader = "timestamp,pitch,yaw,acceleration_magnitude,rotation_magnitude,"
        + "roll,user_acceleration_x,user_acceleration_y,user_acceleration_z,"
        + "rotation_rate_x,rotation_rate_y,rotation_rate_z,gravity_x,gravity_y,gravity_z"

    static func line(for sample: HeadMotionSample, format: CaptureFormat) -> String {
        switch format {
        case .jsonl:
            let record = CaptureRecord(sample: sample)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(record),
                  let text = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return text
        case .csv:
            return [
                decimal(sample.timestamp),
                decimal(sample.pitch),
                decimal(sample.yaw),
                decimal(sample.accelerationMagnitude),
                decimal(sample.rotationMagnitude),
                decimal(sample.roll),
                decimal(sample.userAcceleration.x),
                decimal(sample.userAcceleration.y),
                decimal(sample.userAcceleration.z),
                decimal(sample.rotationRate.x),
                decimal(sample.rotationRate.y),
                decimal(sample.rotationRate.z),
                decimal(sample.gravity.x),
                decimal(sample.gravity.y),
                decimal(sample.gravity.z),
            ].joined(separator: ",")
        }
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private struct CaptureRecord: Encodable {
        let timestamp: TimeInterval
        let pitch: Double
        let yaw: Double
        let roll: Double
        let accelerationMagnitude: Double
        let rotationMagnitude: Double
        let userAccelerationX: Double
        let userAccelerationY: Double
        let userAccelerationZ: Double
        let rotationRateX: Double
        let rotationRateY: Double
        let rotationRateZ: Double
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double

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

        init(sample: HeadMotionSample) {
            timestamp = sample.timestamp
            pitch = sample.pitch
            yaw = sample.yaw
            roll = sample.roll
            accelerationMagnitude = sample.accelerationMagnitude
            rotationMagnitude = sample.rotationMagnitude
            userAccelerationX = sample.userAcceleration.x
            userAccelerationY = sample.userAcceleration.y
            userAccelerationZ = sample.userAcceleration.z
            rotationRateX = sample.rotationRate.x
            rotationRateY = sample.rotationRate.y
            rotationRateZ = sample.rotationRate.z
            gravityX = sample.gravity.x
            gravityY = sample.gravity.y
            gravityZ = sample.gravity.z
        }
    }
}

enum CaptureOutputError: Error, LocalizedError, Equatable {
    case alreadyExists(String)
    case cannotCreate(String)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let path):
            return "Capture output already exists at \(path). Use --force to replace it."
        case .cannotCreate(let path):
            return "Could not create capture output at \(path)."
        }
    }
}

final class CaptureFileWriter {
    private let handle: FileHandle

    init(url: URL, format: CaptureFormat, force: Bool) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            guard force else { throw CaptureOutputError.alreadyExists(url.path) }
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw CaptureOutputError.cannotCreate(url.path)
        }
        handle = try FileHandle(forWritingTo: url)
        if format == .csv {
            write(MotionSampleFormatter.csvHeader)
        }
    }

    func write(_ line: String) {
        handle.write(Data((line + "\n").utf8))
    }

    func close() throws {
        try handle.close()
    }

    deinit {
        try? handle.close()
    }
}
