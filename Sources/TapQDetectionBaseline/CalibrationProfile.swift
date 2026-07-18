import Foundation

/// Persisted nod/shake calibration. Tap calibration deliberately lives in a separate
/// document so either input can be recalibrated without invalidating the other.
public struct TapQGestureCalibrationProfile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let calibratedAt: Date
    public let config: HeadGestureConfig
    public let quality: GestureCalibrationQuality

    public init(
        schemaVersion: Int = currentSchemaVersion,
        calibratedAt: Date = Date(),
        config: HeadGestureConfig,
        quality: GestureCalibrationQuality
    ) {
        self.schemaVersion = schemaVersion
        self.calibratedAt = calibratedAt
        self.config = config
        self.quality = quality
    }
}

public struct GestureCalibrationQuality: Codable, Sendable, Equatable {
    public let restingSampleCount: Int
    public let nodSampleCount: Int
    public let shakeSampleCount: Int

    public init(
        restingSampleCount: Int,
        nodSampleCount: Int,
        shakeSampleCount: Int
    ) {
        self.restingSampleCount = restingSampleCount
        self.nodSampleCount = nodSampleCount
        self.shakeSampleCount = shakeSampleCount
    }
}

/// Persisted tap calibration. Aggregate peaks explain why a calibration was accepted
/// without retaining any raw motion samples.
public struct TapQTapCalibrationProfile: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let calibratedAt: Date
    public let config: TapConfig
    public let quality: TapCalibrationQuality

    public init(
        schemaVersion: Int = currentSchemaVersion,
        calibratedAt: Date = Date(),
        config: TapConfig,
        quality: TapCalibrationQuality
    ) {
        self.schemaVersion = schemaVersion
        self.calibratedAt = calibratedAt
        self.config = config
        self.quality = quality
    }
}

public struct TapCalibrationQuality: Codable, Sendable, Equatable {
    public let restingSampleCount: Int
    public let tapSampleCount: Int
    public let restingAccelerationPeak: Double
    public let tapAccelerationPeak: Double

    public init(
        restingSampleCount: Int,
        tapSampleCount: Int,
        restingAccelerationPeak: Double,
        tapAccelerationPeak: Double
    ) {
        self.restingSampleCount = restingSampleCount
        self.tapSampleCount = tapSampleCount
        self.restingAccelerationPeak = restingAccelerationPeak
        self.tapAccelerationPeak = tapAccelerationPeak
    }
}
